// Grapheion — mesh-synced corrective-maintenance approval chain (POC).
//
// Each device logs in as one role. A technician originates a job; it climbs the
// on-ship approval ladder (WCS -> LPO -> DIVO), is worked by the work center,
// then climbs the close-out ladder (WCS -> LPO -> DIVO) before it's CLOSED. The
// off-ship Port Engineer is connected only when the DIVO raises a Technical
// Assistance (TA) request. Jobs + their audit log sync as peat documents; the
// next approver gets a "your turn" alert and the originator hears approve /
// return / close updates.

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Directory, NetworkInterface, InternetAddressType, Platform;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pointycastle/export.dart'
    show GCMBlockCipher, AESEngine, AEADParameters, KeyParameter;
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:peat_flutter/peat_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain/bulletin.dart';
import 'domain/casrep.dart';
import 'domain/chain.dart';
import 'domain/feedback.dart';
import 'domain/job.dart';
import 'domain/org.dart';
import 'domain/schedule.dart';
import 'domain/sked.dart';
import 'domain/watch.dart';
import 'mesh_store.dart';
import 'notifications.dart';

/// Payload for dragging a schedulable item (a PMS check or a job) onto a day.
typedef _SchedDrag = ({PmsCheck? check, Job? job});

// POC unit credentials: every grapheion node on the same LAN/relay with this
// app id + key forms one mesh ("the ship"). Replace the key for a real unit.
const _kAppId = 'grapheion';
// Synced collection names + the Peer model live in mesh_store.dart (kJobs, …).

// Kratos (god-mode) gate. Kratos is NOT a pickable role — it's unlocked by this
// secret (long-press the sign-in title) AND bound to the first device that
// claims it. CHANGE THIS before building the demo, and keep it to yourself.
const _kKratosPass = 'kratos-change-me-before-demo';

/// A peer is "online" if we've heard a presence beat from it within this window.
const _kOnlineWindowMs = 30 * 1000;

/// Peers not heard from within this window are dropped from the Connection list
/// (clears stale ghosts left by reinstalls that churned a device's node id).
const _kStaleWindowMs = 3 * 60 * 1000;

/// How long a shared join code stays valid (demo-grade — a leaked code expires).
const _kJoinTtlMs = 10 * 60 * 1000; // 10 min

// CRDT-over-BLE 0xAF frame format (matches the peat BleBridge wire format):
//   [0xAF][transport][collLen][collection][msgId:u32][fragIdx:u8][fragCount:u8][chunk]
// grapheion rides this in parallel with the Iroh path: each doc is broadcast as
// one logical message (fragmented if > _kBleChunk), payload = {i: docId, d: json}.
const _kBleTransport = 2;
const _kBleHdr = 6; // msgId(4) + fragIdx(1) + fragCount(1)
const _kBleChunk = 480;
const _kReasmTtlMs = 15000;
const _bleChannel = MethodChannel('peat/ble');
const _bleRxChannel = EventChannel('peat/ble_rx');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PeatFlutterNode.initialize();
  PeatNotifications.instance.init();
  final tm = (await SharedPreferences.getInstance()).getString('themeMode');
  // Dark by default (the Defense Unicorns look) unless the user chose light.
  grapheionThemeMode.value = tm == 'light' ? ThemeMode.light : ThemeMode.dark;
  runApp(const GrapheionApp());
}

// Defense Unicorns brand palette (from defenseunicorns.com): deep navy fields,
// electric-cyan accents/links, gold pill CTAs, an orange-red alert accent.
const _duNavy = Color(0xFF00153F); // deep navy — page background
const _duSurface = Color(0xFF021F49); // navy surface / cards
const _duBlue = Color(0xFF002D82); // brand royal blue (raised blocks)
const _duCyan = Color(0xFF1FDFFF); // electric cyan — accent / links / primary
const _duGold = Color(0xFFF2AB44); // amber/gold — CTA buttons
const _duGoldInk = Color(0xFF082935); // text on gold
const _duOrange = Color(0xFFE53600); // orange-red — alert / tertiary accent

final ColorScheme _duDark =
    ColorScheme.fromSeed(
      seedColor: _duCyan,
      brightness: Brightness.dark,
    ).copyWith(
      primary: _duCyan,
      onPrimary: _duNavy,
      secondary: _duGold,
      onSecondary: _duGoldInk,
      tertiary: _duOrange,
      onTertiary: Colors.white,
      surface: _duSurface,
      onSurface: Colors.white,
      surfaceContainerHighest: _duBlue,
      error: _duOrange,
    );

final ColorScheme _duLight =
    ColorScheme.fromSeed(
      seedColor: _duBlue,
      brightness: Brightness.light,
    ).copyWith(
      primary: _duBlue,
      onPrimary: Colors.white,
      secondary: _duGold,
      onSecondary: _duGoldInk,
      tertiary: _duOrange,
    );

/// App-wide theme mode. Dark by default to match the Defense Unicorns look;
/// toggled from the app bar and persisted.
final ValueNotifier<ThemeMode> grapheionThemeMode = ValueNotifier(
  ThemeMode.dark,
);

ThemeData _grapheionTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark ? _duDark : _duLight;
  // Base the fonts on a brightness-correct text theme so inherited text (e.g.
  // dropdown items/values) is light on dark, not the default near-black.
  final baseText = dark
      ? Typography.material2021().white
      : Typography.material2021().black;
  final inter = GoogleFonts.interTextTheme(baseText);
  // Teko (condensed display) for the big headings; Inter for everything else.
  TextStyle? teko(TextStyle? s) =>
      GoogleFonts.teko(textStyle: s, fontWeight: FontWeight.w600);
  final text = inter.copyWith(
    displayLarge: teko(inter.displayLarge),
    displayMedium: teko(inter.displayMedium),
    displaySmall: teko(inter.displaySmall),
    headlineLarge: teko(inter.headlineLarge),
    headlineMedium: teko(inter.headlineMedium),
    headlineSmall: teko(inter.headlineSmall),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: dark ? _duNavy : null,
    // Deep-navy app bar in both modes (the white header strip reads on it).
    appBarTheme: AppBarTheme(
      backgroundColor: _duNavy,
      foregroundColor: Colors.white,
      titleTextStyle: GoogleFonts.teko(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: Colors.white,
        letterSpacing: 0.5,
      ),
    ),
    // Gold pill CTAs (the DU button look).
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: _duGold,
        foregroundColor: _duGoldInk,
        shape: const StadiumBorder(),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: _duGold,
      foregroundColor: _duGoldInk,
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: scheme.primary),
    ),
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

/// Flip between light and dark (resolving `system` to the current brightness),
/// persisting the choice.
void toggleGrapheionTheme(BuildContext context) {
  final cur = grapheionThemeMode.value;
  final brightness = cur == ThemeMode.system
      ? MediaQuery.platformBrightnessOf(context)
      : (cur == ThemeMode.dark ? Brightness.dark : Brightness.light);
  final next = brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark;
  grapheionThemeMode.value = next;
  SharedPreferences.getInstance().then(
    (p) => p.setString('themeMode', next == ThemeMode.dark ? 'dark' : 'light'),
  );
}

/// Reusable app-bar action to toggle the theme.
Widget themeToggleButton(BuildContext context) => IconButton(
  onPressed: () => toggleGrapheionTheme(context),
  icon: Icon(
    Theme.of(context).brightness == Brightness.dark
        ? Icons.light_mode
        : Icons.dark_mode,
  ),
  tooltip: 'Toggle light / dark',
);

class GrapheionApp extends StatelessWidget {
  const GrapheionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: grapheionThemeMode,
      builder: (_, mode, __) => MaterialApp(
        title: 'Grapheion',
        theme: _grapheionTheme(Brightness.light),
        darkTheme: _grapheionTheme(Brightness.dark),
        themeMode: mode,
        home: const HomePage(),
      ),
    );
  }
}

/// How the Admin personnel roster is ordered.
enum _AdminSort { name, division, department }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  PeatFlutterNode? _node;
  // Synced domain state + the apply/query/notify logic live in the (testable,
  // node-free) MeshStore; the widget owns the node, BLE, onboarding and UI and
  // reads the store through these thin getters so the rest of the code is
  // unchanged.
  late final MeshStore _store = MeshStore(onNotify: _notify);
  Account? get _account => _store.account;
  String get _name => _store.name;
  Role? get _role => _store.role;
  String get _workcenter => _store.workcenter;
  Map<String, Account> get _accounts => _store.accounts;
  Map<String, Job> get _jobs => _store.jobs;
  Map<String, Casrep> get _casreps => _store.casreps;
  OrgChart get _org => _store.org;
  Map<String, List<JobEvent>> get _events => _store.events;
  Map<String, Peer> get _presence => _store.presence;
  Map<String, int> get _lastSeenMs => _store.lastSeenMs;
  String? get _pendingAccountId => _store.pendingAccountId;

  String? _error;
  bool _isMeshHost = false; // minted the key -> bootstraps the first admin
  int _peers = 0;
  int _feature = 0; // selected feature (CSMP/SKED/CASREP/…)
  bool _featureOpen = false; // narrow layout: is a feature open (vs the menu)
  int _watchDayOffset = 0; // watchbill: days from today
  String? _evolutionId; // watchbill: selected evolution (null = first)
  _AdminSort _adminSort = _AdminSort.name; // admin roster ordering
  final TextEditingController _adminSearchCtrl =
      TextEditingController(); // admin roster search
  String _dsSection = '1'; // duty-section tab: section a manager is viewing
  final TextEditingController _bulletinCtrl = TextEditingController();
  final ValueNotifier<int> _feedbackTick = ValueNotifier(
    0,
  ); // refreshes open feedback sheet

  // Mesh presence transports (node-derived; the peer set itself is in the store).
  final Map<String, TransportLink?> _transport = {};
  Timer? _presenceTimer;
  Timer? _tickTimer;
  String? _lanIp; // resolved LAN IP, for the join token's dial address
  // The mesh formation key. The DIVO mints one (the QR carries it); everyone
  // else must scan that QR to obtain it before they can start a node. No key =>
  // no mesh, so scanning the DIVO's QR is the only way in.
  String? _formationKey;

  // BLE bridge (CRDT-over-BLE, parallel to the Iroh path) — iOS/macOS only.
  StreamSubscription<dynamic>? _bleRxSub;
  bool _bleRunning = false;
  final Map<String, Map<int, Uint8List>> _reasm =
      {}; // "coll:msgId" -> fragments
  final Map<String, int> _reasmTs = {};
  int _gossipTick = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreIdentity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground: the mesh node was likely suspended by the
    // OS, so clear backoff, re-dial known peers, and pull immediately — so we
    // don't have to restart the app to catch changes made while we were away.
    if (state == AppLifecycleState.resumed) {
      final n = _node;
      if (n != null) {
        try {
          n.wakeReconnect();
        } catch (_) {}
      }
    }
  }

  String _genKey() {
    final r = Random.secure();
    return base64Encode(List<int>.generate(32, (_) => r.nextInt(256)));
  }

  String _randHex(int bytes) {
    final r = Random.secure();
    return List.generate(
      bytes,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Restore mesh membership + the last signed-in account on launch.
  Future<void> _restoreIdentity() async {
    final p = await SharedPreferences.getInstance();
    _formationKey = p.getString('formationKey');
    // A device that minted the key is the host (migration: an old DIVO install
    // that already hosts a mesh is treated as host so it can bootstrap admins).
    _isMeshHost =
        (p.getBool('isMeshHost') ?? false) ||
        (p.getString('role') == 'divo' && _formationKey != null);
    if (_isMeshHost) await p.setBool('isMeshHost', true);
    _store.pendingAccountId = p.getString('accountId');
    if (_formationKey != null) {
      await _startNode(); // node runs; _restoreAccount() fires after load
    } else {
      setState(() {}); // -> start screen (host a mesh / join one)
    }
  }

  /// Create a fresh mesh and become its host (mints the formation key).
  Future<void> _hostMesh() async {
    final p = await SharedPreferences.getInstance();
    _formationKey = _genKey();
    _isMeshHost = true;
    await p.setString('formationKey', _formationKey!);
    await p.setBool('isMeshHost', true);
    await _startNode(); // seeds the org chart, then -> bootstrap sign-in
  }

  /// Adopt [a] as the signed-in identity (role/name/work center derive from it).
  void _setAccount(Account a) {
    // Adopt the freshest synced copy if we have one. The sign-in list can hand
    // us a stale Account object (captured before an admin assigned a duty
    // section / role / work center), which would otherwise leave the live
    // identity behind what Admin already shows — e.g. "not assigned to a duty
    // section" even though the account is in section 1.
    final fresh = _store.accounts[a.id] ?? a;
    _store.account = fresh;
    _store.pendingAccountId = fresh.id;
    SharedPreferences.getInstance().then(
      (p) => p.setString('accountId', fresh.id),
    );
    _publishPresence();
    if (mounted) setState(() {});
  }

  /// Re-adopt the last account once it's present locally (after node load or a
  /// later sync).
  void _restoreAccount() {
    final id = _pendingAccountId;
    if (_account == null && id != null && _accounts.containsKey(id)) {
      _setAccount(_accounts[id]!);
    }
  }

  /// Admin action: create + sync a PIN-protected account.
  Account _createAccount({
    required String name,
    required String rate,
    required Role role,
    required String workcenterId,
    required String pin,
  }) {
    final id = 'acct-${DateTime.now().microsecondsSinceEpoch}-${_randHex(3)}';
    final salt = _randHex(16);
    final a = Account(
      id: id,
      name: name,
      rate: rate,
      role: role,
      workcenterId: workcenterId,
      pinSalt: salt,
      pinHash: hashPin(salt, pin),
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _accounts[id] = a;
    final json = jsonEncode(a.toJson());
    _node!.putRaw(kAccounts, id, json);
    _bleBroadcast(kAccounts, id, json);
    if (mounted) setState(() {});
    return a;
  }

  /// Unlock god-mode (Kratos): validate the passphrase, then claim Kratos on
  /// this device (binding it) or sign in if it's already this device's. Returns
  /// an error string, or null on success (signs in).
  String? _unlockKratos(String pass) {
    if (pass != _kKratosPass) return 'Incorrect passphrase.';
    final me = _store.myNodeId;
    if (me == null || me.isEmpty) return 'Node not ready — try again.';
    final existing = _accounts.values
        .where((a) => a.role == Role.kratos)
        .toList();
    if (existing.isNotEmpty) {
      final k = existing.first;
      if (k.boundNodeId == me) {
        _setAccount(k);
        return null;
      }
      return 'Kratos is bound to another device.';
    }
    // Claim Kratos on this device.
    final salt = _randHex(16);
    final a = Account(
      id: 'acct-kratos-${_randHex(8)}',
      name: 'Kratos',
      rate: '',
      role: Role.kratos,
      workcenterId: _org.workcenters.isNotEmpty
          ? _org.workcenters.keys.first
          : '',
      pinSalt: salt,
      pinHash: hashPin(
        salt,
        _randHex(8),
      ), // unused — access is passphrase+device
      boundNodeId: me,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _accounts[a.id] = a;
    final json = jsonEncode(a.toJson());
    _node!.putRaw(kAccounts, a.id, json);
    _bleBroadcast(kAccounts, a.id, json);
    _setAccount(a);
    return null;
  }

  /// Admin action: persist an edited account (e.g. adjusting a self-registered
  /// person's role / work center).
  void _updateAccount(Account a) {
    a.updatedAtMs = DateTime.now().millisecondsSinceEpoch; // newest wins on sync
    _accounts[a.id] = a;
    final json = jsonEncode(a.toJson());
    _node!.putRaw(kAccounts, a.id, json);
    _bleBroadcast(kAccounts, a.id, json);
    // If we edited our own account, mirror the change into the live identity.
    if (_account?.id == a.id) {
      _store.account = a;
    }
    if (mounted) setState(() {});
  }

  /// Admin migration: stamp every account with a fresh `updatedAtMs` and
  /// re-broadcast THIS device's copies, so this node's (authoritative) account
  /// data wins the last-write-wins race everywhere — pulling stragglers into
  /// convergence (e.g. pre-timestamp duty-section assignments stuck on an old
  /// device). Run from the node that holds the correct assignments.
  void _restampAllAccounts() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    for (final a in _store.accounts.values.toList()) {
      a.updatedAtMs = now;
      final json = jsonEncode(a.toJson());
      _node!.putRaw(kAccounts, a.id, json);
      _bleBroadcast(kAccounts, a.id, json);
      n++;
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Re-stamped $n account${n == 1 ? '' : 's'} — this device's data now wins sync",
          ),
        ),
      );
    }
  }

  void _confirmRestampAccounts() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Re-stamp all accounts?'),
        content: Text(
          "Pushes THIS device's ${_store.accounts.length} account records as the "
          'newest version across the mesh — the duty sections, roles, and work '
          'centers shown here will override stale copies on other devices.\n\n'
          'Use this from the node with the correct assignments (e.g. when an old '
          'device is showing the wrong/empty duty section).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _restampAllAccounts();
            },
            child: const Text('Re-stamp'),
          ),
        ],
      ),
    );
  }

  /// Sign out of the account but stay in the mesh (node + key live on).
  Future<void> _signOut() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('accountId');
    setState(() {
      _store.account = null;
      _store.pendingAccountId = null;
    });
  }

  /// Confirm, then wipe ALL mesh state on this device and return to the start
  /// screen — for spinning up a fresh mesh.
  Future<void> _confirmReset(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset this device?'),
        content: const Text(
          'Wipes the mesh key, every account, the org chart, and all jobs '
          'from THIS device, and returns to the start screen. Other devices '
          'keep their copy until you reset them too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (yes == true) await _resetDevice();
  }

  Future<void> _resetDevice() async {
    _presenceTimer?.cancel();
    _tickTimer?.cancel();
    _bleRxSub?.cancel();
    try {
      _node?.dispose();
    } catch (_) {}
    _node = null;
    _bleRunning = false;
    final p = await SharedPreferences.getInstance();
    await p.clear();
    try {
      final dir = await getApplicationSupportDirectory();
      final store = Directory('${dir.path}/grapheion');
      if (await store.exists()) await store.delete(recursive: true);
    } catch (_) {}
    _formationKey = null;
    _isMeshHost = false;
    _store.clear(); // jobs/events/accounts/casreps/org/presence + identity
    _transport.clear();
    _reasm.clear();
    _reasmTs.clear();
    if (mounted) setState(() {});
  }

  Future<void> _startNode() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final node = PeatFlutterNode.create(
        NodeConfig(
          appId: _kAppId,
          sharedKey: _formationKey!,
          bindAddress: null,
          storagePath: '${dir.path}/grapheion',
          transport: const TransportConfigFFI(
            enableBle: true, // BLE mesh for in-space handhelds (alongside Iroh)
            bleMeshId: null,
            blePowerProfile: 'balanced',
            transportPreference: null,
            collectionRoutesJson: null,
            enableN0Relay:
                true, // lets the off-ship Port Engineer reach the ship
          ),
        ),
      );
      node.startSync();
      _store.myNodeId =
          node.nodeId; // so the store skips our own presence beats
      node.subscribeChanges().listen(_onChange);
      _loadExisting(node);
      setState(() => _node = node);
      _seedOrgIfHost();
      _restoreAccount(); // re-adopt the last signed-in account if it's local
      // Announce ourselves and start the heartbeat; refresh transports + the
      // freshness display on a tick.
      _publishPresence();
      _refreshTransports();
      _resolveLanIp();
      _startBle();
      _presenceTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _publishPresence(),
      );
      _tickTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _refreshTransports();
        // Iroh catch-up: keep the reconnect roster fresh with everyone we're
        // actually connected to (incl. a hidden Kratos peer we never explicitly
        // "joined"), re-dial any that dropped (respects backoff), and pull the
        // latest from connected peers — so changes converge without an app
        // restart after the OS suspends us or a link goes idle.
        final n = _node;
        if (n != null) {
          try {
            for (final p in n.connectedPeers) {
              n.rememberPeer(groupId: _kAppId, nodeId: p, name: '');
            }
            n.reconnectKnownPeers();
          } catch (_) {}
        }
        // Periodic BLE catch-up gossip (every other tick ~10s): re-broadcast
        // jobs so a handheld that just came into range converges.
        if (_bleRunning && (_gossipTick++).isEven) {
          for (final job in _jobs.values) {
            _bleBroadcast(kJobs, job.id, jsonEncode(job.toJson()));
          }
          // Re-broadcast the small org chart so late BLE joiners converge.
          for (final d in _org.departments.values) {
            _bleBroadcast(kDepts, d.id, jsonEncode(d.toJson()));
          }
          for (final v in _org.divisions.values) {
            _bleBroadcast(kDivs, v.id, jsonEncode(v.toJson()));
          }
          for (final w in _org.workcenters.values) {
            _bleBroadcast(kWcs, w.id, jsonEncode(w.toJson()));
          }
          for (final a in _accounts.values) {
            _bleBroadcast(kAccounts, a.id, jsonEncode(a.toJson()));
          }
          for (final c in _casreps.values) {
            _bleBroadcast(kCasreps, c.id, jsonEncode(c.toJson()));
          }
          for (final p in _store.pmsChecks.values) {
            _bleBroadcast(kPmsChecks, p.id, jsonEncode(p.toJson()));
          }
          for (final s in _store.qualifications.values) {
            _bleBroadcast(kQualifications, s.id, jsonEncode(s.toJson()));
          }
          for (final q in _store.quals.values) {
            _bleBroadcast(kQuals, q.id, jsonEncode(q.toJson()));
          }
          for (final e in _store.evolutions.values) {
            _bleBroadcast(kEvolutions, e.id, jsonEncode(e.toJson()));
          }
          for (final a in _store.bill.values) {
            _bleBroadcast(kBill, a.id, jsonEncode(a.toJson()));
          }
          for (final b in _store.bulletin.values) {
            _bleBroadcast(kBulletin, b.id, jsonEncode(b.toJson()));
          }
          for (final w in _store.stood.values) {
            _bleBroadcast(kStood, w.id, jsonEncode(w.toJson()));
          }
          for (final e in _store.dutyEvents.values) {
            _bleBroadcast(kEvents, e.id, jsonEncode(e.toJson()));
          }
          for (final r in _store.routing.values) {
            _bleBroadcast(kRouting, r.id, jsonEncode(r.toJson()));
          }
          for (final f in _store.feedback.values) {
            _bleBroadcast(kFeedback, f.id, jsonEncode(f.toJson()));
          }
        }
        if (mounted) setState(() {});
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceTimer?.cancel();
    _tickTimer?.cancel();
    _bleRxSub?.cancel();
    super.dispose();
  }

  void _publishPresence() {
    final node = _node;
    if (node == null || _role == null) return; // no beat until signed in
    if (_isKratos) return; // god mode stays off the presence list
    final json = jsonEncode({
      'nodeId': node.nodeId,
      'name': _name,
      'role': _role!.token,
      'workcenter': _workcenter,
      'hb': DateTime.now().millisecondsSinceEpoch,
    });
    node.putRaw(kPresence, node.nodeId, json);
    _bleBroadcast(kPresence, node.nodeId, json);
  }

  void _refreshTransports() {
    final node = _node;
    if (node == null) return;
    _transport.clear();
    for (final s in node.peerTransportStates()) {
      _transport[s.peerId] = s.links.isNotEmpty ? s.links.first : null;
    }
  }

  // --- BLE bridge (CRDT-over-BLE; parallel to the Iroh path) ----------------

  static const _kBleNonce = 12; // AES-GCM nonce length
  static const _kBleTag = 16; // AES-GCM auth tag length

  /// Seal a BLE frame body with AES-256-GCM under the formation key →
  /// nonce(12) + ciphertext + tag. The nonce is SHA-256(body)[:12] — content-
  /// derived, so a re-broadcast of an unchanged doc is byte-identical (dedup /
  /// reassembly safe) and distinct docs never share a nonce. Gives both
  /// confidentiality and membership auth (a wrong key fails the GCM tag).
  Uint8List? _bleSeal(Uint8List key, Uint8List body) {
    try {
      final nonce = Uint8List.fromList(
        sha256.convert(body).bytes.sublist(0, _kBleNonce),
      );
      final c = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
        );
      final ct = c.process(body);
      final out = Uint8List(_kBleNonce + ct.length);
      out.setRange(0, _kBleNonce, nonce);
      out.setRange(_kBleNonce, out.length, ct);
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Open a sealed frame; null if the key is wrong or the frame was tampered.
  Uint8List? _bleOpen(Uint8List key, Uint8List wire) {
    if (wire.length < _kBleNonce + _kBleTag) return null;
    try {
      final nonce = Uint8List.sublistView(wire, 0, _kBleNonce);
      final ct = Uint8List.sublistView(wire, _kBleNonce);
      final c = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
        );
      return c.process(ct);
    } catch (_) {
      return null; // GCM auth failure: wrong key or tampered
    }
  }

  void _startBle() {
    final node = _node;
    if (node == null || _bleRunning) return;
    // Native BLE bridge exists on iOS/macOS (CoreBluetooth) and Android (Kotlin).
    if (!(Platform.isIOS || Platform.isMacOS || Platform.isAndroid)) return;
    try {
      // iOS/macOS take {nodeId, callsign}; Android ignores them (it reads the
      // node from the global handle).
      final bleNodeId = int.parse(node.nodeId.substring(0, 8), radix: 16);
      final args = {
        'nodeId': bleNodeId,
        'callsign': _name.isEmpty ? 'grapheion' : _name,
      };
      if (Platform.isAndroid) {
        // Android rejects startBle until the BLE runtime permissions are
        // granted — retry until it succeeds, then subscribe + mark running.
        _bleChannel
            .invokeMethod('startBle', args)
            .then((ok) {
              if (ok == true) {
                _bleRxSub = _bleRxChannel.receiveBroadcastStream().listen(
                  _onBleFrame,
                );
                _bleRunning = true;
                debugPrint(
                  '[BLE] android radio started — listening for frames',
                );
              } else if (mounted) {
                Future.delayed(const Duration(seconds: 3), _startBle);
              }
            })
            .catchError((_) {
              if (mounted)
                Future.delayed(const Duration(seconds: 3), _startBle);
            });
        return;
      }
      _bleChannel.invokeMethod('startBle', args).catchError((_) => null);
      _bleRxSub = _bleRxChannel.receiveBroadcastStream().listen(_onBleFrame);
      _bleRunning = true;
      debugPrint('[BLE] radio started — listening for frames');
    } catch (_) {}
  }

  /// Broadcast one document as a (possibly fragmented) 0xAF CRDT frame.
  void _bleBroadcast(String coll, String docId, String docJson) {
    final key = _formationKey;
    if (!_bleRunning || key == null) return;
    final collBytes = utf8.encode(coll);
    final body = Uint8List.fromList(
      utf8.encode(jsonEncode({'i': docId, 'd': docJson})),
    );
    // Encrypt + authenticate the frame with the formation key (AES-256-GCM):
    // only same-mesh nodes can decrypt, and it's confidential on the air.
    final payload = _bleSeal(base64Decode(key), body);
    if (payload == null) return;
    int msgId = 0x811c9dc5; // FNV over PLAINTEXT — stable across re-encryptions
    for (final b in body) {
      msgId = ((msgId ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    final fragCount = payload.isEmpty
        ? 1
        : ((payload.length + _kBleChunk - 1) ~/ _kBleChunk);
    for (var idx = 0; idx < fragCount; idx++) {
      final start = idx * _kBleChunk;
      final end = (start + _kBleChunk < payload.length)
          ? start + _kBleChunk
          : payload.length;
      final env = Uint8List(3 + collBytes.length + _kBleHdr + (end - start));
      env[0] = 0xAF;
      env[1] = _kBleTransport;
      env[2] = collBytes.length;
      env.setRange(3, 3 + collBytes.length, collBytes);
      final h = 3 + collBytes.length;
      env[h] = (msgId >> 24) & 0xFF;
      env[h + 1] = (msgId >> 16) & 0xFF;
      env[h + 2] = (msgId >> 8) & 0xFF;
      env[h + 3] = msgId & 0xFF;
      env[h + 4] = idx;
      env[h + 5] = fragCount;
      env.setRange(h + _kBleHdr, env.length, payload.sublist(start, end));
      // Android's bridge takes the bytes in a map under 'crdtTx'; Apple takes
      // the raw envelope on 'bleTx'.
      if (Platform.isAndroid) {
        _bleChannel
            .invokeMethod('crdtTx', {'bytes': env})
            .catchError((_) => null);
      } else {
        _bleChannel.invokeMethod('bleTx', env).catchError((_) => null);
      }
    }
  }

  void _onBleFrame(dynamic event) {
    if (event is! Uint8List || event.length < 3 || event[0] != 0xAF) return;
    final transport = event[1];
    final collLen = event[2];
    if (transport != _kBleTransport || event.length < 3 + collLen + _kBleHdr) {
      return;
    }
    final coll = utf8.decode(event.sublist(3, 3 + collLen));
    final frame = Uint8List.sublistView(event, 3 + collLen);
    final msgId =
        (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
    final wire = _reassemble(
      coll,
      msgId,
      frame[4],
      frame[5],
      Uint8List.sublistView(frame, _kBleHdr),
    );
    if (wire == null) return; // incomplete — await more fragments
    // Decrypt under OUR formation key; a wrong key / tamper fails the GCM tag.
    final key = _formationKey;
    if (key == null) return;
    final body = _bleOpen(base64Decode(key), wire);
    if (body == null) return; // not our mesh, or tampered -> drop
    try {
      final m = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final id = m['i'] as String;
      final docRaw = m['d'] as String;
      _store.applyDoc(coll, id, docRaw, remote: true, peer: null);
      if (coll == kFeedback) _feedbackTick.value++;
      _node?.putRaw(coll, id, docRaw); // persist + re-bridge over Iroh
      // Visibility for BLE testing — a grapheion doc just crossed over Bluetooth.
      if (coll == kJobs || coll == kLog) debugPrint('[BLE-RX] $coll · $id');
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// Reassemble a fragmented BLE message; full payload once all fragments are
  /// in, else null. Partial sets are evicted after a TTL.
  Uint8List? _reassemble(
    String coll,
    int msgId,
    int fragIdx,
    int fragCount,
    Uint8List chunk,
  ) {
    if (fragCount <= 1) return Uint8List.fromList(chunk);
    final key = '$coll:$msgId';
    final now = DateTime.now().millisecondsSinceEpoch;
    _reasmTs.removeWhere((k, t) {
      if (now - t <= _kReasmTtlMs) return false;
      _reasm.remove(k);
      return true;
    });
    final parts = _reasm.putIfAbsent(key, () => {});
    parts[fragIdx] = Uint8List.fromList(chunk);
    _reasmTs[key] = now;
    if (parts.length < fragCount) return null;
    final buf = BytesBuilder();
    for (var i = 0; i < fragCount; i++) {
      final p = parts[i];
      if (p == null) return null;
      buf.add(p);
    }
    _reasm.remove(key);
    _reasmTs.remove(key);
    return buf.toBytes();
  }

  bool _online(String nid) {
    final ls = _lastSeenMs[nid];
    return ls != null &&
        DateTime.now().millisecondsSinceEpoch - ls <= _kOnlineWindowMs;
  }

  /// Time since we last heard from [nid], in whole hours (or "<1h ago").
  String _sinceText(String nid) {
    final ls = _lastSeenMs[nid];
    if (ls == null) return 'never seen';
    final hours = (DateTime.now().millisecondsSinceEpoch - ls) / 3600000.0;
    return hours < 1 ? '<1h ago' : '${hours.floor()}h ago';
  }

  /// Icon + label for how a peer is currently reachable.
  (IconData, String) _transportFor(String nid) {
    final link = _transport[nid];
    if (link == null) return (Icons.cloud_queue, 'Relay / multi-hop');
    final t = link.transportType.toLowerCase();
    if (t.contains('ble') || t.contains('blue'))
      return (Icons.bluetooth, 'BLE');
    if (link.pathKind == TransportPathKind.relay) return (Icons.cloud, 'Relay');
    return (Icons.wifi, 'Direct (Wi-Fi)');
  }

  // --- Join QR (DIVO hosts; others scan) ------------------------------------

  Future<void> _resolveLanIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final ni in ifaces) {
        for (final a in ni.addresses) {
          if (!a.isLoopback && !a.isLinkLocal) {
            if (mounted) setState(() => _lanIp = a.address);
            return;
          }
        }
      }
    } catch (_) {}
  }

  /// This node's dialable "host:port" — the bound socket address, with an
  /// unspecified host (0.0.0.0 / ::) swapped for the resolved LAN IP.
  String? _dialAddr() {
    final s = _node?.endpointSocketAddr;
    if (s == null || s.isEmpty) return null;
    final i = s.lastIndexOf(':');
    if (i <= 0) return null;
    final host = s.substring(0, i);
    final port = s.substring(i + 1);
    final unspecified =
        host == '0.0.0.0' || host == '::' || host == '[::]' || host.isEmpty;
    if (unspecified) return _lanIp == null ? null : '$_lanIp:$port';
    return s;
  }

  /// Compact join token as base64(JSON): node id, LAN addr (same-network),
  /// relay addr (works off-network over the n0 relay), formation key, and an
  /// expiry. The relay addr + expiry are what make this a shareable, demo-grade
  /// "join code" you can send to someone anywhere. The key gates membership —
  /// guard who you send it to, and it goes stale after [_kJoinTtlMs].
  String? _joinToken() {
    final node = _node;
    if (node == null || _formationKey == null) return null;
    final addr = _dialAddr();
    final relay = node.endpointAddr; // relay/derp form — reachable anywhere
    return base64Encode(
      utf8.encode(
        jsonEncode({
          'n': node.nodeId,
          if (addr != null && addr.isNotEmpty) 'a': addr,
          if (relay.isNotEmpty && relay != '—') 'r': relay,
          'k': _formationKey,
          'x': DateTime.now().millisecondsSinceEpoch + _kJoinTtlMs,
        }),
      ),
    );
  }

  /// Decode a scanned join token: adopt the mesh's formation key (starting or
  /// restarting our node under it), then dial the DIVO and remember it so the
  /// reconnect supervisor keeps the path up.
  Future<void> _joinViaToken(String raw) async {
    try {
      var token = raw.trim();
      // Accept a full join link too: grapheion://join?t=<code>
      final t = Uri.tryParse(token)?.queryParameters['t'];
      if (t != null && t.isNotEmpty) token = t;

      final m =
          jsonDecode(utf8.decode(base64Decode(token))) as Map<String, dynamic>;
      final exp = m['x'] as int?;
      if (exp != null && DateTime.now().millisecondsSinceEpoch > exp) {
        _snack('This join code has expired — ask for a fresh one');
        return;
      }
      final id = m['n'] as String?;
      final addr = m['a'] as String?;
      final relay = m['r'] as String?;
      final key = m['k'] as String?;
      if (id == null || id.isEmpty) throw const FormatException('no node id');

      // Adopting the key is what actually puts us in this mesh. If it's new or
      // different, (re)start the node under it.
      if (key != null && key.isNotEmpty && key != _formationKey) {
        _formationKey = key;
        (await SharedPreferences.getInstance()).setString('formationKey', key);
        if (_node != null) {
          _presenceTimer?.cancel();
          _tickTimer?.cancel();
          _node!.dispose();
          _node = null;
        }
        await _startNode();
      } else if (_node == null && _formationKey != null) {
        await _startNode();
      }

      final node = _node;
      if (node == null) {
        _snack('No mesh key — could not join');
        return;
      }
      node.connectPeerNowait(
        nodeId: id,
        addresses: (addr != null && addr.isNotEmpty) ? [addr] : const [],
        relayUrl: (relay != null && relay.startsWith('http')) ? relay : null,
      );
      node.rememberPeer(groupId: _kAppId, nodeId: id, name: '');
      _snack('Joined — dialing ${id.substring(0, 8)}…');
    } catch (e) {
      _snack('Invalid join code: $e');
    }
  }

  Future<void> _openScanner() async {
    final token = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _QrScanPage()));
    if (token != null && token.isNotEmpty) await _joinViaToken(token);
  }

  /// Join by pasting the code an admin sent (the off-network path — works over
  /// the relay from anywhere; the only way in on desktop, which has no camera).
  void _promptJoinCode() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter join code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Paste the join code your admin sent you',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final code = ctrl.text.trim();
              Navigator.pop(ctx);
              if (code.isNotEmpty) _joinViaToken(code);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// Cold-load whatever's already in the node's store into the [MeshStore].
  void _loadExisting(PeatFlutterNode node) {
    for (final coll in const [
      kJobs,
      kLog,
      kDepts,
      kDivs,
      kWcs,
      kAccounts,
      kCasreps,
      kPmsChecks,
      kQualifications,
      kQuals,
      kEvolutions,
      kBill,
      kBulletin,
      kStood,
      kEvents,
      kRouting,
      kFeedback,
    ]) {
      for (final id in node.listDocuments(coll)) {
        final raw = node.getRaw(coll, id);
        if (raw != null) _store.applyDoc(coll, id, raw, remote: false);
      }
    }
    // Cold-loaded presence seeds last-seen from the peer's own heartbeat.
    for (final id in node.listDocuments(kPresence)) {
      final raw = node.getRaw(kPresence, id);
      if (raw != null) _store.ingestPresence(raw, fromHeartbeat: true);
    }
  }

  void _onChange(DocumentChange change) {
    final node = _node;
    if (node == null) return;
    final raw = node.getRaw(change.collection, change.docId);
    if (raw == null) return;
    _store.applyDoc(
      change.collection,
      change.docId,
      raw,
      remote: change.origin.isRemote,
      peer: change.origin.peerId,
    );
    if (change.collection == kFeedback) _feedbackTick.value++;
    if (mounted) setState(() {});
  }

  // --- Writes (sync over the mesh) -----------------------------------------

  void _saveJob(Job job) {
    final json = jsonEncode(job.toJson());
    _node!.putRaw(kJobs, job.id, json);
    _bleBroadcast(kJobs, job.id, json);
  }

  void _saveCasrep(Casrep c) {
    final json = jsonEncode(c.toJson());
    _node!.putRaw(kCasreps, c.id, json);
    _bleBroadcast(kCasreps, c.id, json);
  }

  String _nextCasrepNumber() => _store.nextCasrepNumber();
  Casrep? _casrepForJob(String jobId) => _store.casrepForJob(jobId);

  // --- Watchbills + PQS -----------------------------------------------------

  void _saveQualification(Qualification q) {
    final json = jsonEncode(q.toJson());
    _store.qualifications[q.id] = q;
    _node!.putRaw(kQualifications, q.id, json);
    _bleBroadcast(kQualifications, q.id, json);
    if (mounted) setState(() {});
  }

  /// Set a person's PQS stage (and qualifier flag) for a qualification, + sync.
  void _setQual(
    String personId,
    String qualId,
    QualStage stage, {
    bool? qualifier,
  }) {
    final id = PersonQual.makeId(personId, qualId);
    final existing = _store.quals[id];
    final q = PersonQual(
      id: id,
      personId: personId,
      qualId: qualId,
      stage: stage,
      percent: stage == QualStage.qualified ? 100 : (existing?.percent ?? 0),
      hoursLogged: existing?.hoursLogged ?? 0,
      qualifier: qualifier ?? existing?.qualifier ?? false,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final json = jsonEncode(q.toJson());
    _store.quals[id] = q;
    _node!.putRaw(kQuals, id, json);
    _bleBroadcast(kQuals, id, json);
    if (mounted) setState(() {});
  }

  void _saveEvolution(Evolution e) {
    final json = jsonEncode(e.toJson());
    _store.evolutions[e.id] = e;
    _node!.putRaw(kEvolutions, e.id, json);
    _bleBroadcast(kEvolutions, e.id, json);
    if (mounted) setState(() {});
  }

  /// Post (or clear, if [personId] is null) a person to a role/shift on a day's
  /// instance of an evolution, and sync it.
  void _setBillEntry(
    int dayMs,
    String evolutionId,
    String roleId,
    String shiftId,
    String? personId,
  ) {
    final id = BillEntry.makeId(dayMs, evolutionId, roleId, shiftId);
    // An empty personId is an "unassigned" tombstone — but still a FULL entry
    // with a real timestamp, kept in the map, so last-write-wins resolves it
    // and the gossip re-broadcasts a consistent state (no oscillation).
    final e = BillEntry(
      id: id,
      dayMs: startOfDay(dayMs),
      evolutionId: evolutionId,
      roleId: roleId,
      shiftId: shiftId,
      personId: personId ?? '',
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final json = jsonEncode(e.toJson());
    _store.bill[id] = e;
    _node!.putRaw(kBill, id, json);
    _bleBroadcast(kBill, id, json);
    if (mounted) setState(() {});
  }

  /// Clear every slot on [ev]'s bill for [dayMs].
  void _clearBill(Evolution ev, int dayMs) {
    for (final s in evolutionSlots(ev)) {
      _setBillEntry(dayMs, ev.id, s.roleId, s.shiftId, null);
    }
  }

  /// Auto-generate [ev]'s bill for [dayMs] from who's qualified — even load, no
  /// overlapping double-booking. Writes every slot exactly once (its assignee,
  /// or empty if nobody's eligible) so there's no clear-then-fill double-write.
  void _autoFillBill(Evolution ev, int dayMs) {
    final slots = evolutionSlots(ev);
    final fill = autoFillBill(
      slots: slots,
      people: _store.accounts.keys.toList(),
      isQualified: (p, st) => _store.isQualified(p, st),
      priorLoad: _priorWatchLoad(ev),
    );
    for (final s in slots) {
      _setBillEntry(dayMs, ev.id, s.roleId, s.shiftId, fill[s.key]);
    }
  }

  /// Per-person historical burden for [autoFillBill], from the stood-log: how
  /// many times someone has stood a slot's watch TIME (the mids/eves), or their
  /// total for a standing watch. This is what makes auto-fill spread the
  /// unpopular night watches across days the same way the manual `_openBillAssign`
  /// picker does — instead of re-stacking the same person every time it's run.
  int Function(String, BillSlot) _priorWatchLoad(Evolution ev) {
    final shiftTime = {
      for (final s in ev.shifts) s.id: '${s.start}-${s.end}',
    };
    return (pid, slot) {
      final h = _personWatchHistory(pid);
      if (slot.standing) return h.total;
      final t = shiftTime[slot.shiftId];
      return t == null ? 0 : (h.byTime[t] ?? 0);
    };
  }

  /// Create + sync a new watch-station qualification (used by the evolution
  /// editor when a role needs a station that doesn't exist yet).
  Qualification _createStation(String name, String abbr) {
    final base = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'(^-|-$)'), '');
    var id = 'q-$base';
    var n = 1;
    while (_store.qualifications.containsKey(id)) {
      id = 'q-$base-${n++}';
    }
    final q = Qualification(
      id: id,
      abbr: abbr.isEmpty ? name : abbr,
      name: name,
      type: QualType.watchStation,
      inPort: true,
      order: _store.qualifications.length,
    );
    _saveQualification(q);
    return q;
  }

  /// Open the evolution editor for [ev] (null = create a new evolution).
  void _openEvolutionEditor(Evolution? ev) {
    final stations =
        _store.qualifications.values.where((q) => q.isWatchStation).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _EvolutionEditorPage(
          initial: ev,
          stations: stations,
          onCreateStation: _createStation,
          onSave: (e) {
            _saveEvolution(e);
            if (mounted) setState(() => _evolutionId = e.id);
          },
        ),
      ),
    );
  }

  /// Seed the default qualification tree — in-port watch stations + the SWO
  /// component quals + the SWO designation (with its prerequisite tree). Stable
  /// ids, so re-seeding refreshes.
  void _seedQualifications() {
    // id, abbr, name, type, inPort, hoursRequired, prereqIds
    final seeds =
        <(String, String, String, QualType, bool, int?, List<String>)>[
          // In-port watch stations (feed the bill)
          (
            'q-cdo',
            'CDO',
            'Command Duty Officer',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-oodip',
            'OOD I/P',
            'Officer of the Deck (In-Port)',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-poow',
            'POOW',
            'Petty Officer of the Watch',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-moow',
            'MOOW',
            'Messenger of the Watch',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-sns',
            'S&S',
            'Sounding & Security Patrol',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-sec',
            'SEC',
            'Roving Security Patrol',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-dutyeng',
            'DUTYENG',
            'Duty Engineer',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-sectionldr',
            'SEC LDR',
            'Duty Section Leader',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-attwo',
            'AT/TWO',
            'Anti-Terrorism / Tactical Watch Officer',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-csoow',
            'CSOOW',
            'Combat Systems Officer of the Watch',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-firemarshal',
            'FIRE MAR',
            'In-Port Fire Marshal',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-dutymaa',
            'DMAA',
            'Duty Master-at-Arms',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-rfl',
            'RF LDR',
            'Reaction Force Leader',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-rfm',
            'RF MBR',
            'Reaction Force Member',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-sentry',
            'SENTRY',
            'Armed Sentry (ECP)',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-topside',
            'TOPSIDE',
            'Topside Rover',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-firewatch',
            'FIRE WCH',
            'Fire Watch Stander',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-coldiron',
            'COLD IRON',
            'Cold Iron Engineering Watch',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-eqmon',
            'EQ MON',
            'In-Port Equipment Monitor',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-iet-tl',
            'IET-TL',
            'In-Port Emergency Team Leader',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-iet-scene',
            'IET-SCN',
            'IET Scene Leader',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-iet-nozzle',
            'IET-NOZ',
            'IET Nozzleman',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-iet-hose',
            'IET-HOSE',
            'IET Hoseman',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          (
            'q-iet-invest',
            'IET-INV',
            'IET Investigator',
            QualType.watchStation,
            true,
            null,
            [],
          ),
          // Underway watch stations (SWO prereqs; not on the in-port bill)
          (
            'q-ooduw',
            'OOD U/W',
            'Officer of the Deck (Underway)',
            QualType.watchStation,
            false,
            100,
            [],
          ),
          (
            'q-cicwo',
            'CICWO',
            'CIC Watch Officer',
            QualType.watchStation,
            false,
            null,
            [],
          ),
          // Knowledge quals
          (
            'q-3m',
            '3M',
            '3-M / PMS Qualification',
            QualType.knowledge,
            false,
            null,
            [],
          ),
          (
            'q-dc',
            'Basic DC',
            'Basic Damage Control',
            QualType.knowledge,
            false,
            null,
            [],
          ),
          (
            'q-swoeng',
            'SWO Eng',
            'SWO Engineering',
            QualType.knowledge,
            false,
            null,
            [],
          ),
          (
            'q-boato',
            'Boat O',
            'Small Boat Officer',
            QualType.knowledge,
            false,
            null,
            [],
          ),
          // Letter quals (follow-on)
          (
            'q-eoow',
            'EOOW',
            'Engineering Officer of the Watch',
            QualType.letter,
            false,
            null,
            [],
          ),
          (
            'q-tao',
            'TAO',
            'Tactical Action Officer',
            QualType.letter,
            false,
            null,
            [],
          ),
          // Capstone designation, atop its prerequisite tree
          (
            'q-swo',
            'SWO',
            'Surface Warfare Officer',
            QualType.designation,
            false,
            null,
            [
              'q-3m',
              'q-dc',
              'q-boato',
              'q-swoeng',
              'q-oodip',
              'q-ooduw',
              'q-cicwo',
            ],
          ),
        ];
    for (var i = 0; i < seeds.length; i++) {
      final s = seeds[i];
      _saveQualification(
        Qualification(
          id: s.$1,
          abbr: s.$2,
          name: s.$3,
          type: s.$4,
          inPort: s.$5,
          hoursRequired: s.$6,
          prereqIds: s.$7,
          order: i,
        ),
      );
    }
    _seedInPortEvolution();
  }

  /// Seed the In-Port Duty evolution — the day-to-day in-port watchbill: a few
  /// standing watches + rotating watches across 5 section shifts. Stable id.
  void _seedInPortEvolution() {
    // roleId, stationId, name, rotating
    final roles = <(String, String, String, bool)>[
      ('r-cdo', 'q-cdo', 'Command Duty Officer', false),
      ('r-oodip', 'q-oodip', 'Officer of the Deck (In-Port)', false),
      ('r-dutyeng', 'q-dutyeng', 'Duty Engineer', false),
      ('r-poow', 'q-poow', 'Petty Officer of the Watch', true),
      ('r-moow', 'q-moow', 'Messenger of the Watch', true),
      ('r-sns', 'q-sns', 'Sounding & Security Patrol', true),
      ('r-sec', 'q-sec', 'Roving Security Patrol', true),
    ];
    const times = [
      ('s1', '1', '0630', '1130'),
      ('s2', '2', '1130', '1630'),
      ('s3', '3', '1630', '2130'),
      ('s4', '4', '2130', '0130'),
      ('s5', '5', '0130', '0630'),
    ];
    _saveEvolution(
      Evolution(
        id: 'ev-inport',
        name: 'In-Port Duty',
        inPort: true,
        order: 0,
        shifts: [
          for (final t in times)
            WatchShift(id: t.$1, label: t.$2, start: t.$3, end: t.$4),
        ],
        roles: [
          for (var i = 0; i < roles.length; i++)
            EvolutionRole(
              id: roles[i].$1,
              stationId: roles[i].$2,
              name: roles[i].$3,
              rotating: roles[i].$4,
              order: i,
            ),
        ],
      ),
    );
  }

  /// Seed a demo duty section — ~18 sailors (rate + name) pre-qualified across
  /// the in-port watch stations, so Auto-generate produces a full bill instantly
  /// for showing people. Stable ids, so re-running just refreshes them.
  void _seedDemoCrew() {
    _ensureCanonicalOrg(); // guarantee the departments/divisions exist first
    // rate, name, role, division id
    final crew = <(String, String, Role, String)>[
      ('LCDR', 'Reyes', Role.dh, 'EM'),
      ('LT', 'Donnelly', Role.divo, 'CA'),
      ('LTJG', 'Park', Role.divo, 'OI'),
      ('CWO3', 'Bauer', Role.divo, 'EA'),
      ('ENS', 'Carter', Role.divo, '1ST'),
      ('GSCS', 'Nakamura', Role.lpo, 'EM'),
      ('BM1', 'Flores', Role.wcs, '1ST'),
      ('OS1', 'Patel', Role.wcs, 'OI'),
      ('GM2', 'Sullivan', Role.technician, 'GUN'),
      ('ET2', 'Brooks', Role.technician, 'CE'),
      ('MM2', 'Iverson', Role.technician, 'EA'),
      ('OS2', 'Dunn', Role.technician, 'OI'),
      ('BM3', 'Davis', Role.technician, '1ST'),
      ('OS3', 'Nguyen', Role.technician, 'OI'),
      ('FN', 'Castillo', Role.technician, 'EM'),
      ('SN', 'Whitaker', Role.technician, '1ST'),
      ('GSMFN', 'Abara', Role.technician, 'EM'),
      ('SA', 'Rhodes', Role.technician, '1ST'),
    ];
    // Quals by seniority tier, so any bill the user builds can be auto-filled.
    const baseStations = [
      // everyone holds these (the rotating / junior watches)
      'q-poow', 'q-moow', 'q-sns', 'q-sec', 'q-topside', 'q-firewatch',
      'q-eqmon',
      'q-sentry',
      'q-rfm',
      'q-iet-hose',
      'q-iet-nozzle',
      'q-coldiron',
    ];
    const seniorStations = [
      // officers + senior enlisted add the command watches
      'q-cdo', 'q-oodip', 'q-csoow', 'q-attwo', 'q-dutyeng', 'q-sectionldr',
      'q-firemarshal', 'q-dutymaa', 'q-rfl', 'q-iet-tl', 'q-iet-scene',
      'q-iet-invest',
    ];
    const seniorRoles = {Role.lpo, Role.wcs, Role.dh, Role.divo, Role.threeMC};
    const salt = 'grapheion-demo-crew';
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < crew.length; i++) {
      final c = crew[i];
      final id = 'acct-demo-${i + 1}';
      final a = Account(
        id: id,
        name: c.$2,
        rate: c.$1,
        role: c.$3,
        workcenterId: '${c.$4}-WC',
        dutySection: '${(i % 5) + 1}', // spread across 5 in-port sections
        pinSalt: salt,
        pinHash: hashPin(salt, '0000'),
        createdAtMs: now,
      );
      _accounts[id] = a;
      final json = jsonEncode(a.toJson());
      _node!.putRaw(kAccounts, id, json);
      _bleBroadcast(kAccounts, id, json);
      final senior = _isOfficer(a) || seniorRoles.contains(a.role);
      for (final st in [...baseStations, if (senior) ...seniorStations]) {
        _setQual(id, st, QualStage.qualified);
      }
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Seeded ${crew.length} demo crew — Auto-generate the bill',
          ),
        ),
      );
    }
  }

  /// Work-center members as (accountId, name), for assignment + quals.
  List<(String, String)> _watchPeople() {
    final wc = _workcenter;
    return (_store.accounts.values.where((a) => a.workcenterId == wc).toList()
          ..sort((a, b) => a.name.compareTo(b.name)))
        .map((a) => (a.id, a.name))
        .toList();
  }

  String _personName(String id) =>
      _store.accounts[id]?.name ?? (id.isEmpty ? '' : id);

  /// Roles that build the watchbill / sign off PQS.
  bool get _canManageWatch =>
      _role != null && _role != Role.technician && _role != Role.portEngineer;

  /// Ship-wide roles run the duty-section rotation + see every section. Everyone
  /// DH-and-below sees only their own duty section.
  bool get _canManageSections => _role == Role.threeMC || _role == Role.kratos;

  /// Section-watchbill admin (create / auto-fill / record / clear / assign).
  /// Duty-POSITION axis, additive to role: 3MC/Kratos manage any section; a
  /// Section Leader or CDO manages THEIR own section's bill. A plain
  /// watchstander sees the bill read-only.
  bool _canEditSectionBill(String section) {
    if (_canManageSections) return true;
    final a = _account;
    return a != null &&
        a.dutySection == section &&
        a.dutyPosition.leadsDutySection;
  }

  /// The in-port stations a duty section must be able to man — the distinct role
  /// stations across the in-port evolutions (drives the auto-partition).
  List<String> _inPortRequiredStations() {
    final out = <String>{};
    for (final ev in _store.evolutions.values.where((e) => e.inPort)) {
      for (final r in ev.roles) {
        out.add(r.stationId);
      }
    }
    return out.toList();
  }

  /// Auto-partition the whole crew into 5 balanced duty sections, each able to
  /// man the in-port bill, and write each person's section. Ship-wide only.
  void _autoAssignDutySections() {
    final crew = _store.accounts.values
        .where((a) => a.role != Role.kratos)
        .toList();
    final required = _inPortRequiredStations();
    final assignment = assignDutySections(
      people: crew.map((a) => a.id).toList(),
      requiredStations: required,
      isQualified: (p, st) => _store.isQualified(p, st),
      sections: 5,
    );
    assignment.forEach((pid, sec) {
      final a = _store.accounts[pid];
      if (a != null && a.dutySection != '$sec') {
        a.dutySection = '$sec';
        _updateAccount(a);
      }
    });
    final gaps = dutySectionGaps(
      assignment: assignment,
      requiredStations: required,
      isQualified: (p, st) => _store.isQualified(p, st),
    );
    if (mounted) {
      setState(() {});
      final msg = gaps.isEmpty
          ? 'Built 5 duty sections — every section can man the bill'
          : 'Built 5 sections — ${gaps.length} have coverage gaps (see warnings)';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// The in-port evolution whose required positions are the constraint set
  /// (first in-port evolution), or null if none defined yet.
  Evolution? _inPortEvolution() {
    final evos = _store.evolutions.values.where((e) => e.inPort).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return evos.isEmpty ? null : evos.first;
  }

  /// A stable synthetic "duty day" per section, so each section keeps its own
  /// bill (distinct from the calendar-day bills on the Watchbills tab).
  int _sectionDayMs(String section) => DateTime(
    2000,
    1,
    1 + (int.tryParse(section) ?? 0),
  ).millisecondsSinceEpoch;

  List<String> _sectionMemberIds(String section) => _store.accounts.values
      .where((a) => a.dutySection == section && a.role != Role.kratos)
      .map((a) => a.id)
      .toList();

  /// Auto-fill [ev]'s bill for a section from ONLY that section's members.
  void _autoFillSectionBill(Evolution ev, String section) {
    final day = _sectionDayMs(section);
    final slots = evolutionSlots(ev);
    final fill = autoFillBill(
      slots: slots,
      people: _sectionMemberIds(section),
      isQualified: (p, st) => _store.isQualified(p, st),
      priorLoad: _priorWatchLoad(ev),
    );
    for (final s in slots) {
      _setBillEntry(day, ev.id, s.roleId, s.shiftId, fill[s.key]);
    }
  }

  void _clearSectionBill(Evolution ev, String section) {
    final day = _sectionDayMs(section);
    for (final s in evolutionSlots(ev)) {
      _setBillEntry(day, ev.id, s.roleId, s.shiftId, null);
    }
  }

  void _saveStood(WatchStood w) {
    final json = jsonEncode(w.toJson());
    _store.stood[w.id] = w;
    _node!.putRaw(kStood, w.id, json);
    _bleBroadcast(kStood, w.id, json);
  }

  /// Commit [ev]'s filled bill into the permanent stood-log — each filled slot
  /// becomes a confirmed watch stood (idempotent per slot). Assignments are read
  /// from [billDayMs] (where the editable bill lives); the stood entries are
  /// stamped with [recordDayMs] — the real calendar day, defaulting to billDayMs
  /// — and [section], so a section's recording snapshots to a dated, browsable
  /// duty day (and the night-balance counts accumulate across real days).
  /// Returns the number of watches recorded.
  int _recordWatches(
    Evolution ev,
    int billDayMs, {
    int? recordDayMs,
    String section = '',
    bool snack = true,
  }) {
    final recDay = recordDayMs ?? billDayMs;
    var n = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final slot in evolutionSlots(ev)) {
      final pid = _store.billAssignee(
        billDayMs,
        ev.id,
        slot.roleId,
        slot.shiftId,
      );
      if (pid == null || pid.isEmpty) continue;
      EvolutionRole? role;
      for (final r in ev.roles) {
        if (r.id == slot.roleId) {
          role = r;
          break;
        }
      }
      final stationName = role == null
          ? slot.roleId
          : (_store.qualifications[role.stationId]?.name ?? role.name);
      var timeLabel = '';
      if (slot.shiftId.isNotEmpty) {
        for (final s in ev.shifts) {
          if (s.id == slot.shiftId) {
            timeLabel = '${s.start}-${s.end}';
            break;
          }
        }
      }
      _saveStood(
        WatchStood(
          id: WatchStood.makeId(recDay, ev.id, slot.roleId, slot.shiftId),
          personId: pid,
          stationName: stationName,
          evolutionName: ev.name,
          timeLabel: timeLabel,
          dayMs: startOfDay(recDay),
          section: section,
          atMs: now,
        ),
      );
      n++;
    }
    if (mounted) {
      setState(() {});
      if (snack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Recorded $n watch${n == 1 ? '' : 'es'} stood'),
          ),
        );
      }
    }
    return n;
  }

  /// Sync a duty-day event (or tombstone it by saving an empty-type record).
  void _saveDutyEvent(DutyDayEvent e) {
    final json = jsonEncode(e.toJson());
    _store.dutyEvents[e.id] = e;
    _node!.putRaw(kEvents, e.id, json);
    _bleBroadcast(kEvents, e.id, json);
  }

  // --- Watchbill approval chain --------------------------------------------

  void _saveRouting(WatchbillRouting r) {
    r.updatedAtMs = DateTime.now().millisecondsSinceEpoch; // newest wins on sync
    final json = jsonEncode(r.toJson());
    _store.routing[r.id] = r;
    _node!.putRaw(kRouting, r.id, json);
    _bleBroadcast(kRouting, r.id, json);
    if (mounted) setState(() {});
  }

  bool _isSectionLeaderOf(String section) {
    final a = _account;
    return a != null &&
        a.dutySection == section &&
        a.dutyPosition == DutyPosition.sectionLeader;
  }

  bool _isCdoOf(String section) {
    final a = _account;
    return a != null &&
        a.dutySection == section &&
        a.dutyPosition == DutyPosition.cdo;
  }

  /// May submit (the plan, or the finalize): the Section Leader of the section,
  /// or a ship-wide manager.
  bool _canSubmitBill(String section) =>
      _canManageSections || _isSectionLeaderOf(section);

  /// May approve / return (the plan, or the finalize): the CDO, or a manager.
  bool _canApproveBill(String section) =>
      _canManageSections || _isCdoOf(section);

  /// SL submits the built plan for the CDO's approval.
  void _submitBill(String section) {
    final r = _store.routingFor(section)
      ..status = BillStatus.submitted
      ..submittedBy = _account?.id ?? ''
      ..returnedBy = ''
      ..returnedNote = '';
    _saveRouting(r);
  }

  /// CDO approves the plan — the duty day may now run.
  void _approveBill(String section) {
    final r = _store.routingFor(section)
      ..status = BillStatus.approved
      ..approvedBy = _account?.id ?? '';
    _saveRouting(r);
  }

  /// CDO returns the plan to the SL with a reason; back to Draft.
  void _returnBill(String section, String note) {
    final r = _store.routingFor(section)
      ..status = BillStatus.draft
      ..returnedBy = _account?.id ?? ''
      ..returnedNote = note;
    _saveRouting(r);
  }

  /// SL submits the finalize (events already logged) for the day [r.dayMs].
  void _submitFinalize(String section) {
    final r = _store.routingFor(section)
      ..status = BillStatus.finalizing
      ..submittedBy = _account?.id ?? ''
      ..dayMs = startOfDay(DateTime.now().millisecondsSinceEpoch)
      ..returnedBy = ''
      ..returnedNote = '';
    _saveRouting(r);
  }

  /// CDO approves the finalize: records the watches (counters + history) and
  /// marks the bill Finalized.
  void _approveFinalize(Evolution ev, String section) {
    final r = _store.routingFor(section);
    final day = r.dayMs == 0
        ? startOfDay(DateTime.now().millisecondsSinceEpoch)
        : r.dayMs;
    final n = _recordWatches(
      ev,
      _sectionDayMs(section),
      recordDayMs: day,
      section: section,
      snack: false,
    );
    r
      ..status = BillStatus.finalized
      ..approvedBy = _account?.id ?? ''
      ..dayMs = day;
    _saveRouting(r);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Finalized — recorded $n watch${n == 1 ? '' : 'es'}')),
      );
    }
  }

  /// CDO returns the finalize to the SL; back to Approved.
  void _returnFinalize(String section, String note) {
    final r = _store.routingFor(section)
      ..status = BillStatus.approved
      ..returnedBy = _account?.id ?? ''
      ..returnedNote = note;
    _saveRouting(r);
  }

  /// Start the next duty day's bill from a Finalized one (SL): back to Draft.
  void _newBillCycle(String section) {
    final r = _store.routingFor(section)
      ..status = BillStatus.draft
      ..submittedBy = ''
      ..approvedBy = ''
      ..returnedBy = ''
      ..returnedNote = '';
    _saveRouting(r);
  }

  /// Record a duty section's duty day: pick the events that occurred, then
  /// commit the watchbill (snapshotted to today's real date) + the events.
  void _addDutyEvent(int day, String section, String type, String note) {
    _saveDutyEvent(
      DutyDayEvent(
        id: DutyDayEvent.makeId(day, section, type),
        dayMs: startOfDay(day),
        section: section,
        type: type,
        note: note,
        atMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (mounted) setState(() {});
  }

  void _deleteDutyEvent(DutyDayEvent e) {
    // Tombstone (empty type) so the delete syncs and survives a rebroadcast.
    final tomb = DutyDayEvent(
      id: e.id,
      dayMs: e.dayMs,
      section: e.section,
      type: '',
      note: '',
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    final json = jsonEncode(tomb.toJson());
    _store.dutyEvents.remove(e.id);
    _node!.putRaw(kEvents, e.id, json);
    _bleBroadcast(kEvents, e.id, json);
    if (mounted) setState(() {});
  }

  /// The finalize sheet: log/adjust the events that occurred, then (SL) submit
  /// to the CDO, or (CDO, [forCdo]) approve to record the day or return it.
  /// Both the SL and the CDO may add/delete events here.
  void _openFinalizeSheet(
    Evolution ev,
    String section, {
    required bool forCdo,
  }) {
    final r = _store.routingFor(section);
    final day = r.dayMs != 0
        ? r.dayMs
        : startOfDay(DateTime.now().millisecondsSinceEpoch);
    var pickType = kDutyDayEventTypes.first;
    final noteCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final events = _store.eventsForDay(day, section);
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      forCdo
                          ? 'Review Section $section duty day'
                          : 'Finalize Section $section duty day',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      forCdo
                          ? 'Adjust the events if needed, then approve to record the watches, or return it to the section leader.'
                          : 'Log the events that occurred, then submit to the CDO to record the day.',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    if (events.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'No events logged.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    for (final e in events)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: Colors.orange,
                        ),
                        title: Text(e.type),
                        subtitle: e.note.isEmpty ? null : Text(e.note),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () {
                            _deleteDutyEvent(e);
                            setS(() {});
                          },
                        ),
                      ),
                    const Divider(),
                    DropdownButton<String>(
                      value: pickType,
                      isExpanded: true,
                      items: [
                        for (final t in kDutyDayEventTypes)
                          DropdownMenuItem(value: t, child: Text(t)),
                      ],
                      onChanged: (v) => setS(() => pickType = v ?? pickType),
                    ),
                    TextField(
                      controller: noteCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Note (optional)',
                        hintText: 'Details',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add event'),
                      onPressed: () {
                        _addDutyEvent(
                          day,
                          section,
                          pickType,
                          noteCtrl.text.trim(),
                        );
                        noteCtrl.clear();
                        setS(() {});
                      },
                    ),
                    const SizedBox(height: 16),
                    if (!forCdo)
                      SizedBox(
                        width: double.infinity,
                        child: _ConfirmButton(
                          label: 'Submit to CDO',
                          confirmLabel: 'Tap to confirm',
                          icon: Icons.send,
                          onConfirm: () {
                            _submitFinalize(section);
                            Navigator.pop(ctx);
                          },
                        ),
                      )
                    else ...[
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.check),
                          label: const Text('Approve & record'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _approveFinalize(ev, section);
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.undo),
                          label: const Text('Return to section leader'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _promptBillReturn(section, finalize: true);
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _promptBillReturn(String section, {required bool finalize}) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Return to section leader'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Reason for return',
            hintText: 'e.g. POOW not qualified on the 22-02',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final note = ctrl.text.trim();
              Navigator.pop(ctx);
              if (finalize) {
                _returnFinalize(section, note);
              } else {
                _returnBill(section, note);
              }
            },
            child: const Text('Return'),
          ),
        ],
      ),
    );
  }

  /// The routing status chip + the contextual actions for the current phase.
  Widget _billStatusBar(Evolution? ev, String section, WatchbillRouting r) {
    final actions = <Widget>[];
    switch (r.status) {
      case BillStatus.draft:
        if (ev != null && _canEditSectionBill(section)) {
          actions.add(
            FilledButton.tonalIcon(
              onPressed: () => _autoFillSectionBill(ev, section),
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('Auto-fill'),
            ),
          );
          actions.add(
            TextButton.icon(
              onPressed: () => _clearSectionBill(ev, section),
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('Clear'),
            ),
          );
        }
        if (_canSubmitBill(section)) {
          actions.add(
            _ConfirmButton(
              label: 'Submit to CDO',
              confirmLabel: 'Tap to confirm',
              icon: Icons.send,
              onConfirm: () => _submitBill(section),
            ),
          );
        }
      case BillStatus.submitted:
        if (_canApproveBill(section)) {
          actions.add(
            FilledButton.icon(
              onPressed: () => _approveBill(section),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Approve'),
            ),
          );
          actions.add(
            OutlinedButton.icon(
              onPressed: () => _promptBillReturn(section, finalize: false),
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Return'),
            ),
          );
        }
      case BillStatus.approved:
        if (ev != null && _canSubmitBill(section)) {
          actions.add(
            FilledButton.icon(
              onPressed: () => _openFinalizeSheet(ev, section, forCdo: false),
              icon: const Icon(Icons.fact_check_outlined, size: 18),
              label: const Text('Finalize duty day'),
            ),
          );
        }
      case BillStatus.finalizing:
        if (ev != null && _canApproveBill(section)) {
          actions.add(
            FilledButton.icon(
              onPressed: () => _openFinalizeSheet(ev, section, forCdo: true),
              icon: const Icon(Icons.rule, size: 18),
              label: const Text('Review & approve'),
            ),
          );
        }
      case BillStatus.finalized:
        if (_canSubmitBill(section)) {
          actions.add(
            TextButton.icon(
              onPressed: () => _newBillCycle(section),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Start next duty day'),
            ),
          );
        }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _billStatusChip(r),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: actions),
          ],
        ],
      ),
    );
  }

  Widget _billStatusChip(WatchbillRouting r) {
    final (label, color, detail) = switch (r.status) {
      BillStatus.draft => r.returnedNote.isNotEmpty
          ? (
              'RETURNED',
              _duOrange,
              'by ${_billPersonLabel(r.returnedBy)}: ${r.returnedNote}',
            )
          : ('DRAFT', Colors.grey, 'section leader is building the bill'),
      BillStatus.submitted => (
        'IN ROUTING',
        Colors.blue,
        'submitted by ${_billPersonLabel(r.submittedBy)} — awaiting CDO',
      ),
      BillStatus.approved => (
        'APPROVED',
        Colors.green,
        'plan approved by ${_billPersonLabel(r.approvedBy)}',
      ),
      BillStatus.finalizing => (
        'FINALIZING',
        Colors.blue,
        'submitted by ${_billPersonLabel(r.submittedBy)} — awaiting CDO',
      ),
      BillStatus.finalized => (
        'FINALIZED',
        Colors.green,
        'recorded · approved by ${_billPersonLabel(r.approvedBy)}',
      ),
    };
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            detail,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  void _postBulletin(String section, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final me = _account;
    final post = BulletinPost(
      id: 'bp-$now-${_randHex(3)}',
      section: section,
      authorId: me?.id ?? '',
      authorName: me == null
          ? 'Unknown'
          : (me.rate.isEmpty ? me.name : '${me.rate} ${me.name}'),
      text: t,
      atMs: now,
    );
    final json = jsonEncode(post.toJson());
    _store.bulletin[post.id] = post;
    _node!.putRaw(kBulletin, post.id, json);
    _bleBroadcast(kBulletin, post.id, json);
    _bulletinCtrl.clear();
    if (mounted) setState(() {});
  }

  // --- Admin (personnel hub) — DIVO and higher ------------------------------

  /// DIVO and up may open the personnel hub.
  bool get _canAdmin {
    final r = _role;
    return r == Role.divo ||
        r == Role.dh ||
        r == Role.threeMC ||
        r == Role.portEngineer ||
        r == Role.kratos;
  }

  static const _officerRates = {
    'ENS',
    'LTJG',
    'LT',
    'LCDR',
    'CDR',
    'CAPT',
    'RADM',
    'VADM',
    'ADM',
    'WO',
    'WO1',
    'CWO2',
    'CWO3',
    'CWO4',
    'CWO5',
    'CW2',
    'CW3',
    'CW4',
    'CW5',
  };

  bool _isOfficer(Account a) =>
      _officerRates.contains(a.rate.toUpperCase().trim());

  /// The division name for a person (via their work center), or '—'.
  String _divisionName(Account a) {
    final wc = _org.workcenters[a.workcenterId];
    if (wc == null) return '—';
    return _org.divisions[wc.divisionId]?.name ?? '—';
  }

  /// The department name for a person (work center → division → department).
  String _departmentName(Account a) {
    final wc = _org.workcenters[a.workcenterId];
    final div = wc == null ? null : _org.divisions[wc.divisionId];
    if (div == null) return '—';
    return _org.departments[div.departmentId]?.name ?? '—';
  }

  /// Qualification names a person currently holds (qualified stage).
  List<String> _personQuals(String personId) {
    final out = <String>[];
    for (final q in _store.quals.values) {
      if (q.personId == personId && q.isQualified) {
        out.add(_store.qualifications[q.qualId]?.name ?? q.qualId);
      }
    }
    out.sort();
    return out;
  }

  /// Confirmed watch-standing history for a person, from the stood-log: how
  /// many watches stood total, by station, by evolution, and by time slot (so
  /// you can spread the unpopular mid/morning watches fairly). Permanent —
  /// survives bill edits; populated by "Record watches" on a bill.
  ({
    int total,
    Map<String, int> byStation,
    Map<String, int> byEvolution,
    Map<String, int> byTime,
  })
  _personWatchHistory(String personId) {
    final byStation = <String, int>{};
    final byEvolution = <String, int>{};
    final byTime = <String, int>{};
    var total = 0;
    for (final w in _store.stood.values) {
      if (w.personId != personId) continue;
      byStation[w.stationName] = (byStation[w.stationName] ?? 0) + 1;
      byEvolution[w.evolutionName] = (byEvolution[w.evolutionName] ?? 0) + 1;
      if (w.timeLabel.isNotEmpty) {
        byTime[w.timeLabel] = (byTime[w.timeLabel] ?? 0) + 1;
      }
      total++;
    }
    return (
      total: total,
      byStation: byStation,
      byEvolution: byEvolution,
      byTime: byTime,
    );
  }

  // --- Feedback (anyone submits; only Kratos reads) -------------------------

  bool get _isKratos => _role == Role.kratos;

  void _saveFeedback(FeedbackNote f) {
    final json = jsonEncode(f.toJson());
    _store.feedback[f.id] = f;
    _node!.putRaw(kFeedback, f.id, json);
    _bleBroadcast(kFeedback, f.id, json);
    _feedbackTick.value++;
    if (mounted) setState(() {});
  }

  /// Start a new feedback thread (the submitter's first message).
  void _submitFeedback(String text, {String context = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final feature = _feature < _navFeatures.length
        ? _navFeatures[_feature].$2
        : '';
    _saveFeedback(
      FeedbackNote(
        id: 'fb-$now-${_randHex(3)}',
        fromId: _account?.id ?? '',
        fromRate: _account?.rate ?? '', // rate/rank only — no name
        fromRole: _role ?? Role.technician,
        context: context.trim().isEmpty ? feature : context.trim(),
        messages: [FeedbackMessage(fromOwner: false, text: text, atMs: now)],
        readByOwner: false,
        readBySubmitter: true,
        createdAtMs: now,
      ),
    );
  }

  /// Append a message to a thread, from the owner (Kratos) or the submitter.
  void _addFeedbackMessage(
    FeedbackNote f,
    String text, {
    required bool fromOwner,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    f.messages.add(
      FeedbackMessage(fromOwner: fromOwner, text: text, atMs: now),
    );
    // Sender has seen it; the other side now has an unread message.
    f.readByOwner = fromOwner;
    f.readBySubmitter = !fromOwner;
    _saveFeedback(f);
  }

  void _markFeedbackRead(FeedbackNote f, {required bool asOwner}) {
    if (asOwner && !f.readByOwner) {
      f.readByOwner = true;
      _saveFeedback(f);
    } else if (!asOwner && !f.readBySubmitter) {
      f.readBySubmitter = true;
      _saveFeedback(f);
    }
  }

  /// The submitter's "send feedback" sheet — compose a new note, plus a live
  /// list of their existing threads (tap to open the conversation).
  void _openFeedbackSheet() {
    final ctrl = TextEditingController();
    final feature = _feature < _navFeatures.length
        ? _navFeatures[_feature].$2
        : '';
    final ctxCtrl = TextEditingController(text: feature);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.feedback_outlined),
                  const SizedBox(width: 8),
                  Text('Feedback', style: Theme.of(ctx).textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Goes to the demo owner over the mesh.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctxCtrl,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'About',
                  hintText: 'What this is about',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 4,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: "What worked, what didn't, what's missing…",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () {
                  final t = ctrl.text.trim();
                  if (t.isEmpty) return;
                  _submitFeedback(t, context: ctxCtrl.text);
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Feedback sent — thank you!')),
                  );
                },
                icon: const Icon(Icons.send),
                label: const Text('Send'),
              ),
              ValueListenableBuilder<int>(
                valueListenable: _feedbackTick,
                builder: (ctx, _, __) {
                  final mine =
                      _store.feedback.values
                          .where(
                            (f) =>
                                f.fromId.isNotEmpty && f.fromId == _account?.id,
                          )
                          .toList()
                        ..sort(
                          (a, b) =>
                              b.lastActivityMs.compareTo(a.lastActivityMs),
                        );
                  if (mine.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 28),
                      const Text(
                        'YOUR FEEDBACK',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      for (final f in mine)
                        _feedbackThreadTile(f, asOwner: false),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Kratos-only feedback inbox — a list of threads.
  Widget _feedbackPage() {
    return ValueListenableBuilder<int>(
      valueListenable: _feedbackTick,
      builder: (ctx, _, __) {
        final notes = _store.feedbackNewestFirst();
        if (notes.isEmpty) {
          return const Center(
            child: Text(
              'No feedback yet.',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }
        return ListView.separated(
          itemCount: notes.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) =>
              _feedbackThreadTile(notes[i], asOwner: true, deletable: true),
        );
      },
    );
  }

  /// How a submitter is shown — rate/rank + role tag, never a name.
  String _fromLabel(FeedbackNote f) =>
      f.fromRate.isEmpty ? f.fromRole.tag : '${f.fromRate} · ${f.fromRole.tag}';

  /// A thread row (both the Kratos inbox + the submitter's list use this).
  Widget _feedbackThreadTile(
    FeedbackNote f, {
    required bool asOwner,
    bool deletable = false,
  }) {
    final unread = asOwner ? !f.readByOwner : !f.readBySubmitter;
    final last = f.lastMessage;
    return ListTile(
      leading: Icon(
        unread ? Icons.mark_chat_unread : Icons.forum_outlined,
        color: unread ? Theme.of(context).colorScheme.primary : Colors.grey,
      ),
      title: Text(f.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (asOwner) _fromLabel(f),
          if (f.context.isNotEmpty) f.context,
          if (last != null)
            '${last.fromOwner ? (asOwner ? 'you' : 'owner') : (asOwner ? _fromLabel(f) : 'you')}: ${last.text}',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _openFeedbackThread(f, asOwner: asOwner),
      trailing: deletable
          ? IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteFeedback(f),
            )
          : Text(
              _ago(f.lastActivityMs),
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
    );
  }

  /// The conversation view both sides share — chat bubbles + a compose box.
  /// [asOwner] is true for Kratos, false for the submitter.
  void _openFeedbackThread(FeedbackNote f, {required bool asOwner}) {
    final id = f.id;
    _markFeedbackRead(f, asOwner: asOwner);
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_fromLabel(f)}${f.context.isEmpty ? '' : ' · ${f.context}'}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            ),
            const Divider(height: 1),
            ValueListenableBuilder<int>(
              valueListenable: _feedbackTick,
              builder: (ctx, _, __) {
                final note = _store.feedback[id];
                if (note == null) return const SizedBox.shrink();
                // keep marking incoming messages read while the thread is open
                _markFeedbackRead(note, asOwner: asOwner);
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final m in note.messages)
                        _feedbackBubble(m, mine: m.fromOwner == asOwner),
                    ],
                  ),
                );
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Message…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () {
                      final t = ctrl.text.trim();
                      if (t.isEmpty) return;
                      final note = _store.feedback[id];
                      if (note == null) return;
                      _addFeedbackMessage(note, t, fromOwner: asOwner);
                      ctrl.clear();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feedbackBubble(FeedbackMessage m, {required bool mine}) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: mine
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(m.text),
            const SizedBox(height: 2),
            Text(
              _ago(m.atMs),
              style: const TextStyle(color: Colors.grey, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteFeedback(FeedbackNote f) {
    _store.feedback.remove(f.id);
    _node!.putRaw(kFeedback, f.id, jsonEncode({'id': f.id, 'text': ''}));
    _bleBroadcast(kFeedback, f.id, jsonEncode({'id': f.id, 'text': ''}));
    if (mounted) setState(() {});
  }

  String _ago(int ms) {
    final d = Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch - ms,
    );
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  // --- SKED (PMS) -----------------------------------------------------------

  void _savePmsCheck(PmsCheck c) {
    final json = jsonEncode(c.toJson());
    _store.pmsChecks[c.id] = c;
    _node!.putRaw(kPmsChecks, c.id, json);
    _bleBroadcast(kPmsChecks, c.id, json);
    if (mounted) setState(() {});
  }

  /// Record a PMS check as accomplished by the signed-in person on [forDayMs]
  /// (defaults to today) and sync it.
  void _accomplishCheck(PmsCheck c, {int? forDayMs}) {
    c.accomplish(
      _name,
      DateTime.now().millisecondsSinceEpoch,
      forDayMs: forDayMs,
    );
    _savePmsCheck(c);
  }

  PmsCheck _createPmsCheck({
    required String mip,
    required int seq,
    required String title,
    required String ein,
    required Periodicity periodicity,
    required int estMinutes,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = PmsCheck.create(
      id: 'pms-$now-${_randHex(3)}',
      mip: mip,
      seq: seq,
      title: title,
      ein: ein,
      workcenter: _workcenter,
      periodicity: periodicity,
      estMinutes: estMinutes,
      nowMs: now,
    );
    _savePmsCheck(c);
    return c;
  }

  /// Roles that schedule PMS work (vs. just accomplishing it).
  bool get _canManageSked =>
      _role != null && _role != Role.technician && _role != Role.portEngineer;

  /// Seed a relatable example — a bicycle (EIN BIKE-1) with a spread of PMS
  /// checks across periodicities + statuses — at the signed-in work center.
  /// Stable ids, so re-loading just refreshes them.
  void _seedBicyclePms() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const ein = 'BIKE-1';
    const mip = 'BCYL/001-26'; // the bicycle's Maintenance Index Page
    const day = 86400000;
    // id, seq, title, periodicity, est-min, last-done-days-ago (null = never).
    // One MRC per periodicity (D/W/2W/M/Q/S/A) + a situational (R); the MRC code
    // is the periodicity code + seq (D-1, W-1, …). Back-dated for a status spread.
    final seeds = <(String, int, String, Periodicity, int, int?)>[
      (
        'pms-bike-001',
        1,
        'Inspect tires & check pressure',
        Periodicity.daily,
        5,
        0,
      ),
      ('pms-bike-002', 1, 'Clean & lubricate chain', Periodicity.weekly, 10, 9),
      (
        'pms-bike-003',
        1,
        'Check & torque frame bolts',
        Periodicity.biweekly,
        10,
        13,
      ),
      ('pms-bike-004', 1, 'Clean headset bearing', Periodicity.monthly, 20, 28),
      (
        'pms-bike-005',
        1,
        'True wheels & check spoke tension',
        Periodicity.quarterly,
        45,
        95,
      ),
      ('pms-bike-006', 1, 'Bleed brakes', Periodicity.semiannual, 40, 175),
      (
        'pms-bike-007',
        1,
        'Full drivetrain overhaul',
        Periodicity.annual,
        120,
        null,
      ),
      (
        'pms-bike-008',
        1,
        'Replace brake pads when worn',
        Periodicity.situational,
        25,
        null,
      ),
    ];
    for (final s in seeds) {
      _savePmsCheck(
        PmsCheck(
          id: s.$1,
          mip: mip,
          seq: s.$2,
          title: s.$3,
          ein: ein,
          workcenter: _workcenter,
          periodicity: s.$4,
          estMinutes: s.$5,
          lastDoneMs: s.$6 == null ? null : now - s.$6! * day,
          lastBy: s.$6 == null ? '' : 'demo',
          createdAtMs: now,
          updatedAtMs: now,
        ),
      );
    }
  }

  void _saveOrgEntity(String coll, String id, String json) {
    _node!.putRaw(coll, id, json);
    _bleBroadcast(coll, id, json);
  }

  /// The mesh host (the DIVO who minted the key) seeds a starter org chart the
  /// first time it comes up, so the mesh isn't empty. Joiners receive it synced.
  void _seedOrgIfHost() {
    // Runs at node start (before sign-in), so gate on host, not role. Re-seed
    // when the current departments aren't present yet, so an existing mesh on
    // an older org picks up the standard structure (overwrites by id; old extra
    // work centers simply go unused).
    if (!_isMeshHost || _org.departments.containsKey('EXEC')) return;
    _ensureCanonicalOrg();
  }

  /// Write the canonical departments/divisions/work centers to the org + mesh
  /// (idempotent — overwrites by id). The shared org-setup path.
  void _ensureCanonicalOrg() {
    final seed = seedOrgChart();
    for (final d in seed.departments.values) {
      _org.departments[d.id] = d;
      _saveOrgEntity(kDepts, d.id, jsonEncode(d.toJson()));
    }
    for (final v in seed.divisions.values) {
      _org.divisions[v.id] = v;
      _saveOrgEntity(kDivs, v.id, jsonEncode(v.toJson()));
    }
    for (final w in seed.workcenters.values) {
      _org.workcenters[w.id] = w;
      _saveOrgEntity(kWcs, w.id, jsonEncode(w.toJson()));
    }
  }

  void _appendEvent(Job job, String action, String comment) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ev = JobEvent(
      jobId: job.id,
      seq: now,
      actor: _name,
      role: _role!,
      action: action,
      comment: comment,
      tsMs: now,
    );
    _store.ingestEvent(ev);
    final json = jsonEncode(ev.toJson());
    _node!.putRaw(kLog, ev.docId, json);
    _bleBroadcast(kLog, ev.docId, json);
  }

  void _createJob({
    required String title,
    required String ein,
    required String symptom,
    required int priority,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final job = Job.originate(
      id: 'JOB-$now',
      title: title,
      ein: ein,
      symptom: symptom,
      priority: priority,
      originator: _name,
      workcenter: _workcenter,
      nowMs: now,
    );
    _jobs[job.id] = job;
    _saveJob(job);
    _appendEvent(job, 'originate', '');
    setState(() {});
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  void _approve(Job job) {
    final wasCloseout = job.phase == JobPhase.closeout;
    job.approve(_now);
    _saveJob(job);
    final verb = !wasCloseout
        ? 'approve'
        : (job.phase == JobPhase.closed ? 'close' : 'close_confirm');
    _appendEvent(job, verb, '');
    setState(() {});
  }

  void _returnDown(Job job, String comment) {
    job.returnDown(_now);
    _saveJob(job);
    _appendEvent(job, 'return', comment);
    setState(() {});
  }

  void _requestTa(Job job) {
    job.requestTa(_now);
    _saveJob(job);
    _appendEvent(job, 'ta_request', '');
    setState(() {});
  }

  void _engageTa(Job job) {
    job.engageTa(_now);
    _saveJob(job);
    _appendEvent(job, 'ta_engage', '');
    setState(() {});
  }

  void _declineTa(Job job, String comment) {
    job.declineTa(_now);
    _saveJob(job);
    _appendEvent(job, 'ta_decline', comment);
    setState(() {});
  }

  void _startWork(Job job) {
    job.startWork(_now);
    _saveJob(job);
    _appendEvent(job, 'start_work', '');
    setState(() {});
  }

  void _markComplete(Job job) {
    job.markComplete(_now);
    _saveJob(job);
    _appendEvent(job, 'complete', '');
    setState(() {});
  }

  void _rejectCloseout(Job job, String comment) {
    job.rejectCloseout(_now);
    _saveJob(job);
    _appendEvent(job, 'close_reject', comment);
    setState(() {});
  }

  // Queries delegate to the store (single source of truth; the store's
  // notification policy fires _notify via its onNotify callback).
  bool _needsMyAction(Job j) => _store.needsMyAction(j);
  bool _canSee(Job j) => _store.canSee(j);

  void _notify(String title, String preview, String? peer) => PeatNotifications
      .instance
      .showRemoteChange(collection: title, preview: preview, peerId: peer);

  @override
  Widget build(BuildContext context) {
    // 1. Mesh membership: host a new mesh or scan a join QR.
    if (_formationKey == null) {
      return _StartScreen(
        onHost: _hostMesh,
        onJoin: _openScanner,
        onJoinByCode: _promptJoinCode,
      );
    }
    if (_error != null) {
      return Scaffold(body: Center(child: Text('Failed to start: $_error')));
    }
    if (_node == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // 2. Account sign-in (pick your profile + PIN, or bootstrap the first admin).
    if (_account == null) {
      return _SignInScreen(
        accounts:
            _accounts.values
                .where((a) => a.role != Role.kratos) // Kratos stays hidden
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
        org: _org,
        isHost: _isMeshHost,
        onSignIn: _setAccount,
        onCreate: _createAccount,
        onUnlockKratos: _unlockKratos,
        onReset: () => _confirmReset(context),
      );
    }

    // Role-scoped visibility: a WCS/Tech sees their work center, LPO/DIVO their
    // division, DH their department, 3MC the ship, the PE only TA'd jobs.
    final mine =
        _jobs.values.where((j) => _needsMyAction(j) && _canSee(j)).toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));
    // PENDING = in routing (climbing the approval or close-out ladder);
    // ACTIVE = approved + being worked (execution, or off-ship via TA).
    final pending =
        _jobs.values
            .where(
              (j) =>
                  _canSee(j) &&
                  (j.phase == JobPhase.approval ||
                      j.phase == JobPhase.closeout),
            )
            .toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final active =
        _jobs.values
            .where(
              (j) =>
                  _canSee(j) &&
                  (j.phase == JobPhase.execution || j.phase == JobPhase.ta),
            )
            .toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final completed =
        _jobs.values.where((j) => j.isClosed && _canSee(j)).toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));

    _peers = _node!.peerCount;

    // Wide (macOS / tablet): vertical rail + content. Narrow (phone): a feature
    // menu that opens each feature full-screen.
    final wide = MediaQuery.of(context).size.width >= 600;
    return wide
        ? _wideHome(mine, pending, active, completed)
        : _narrowHome(mine, pending, active, completed);
  }

  List<Widget> _appBarActions() => [
    if (!_isKratos)
      IconButton(
        onPressed: _openFeedbackSheet,
        icon: const Icon(Icons.feedback_outlined),
        tooltip: 'Send feedback',
      ),
    if (_account?.isAdmin ?? false)
      IconButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _AdminScreen(
              accounts:
                  _accounts.values
                      .where(
                        (a) => a.role != Role.kratos,
                      ) // Kratos stays hidden
                      .toList()
                    ..sort((a, b) => a.name.compareTo(b.name)),
              org: _org,
              onCreate: _createAccount,
              onUpdate: _updateAccount,
            ),
          ),
        ),
        icon: const Icon(Icons.manage_accounts),
        tooltip: 'Manage accounts',
      ),
    themeToggleButton(context),
    PopupMenuButton<String>(
      tooltip: 'Account',
      onSelected: (v) {
        if (v == 'signout') _signOut();
        if (v == 'reset') _confirmReset(context);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'signout',
          child: ListTile(
            leading: Icon(Icons.logout),
            title: Text('Sign out / switch user'),
          ),
        ),
        PopupMenuItem(
          value: 'reset',
          child: ListTile(
            leading: Icon(Icons.restart_alt),
            title: Text('Reset / leave mesh'),
          ),
        ),
      ],
    ),
  ];

  /// The role / work-center / scope / peer-count strip under the app-bar title.
  PreferredSizeWidget _headerBar() => PreferredSize(
    preferredSize: const Size.fromHeight(34),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          _Badge(_role!.tag, off: _role!.offShip),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '$_name · $_workcenter · sees ${scopeLabel(_role!)}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          const Spacer(),
          Icon(Icons.hub, size: 16, color: Colors.white.withValues(alpha: 0.9)),
          const SizedBox(width: 4),
          Text('$_peers', style: const TextStyle(color: Colors.white)),
        ],
      ),
    ),
  );

  Widget _newJobFab() => FloatingActionButton.extended(
    onPressed: _openCreate,
    backgroundColor: _duOrange, // DU orange-red for the New Job box
    foregroundColor: Colors.white,
    icon: const Icon(Icons.add),
    label: const Text('New job'),
  );

  /// A feature icon, with an unread-count badge on the Feedback item (Kratos).
  /// Features considered done for the v1 (target: 2026-09-01) — their rail icon
  /// turns DU orange-red to mark them complete.
  static const _v1Done = {'Feedback'};

  Widget _badgedIcon(
    IconData icon,
    String label, {
    Color? color,
    double? size,
  }) {
    // A v1-complete feature shows its icon in the DU red.
    final base = Icon(
      icon,
      color: _v1Done.contains(label) ? _duOrange : color,
      size: size,
    );
    if (label == 'Feedback' && _store.unreadFeedback > 0) {
      return Badge.count(count: _store.unreadFeedback, child: base);
    }
    return base;
  }

  /// The action button for the current feature (CSMP → new job, SKED → add
  /// check), or none.
  Widget? _featureFab() {
    switch (_navFeatures[_feature].$2) {
      case 'CSMP':
        return _newJobFab();
      case 'SKED':
        return _canManageSked
            ? FloatingActionButton.extended(
                onPressed: _openAddCheck,
                icon: const Icon(Icons.add),
                label: const Text('Add check'),
              )
            : null;
      default:
        return null;
    }
  }

  /// Wide layout: the vertical feature rail + content side by side.
  Widget _wideHome(
    List<Job> mine,
    List<Job> pending,
    List<Job> active,
    List<Job> completed,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grapheion'),
        actions: _appBarActions(),
        bottom: _headerBar(),
      ),
      floatingActionButton: _featureFab(),
      body: Row(
        children: [
          _featureRail(),
          const VerticalDivider(width: 1),
          Expanded(child: _featureBody(mine, pending, active, completed)),
        ],
      ),
    );
  }

  /// Narrow layout: a feature menu; tapping opens a feature full-screen (stays
  /// in the widget tree, so it updates live; system back returns to the menu).
  Widget _narrowHome(
    List<Job> mine,
    List<Job> pending,
    List<Job> active,
    List<Job> completed,
  ) {
    if (!_featureOpen) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Grapheion'),
          actions: _appBarActions(),
          bottom: _headerBar(),
        ),
        body: ListView(
          children: [
            for (var i = 0; i < _navFeatures.length; i++)
              ListTile(
                leading: _badgedIcon(_navFeatures[i].$1, _navFeatures[i].$2),
                title: Text(_navFeatures[i].$2),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => setState(() {
                  _feature = i;
                  _featureOpen = true;
                }),
              ),
          ],
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _featureOpen = false);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: () => setState(() => _featureOpen = false),
          ),
          title: Text(_navFeatures[_feature].$2),
          actions: _appBarActions(),
        ),
        floatingActionButton: _featureFab(),
        body: _featureBody(mine, pending, active, completed),
      ),
    );
  }

  // Feature areas, in top-bar order. Index 0 (CSMP) shows the New-job FAB.
  static const _features = <(IconData, String)>[
    (Icons.construction, 'CSMP'),
    (Icons.calendar_month, 'SKED'),
    (Icons.warning_amber, 'CASREP'),
    (Icons.event_note, 'Watchbills'),
    (Icons.shield, 'Duty Section'),
    (Icons.workspace_premium, 'PQS'),
    (Icons.hub, 'Connection'),
    (Icons.inventory_2, 'Supply'),
    (Icons.school, 'Training'),
    (Icons.how_to_reg, 'Muster'),
  ];

  /// The nav features for the signed-in role — Kratos additionally gets the
  /// Feedback inbox (the only role that can read it).
  List<(IconData, String)> get _navFeatures => [
    ..._features,
    if (_canAdmin) (Icons.admin_panel_settings, 'Admin'),
    if (_isKratos) (Icons.feedback, 'Feedback'),
  ];

  /// Left feature rail: a vertical, tappable list of features (scrolls if it
  /// can't all fit; content switches on tap — no swipe).
  Widget _featureRail() {
    return Container(
      width: 78,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 8),
            for (var i = 0; i < _navFeatures.length; i++)
              _featureRailItem(i, _navFeatures[i].$1, _navFeatures[i].$2),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _featureRailItem(int idx, IconData icon, String label) {
    final selected = _feature == idx;
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return InkWell(
      onTap: () => setState(() => _feature = idx),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 1),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            _badgedIcon(icon, label, color: fg, size: 26),
            const SizedBox(height: 3),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: fg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _featureBody(
    List<Job> mine,
    List<Job> pending,
    List<Job> active,
    List<Job> completed,
  ) {
    // Dispatch on the feature label so the order of _features can change freely.
    switch (_navFeatures[_feature].$2) {
      case 'CSMP':
        return _csmpView(mine, pending, active, completed);
      case 'SKED':
        return _skedPage(active);
      case 'CASREP':
        return _casrepPage();
      case 'Connection':
        return _connectionsPage();
      case 'Watchbills':
        return _watchbillPage();
      case 'PQS':
        return _pqsPage();
      case 'Duty Section':
        return _dutySectionPage();
      case 'Admin':
        return _adminPage();
      case 'Feedback':
        return _feedbackPage();
      case 'Supply':
        return _stubPage(
          Icons.inventory_2,
          'Supply',
          'Parts ordering, NSN lookup, requisition status.',
        );
      case 'Training':
        return _stubPage(
          Icons.school,
          'Training',
          'Qualifications + PQS tracking.',
        );
      default:
        return _stubPage(
          Icons.how_to_reg,
          'Muster',
          'Personnel accountability + muster.',
        );
    }
  }

  /// CSMP: the corrective-maintenance views as tap-only sub-tabs (no swipe).
  /// INBOX = my action · PENDING = in routing · ACTIVE = approved/in work ·
  /// COMPLETED = closed.
  Widget _csmpView(
    List<Job> mine,
    List<Job> pending,
    List<Job> active,
    List<Job> completed,
  ) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            labelPadding: EdgeInsets.symmetric(horizontal: 4),
            tabs: [
              Tab(text: 'INBOX'),
              Tab(text: 'PENDING'),
              Tab(text: 'ACTIVE'),
              Tab(text: 'COMPLETED'),
            ],
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _jobList(mine, emptyText: 'No jobs awaiting your action.'),
                _jobList(pending, emptyText: 'Nothing in routing.'),
                _jobList(active, emptyText: 'No approved jobs in work.'),
                _jobList(completed, emptyText: 'No closed jobs yet.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stubPage(IconData icon, String title, String blurb) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '$blurb\n\nComing soon.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // --- Watchbills + PQS -----------------------------------------------------

  static const _qualColors = {
    QualStage.qualified: Colors.green,
    QualStage.boardPending: Colors.blue,
    QualStage.inProgress: Colors.orange,
    QualStage.notStarted: Colors.grey,
  };

  /// Watchbills — fill the roles an evolution requires for a day. In port the
  /// evolution is the day-to-day duty: standing watches + rotating section
  /// shifts. Only PQS-qualified people can be posted; auto-generate fills it.
  Widget _watchbillPage() {
    final evos = _store.evolutions.values.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    if (evos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No watchbill set up yet.',
                style: TextStyle(color: Colors.grey),
              ),
              if (_canManageWatch) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _seedQualifications,
                  icon: const Icon(Icons.anchor),
                  label: const Text('Load In-Port Duty + stations'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => _openEvolutionEditor(null),
                  icon: const Icon(Icons.add),
                  label: const Text('New evolution'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final ev = evos.firstWhere(
      (e) => e.id == _evolutionId,
      orElse: () => evos.first,
    );
    final day =
        startOfDay(DateTime.now().millisecondsSinceEpoch) +
        _watchDayOffset * 86400000;
    final roles = ev.roles.toList()..sort((a, b) => a.order.compareTo(b.order));
    return Column(
      children: [
        // Evolution selector + edit / new (admins).
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  value: ev.id,
                  items: [
                    for (final e in evos)
                      DropdownMenuItem(
                        value: e.id,
                        child: Text(
                          e.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _evolutionId = v),
                ),
              ),
              if (_canManageWatch) ...[
                IconButton(
                  tooltip: 'Edit evolution',
                  icon: const Icon(Icons.edit, size: 20),
                  onPressed: () => _openEvolutionEditor(ev),
                ),
                IconButton(
                  tooltip: 'New evolution',
                  icon: const Icon(Icons.add),
                  onPressed: () => _openEvolutionEditor(null),
                ),
              ],
            ],
          ),
        ),
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() => _watchDayOffset--),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Center(
                child: Text(
                  '${weekdayLabel(day)}  ${_shortDate(day)}',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _watchDayOffset++),
              icon: const Icon(Icons.chevron_right),
            ),
            if (_watchDayOffset != 0)
              TextButton(
                onPressed: () => setState(() => _watchDayOffset = 0),
                child: const Text('Today'),
              ),
          ],
        ),
        if (_canManageWatch)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _autoFillBill(ev, day),
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('Auto-generate'),
                ),
                TextButton.icon(
                  onPressed: () => _recordWatches(ev, day),
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('Record'),
                ),
                TextButton.icon(
                  onPressed: () => _clearBill(ev, day),
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: const Text('Clear'),
                ),
                TextButton.icon(
                  onPressed: _seedDemoCrew,
                  icon: const Icon(Icons.group_add, size: 18),
                  label: const Text('Demo crew'),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final r in roles)
                if (r.rotating)
                  _billRotatingGroup(day, ev, r)
                else
                  _billSlotTile(day, ev, r, '', r.name, 'whole day'),
            ],
          ),
        ),
      ],
    );
  }

  /// A rotating role — a header + one row per section shift.
  Widget _billRotatingGroup(
    int day,
    Evolution ev,
    EvolutionRole r, {
    Set<String>? scope,
    bool? canEdit,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(
            r.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        for (final s in ev.shifts)
          _billSlotTile(
            day,
            ev,
            r,
            s.id,
            'Sec ${s.label}',
            '${s.start}-${s.end}',
            scope: scope,
            canEdit: canEdit,
          ),
      ],
    );
  }

  /// One fillable bill slot (a standing role, or one shift of a rotating role).
  Widget _billSlotTile(
    int day,
    Evolution ev,
    EvolutionRole r,
    String shiftId,
    String label,
    String sub, {
    Set<String>? scope,
    bool? canEdit,
  }) {
    final edit = canEdit ?? _canManageWatch;
    final pid = _store.billAssignee(day, ev.id, r.id, shiftId);
    final unqual =
        pid != null && pid.isNotEmpty && !_store.isQualified(pid, r.stationId);
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 58,
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      title: (pid == null || pid.isEmpty)
          ? const Text('— unassigned', style: TextStyle(color: Colors.grey))
          : Row(
              children: [
                Flexible(
                  child: Text(
                    _billPersonLabel(pid),
                    style: TextStyle(
                      color: unqual ? _duOrange : null,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _qualMark(pid, r.stationId),
              ],
            ),
      subtitle: Text(
        sub,
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      trailing: edit ? const Icon(Icons.edit, size: 18) : null,
      onTap: edit
          ? () => _openBillAssign(day, ev, r, shiftId, label, scope: scope)
          : null,
    );
  }

  /// A person on the bill — rate + name (a watchbill is a roster, names show).
  String _billPersonLabel(String pid) {
    final a = _store.accounts[pid];
    if (a == null) return pid;
    return a.rate.isEmpty ? a.name : '${a.rate} ${a.name}';
  }

  /// QUAL marker per the bill legend (Q / I / UI / N).
  Widget _qualMark(String pid, String stationId) {
    final (txt, color) = switch (_store.qualStage(pid, stationId)) {
      QualStage.qualified => ('Q', Colors.green),
      QualStage.boardPending => ('I', Colors.blue),
      QualStage.inProgress => ('UI', Colors.orange),
      QualStage.notStarted => ('N', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        txt,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _openBillAssign(
    int day,
    Evolution ev,
    EvolutionRole r,
    String shiftId,
    String slot, {
    Set<String>? scope, // if set, only these people may be posted (a section)
  }) {
    // The time of this slot (empty for a standing watch).
    var slotTime = '';
    for (final s in ev.shifts) {
      if (s.id == shiftId) {
        slotTime = '${s.start}-${s.end}';
        break;
      }
    }
    // How many times each person has already stood THIS watch time (or, for a
    // standing watch, their total) — so the least-burdened sort to the top and
    // you stop stacking the same people on the mids.
    final load = <String, int>{};
    final qualified = _store
        .qualifiedFor(r.stationId)
        .where((p) => scope == null || scope.contains(p))
        .toList();
    for (final pid in qualified) {
      final h = _personWatchHistory(pid);
      load[pid] = slotTime.isEmpty ? h.total : (h.byTime[slotTime] ?? 0);
    }
    qualified.sort((a, b) {
      final c = (load[a] ?? 0).compareTo(load[b] ?? 0);
      return c != 0 ? c : _billPersonLabel(a).compareTo(_billPersonLabel(b));
    });
    final current = _store.billAssignee(day, ev.id, r.id, shiftId);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${r.name} · $slot',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              if (qualified.isEmpty)
                const ListTile(
                  leading: Icon(Icons.block, color: Colors.grey),
                  title: Text('No qualified watchstanders'),
                  subtitle: Text('Qualify someone for this station in PQS.'),
                ),
              for (final pid in qualified)
                ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(_billPersonLabel(pid)),
                  subtitle: (load[pid] ?? 0) == 0
                      ? const Text(
                          'not stood yet',
                          style: TextStyle(color: Colors.green, fontSize: 12),
                        )
                      : Text(
                          slotTime.isEmpty
                              ? 'stood ${load[pid]} watch${load[pid] == 1 ? '' : 'es'}'
                              : 'stood this watch ×${load[pid]}',
                          style: const TextStyle(fontSize: 12),
                        ),
                  trailing: current == pid
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                  onTap: () {
                    _setBillEntry(day, ev.id, r.id, shiftId, pid);
                    Navigator.pop(ctx);
                  },
                ),
              if (current != null && current.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.clear),
                  title: const Text('Unassign'),
                  onTap: () {
                    _setBillEntry(day, ev.id, r.id, shiftId, null);
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Duty Section — your 1/5 of the crew for the in-port duty day. Everyone
  /// DH-and-below sees only their own section; ship-wide roles see all five and
  /// can auto-generate the rotation.
  Widget _dutySectionPage() {
    final manager = _canManageSections;
    final mine = _account?.dutySection ?? '';
    if (!manager && mine.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            "You're not assigned to a duty section yet.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    final section = manager ? _dsSection : mine;
    final members =
        _store.accounts.values
            .where((a) => a.role != Role.kratos && a.dutySection == section)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final memberIds = members.map((a) => a.id).toSet();
    final secGaps = _inPortRequiredStations()
        .where((st) => !members.any((a) => _store.isQualified(a.id, st)))
        .toList();
    final ev = _inPortEvolution();

    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          if (manager) _dsManagerBar(),
          _dutySectionHeader(
            manager ? 'Section $section' : 'Your Duty Section — $section',
            members.length,
            secGaps.isEmpty ? null : secGaps,
          ),
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'ROSTER'),
              Tab(text: 'WATCHBILL'),
              Tab(text: 'BULLETIN'),
              Tab(text: 'HISTORY'),
            ],
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                members.isEmpty
                    ? const Center(
                        child: Text(
                          'No one in this section yet.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView(
                        children: [for (final a in members) _personnelTile(a)],
                      ),
                _dsWatchbill(ev, section, memberIds),
                _dsBulletin(section),
                _dsHistory(section),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dsManagerBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in ['1', '2', '3', '4', '5'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('Sec $s'),
                      selected: _dsSection == s,
                      onSelected: (_) => setState(() => _dsSection = s),
                    ),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Edit in-port positions (the constraints)',
          icon: const Icon(Icons.tune),
          onPressed: () => _openEvolutionEditor(_inPortEvolution()),
        ),
        IconButton(
          tooltip: 'Auto-generate 5 sections',
          icon: const Icon(Icons.auto_fix_high),
          onPressed: _autoAssignDutySections,
        ),
      ],
    ),
  );

  /// The section's in-port watchbill — the In-Port Duty evolution filled from
  /// ONLY this section's members.
  Widget _dsWatchbill(Evolution? ev, String section, Set<String> memberIds) {
    if (ev == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No in-port watchbill defined yet.',
                style: TextStyle(color: Colors.grey),
              ),
              if (_canManageWatch) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _openEvolutionEditor(null),
                  icon: const Icon(Icons.add),
                  label: const Text('Define in-port positions'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final day = _sectionDayMs(section);
    final roles = ev.roles.toList()..sort((a, b) => a.order.compareTo(b.order));
    final routing = _store.routingFor(section);
    // Assignments are editable only while drafting, by a section lead or manager.
    final canEdit = _canEditSectionBill(section) && routing.status.planEditable;
    return Column(
      children: [
        _billStatusBar(ev, section, routing),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final r in roles)
                if (r.rotating)
                  _billRotatingGroup(
                    day,
                    ev,
                    r,
                    scope: memberIds,
                    canEdit: canEdit,
                  )
                else
                  _billSlotTile(
                    day,
                    ev,
                    r,
                    '',
                    r.name,
                    'whole day',
                    scope: memberIds,
                    canEdit: canEdit,
                  ),
            ],
          ),
        ),
      ],
    );
  }

  /// Past recorded duty days for a section, newest first — each expands to the
  /// watchbill that was stood that day plus any logged duty-day events.
  Widget _dsHistory(String section) {
    final days = _store.recordedDutyDays(section);
    if (days.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No recorded duty days yet.\n'
            'A day lands here once the CDO approves the finalized watchbill.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView(
      children: [
        for (final day in days)
          _dsHistoryCard(
            day,
            _store.stoodForDay(day, section),
            _store.eventsForDay(day, section),
          ),
      ],
    );
  }

  Widget _dsHistoryCard(
    int day,
    List<WatchStood> watches,
    List<DutyDayEvent> events,
  ) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        title: Text('${weekdayLabel(day)}   ${_shortDate(day)}'),
        subtitle: Text(
          '${watches.length} watch${watches.length == 1 ? '' : 'es'}'
          '${events.isEmpty ? '' : ' · ${events.length} event${events.length == 1 ? '' : 's'}'}',
        ),
        children: [
          for (final w in watches)
            ListTile(
              dense: true,
              leading: const Icon(Icons.schedule, size: 18),
              title: Text(w.stationName),
              subtitle: Text(w.timeLabel.isEmpty ? 'Standing watch' : w.timeLabel),
              trailing: Text(_billPersonLabel(w.personId)),
            ),
          if (events.isNotEmpty)
            const Divider(height: 1, indent: 16, endIndent: 16),
          for (final e in events)
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: Colors.orange,
              ),
              title: Text(e.type),
              subtitle: e.note.isEmpty ? null : Text(e.note),
            ),
        ],
      ),
    );
  }

  /// The section bulletin — a post board scoped to the section.
  Widget _dsBulletin(String section) {
    final posts = _store.bulletinForSection(section);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: posts.isEmpty
              ? const Center(
                  child: Text(
                    'No posts yet — say something.',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: posts.length,
                  itemBuilder: (_, i) {
                    final p = posts[i];
                    final mine = p.authorId == _account?.id;
                    return ListTile(
                      dense: true,
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              p.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _shortDate(p.atMs),
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(p.text),
                      trailing: (mine || _canManageSections)
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => _deleteBulletin(p.id),
                            )
                          : null,
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bulletinCtrl,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Post to Section $section…',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.send, color: scheme.primary),
                onPressed: () => _postBulletin(section, _bulletinCtrl.text),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _deleteBulletin(String id) {
    final p = _store.bulletin[id];
    if (p == null) return;
    _store.bulletin.remove(id);
    final tomb = jsonEncode({
      ...p.toJson(),
      'text': '',
    }); // empty text = removed
    _node!.putRaw(kBulletin, id, tomb);
    _bleBroadcast(kBulletin, id, tomb);
    if (mounted) setState(() {});
  }

  Widget _dutySectionHeader(String title, int count, List<String>? gaps) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          if (gaps != null && gaps.isNotEmpty)
            Expanded(
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: _duOrange, size: 15),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      "can't man: ${gaps.map((s) => _store.qualifications[s]?.abbr ?? s).join(', ')}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _duOrange, fontSize: 11),
                    ),
                  ),
                ],
              ),
            )
          else
            const Spacer(),
          Text(
            '$count',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Admin — the personnel hub for DIVO and up. Two shelves (Officer /
  /// Enlisted), each a roster of people with their division + qualifications.
  Widget _adminPage() {
    final q = _adminSearchCtrl.text.trim().toLowerCase();
    final people = _store.accounts.values
        .where((a) => a.role != Role.kratos)
        .where(
          (a) =>
              q.isEmpty ||
              '${a.rate} ${a.name}'.toLowerCase().contains(q) ||
              _divisionName(a).toLowerCase().contains(q),
        )
        .toList();
    int byName(Account a, Account b) => a.name.compareTo(b.name);
    final officers = people.where(_isOfficer).toList()..sort(byName);
    final enlisted = people.where((a) => !_isOfficer(a)).toList()..sort(byName);
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'OFFICER (${officers.length})'),
              Tab(text: 'ENLISTED (${enlisted.length})'),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _adminSearchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search name, rate, or division',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _adminSearchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () =>
                            setState(() => _adminSearchCtrl.clear()),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          _adminSortBar(),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [_personnelList(officers), _personnelList(enlisted)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _adminSortBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Row(
      children: [
        const Text('Sort', style: TextStyle(color: Colors.grey)),
        const SizedBox(width: 10),
        for (final s in _AdminSort.values)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(switch (s) {
                _AdminSort.name => 'A–Z',
                _AdminSort.division => 'Division',
                _AdminSort.department => 'Department',
              }),
              selected: _adminSort == s,
              onSelected: (_) => setState(() => _adminSort = s),
            ),
          ),
        const Spacer(),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Re-stamp all accounts (force sync convergence)',
          icon: const Icon(Icons.published_with_changes, size: 20),
          onPressed: _confirmRestampAccounts,
        ),
      ],
    ),
  );

  Widget _personnelList(List<Account> people) {
    if (people.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No personnel here yet.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (_adminSort == _AdminSort.name) {
      final sorted = [...people]..sort((a, b) => a.name.compareTo(b.name));
      return ListView.builder(
        itemCount: sorted.length,
        itemBuilder: (_, i) => _personnelTile(sorted[i]),
      );
    }
    final keyOf = _adminSort == _AdminSort.division
        ? _divisionName
        : _departmentName;
    final groups = <String, List<Account>>{};
    for (final a in people) {
      (groups[keyOf(a)] ??= []).add(a);
    }
    final keys = groups.keys.toList()..sort();
    final items = <Widget>[];
    for (final k in keys) {
      final members = groups[k]!..sort((a, b) => a.name.compareTo(b.name));
      items.add(_groupHeader(k, members.length));
      items.addAll(members.map(_personnelTile));
    }
    return ListView(children: items);
  }

  Widget _groupHeader(String title, int n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: scheme.primary,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          Text('$n', style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _personnelTile(Account a) {
    final quals = _personQuals(a.id);
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        child: Text(a.name.isEmpty ? '?' : a.name[0].toUpperCase()),
      ),
      title: Text(a.rate.isEmpty ? a.name : '${a.rate} ${a.name}'),
      subtitle: Text(
        '${a.role.title} · ${_divisionName(a)}'
        '${a.dutyPosition.leadsDutySection ? ' · ${a.dutyPosition.tag}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        '${quals.length} qual${quals.length == 1 ? '' : 's'}',
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
      onTap: () => _openPersonSheet(a),
    );
  }

  void _openPersonSheet(Account a) {
    final quals = _personQuals(a.id);
    final history = _personWatchHistory(a.id);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      child: Text(
                        a.name.isEmpty ? '?' : a.name[0].toUpperCase(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.rate.isEmpty ? a.name : '${a.rate} ${a.name}',
                            style: Theme.of(ctx).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 2),
                          _Badge(a.role.tag, off: a.role.offShip),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _infoRow('Department', _departmentName(a)),
                _infoRow('Division', _divisionName(a)),
                _infoRow(
                  'Duty section',
                  a.dutySection.isEmpty ? '—' : 'Section ${a.dutySection}',
                ),
                _infoRow('Billet', a.billet.isEmpty ? '—' : a.billet),
                const SizedBox(height: 16),
                Text(
                  'Qualifications (${quals.length})',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (quals.isEmpty)
                  const Text('None yet', style: TextStyle(color: Colors.grey))
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [for (final q in quals) Chip(label: Text(q))],
                  ),
                if (history.total > 0) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Watch history (${history.total} stood)',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e
                          in (history.byStation.entries.toList()
                            ..sort((x, y) => y.value.compareTo(x.value))))
                        Chip(label: Text('${e.key} ×${e.value}')),
                    ],
                  ),
                  if (history.byTime.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'By watch time — spread the mids',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final e
                            in (history.byTime.entries.toList()
                              ..sort((x, y) => x.key.compareTo(y.key))))
                          Chip(label: Text('${e.key}  ×${e.value}')),
                      ],
                    ),
                  ],
                ],
                if (_canAdmin) ...[
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openPersonEditor(a);
                    },
                    icon: const Icon(Icons.edit, size: 18),
                    label: const Text('Edit role & assignment'),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Edit a person's role + department/division assignment (admins). Picking a
  /// division sets the person's work center to that division's default WC, so
  /// their department + division derive correctly everywhere.
  void _openPersonEditor(Account a) {
    var role = a.role;
    final curWc = _org.workcenters[a.workcenterId];
    var deptId = curWc != null
        ? _org.divisions[curWc.divisionId]?.departmentId
        : null;
    var divId = curWc?.divisionId;
    var dutySection = a.dutySection;
    var dutyPosition = a.dutyPosition;
    final billetCtrl = TextEditingController(text: a.billet);
    final depts = _org.departments.values.toList()
      ..sort((x, y) => x.name.compareTo(y.name));
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final divs =
              _org.divisions.values
                  .where((d) => d.departmentId == deptId)
                  .toList()
                ..sort((x, y) => x.name.compareTo(y.name));
          if (!divs.any((d) => d.id == divId)) {
            divId = divs.isNotEmpty ? divs.first.id : null;
          }
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Edit ${a.rate} ${a.name}',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<Role>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: [
                    for (final r in Role.values)
                      if (r != Role.kratos)
                        DropdownMenuItem(value: r, child: Text(r.title)),
                  ],
                  onChanged: (r) => setS(() => role = r ?? role),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: deptId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Department'),
                  items: [
                    for (final d in depts)
                      DropdownMenuItem(value: d.id, child: Text(d.name)),
                  ],
                  onChanged: (v) => setS(() {
                    deptId = v;
                    divId = null; // reset; recomputed above on rebuild
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: divId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Division'),
                  items: [
                    for (final d in divs)
                      DropdownMenuItem(value: d.id, child: Text(d.name)),
                  ],
                  onChanged: (v) => setS(() => divId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: dutySection.isEmpty ? null : dutySection,
                  decoration: const InputDecoration(labelText: 'Duty section'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('—')),
                    for (var s = 1; s <= 6; s++)
                      DropdownMenuItem(value: '$s', child: Text('Section $s')),
                  ],
                  onChanged: (v) => setS(() => dutySection = v ?? ''),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<DutyPosition>(
                  initialValue: dutyPosition,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Duty position',
                    helperText:
                        'Section Leader / CDO can run the section watchbill',
                  ),
                  items: [
                    for (final p in DutyPosition.values)
                      DropdownMenuItem(value: p, child: Text(p.title)),
                  ],
                  onChanged: (p) => setS(() => dutyPosition = p ?? dutyPosition),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: billetCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Billet',
                    hintText: 'e.g. CSE Maintenance, 1st Div LPO',
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    a.role = role;
                    if (divId != null) a.workcenterId = '$divId-WC';
                    a.dutySection = dutySection;
                    a.dutyPosition = dutyPosition;
                    a.billet = billetCtrl.text.trim();
                    _updateAccount(a);
                    Navigator.pop(ctx);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(color: Colors.grey)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  /// PQS — each work-center member's progress across the whole qualification
  /// tree (designations first, then watch stations, knowledge, letters).
  Widget _pqsPage() {
    final quals = _store.qualifications.values.toList()..sort(_qualSort);
    final people = _watchPeople();
    if (quals.isEmpty) {
      return const Center(
        child: Text(
          'Load the qualification set first (BILL tab).',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    if (people.isEmpty) {
      return const Center(
        child: Text(
          'No people in your work center yet.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView(
      children: [
        for (final (pid, name) in people)
          ExpansionTile(
            title: Text(name),
            subtitle: Text(_qualSummary(pid)),
            children: [for (final q in quals) _qualRow(pid, q)],
          ),
      ],
    );
  }

  static int _qualRank(QualType t) => const {
    QualType.designation: 0,
    QualType.watchStation: 1,
    QualType.knowledge: 2,
    QualType.letter: 3,
  }[t]!;

  int _qualSort(Qualification a, Qualification b) {
    final r = _qualRank(a.type).compareTo(_qualRank(b.type));
    return r != 0 ? r : a.order.compareTo(b.order);
  }

  Widget _qualRow(String pid, Qualification q) {
    Widget? subtitle;
    if (q.type == QualType.designation && q.prereqIds.isNotEmpty) {
      final qualifiedIds = _store.qualifiedIdsFor(pid);
      final done = q.prereqIds.where(qualifiedIds.contains).length;
      final ready = readyToBoard(
        q,
        _store.quals[PersonQual.makeId(pid, q.id)],
        qualifiedIds,
      );
      subtitle = Text(
        '$done/${q.prereqIds.length} prereqs${ready ? ' · ready to board' : ''}',
        style: TextStyle(
          fontSize: 11,
          color: ready ? Colors.green : Colors.grey,
        ),
      );
    }
    return ListTile(
      dense: true,
      title: Text('${q.abbr} — ${q.name}'),
      subtitle: subtitle,
      trailing: _qualChip(pid, q.id),
      onTap: _canManageWatch ? () => _openQualSet(pid, q) : null,
    );
  }

  String _qualSummary(String pid) {
    var q = 0, ip = 0;
    for (final qual in _store.qualifications.values) {
      switch (_store.qualStage(pid, qual.id)) {
        case QualStage.qualified:
          q++;
        case QualStage.inProgress:
        case QualStage.boardPending:
          ip++;
        case QualStage.notStarted:
          break;
      }
    }
    return '$q qualified · $ip in progress';
  }

  Widget _qualChip(String pid, String qualId) {
    final stage = _store.qualStage(pid, qualId);
    final q = _store.quals[PersonQual.makeId(pid, qualId)];
    final color = _qualColors[stage]!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (q?.qualifier ?? false)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Icon(Icons.star, size: 14, color: Colors.amber),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color),
          ),
          child: Text(
            stage.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  void _openQualSet(String pid, Qualification qual) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final pq = _store.quals[PersonQual.makeId(pid, qual.id)];
          final stage = pq?.stage ?? QualStage.notStarted;
          final missing = qual.type == QualType.designation
              ? missingPrereqs(
                  qual,
                  _store.qualifiedIdsFor(pid),
                ).map((id) => _store.qualifications[id]?.abbr ?? id).toList()
              : <String>[];
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      '${_personName(pid)} · ${qual.abbr}',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                  if (missing.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Prereqs remaining: ${missing.join(', ')}',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  for (final l in QualStage.values)
                    ListTile(
                      leading: Icon(
                        Icons.circle,
                        size: 14,
                        color: _qualColors[l],
                      ),
                      title: Text(l.label),
                      trailing: stage == l
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () {
                        _setQual(pid, qual.id, l);
                        setS(() {});
                      },
                    ),
                  const Divider(),
                  SwitchListTile(
                    secondary: const Icon(Icons.star, color: Colors.amber),
                    title: const Text('Qualifier (can sign others off)'),
                    value: pq?.qualifier ?? false,
                    onChanged: stage == QualStage.qualified
                        ? (v) {
                            _setQual(
                              pid,
                              qual.id,
                              QualStage.qualified,
                              qualifier: v,
                            );
                            setS(() {});
                          }
                        : null,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- SKED (PMS schedule) page --------------------------------------------

  static const _skedColors = {
    PmsStatus.overdue: _duOrange,
    PmsStatus.due: Colors.orange,
    PmsStatus.scheduled: Colors.green,
  };

  /// SKED — the weekly PMS schedule. The current Mon–Sun week as a board: an
  /// Unscheduled pool (all PMS checks not placed this week + active jobs) and a
  /// section per day. Each item carries its full PMS detail + Accomplish.
  Widget _skedPage(List<Job> active) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final days = weekDays(now);
    final weekStart = days.first;
    final weekEnd = days.last + 86400000;
    final today = startOfDay(now);
    bool thisWeek(int? ms) => ms != null && ms >= weekStart && ms < weekEnd;

    final checks = _store.pmsChecks.values.where(_store.canSeeCheck).toList();
    // Overdue first, then due, then scheduled; ties broken by next-due.
    int byStatus(PmsCheck a, PmsCheck b) {
      final r = b.statusAt(now).index.compareTo(a.statusAt(now).index);
      return r != 0 ? r : a.nextDueMs.compareTo(b.nextDueMs);
    }

    // Daily checks recur every day, so they appear on every day automatically;
    // other checks appear on the one day they're placed.
    List<Widget> forDay(int dayMs) {
      final dc =
          checks
              .where(
                (c) =>
                    c.periodicity == Periodicity.daily ||
                    (c.scheduledForMs != null &&
                        isSameDay(c.scheduledForMs!, dayMs)),
              )
              .toList()
            ..sort(byStatus);
      final dj = active.where(
        (j) => j.scheduledForMs != null && isSameDay(j.scheduledForMs!, dayMs),
      );
      return [
        for (final c in dc) _draggableTile(check: c, dayMs: dayMs),
        for (final j in dj) _draggableTile(job: j, dayMs: dayMs),
      ];
    }

    // Pool = checks not placed this week (daily checks are excluded — they're
    // already on every day) + active jobs not placed this week.
    final poolChecks =
        checks
            .where(
              (c) =>
                  c.periodicity != Periodicity.daily &&
                  !thisWeek(c.scheduledForMs),
            )
            .toList()
          ..sort(byStatus);
    final pool = <Widget>[
      for (final c in poolChecks) _draggableTile(check: c),
      for (final j in active)
        if (!thisWeek(j.scheduledForMs)) _draggableTile(job: j),
    ];

    return ListView(
      children: [
        _scheduleHeader(weekStart),
        if (checks.isEmpty && _canManageSked)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: OutlinedButton.icon(
              onPressed: _seedBicyclePms,
              icon: const Icon(Icons.pedal_bike),
              label: const Text(
                'No PMS checks yet — load example: Bicycle PMS',
              ),
            ),
          ),
        _scheduleGroup(
          'Unscheduled',
          pool,
          empty: 'Nothing waiting — all placed on a day.',
          tint: false,
          targetDayMs: null,
        ),
        for (final d in days)
          _scheduleGroup(
            '${weekdayLabel(d)}   ${_shortDate(d)}',
            forDay(d),
            empty: '—',
            tint: d == today,
            targetDayMs: d,
          ),
      ],
    );
  }

  /// Board dot color. On a day ([dayMs] set), it's green once done that day, red
  /// if the day passed without it, orange while still upcoming. In the pool
  /// ([dayMs] null) it uses the PMS due-status color.
  Color _checkDot(PmsCheck c, int? dayMs, int nowMs) {
    if (dayMs == null) return _skedColors[c.statusAt(nowMs)]!;
    switch (schedOutcome(done: c.doneOn(dayMs), dayMs: dayMs, nowMs: nowMs)) {
      case SchedOutcome.done:
        return Colors.green;
      case SchedOutcome.missed:
        return _duOrange;
      case SchedOutcome.upcoming:
        return Colors.orange;
    }
  }

  String _dueText(PmsCheck c, int nowMs) {
    if (!c.periodicity.isCalendar) return 'as required';
    final d = c.daysUntilDue(nowMs);
    switch (c.statusAt(nowMs)) {
      case PmsStatus.overdue:
        return 'OVERDUE ${-d}d';
      case PmsStatus.due:
        return d <= 0 ? 'DUE today' : 'DUE in ${d}d';
      case PmsStatus.scheduled:
        return 'due in ${d}d';
    }
  }

  void _openAddCheck() {
    final mip = TextEditingController();
    final seq = TextEditingController(text: '1');
    final title = TextEditingController();
    final ein = TextEditingController();
    final mins = TextEditingController(text: '15');
    Periodicity per = Periodicity.monthly;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Add PMS check (${_workcenter})',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: mip,
                  decoration: const InputDecoration(
                    labelText: 'MIP number (e.g. 5921/023-14)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: title,
                  decoration: const InputDecoration(
                    labelText: 'What the check covers',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ein,
                  decoration: const InputDecoration(labelText: 'Equipment EIN'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<Periodicity>(
                        initialValue: per,
                        decoration: const InputDecoration(
                          labelText: 'Periodicity',
                        ),
                        items: Periodicity.values
                            .map(
                              (p) => DropdownMenuItem(
                                value: p,
                                child: Text('${p.label} (${p.code})'),
                              ),
                            )
                            .toList(),
                        onChanged: (p) => setS(() => per = p ?? per),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 64,
                      child: TextField(
                        controller: seq,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setS(() {}),
                        decoration: const InputDecoration(labelText: 'Seq'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 84,
                      child: TextField(
                        controller: mins,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Est. min',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'MRC code: ${per.code}-${int.tryParse(seq.text.trim()) ?? 1}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    final m = mip.text.trim();
                    if (m.isEmpty) return;
                    _createPmsCheck(
                      mip: m,
                      seq: int.tryParse(seq.text.trim()) ?? 1,
                      title: title.text.trim(),
                      ein: ein.text.trim(),
                      periodicity: per,
                      estMinutes: int.tryParse(mins.text.trim()) ?? 0,
                    );
                    Navigator.pop(ctx);
                  },
                  child: const Text('Add to schedule'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Weekly schedule (PMS checks + active jobs assigned to days) ----------

  Widget _scheduleHeader(int weekStart) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Row(
      children: [
        Text(
          'Week of ${_shortDate(weekStart)}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Spacer(),
        if (_canManageSked)
          const Text(
            'drag onto a day · tap to assign',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
      ],
    ),
  );

  /// A board section (the Unscheduled pool or one day). Doubles as a drop
  /// target: dropping an item here assigns it to [targetDayMs] (null = pool /
  /// unschedule). Highlights while an item is dragged over it.
  Widget _scheduleGroup(
    String title,
    List<Widget> tiles, {
    required String empty,
    required bool tint,
    int? targetDayMs,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<_SchedDrag>(
      onAcceptWithDetails: (d) => _scheduleItemForDay(
        check: d.data.check,
        job: d.data.job,
        dayMs: targetDayMs,
      ),
      builder: (ctx, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: hovering
                  ? scheme.primary.withValues(alpha: 0.30)
                  : (tint
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: tint ? scheme.onPrimaryContainer : null,
                    ),
                  ),
                  const Spacer(),
                  if (tiles.isNotEmpty)
                    Text(
                      '${tiles.length}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (tiles.isEmpty)
              Container(
                constraints: const BoxConstraints(minHeight: 38),
                alignment: Alignment.centerLeft,
                color: hovering ? scheme.primary.withValues(alpha: 0.08) : null,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Text(empty, style: const TextStyle(color: Colors.grey)),
              )
            else
              ...tiles,
          ],
        );
      },
    );
  }

  /// Wraps a tile so a manager can drag it onto a day (click-drag on desktop,
  /// long-press-drag on touch so it doesn't fight list scrolling).
  Widget _draggableTile({PmsCheck? check, Job? job, int? dayMs}) {
    final tile = _scheduleTile(check: check, job: job, dayMs: dayMs);
    if (!_canManageSked) return tile;
    // Daily checks are inherently every-day — not draggable to a single day.
    if (check != null && check.periodicity == Periodicity.daily) return tile;
    final data = (check: check, job: job);
    final label = check != null
        ? (check.title.isEmpty ? check.mrcCode : check.title)
        : job!.title;
    final feedback = Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 260),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              check != null ? Icons.event_repeat : Icons.construction,
              size: 16,
            ),
            const SizedBox(width: 8),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
    final dragging = Opacity(opacity: 0.35, child: tile);
    final desktop = {
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(Theme.of(context).platform);
    return desktop
        ? Draggable<_SchedDrag>(
            data: data,
            feedback: feedback,
            childWhenDragging: dragging,
            child: tile,
          )
        : LongPressDraggable<_SchedDrag>(
            data: data,
            feedback: feedback,
            childWhenDragging: dragging,
            child: tile,
          );
  }

  /// A schedulable item on the board. PMS checks carry their full detail
  /// (status dot, MIP · MRC code · EIN · due · assignee) + a Done button; jobs
  /// show priority/EIN/assignee. [dayMs] is the day this tile renders on (null
  /// in the pool). Tap (managers) to assign a person / move the day.
  Widget _scheduleTile({PmsCheck? check, Job? job, int? dayMs}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (check != null) {
      return ListTile(
        dense: true,
        isThreeLine: true,
        leading: Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            color: _checkDot(check, dayMs, now),
            shape: BoxShape.circle,
          ),
        ),
        title: Text(
          check.title.isEmpty ? '${check.mip} ${check.mrcCode}' : check.title,
        ),
        subtitle: Text(
          [
            'MIP ${check.mip}',
            check.mrcCode,
            if (check.ein.isNotEmpty) check.ein,
            _dueText(check, now),
            if (check.assignedTo.isNotEmpty) 'asgd: ${check.assignedTo}',
          ].join('  ·  '),
        ),
        trailing: FilledButton.tonal(
          onPressed: () => _accomplishCheck(check, forDayMs: dayMs),
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
          child: const Text('Done'),
        ),
        onTap: _canManageSked ? () => _openScheduleAssign(check: check) : null,
      );
    }
    final j = job!;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.construction, size: 20),
      title: Text(j.title),
      subtitle: Text(
        [
          'Job',
          'PRI ${j.priority}',
          if (j.ein.isNotEmpty) j.ein,
          if (j.assignedTo.isNotEmpty) 'asgd: ${j.assignedTo}',
        ].join('  ·  '),
      ),
      trailing: _canManageSked ? const Icon(Icons.more_vert, size: 18) : null,
      onTap: _canManageSked ? () => _openScheduleAssign(job: j) : null,
    );
  }

  String _shortDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day}';
  }

  void _openScheduleAssign({PmsCheck? check, Job? job}) {
    final days = weekDays(DateTime.now().millisecondsSinceEpoch);
    final isDaily = check != null && check.periodicity == Periodicity.daily;
    final wc = check?.workcenter ?? job!.workcenter;
    final people =
        _store.accounts.values
            .where((a) => a.workcenterId == wc)
            .map((a) => a.name)
            .toSet()
            .toList()
          ..sort();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final assignedTo = check?.assignedTo ?? job?.assignedTo ?? '';
          final current = check?.scheduledForMs ?? job?.scheduledForMs;
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      check != null
                          ? (check.title.isEmpty
                                ? '${check.mip} ${check.mrcCode}'
                                : check.title)
                          : job!.title,
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      'ASSIGN TO',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        ChoiceChip(
                          label: const Text('Unassigned'),
                          selected: assignedTo.isEmpty,
                          onSelected: (_) {
                            _assignItem(check: check, job: job, person: '');
                            setS(() {});
                          },
                        ),
                        for (final p in people)
                          ChoiceChip(
                            label: Text(p),
                            selected: assignedTo == p,
                            onSelected: (_) {
                              _assignItem(check: check, job: job, person: p);
                              setS(() {});
                            },
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 20),
                  if (isDaily)
                    const ListTile(
                      leading: Icon(Icons.repeat),
                      title: Text('Performed daily — shown on every day'),
                    )
                  else ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        'DAY',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final d in days)
                      ListTile(
                        leading: const Icon(Icons.today),
                        title: Text('${weekdayLabel(d)}   ${_shortDate(d)}'),
                        trailing: (current != null && isSameDay(current, d))
                            ? const Icon(Icons.check, color: Colors.green)
                            : null,
                        onTap: () {
                          _scheduleItemForDay(check: check, job: job, dayMs: d);
                          Navigator.pop(ctx);
                        },
                      ),
                    if (current != null)
                      ListTile(
                        leading: const Icon(Icons.clear),
                        title: const Text('Unschedule'),
                        onTap: () {
                          _scheduleItemForDay(
                            check: check,
                            job: job,
                            dayMs: null,
                          );
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _assignItem({PmsCheck? check, Job? job, required String person}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (check != null) {
      check.assignedTo = person;
      check.updatedAtMs = now;
      _savePmsCheck(check);
    } else if (job != null) {
      job.assignedTo = person;
      job.updatedAtMs = now;
      _saveJob(job);
    }
    if (mounted) setState(() {});
  }

  void _scheduleItemForDay({PmsCheck? check, Job? job, int? dayMs}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (check != null) {
      check.scheduledForMs = dayMs;
      check.updatedAtMs = now;
      _savePmsCheck(check);
    } else if (job != null) {
      job.scheduledForMs = dayMs;
      job.updatedAtMs = now;
      _saveJob(job);
    }
    if (mounted) setState(() {});
  }

  Widget _jobList(List<Job> jobs, {required String emptyText}) {
    if (jobs.isEmpty) {
      return Center(
        child: Text(emptyText, style: const TextStyle(color: Colors.grey)),
      );
    }
    return ListView.separated(
      itemCount: jobs.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final j = jobs[i];
        return ListTile(
          leading: _PriorityDot(j.priority),
          title: Text(j.title.isEmpty ? '(untitled)' : j.title),
          subtitle: Text(
            '${j.ein.isEmpty ? '—' : j.ein} · ${j.workcenter} · orig ${j.originator}',
          ),
          trailing: _StageChip(job: j),
          onTap: () => _openDetail(j),
        );
      },
    );
  }

  // --- CASREP tab -----------------------------------------------------------

  bool get _canSeeCasreps =>
      _role == Role.divo ||
      _role == Role.threeMC ||
      _role == Role.dh ||
      _role == Role.portEngineer;

  Widget _casrepPage() {
    if (!_canSeeCasreps) {
      return const Center(
        child: Text(
          'CASREPs are visible to DIVO, 3MC, DH, and Port Engineer.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    final active =
        _casreps.values.where((c) => c.type != CasrepType.cancel).toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final cancelled =
        _casreps.values.where((c) => c.type == CasrepType.cancel).toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final all = [...active, ...cancelled];
    if (all.isEmpty) {
      return const Center(
        child: Text(
          'No CASREPs filed yet.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.separated(
      itemCount: all.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final c = all[i];
        final cancelled = c.type == CasrepType.cancel;
        return ListTile(
          leading: _Badge(
            'CR-${c.number}',
            color: cancelled ? Colors.grey : null,
          ),
          title: Text(
            c.wuc.isEmpty ? c.jobId : c.wuc,
            style: TextStyle(
              decoration: cancelled ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            '${c.hull}  ·  ${opImpactLabel[c.opImpact]}  ·  ETR: ${c.etr.isEmpty ? 'TBD' : c.etr}',
          ),
          trailing: _Badge(
            c.type.name.toUpperCase(),
            color: cancelled
                ? Colors.grey
                : c.type == CasrepType.initial
                ? _duOrange
                : Colors.orange.shade700,
          ),
          onTap: () => _openCasrepDetail(c),
        );
      },
    );
  }

  void _openCasrepDetail(Casrep c) {
    final job = _jobs[c.jobId];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                _Badge('CR-${c.number}'),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.wuc.isEmpty ? '(no WUC)' : c.wuc,
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                ),
                _Badge(
                  c.type.name.toUpperCase(),
                  color: c.type == CasrepType.cancel
                      ? Colors.grey
                      : c.type == CasrepType.initial
                      ? _duOrange
                      : Colors.orange.shade700,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${c.hull}  ·  ${opImpactLabel[c.opImpact]}  ·  ETR: ${c.etr.isEmpty ? 'TBD' : c.etr}',
              style: const TextStyle(color: Colors.grey),
            ),
            if (job != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Job: ${job.title.isEmpty ? c.jobId : job.title}',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            const Divider(height: 20),
            Text(c.narrative),
            if (c.partsNeeded.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Parts/assist: ${c.partsNeeded}',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
            const Divider(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: c.toMessageText()));
                  Navigator.pop(ctx);
                  _snack('CASREP message copied');
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy message text'),
              ),
            ),
            if (_role == Role.divo && c.type != CasrepType.cancel) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openCasrepDialog(
                          job ?? _jobs.values.first,
                          existing: c,
                        );
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Update'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      c.type = CasrepType.cancel;
                      c.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
                      _casreps[c.id] = c;
                      _saveCasrep(c);
                      Navigator.pop(ctx);
                      setState(() {});
                      _snack('CASREP ${c.number} cancelled');
                    },
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel'),
                    style: OutlinedButton.styleFrom(foregroundColor: _duOrange),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openCasrepDialog(Job job, {Casrep? existing}) {
    final hullCtrl = TextEditingController(text: existing?.hull ?? '');
    final wucCtrl = TextEditingController(text: existing?.wuc ?? '');
    final narrativeCtrl = TextEditingController(
      text: existing?.narrative ?? job.symptom,
    );
    final etrCtrl = TextEditingController(text: existing?.etr ?? '');
    final partsCtrl = TextEditingController(text: existing?.partsNeeded ?? '');
    // New CASREP: default the category from the job's priority (editable).
    OpImpact impact =
        existing?.opImpact ?? casrepImpactForPriority(job.priority);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  existing == null
                      ? 'Generate CASREP — ${job.title.isEmpty ? job.id : job.title}'
                      : 'Update CASREP CR-${existing.number}',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'EIN: ${job.ein.isEmpty ? '—' : job.ein}  ·  P${job.priority}',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: hullCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Hull designator',
                    hintText: 'e.g. DDG-51',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: wucCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Work Unit Code (WUC)',
                    hintText: 'e.g. HM000',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<OpImpact>(
                  value: impact,
                  decoration: const InputDecoration(
                    labelText: 'Operational impact',
                  ),
                  items: OpImpact.values
                      .map(
                        (o) => DropdownMenuItem(
                          value: o,
                          child: Text(opImpactLabel[o]!),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setS(() => impact = v ?? impact),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: narrativeCtrl,
                  decoration: const InputDecoration(labelText: 'Narrative'),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: etrCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ETR',
                    hintText: 'e.g. 72 HRS, AWAITING PARTS',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: partsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Parts / assistance required (optional)',
                    hintText: 'NSN, nomenclature, or request type',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    final now = DateTime.now().millisecondsSinceEpoch;
                    final Casrep c;
                    if (existing == null) {
                      c = Casrep(
                        id: 'CR-$now',
                        jobId: job.id,
                        number: _nextCasrepNumber(),
                        type: CasrepType.initial,
                        hull: hullCtrl.text.trim(),
                        wuc: wucCtrl.text.trim(),
                        opImpact: impact,
                        etr: etrCtrl.text.trim(),
                        narrative: narrativeCtrl.text.trim(),
                        partsNeeded: partsCtrl.text.trim(),
                        originator: _name,
                        createdAtMs: now,
                        updatedAtMs: now,
                      );
                    } else {
                      existing.type = CasrepType.update;
                      existing.hull = hullCtrl.text.trim();
                      existing.wuc = wucCtrl.text.trim();
                      existing.opImpact = impact;
                      existing.etr = etrCtrl.text.trim();
                      existing.narrative = narrativeCtrl.text.trim();
                      existing.partsNeeded = partsCtrl.text.trim();
                      existing.updatedAtMs = now;
                      c = existing;
                    }
                    _casreps[c.id] = c;
                    _saveCasrep(c);
                    Navigator.pop(ctx);
                    setState(() {});
                    _snack(
                      existing == null
                          ? 'CASREP CR-${c.number} filed and syncing'
                          : 'CASREP CR-${c.number} updated',
                    );
                  },
                  child: Text(existing == null ? 'File CASREP' : 'Save update'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionsPage() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final peers =
        _presence.values.where((p) {
          final ls = _lastSeenMs[p.nodeId];
          return ls != null && now - ls <= _kStaleWindowMs;
        }).toList()..sort((a, b) {
          final ao = _online(a.nodeId) ? 0 : 1;
          final bo = _online(b.nodeId) ? 0 : 1;
          if (ao != bo) return ao - bo; // online first
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    final Widget list = peers.isEmpty
        ? const Center(
            child: Text(
              'No other nodes seen yet.',
              style: TextStyle(color: Colors.grey),
            ),
          )
        : ListView.separated(
            itemCount: peers.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = peers[i];
              final online = _online(p.nodeId);
              final (icon, tlabel) = _transportFor(p.nodeId);
              return ListTile(
                leading: Icon(
                  icon,
                  color: online
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        p.name.isEmpty ? p.nodeId.substring(0, 8) : p.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _Badge(p.role.tag, off: p.role.offShip),
                  ],
                ),
                subtitle: Text('$tlabel · ${p.workcenter}'),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: online ? Colors.green : Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          online ? 'Online' : 'Offline',
                          style: TextStyle(
                            color: online ? Colors.green : Colors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    if (!online)
                      Text(
                        _sinceText(p.nodeId),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              );
            },
          );
    return Column(
      children: [
        _meshHeader(),
        Expanded(child: list),
      ],
    );
  }

  /// Mesh-tab header: admins (or the host) show the join QR to onboard people;
  /// everyone else gets a scanner. Any member already holds the key, so an admin
  /// can share it whether or not they originally minted the mesh.
  Widget _meshHeader() {
    if (_isMeshHost || (_account?.isAdmin ?? false)) {
      final token = _joinToken();
      return Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Text(
                'Join the mesh',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 2),
              const Text(
                'Have personnel scan this to connect',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              if (token == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'Resolving network address…',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: QrImageView(
                    data: token,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                    errorStateBuilder: (_, __) => const SizedBox(
                      width: 200,
                      height: 200,
                      child: Center(child: Text('Token too long for QR')),
                    ),
                  ),
                ),
              if (token != null) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                const Text(
                  '…or send a join code (works anywhere, valid 10 min)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: token));
                    _snack('Join code copied — send it to your sailor');
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy join code'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _openScanner,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan join QR'),
        ),
      ),
    );
  }

  // --- Dialogs --------------------------------------------------------------

  void _openCreate() {
    final title = TextEditingController();
    final ein = TextEditingController();
    final symptom = TextEditingController();
    int priority = 3;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Originate job'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                TextField(
                  controller: ein,
                  decoration: const InputDecoration(
                    labelText: 'Equipment (EIN)',
                  ),
                ),
                TextField(
                  controller: symptom,
                  decoration: const InputDecoration(labelText: 'Symptom'),
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Priority '),
                    DropdownButton<int>(
                      value: priority,
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 (urgent)')),
                        DropdownMenuItem(value: 2, child: Text('2')),
                        DropdownMenuItem(value: 3, child: Text('3')),
                        DropdownMenuItem(value: 4, child: Text('4 (routine)')),
                      ],
                      onChanged: (v) => setLocal(() => priority = v ?? 3),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty) return;
                _createJob(
                  title: title.text.trim(),
                  ein: ein.text.trim(),
                  symptom: symptom.text.trim(),
                  priority: priority,
                );
                Navigator.pop(ctx);
              },
              child: const Text('Submit to WCS'),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(Job job) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final log = _events[job.id] ?? const [];
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (ctx, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      job.title.isEmpty ? '(untitled)' : job.title,
                      style: Theme.of(ctx).textTheme.titleLarge,
                    ),
                  ),
                  _StageChip(job: job),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${job.id}  ·  EIN ${job.ein.isEmpty ? '—' : job.ein}  ·  '
                '${job.workcenter}  ·  P${job.priority}',
              ),
              const SizedBox(height: 8),
              if (job.symptom.isNotEmpty) Text(job.symptom),
              const Divider(height: 24),
              Text(
                'Chain of custody',
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              ...log.map((e) => _eventTile(e)),
              ..._detailActions(ctx, job),
            ],
          ),
        );
      },
    );
  }

  /// Phase-aware action buttons for the job detail sheet.
  List<Widget> _detailActions(BuildContext ctx, Job job) {
    final rows = <Widget>[];
    void pop() => Navigator.pop(ctx);

    Widget wide(String label, IconData icon, VoidCallback onTap) => SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label),
      ),
    );

    Widget approveReturn(String approveLabel, VoidCallback onReturn) => Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () {
              _approve(job);
              pop();
            },
            icon: const Icon(Icons.check),
            label: Text(approveLabel),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: onReturn,
          icon: const Icon(Icons.undo),
          label: const Text('Return'),
        ),
      ],
    );

    switch (job.phase) {
      case JobPhase.approval:
        if (job.approver == _role) {
          final next = nextInChain(job.approver);
          rows.add(
            approveReturn(
              next == null ? 'Approve (DIVO)' : 'Approve → ${next.tag}',
              () => _promptReturn(ctx, job),
            ),
          );
          if (_role == Role.divo) {
            rows.add(const SizedBox(height: 8));
            rows.add(
              wide('Request off-ship assistance (TA)', Icons.sailing, () {
                _requestTa(job);
                pop();
              }),
            );
          }
        }
        break;
      case JobPhase.ta:
        if (_role == Role.portEngineer) {
          rows.add(
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      _engageTa(job);
                      pop();
                    },
                    icon: const Icon(Icons.handshake),
                    label: const Text('Engage (accept)'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _promptAction(
                    ctx,
                    'Decline TA',
                    'Decline',
                    (c) => _declineTa(job, c),
                  ),
                  icon: const Icon(Icons.close),
                  label: const Text('Decline'),
                ),
              ],
            ),
          );
        }
        break;
      case JobPhase.execution:
        if (_role == Role.technician) {
          rows.add(
            wide(
              job.inWork ? 'Mark complete' : 'Start work',
              job.inWork ? Icons.done_all : Icons.play_arrow,
              () {
                job.inWork ? _markComplete(job) : _startWork(job);
                pop();
              },
            ),
          );
        }
        if (_role == Role.divo && !job.taRequested) {
          rows.add(const SizedBox(height: 8));
          rows.add(
            wide('Request off-ship assistance (TA)', Icons.sailing, () {
              _requestTa(job);
              pop();
            }),
          );
        }
        break;
      case JobPhase.closeout:
        if (job.approver == _role) {
          final next = nextInChain(job.approver);
          rows.add(
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      _approve(job);
                      pop();
                    },
                    icon: const Icon(Icons.check),
                    label: Text(
                      next == null
                          ? 'Approve close-out (DIVO)'
                          : 'Confirm → ${next.tag}',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _promptAction(
                    ctx,
                    'Reject close-out',
                    'Reject',
                    (c) => _rejectCloseout(job, c),
                  ),
                  icon: const Icon(Icons.undo),
                  label: const Text('Reject'),
                ),
              ],
            ),
          );
        }
        break;
      case JobPhase.closed:
        break;
    }
    // DIVO can generate or update a CASREP on any active job.
    if (_role == Role.divo && job.phase != JobPhase.closed) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      final existing = _casrepForJob(job.id);
      rows.add(
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              pop();
              _openCasrepDialog(job, existing: existing);
            },
            icon: const Icon(Icons.assignment_late_outlined),
            label: Text(existing == null ? 'Generate CASREP' : 'Update CASREP'),
          ),
        ),
      );
    }
    if (rows.isEmpty) return const [];
    return [const Divider(height: 24), ...rows];
  }

  /// Generic comment dialog: runs [onSubmit] with the entered text, then closes
  /// the dialog and the detail sheet ([sheetCtx]).
  void _promptAction(
    BuildContext sheetCtx,
    String title,
    String submitLabel,
    void Function(String) onSubmit,
  ) {
    final c = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Reason / comment'),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              onSubmit(c.text.trim());
              Navigator.pop(ctx);
              Navigator.pop(sheetCtx);
            },
            child: Text(submitLabel),
          ),
        ],
      ),
    );
  }

  Widget _eventTile(JobEvent e) {
    final t = DateTime.fromMillisecondsSinceEpoch(e.tsMs);
    final stamp =
        '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final verb =
        {
          'originate': 'originated',
          'approve': 'approved',
          'return': 'returned',
          'ta_request': 'requested off-ship assistance (TA)',
          'ta_engage': 'engaged — off-ship',
          'ta_decline': 'declined TA',
          'start_work': 'started work',
          'complete': 'reported complete',
          'close_confirm': 'confirmed close-out',
          'close': 'closed out',
          'close_reject': 'rejected close-out',
        }[e.action] ??
        e.action;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Badge(e.role.tag, off: e.role.offShip),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${e.actor} $verb',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                if (e.comment.isNotEmpty)
                  Text(
                    '“${e.comment}”',
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                Text(
                  stamp,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _promptReturn(BuildContext sheetCtx, Job job) {
    final c = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Return for rework'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Reason / comment'),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              _returnDown(job, c.text.trim());
              Navigator.pop(ctx);
              Navigator.pop(sheetCtx);
            },
            child: Text('Return → ${prevOwner(job.approver).tag}'),
          ),
        ],
      ),
    );
  }
}

// --- Login ------------------------------------------------------------------

/// Mesh entry: host a new mesh (become its admin) or scan a join QR.
class _StartScreen extends StatelessWidget {
  const _StartScreen({
    required this.onHost,
    required this.onJoin,
    required this.onJoinByCode,
  });
  final Future<void> Function() onHost;
  final Future<void> Function() onJoin;
  final VoidCallback onJoinByCode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: themeToggleButton(context),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Grapheion',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Corrective-maintenance mesh',
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: onJoin,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan join QR'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: onJoinByCode,
                          icon: const Icon(Icons.keyboard),
                          label: const Text('Enter a join code'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Scan your admin's QR, or paste a join code they sent — "
                        'a code works from anywhere.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      const SizedBox(height: 28),
                      TextButton(
                        onPressed: onHost,
                        child: const Text('Set up a new mesh instead'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A title that reveals a hidden action on 5 quick taps (within 3s) or a
/// long-press — the discreet Kratos unlock trigger.
class _SecretTitle extends StatefulWidget {
  const _SecretTitle({required this.child, required this.onUnlock});
  final Widget child;
  final VoidCallback onUnlock;
  @override
  State<_SecretTitle> createState() => _SecretTitleState();
}

class _SecretTitleState extends State<_SecretTitle> {
  int _taps = 0;
  DateTime? _first;

  void _tap() {
    final now = DateTime.now();
    if (_first == null ||
        now.difference(_first!) > const Duration(seconds: 3)) {
      _first = now;
      _taps = 1;
    } else {
      _taps++;
    }
    if (_taps >= 5) {
      _taps = 0;
      _first = null;
      widget.onUnlock();
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: _tap,
    onLongPress: widget.onUnlock,
    child: widget.child,
  );
}

/// Account sign-in: bootstrap the first admin (host) or pick your profile + PIN.
class _SignInScreen extends StatelessWidget {
  const _SignInScreen({
    required this.accounts,
    required this.org,
    required this.isHost,
    required this.onSignIn,
    required this.onCreate,
    required this.onUnlockKratos,
    required this.onReset,
  });
  final List<Account> accounts;
  final OrgChart org;
  final bool isHost;
  final void Function(Account) onSignIn;
  final String? Function(String passphrase) onUnlockKratos;
  final VoidCallback onReset;
  final Account Function({
    required String name,
    required String rate,
    required Role role,
    required String workcenterId,
    required String pin,
  })
  onCreate;

  @override
  Widget build(BuildContext context) {
    // Bootstrap: the host with no accounts yet creates the first admin.
    if (isHost && accounts.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: _kratosTitle(context, 'Set up admin'),
          actions: [_resetButton(), themeToggleButton(context)],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Create the admin account for this mesh. As DIVO or 3-M '
                    'Coordinator you can then add everyone else.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                  _AccountForm(
                    org: org,
                    roles: const [Role.divo, Role.threeMC],
                    initialRole: Role.divo,
                    submitLabel: 'Create admin & sign in',
                    onSubmit: (name, rate, role, wc, pin) => onSignIn(
                      onCreate(
                        name: name,
                        rate: rate,
                        role: role,
                        workcenterId: wc,
                        pin: pin,
                      ),
                    ),
                  ),
                  _versionUnlock(context),
                ],
              ),
            ),
          ),
        ),
      );
    }
    // Hybrid: pick an admin-created account (+ PIN), or self-register.
    return Scaffold(
      appBar: AppBar(
        title: _kratosTitle(context, 'Sign in'),
        actions: [_resetButton(), themeToggleButton(context)],
      ),
      body: ListView(
        children: [
          if (accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Text(
                "You're in the mesh. Pick your profile if your admin already "
                'added you, or register yourself below.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          for (final a in accounts)
            ListTile(
              leading: _Badge(a.role.tag),
              title: Text(a.rate.isEmpty ? a.name : '${a.rate} ${a.name}'),
              subtitle: Text('${a.role.title} · ${org.pathOf(a.workcenterId)}'),
              trailing: const Icon(Icons.lock_outline),
              onTap: () => _enterPin(context, a),
            ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.person_add_alt_1),
            title: const Text('Register myself'),
            subtitle: const Text(
              'Create your own profile — your admin can adjust it later',
            ),
            onTap: () => _selfRegister(context),
          ),
          _versionUnlock(context),
        ],
      ),
    );
  }

  Widget _resetButton() => IconButton(
    onPressed: onReset,
    icon: const Icon(Icons.restart_alt),
    tooltip: 'Reset / leave mesh',
  );

  /// The title — 5 quick taps (or a long-press) reveals the hidden Kratos
  /// unlock (god mode). Tap-count is far more reliable than long-press alone.
  Widget _kratosTitle(BuildContext context, String text) =>
      _SecretTitle(onUnlock: () => _promptKratos(context), child: Text(text));

  /// A discreet version label at the bottom of the sign-in screens — tap it 5×
  /// (or long-press) to reveal the Kratos unlock. Unmistakable target, away
  /// from the form; looks like an innocuous build string to anyone else.
  Widget _versionUnlock(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 10),
    child: Center(
      child: _SecretTitle(
        onUnlock: () => _promptKratos(context),
        child: Text(
          'grapheion · build 2026.06',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
        ),
      ),
    ),
  );

  void _promptKratos(BuildContext context) {
    final ctrl = TextEditingController();
    String? error;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          void attempt() {
            final err = onUnlockKratos(ctrl.text);
            if (err == null) {
              Navigator.pop(ctx); // success — parent rebuilds out of sign-in
            } else {
              setS(() => error = err);
            }
          }

          return AlertDialog(
            title: const Text('Unlock'),
            content: TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                errorText: error,
              ),
              onSubmitted: (_) => attempt(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: attempt, child: const Text('Unlock')),
            ],
          );
        },
      ),
    );
  }

  void _selfRegister(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: const Text('Register yourself')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _AccountForm(
                  org: org,
                  roles: Role.values.where((r) => r != Role.kratos).toList(),
                  submitLabel: 'Register & sign in',
                  onSubmit: (name, rate, role, wc, pin) {
                    final a = onCreate(
                      name: name,
                      rate: rate,
                      role: role,
                      workcenterId: wc,
                      pin: pin,
                    );
                    Navigator.pop(ctx);
                    onSignIn(a);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _enterPin(BuildContext context, Account a) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          String? err;
          void check() {
            if (a.checkPin(ctrl.text)) {
              Navigator.pop(ctx, true);
            } else {
              setS(() => err = 'Incorrect PIN');
            }
          }

          return AlertDialog(
            title: Text('PIN for ${a.name}'),
            content: TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'PIN', errorText: err),
              onSubmitted: (_) => check(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: check, child: const Text('Sign in')),
            ],
          );
        },
      ),
    );
    if (ok == true) onSignIn(a);
  }
}

/// Admin-only: list personnel and add accounts (assigned to org work centers).
class _AdminScreen extends StatefulWidget {
  const _AdminScreen({
    required this.accounts,
    required this.org,
    required this.onCreate,
    required this.onUpdate,
  });
  final List<Account> accounts;
  final OrgChart org;
  final Account Function({
    required String name,
    required String rate,
    required Role role,
    required String workcenterId,
    required String pin,
  })
  onCreate;
  final void Function(Account) onUpdate;
  @override
  State<_AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<_AdminScreen> {
  late List<Account> _accounts;
  @override
  void initState() {
    super.initState();
    _accounts = List.of(widget.accounts);
  }

  void _add() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add person', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              _AccountForm(
                org: widget.org,
                roles: Role.values.where((r) => r != Role.kratos).toList(),
                submitLabel: 'Create account',
                onSubmit: (name, rate, role, wc, pin) {
                  final a = widget.onCreate(
                    name: name,
                    rate: rate,
                    role: role,
                    workcenterId: wc,
                    pin: pin,
                  );
                  setState(
                    () =>
                        _accounts = [..._accounts, a]
                          ..sort((x, y) => x.name.compareTo(y.name)),
                  );
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _edit(Account a) {
    Role role = a.role;
    String? wc = a.workcenterId;
    final wcs = widget.org.workcenters.values.toList()
      ..sort((x, y) => x.id.compareTo(y.id));
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit ${a.name}', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              DropdownButtonFormField<Role>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: Role.values
                    .map(
                      (r) => DropdownMenuItem(value: r, child: Text(r.title)),
                    )
                    .toList(),
                onChanged: (r) => setS(() => role = r ?? role),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: wcs.any((w) => w.id == wc) ? wc : null,
                decoration: const InputDecoration(labelText: 'Work center'),
                items: wcs
                    .map(
                      (w) => DropdownMenuItem(
                        value: w.id,
                        child: Text('${w.id} · ${w.name}'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setS(() => wc = v),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  a.role = role;
                  if (wc != null) a.workcenterId = wc!;
                  widget.onUpdate(a);
                  setState(() {});
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.person_add),
        label: const Text('Add person'),
      ),
      body: _accounts.isEmpty
          ? const Center(
              child: Text(
                'No accounts yet.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView(
              children: [
                for (final a in _accounts)
                  ListTile(
                    leading: _Badge(a.role.tag),
                    title: Text(
                      a.rate.isEmpty ? a.name : '${a.rate} ${a.name}',
                    ),
                    subtitle: Text(
                      '${a.role.title} · ${widget.org.pathOf(a.workcenterId)} · sees ${scopeLabel(a.role)}',
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => _edit(a),
                  ),
              ],
            ),
    );
  }
}

/// Shared form to create an account (name, rate, role, work center, PIN).
class _AccountForm extends StatefulWidget {
  const _AccountForm({
    required this.org,
    required this.roles,
    required this.submitLabel,
    required this.onSubmit,
    this.initialRole,
  });
  final OrgChart org;
  final List<Role> roles;
  final String submitLabel;
  final Role? initialRole;
  final void Function(
    String name,
    String rate,
    Role role,
    String workcenterId,
    String pin,
  )
  onSubmit;
  @override
  State<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<_AccountForm> {
  final _name = TextEditingController();
  final _rate = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  final _wcText = TextEditingController(); // fallback if the org hasn't synced
  late Role _role;
  String? _wc;
  String? _err;

  @override
  void initState() {
    super.initState();
    _role = widget.initialRole ?? widget.roles.first;
    final wcs = widget.org.workcenters.keys.toList()..sort();
    _wc = wcs.isNotEmpty ? wcs.first : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _rate.dispose();
    _pin.dispose();
    _pin2.dispose();
    _wcText.dispose();
    super.dispose();
  }

  void _submit() {
    final n = _name.text.trim();
    final wc = widget.org.workcenters.isEmpty
        ? _wcText.text.trim()
        : (_wc ?? '');
    if (n.isEmpty) return setState(() => _err = 'Name is required');
    if (wc.isEmpty) return setState(() => _err = 'Work center is required');
    if (_pin.text.length < 4) {
      return setState(() => _err = 'PIN must be at least 4 digits');
    }
    if (_pin.text != _pin2.text) {
      return setState(() => _err = 'PINs do not match');
    }
    widget.onSubmit(n, _rate.text.trim(), _role, wc, _pin.text);
  }

  @override
  Widget build(BuildContext context) {
    final wcs = widget.org.workcenters.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _rate,
          decoration: const InputDecoration(
            labelText: 'Rate / rank (e.g. MM2)',
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<Role>(
          initialValue: _role,
          decoration: const InputDecoration(labelText: 'Role'),
          items: widget.roles
              .map((r) => DropdownMenuItem(value: r, child: Text(r.title)))
              .toList(),
          onChanged: (r) => setState(() => _role = r ?? _role),
        ),
        const SizedBox(height: 12),
        if (wcs.isEmpty)
          TextField(
            controller: _wcText,
            decoration: const InputDecoration(
              labelText: 'Work center (e.g. CP01)',
              helperText: 'Org chart not synced yet — type your work center',
            ),
          )
        else
          DropdownButtonFormField<String>(
            initialValue: _wc,
            decoration: const InputDecoration(labelText: 'Work center'),
            items: wcs
                .map(
                  (w) => DropdownMenuItem(
                    value: w.id,
                    child: Text('${w.id} · ${w.name}'),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _wc = v),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'PIN'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _pin2,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Confirm PIN'),
              ),
            ),
          ],
        ),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_err!, style: const TextStyle(color: _duOrange)),
          ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}

// --- Models / small widgets -------------------------------------------------

/// A peer seen on the mesh, from its presence beat.
// Peer model lives in mesh_store.dart.

/// A two-tap action button: the first tap arms it (label/color change to a
/// confirm state), the second tap fires [onConfirm]. Auto-disarms after a few
/// seconds so a stray first tap doesn't stay armed. Used for important sends
/// like submitting a watchbill to the CDO.
class _ConfirmButton extends StatefulWidget {
  const _ConfirmButton({
    required this.label,
    required this.confirmLabel,
    required this.icon,
    required this.onConfirm,
  });

  final String label;
  final String confirmLabel;
  final IconData icon;
  final VoidCallback onConfirm;

  @override
  State<_ConfirmButton> createState() => _ConfirmButtonState();
}

class _ConfirmButtonState extends State<_ConfirmButton> {
  bool _armed = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      icon: Icon(_armed ? Icons.check_circle : widget.icon, size: 18),
      label: Text(_armed ? widget.confirmLabel : widget.label),
      style: _armed
          ? FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            )
          : null,
      onPressed: () {
        if (_armed) {
          _reset?.cancel();
          setState(() => _armed = false);
          widget.onConfirm();
        } else {
          setState(() => _armed = true);
          _reset = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _armed = false);
          });
        }
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.off = false, this.color});
  final String text;
  final bool off;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color ?? (off ? Colors.deepOrange : const Color(0xFF2E5E8C)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  const _StageChip({required this.job});
  final Job job;
  @override
  Widget build(BuildContext context) {
    switch (job.phase) {
      case JobPhase.approval:
        return _Badge(
          job.returned ? '↩ ${job.approver.tag}' : job.approver.tag,
          off: job.approver.offShip,
        );
      case JobPhase.ta:
        return const _Badge('TA · PORT ENG', off: true);
      case JobPhase.execution:
        return _Badge(job.inWork ? 'IN WORK' : 'APPROVED', color: Colors.teal);
      case JobPhase.closeout:
        return _Badge('CLOSING · ${job.approver.tag}', color: Colors.indigo);
      case JobPhase.closed:
        return const _Badge('CLOSED', color: Colors.green);
    }
  }
}

class _PriorityDot extends StatelessWidget {
  const _PriorityDot(this.priority);
  final int priority;
  @override
  Widget build(BuildContext context) {
    const colors = {
      1: _duOrange,
      2: Colors.orange,
      3: Colors.amber,
      4: Colors.green,
    };
    return CircleAvatar(
      radius: 6,
      backgroundColor: colors[priority] ?? Colors.grey,
    );
  }
}

/// Full-screen camera scanner. Pops the first non-empty QR value back to the
/// caller (a grapheion join token), which then dials that node into the mesh.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();
  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false; // detection fires repeatedly per frame

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan join QR')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const Positioned(
            bottom: 48,
            child: Text(
              "Point at the DIVO's join QR",
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// Editor to create or edit an evolution — its name, the watchstations (roles)
/// it requires (each standing or rotating), and the rotation shifts.
class _EvolutionEditorPage extends StatefulWidget {
  final Evolution? initial;
  final List<Qualification> stations;
  final Qualification Function(String name, String abbr) onCreateStation;
  final void Function(Evolution) onSave;

  const _EvolutionEditorPage({
    required this.initial,
    required this.stations,
    required this.onCreateStation,
    required this.onSave,
  });

  @override
  State<_EvolutionEditorPage> createState() => _EvolutionEditorPageState();
}

class _EvolutionEditorPageState extends State<_EvolutionEditorPage> {
  late final TextEditingController _name;
  late bool _inPort;
  late List<WatchShift> _shifts;
  late List<EvolutionRole> _roles;
  late List<Qualification> _stations; // local; grows as new stations are made

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    _name = TextEditingController(text: e?.name ?? '');
    _inPort = e?.inPort ?? true;
    _shifts = e == null
        ? _defaultShifts()
        : e.shifts
              .map(
                (s) => WatchShift(
                  id: s.id,
                  label: s.label,
                  start: s.start,
                  end: s.end,
                ),
              )
              .toList();
    _roles = (e?.roles ?? [])
        .map(
          (r) => EvolutionRole(
            id: r.id,
            stationId: r.stationId,
            name: r.name,
            rotating: r.rotating,
            order: r.order,
          ),
        )
        .toList();
    _stations = [...widget.stations];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<WatchShift> _defaultShifts() {
    const t = [
      ['1', '0630', '1130'],
      ['2', '1130', '1630'],
      ['3', '1630', '2130'],
      ['4', '2130', '0130'],
      ['5', '0130', '0630'],
    ];
    return [
      for (var i = 0; i < t.length; i++)
        WatchShift(
          id: 's${i + 1}',
          label: t[i][0],
          start: t[i][1],
          end: t[i][2],
        ),
    ];
  }

  String _stationName(String id) {
    for (final s in _stations) {
      if (s.id == id) return s.name;
    }
    return id;
  }

  void _save() {
    final nm = _name.text.trim();
    if (nm.isEmpty) {
      _toast('Name the evolution');
      return;
    }
    if (_roles.isEmpty) {
      _toast('Add at least one role');
      return;
    }
    for (var i = 0; i < _roles.length; i++) {
      _roles[i].order = i;
    }
    widget.onSave(
      Evolution(
        id: widget.initial?.id ?? 'ev-${DateTime.now().microsecondsSinceEpoch}',
        name: nm,
        inPort: _inPort,
        shifts: _shifts,
        roles: _roles,
        order: widget.initial?.order ?? 0,
      ),
    );
    Navigator.pop(context);
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final hasRotating = _roles.any((r) => r.rotating);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial == null ? 'New evolution' : 'Edit evolution',
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Evolution name',
              hintText: 'e.g. Sea and Anchor Detail',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _inPort,
            onChanged: (v) => setState(() => _inPort = v),
            title: const Text('In port'),
            subtitle: const Text('Off = an underway evolution'),
          ),
          const SizedBox(height: 8),
          _sectionHeader('Roles', () => _editRole(null)),
          if (_roles.isEmpty)
            _hint('Add the watchstations this evolution requires.'),
          for (final r in _roles)
            ListTile(
              dense: true,
              leading: Icon(
                r.rotating ? Icons.sync : Icons.push_pin,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(r.name),
              subtitle: Text(
                '${_stationName(r.stationId)} · ${r.rotating ? 'Rotating' : 'Standing'}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => setState(() => _roles.remove(r)),
              ),
              onTap: () => _editRole(r),
            ),
          const SizedBox(height: 16),
          _sectionHeader('Rotation shifts', () => _editShift(null)),
          _hint(
            hasRotating
                ? 'Rotating roles are split across these shifts; standing roles ignore them.'
                : 'Only used once a role is set to Rotating.',
          ),
          for (final s in _shifts)
            ListTile(
              dense: true,
              leading: const Icon(Icons.schedule, size: 18),
              title: Text('Section ${s.label}'),
              subtitle: Text('${s.start}–${s.end}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => setState(() => _shifts.remove(s)),
              ),
              onTap: () => _editShift(s),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, VoidCallback onAdd) => Row(
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const Spacer(),
      TextButton.icon(
        onPressed: onAdd,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add'),
      ),
    ],
  );

  Widget _hint(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(t, style: const TextStyle(color: Colors.grey, fontSize: 12)),
  );

  void _editRole(EvolutionRole? existing) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    String? stationId =
        existing?.stationId ??
        (_stations.isNotEmpty ? _stations.first.id : null);
    bool rotating = existing?.rotating ?? false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(existing == null ? 'Add role' : 'Edit role'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Role name',
                    hintText: 'e.g. Officer of the Deck',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: stationId,
                        hint: const Text('Watch station'),
                        items: [
                          for (final s in _stations)
                            DropdownMenuItem(
                              value: s.id,
                              child: Text(
                                s.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setD(() => stationId = v),
                      ),
                    ),
                    IconButton(
                      tooltip: 'New station',
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () async {
                        final created = await _promptNewStation(ctx);
                        if (created != null) {
                          setD(() {
                            _stations.add(created);
                            stationId = created.id;
                          });
                        }
                      },
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: rotating,
                  onChanged: (v) => setD(() => rotating = v),
                  title: const Text('Rotating'),
                  subtitle: const Text('Sectioned across the shifts'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final nm = nameCtrl.text.trim();
                if (nm.isEmpty || stationId == null) return;
                setState(() {
                  if (existing == null) {
                    _roles.add(
                      EvolutionRole(
                        id: 'r-${DateTime.now().microsecondsSinceEpoch}',
                        stationId: stationId!,
                        name: nm,
                        rotating: rotating,
                        order: _roles.length,
                      ),
                    );
                  } else {
                    existing.name = nm;
                    existing.stationId = stationId!;
                    existing.rotating = rotating;
                  }
                });
                Navigator.pop(ctx);
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<Qualification?> _promptNewStation(BuildContext ctx) {
    final nameCtrl = TextEditingController();
    final abbrCtrl = TextEditingController();
    return showDialog<Qualification>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('New watch station'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Station name'),
            ),
            TextField(
              controller: abbrCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Abbreviation (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final nm = nameCtrl.text.trim();
              if (nm.isEmpty) return;
              Navigator.pop(
                c,
                widget.onCreateStation(nm, abbrCtrl.text.trim()),
              );
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _editShift(WatchShift? existing) {
    final labelCtrl = TextEditingController(
      text: existing?.label ?? '${_shifts.length + 1}',
    );
    final startCtrl = TextEditingController(text: existing?.start ?? '');
    final endCtrl = TextEditingController(text: existing?.end ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add shift' : 'Edit shift'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(labelText: 'Section label'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: startCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Start (0630)',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: endCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'End (1130)'),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                if (existing == null) {
                  _shifts.add(
                    WatchShift(
                      id: 's${DateTime.now().microsecondsSinceEpoch}',
                      label: labelCtrl.text.trim(),
                      start: startCtrl.text.trim(),
                      end: endCtrl.text.trim(),
                    ),
                  );
                } else {
                  existing.label = labelCtrl.text.trim();
                  existing.start = startCtrl.text.trim();
                  existing.end = endCtrl.text.trim();
                }
              });
              Navigator.pop(ctx);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
