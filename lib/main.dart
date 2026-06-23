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
  grapheionThemeMode.value =
      tm == 'light' ? ThemeMode.light : ThemeMode.dark;
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
    ColorScheme.fromSeed(seedColor: _duCyan, brightness: Brightness.dark)
        .copyWith(
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
    ColorScheme.fromSeed(seedColor: _duBlue, brightness: Brightness.light)
        .copyWith(
  primary: _duBlue,
  onPrimary: Colors.white,
  secondary: _duGold,
  onSecondary: _duGoldInk,
  tertiary: _duOrange,
);

/// App-wide theme mode. Dark by default to match the Defense Unicorns look;
/// toggled from the app bar and persisted.
final ValueNotifier<ThemeMode> grapheionThemeMode =
    ValueNotifier(ThemeMode.dark);

ThemeData _grapheionTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark ? _duDark : _duLight;
  final inter = GoogleFonts.interTextTheme();
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
          letterSpacing: 0.5),
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
          foregroundColor: scheme.primary, shape: const StadiumBorder()),
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
      (p) => p.setString('themeMode', next == ThemeMode.dark ? 'dark' : 'light'));
}

/// Reusable app-bar action to toggle the theme.
Widget themeToggleButton(BuildContext context) => IconButton(
      onPressed: () => toggleGrapheionTheme(context),
      icon: Icon(Theme.of(context).brightness == Brightness.dark
          ? Icons.light_mode
          : Icons.dark_mode),
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
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
  final ValueNotifier<int> _feedbackTick = ValueNotifier(0); // refreshes open feedback sheet

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
  final Map<String, Map<int, Uint8List>> _reasm = {}; // "coll:msgId" -> fragments
  final Map<String, int> _reasmTs = {};
  int _gossipTick = 0;

  @override
  void initState() {
    super.initState();
    _restoreIdentity();
  }

  String _genKey() {
    final r = Random.secure();
    return base64Encode(List<int>.generate(32, (_) => r.nextInt(256)));
  }

  String _randHex(int bytes) {
    final r = Random.secure();
    return List.generate(
        bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Restore mesh membership + the last signed-in account on launch.
  Future<void> _restoreIdentity() async {
    final p = await SharedPreferences.getInstance();
    _formationKey = p.getString('formationKey');
    // A device that minted the key is the host (migration: an old DIVO install
    // that already hosts a mesh is treated as host so it can bootstrap admins).
    _isMeshHost = (p.getBool('isMeshHost') ?? false) ||
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
    _store.account = a;
    _store.pendingAccountId = a.id;
    SharedPreferences.getInstance().then((p) => p.setString('accountId', a.id));
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
    final existing =
        _accounts.values.where((a) => a.role == Role.kratos).toList();
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
      workcenterId:
          _org.workcenters.isNotEmpty ? _org.workcenters.keys.first : '',
      pinSalt: salt,
      pinHash: hashPin(salt, _randHex(8)), // unused — access is passphrase+device
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
            'keep their copy until you reset them too.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
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
      final node = PeatFlutterNode.create(NodeConfig(
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
          enableN0Relay: true, // lets the off-ship Port Engineer reach the ship
        ),
      ));
      node.startSync();
      _store.myNodeId = node.nodeId; // so the store skips our own presence beats
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
      _presenceTimer =
          Timer.periodic(const Duration(seconds: 8), (_) => _publishPresence());
      _tickTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _refreshTransports();
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
      final nonce =
          Uint8List.fromList(sha256.convert(body).bytes.sublist(0, _kBleNonce));
      final c = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
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
        ..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
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
        _bleChannel.invokeMethod('startBle', args).then((ok) {
          if (ok == true) {
            _bleRxSub =
                _bleRxChannel.receiveBroadcastStream().listen(_onBleFrame);
            _bleRunning = true;
            debugPrint('[BLE] android radio started — listening for frames');
          } else if (mounted) {
            Future.delayed(const Duration(seconds: 3), _startBle);
          }
        }).catchError((_) {
          if (mounted) Future.delayed(const Duration(seconds: 3), _startBle);
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
    final body =
        Uint8List.fromList(utf8.encode(jsonEncode({'i': docId, 'd': docJson})));
    // Encrypt + authenticate the frame with the formation key (AES-256-GCM):
    // only same-mesh nodes can decrypt, and it's confidential on the air.
    final payload = _bleSeal(base64Decode(key), body);
    if (payload == null) return;
    int msgId = 0x811c9dc5; // FNV over PLAINTEXT — stable across re-encryptions
    for (final b in body) {
      msgId = ((msgId ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    final fragCount =
        payload.isEmpty ? 1 : ((payload.length + _kBleChunk - 1) ~/ _kBleChunk);
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
        _bleChannel.invokeMethod('crdtTx', {'bytes': env}).catchError((_) => null);
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
    final wire = _reassemble(coll, msgId, frame[4], frame[5],
        Uint8List.sublistView(frame, _kBleHdr));
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
      String coll, int msgId, int fragIdx, int fragCount, Uint8List chunk) {
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
    if (t.contains('ble') || t.contains('blue')) return (Icons.bluetooth, 'BLE');
    if (link.pathKind == TransportPathKind.relay) return (Icons.cloud, 'Relay');
    return (Icons.wifi, 'Direct (Wi-Fi)');
  }

  // --- Join QR (DIVO hosts; others scan) ------------------------------------

  Future<void> _resolveLanIp() async {
    try {
      final ifaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
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

  /// Compact join token {node id, LAN addr, formation key} as base64(JSON).
  /// The key is what gates membership — it only leaves the DIVO via this QR.
  String? _joinToken() {
    final node = _node;
    final addr = _dialAddr();
    if (node == null || addr == null || _formationKey == null) return null;
    return base64Encode(utf8.encode(
        jsonEncode({'n': node.nodeId, 'a': addr, 'k': _formationKey})));
  }

  /// Decode a scanned join token: adopt the mesh's formation key (starting or
  /// restarting our node under it), then dial the DIVO and remember it so the
  /// reconnect supervisor keeps the path up.
  Future<void> _joinViaToken(String token) async {
    try {
      final m = jsonDecode(utf8.decode(base64Decode(token.trim())))
          as Map<String, dynamic>;
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
    final token = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScanPage()),
    );
    if (token != null && token.isNotEmpty) await _joinViaToken(token);
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
    _store.applyDoc(change.collection, change.docId, raw,
        remote: change.origin.isRemote, peer: change.origin.peerId);
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
  void _setQual(String personId, String qualId, QualStage stage,
      {bool? qualifier}) {
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
  void _setBillEntry(int dayMs, String evolutionId, String roleId,
      String shiftId, String? personId) {
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
    );
    for (final s in slots) {
      _setBillEntry(dayMs, ev.id, s.roleId, s.shiftId, fill[s.key]);
    }
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
    final stations = _store.qualifications.values
        .where((q) => q.isWatchStation)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _EvolutionEditorPage(
        initial: ev,
        stations: stations,
        onCreateStation: _createStation,
        onSave: (e) {
          _saveEvolution(e);
          if (mounted) setState(() => _evolutionId = e.id);
        },
      ),
    ));
  }

  /// Seed the default qualification tree — in-port watch stations + the SWO
  /// component quals + the SWO designation (with its prerequisite tree). Stable
  /// ids, so re-seeding refreshes.
  void _seedQualifications() {
    // id, abbr, name, type, inPort, hoursRequired, prereqIds
    final seeds =
        <(String, String, String, QualType, bool, int?, List<String>)>[
      // In-port watch stations (feed the bill)
      ('q-cdo', 'CDO', 'Command Duty Officer', QualType.watchStation, true,
          null, []),
      ('q-oodip', 'OOD I/P', 'Officer of the Deck (In-Port)',
          QualType.watchStation, true, null, []),
      ('q-poow', 'POOW', 'Petty Officer of the Watch', QualType.watchStation,
          true, null, []),
      ('q-moow', 'MOOW', 'Messenger of the Watch', QualType.watchStation, true,
          null, []),
      ('q-sns', 'S&S', 'Sounding & Security Patrol', QualType.watchStation,
          true, null, []),
      ('q-sec', 'SEC', 'Roving Security Patrol', QualType.watchStation, true,
          null, []),
      ('q-dutyeng', 'DUTYENG', 'Duty Engineer', QualType.watchStation, true,
          null, []),
      // Underway watch stations (SWO prereqs; not on the in-port bill)
      ('q-ooduw', 'OOD U/W', 'Officer of the Deck (Underway)',
          QualType.watchStation, false, 100, []),
      ('q-cicwo', 'CICWO', 'CIC Watch Officer', QualType.watchStation, false,
          null, []),
      // Knowledge quals
      ('q-3m', '3M', '3-M / PMS Qualification', QualType.knowledge, false, null,
          []),
      ('q-dc', 'Basic DC', 'Basic Damage Control', QualType.knowledge, false,
          null, []),
      ('q-swoeng', 'SWO Eng', 'SWO Engineering', QualType.knowledge, false,
          null, []),
      ('q-boato', 'Boat O', 'Small Boat Officer', QualType.knowledge, false,
          null, []),
      // Letter quals (follow-on)
      ('q-eoow', 'EOOW', 'Engineering Officer of the Watch', QualType.letter,
          false, null, []),
      ('q-tao', 'TAO', 'Tactical Action Officer', QualType.letter, false, null,
          []),
      // Capstone designation, atop its prerequisite tree
      ('q-swo', 'SWO', 'Surface Warfare Officer', QualType.designation, false,
          null, [
        'q-3m',
        'q-dc',
        'q-boato',
        'q-swoeng',
        'q-oodip',
        'q-ooduw',
        'q-cicwo'
      ]),
    ];
    for (var i = 0; i < seeds.length; i++) {
      final s = seeds[i];
      _saveQualification(Qualification(
        id: s.$1,
        abbr: s.$2,
        name: s.$3,
        type: s.$4,
        inPort: s.$5,
        hoursRequired: s.$6,
        prereqIds: s.$7,
        order: i,
      ));
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
    _saveEvolution(Evolution(
      id: 'ev-inport',
      name: 'In-Port Duty',
      inPort: true,
      order: 0,
      shifts: [
        for (final t in times)
          WatchShift(id: t.$1, label: t.$2, start: t.$3, end: t.$4)
      ],
      roles: [
        for (var i = 0; i < roles.length; i++)
          EvolutionRole(
              id: roles[i].$1,
              stationId: roles[i].$2,
              name: roles[i].$3,
              rotating: roles[i].$4,
              order: i)
      ],
    ));
  }

  /// Seed a demo duty section — ~18 sailors (rate + name) pre-qualified across
  /// the in-port watch stations, so Auto-generate produces a full bill instantly
  /// for showing people. Stable ids, so re-running just refreshes them.
  void _seedDemoCrew() {
    // rate, name, role, [station qualifications they hold]
    final crew = <(String, String, Role, List<String>)>[
      ('LCDR', 'Reyes', Role.dh, ['q-cdo', 'q-oodip']),
      ('LT', 'Donnelly', Role.divo, ['q-cdo', 'q-oodip', 'q-dutyeng']),
      ('LTJG', 'Park', Role.divo, ['q-oodip', 'q-dutyeng']),
      ('CWO3', 'Bauer', Role.divo, ['q-dutyeng', 'q-cdo']),
      ('ENS', 'Carter', Role.divo, ['q-oodip']),
      ('GSCS', 'Nakamura', Role.lpo, ['q-dutyeng', 'q-poow', 'q-sns']),
      ('BM1', 'Flores', Role.wcs, ['q-poow', 'q-sns', 'q-sec']),
      ('OS1', 'Patel', Role.wcs, ['q-poow', 'q-sec', 'q-moow']),
      ('GM2', 'Sullivan', Role.technician, ['q-poow', 'q-sns', 'q-sec', 'q-moow']),
      ('ET2', 'Brooks', Role.technician, ['q-poow', 'q-sec']),
      ('MM2', 'Iverson', Role.technician, ['q-poow', 'q-sns', 'q-sec']),
      ('OS2', 'Dunn', Role.technician, ['q-poow', 'q-sns', 'q-moow']),
      ('BM3', 'Davis', Role.technician, ['q-moow', 'q-sns', 'q-sec']),
      ('OS3', 'Nguyen', Role.technician, ['q-moow', 'q-sns', 'q-sec']),
      ('FN', 'Castillo', Role.technician, ['q-moow', 'q-sns']),
      ('SN', 'Whitaker', Role.technician, ['q-moow', 'q-sns']),
      ('GSMFN', 'Abara', Role.technician, ['q-moow', 'q-sns', 'q-sec']),
      ('SA', 'Rhodes', Role.technician, ['q-moow']),
    ];
    final wc = _org.workcenters.isNotEmpty ? _org.workcenters.keys.first : 'CP01';
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
        workcenterId: wc,
        pinSalt: salt,
        pinHash: hashPin(salt, '0000'),
        createdAtMs: now,
      );
      _accounts[id] = a;
      final json = jsonEncode(a.toJson());
      _node!.putRaw(kAccounts, id, json);
      _bleBroadcast(kAccounts, id, json);
      for (final st in c.$4) {
        _setQual(id, st, QualStage.qualified);
      }
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Seeded ${crew.length} demo crew — Auto-generate the bill')));
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
    final feature =
        _feature < _navFeatures.length ? _navFeatures[_feature].$2 : '';
    _saveFeedback(FeedbackNote(
      id: 'fb-$now-${_randHex(3)}',
      fromId: _account?.id ?? '',
      fromRate: _account?.rate ?? '', // rate/rank only — no name
      fromRole: _role ?? Role.technician,
      context: context.trim().isEmpty ? feature : context.trim(),
      messages: [FeedbackMessage(fromOwner: false, text: text, atMs: now)],
      readByOwner: false,
      readBySubmitter: true,
      createdAtMs: now,
    ));
  }

  /// Append a message to a thread, from the owner (Kratos) or the submitter.
  void _addFeedbackMessage(FeedbackNote f, String text,
      {required bool fromOwner}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    f.messages.add(FeedbackMessage(fromOwner: fromOwner, text: text, atMs: now));
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
    final feature =
        _feature < _navFeatures.length ? _navFeatures[_feature].$2 : '';
    final ctxCtrl = TextEditingController(text: feature);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.feedback_outlined),
                const SizedBox(width: 8),
                Text('Feedback', style: Theme.of(ctx).textTheme.titleLarge),
              ]),
              const SizedBox(height: 6),
              const Text('Goes to the demo owner over the mesh.',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
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
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Feedback sent — thank you!')));
                },
                icon: const Icon(Icons.send),
                label: const Text('Send'),
              ),
              ValueListenableBuilder<int>(
                valueListenable: _feedbackTick,
                builder: (ctx, _, __) {
                  final mine = _store.feedback.values
                      .where(
                          (f) => f.fromId.isNotEmpty && f.fromId == _account?.id)
                      .toList()
                    ..sort((a, b) =>
                        b.lastActivityMs.compareTo(a.lastActivityMs));
                  if (mine.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 28),
                      const Text('YOUR FEEDBACK',
                          style: TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
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
              child: Text('No feedback yet.',
                  style: TextStyle(color: Colors.grey)));
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
  Widget _feedbackThreadTile(FeedbackNote f,
      {required bool asOwner, bool deletable = false}) {
    final unread = asOwner ? !f.readByOwner : !f.readBySubmitter;
    final last = f.lastMessage;
    return ListTile(
      leading: Icon(
        unread ? Icons.mark_chat_unread : Icons.forum_outlined,
        color: unread ? Theme.of(context).colorScheme.primary : Colors.grey,
      ),
      title: Text(f.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (asOwner) _fromLabel(f),
        if (f.context.isNotEmpty) f.context,
        if (last != null)
          '${last.fromOwner ? (asOwner ? 'you' : 'owner') : (asOwner ? _fromLabel(f) : 'you')}: ${last.text}',
      ].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _openFeedbackThread(f, asOwner: asOwner),
      trailing: deletable
          ? IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteFeedback(f),
            )
          : Text(_ago(f.lastActivityMs),
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
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
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    '${_fromLabel(f)}${f.context.isEmpty ? '' : ' · ${f.context}'}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
              child: Row(children: [
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
              ]),
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
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(m.text),
            const SizedBox(height: 2),
            Text(_ago(m.atMs),
                style: const TextStyle(color: Colors.grey, fontSize: 10)),
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
    final d =
        Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - ms);
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
    c.accomplish(_name, DateTime.now().millisecondsSinceEpoch,
        forDayMs: forDayMs);
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
      ('pms-bike-001', 1, 'Inspect tires & check pressure', Periodicity.daily, 5, 0),
      ('pms-bike-002', 1, 'Clean & lubricate chain', Periodicity.weekly, 10, 9),
      ('pms-bike-003', 1, 'Check & torque frame bolts', Periodicity.biweekly, 10, 13),
      ('pms-bike-004', 1, 'Clean headset bearing', Periodicity.monthly, 20, 28),
      ('pms-bike-005', 1, 'True wheels & check spoke tension', Periodicity.quarterly, 45, 95),
      ('pms-bike-006', 1, 'Bleed brakes', Periodicity.semiannual, 40, 175),
      ('pms-bike-007', 1, 'Full drivetrain overhaul', Periodicity.annual, 120, null),
      ('pms-bike-008', 1, 'Replace brake pads when worn', Periodicity.situational, 25, null),
    ];
    for (final s in seeds) {
      _savePmsCheck(PmsCheck(
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
      ));
    }
  }

  void _saveOrgEntity(String coll, String id, String json) {
    _node!.putRaw(coll, id, json);
    _bleBroadcast(coll, id, json);
  }

  /// The mesh host (the DIVO who minted the key) seeds a starter org chart the
  /// first time it comes up, so the mesh isn't empty. Joiners receive it synced.
  void _seedOrgIfHost() {
    // Runs at node start (before sign-in), so gate on host, not role.
    if (!_isMeshHost || _org.workcenters.isNotEmpty) return;
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

  void _notify(String title, String preview, String? peer) =>
      PeatNotifications.instance
          .showRemoteChange(collection: title, preview: preview, peerId: peer);

  @override
  Widget build(BuildContext context) {
    // 1. Mesh membership: host a new mesh or scan a join QR.
    if (_formationKey == null) {
      return _StartScreen(onHost: _hostMesh, onJoin: _openScanner);
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
        accounts: _accounts.values
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
    final mine = _jobs.values.where((j) => _needsMyAction(j) && _canSee(j)).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    // PENDING = in routing (climbing the approval or close-out ladder);
    // ACTIVE = approved + being worked (execution, or off-ship via TA).
    final pending = _jobs.values
        .where((j) =>
            _canSee(j) &&
            (j.phase == JobPhase.approval || j.phase == JobPhase.closeout))
        .toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final active = _jobs.values
        .where((j) =>
            _canSee(j) &&
            (j.phase == JobPhase.execution || j.phase == JobPhase.ta))
        .toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final completed = _jobs.values.where((j) => j.isClosed && _canSee(j)).toList()
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
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _AdminScreen(
                accounts: _accounts.values
                    .where((a) => a.role != Role.kratos) // Kratos stays hidden
                    .toList()
                  ..sort((a, b) => a.name.compareTo(b.name)),
                org: _org,
                onCreate: _createAccount,
                onUpdate: _updateAccount,
              ),
            )),
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
                    title: Text('Sign out / switch user'))),
            PopupMenuItem(
                value: 'reset',
                child: ListTile(
                    leading: Icon(Icons.restart_alt),
                    title: Text('Reset / leave mesh'))),
          ],
        ),
      ];

  /// The role / work-center / scope / peer-count strip under the app-bar title.
  PreferredSizeWidget _headerBar() => PreferredSize(
        preferredSize: const Size.fromHeight(34),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(children: [
            _Badge(_role!.tag, off: _role!.offShip),
            const SizedBox(width: 8),
            Flexible(
              child: Text('$_name · $_workcenter · sees ${scopeLabel(_role!)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white)),
            ),
            const Spacer(),
            Icon(Icons.hub,
                size: 16, color: Colors.white.withValues(alpha: 0.9)),
            const SizedBox(width: 4),
            Text('$_peers', style: const TextStyle(color: Colors.white)),
          ]),
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
  Widget _badgedIcon(IconData icon, String label, {Color? color, double? size}) {
    final base = Icon(icon, color: color, size: size);
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
  Widget _wideHome(List<Job> mine, List<Job> pending, List<Job> active,
      List<Job> completed) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grapheion'),
        actions: _appBarActions(),
        bottom: _headerBar(),
      ),
      floatingActionButton: _featureFab(),
      body: Row(children: [
        _featureRail(),
        const VerticalDivider(width: 1),
        Expanded(child: _featureBody(mine, pending, active, completed)),
      ]),
    );
  }

  /// Narrow layout: a feature menu; tapping opens a feature full-screen (stays
  /// in the widget tree, so it updates live; system back returns to the menu).
  Widget _narrowHome(List<Job> mine, List<Job> pending, List<Job> active,
      List<Job> completed) {
    if (!_featureOpen) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Grapheion'),
          actions: _appBarActions(),
          bottom: _headerBar(),
        ),
        body: ListView(children: [
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
        ]),
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
              onPressed: () => setState(() => _featureOpen = false)),
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
    (Icons.workspace_premium, 'PQS'),
    (Icons.hub, 'Connection'),
    (Icons.inventory_2, 'Supply'),
    (Icons.school, 'Training'),
    (Icons.how_to_reg, 'Muster'),
  ];

  /// The nav features for the signed-in role — Kratos additionally gets the
  /// Feedback inbox (the only role that can read it).
  List<(IconData, String)> get _navFeatures =>
      [..._features, if (_isKratos) (Icons.feedback, 'Feedback')];

  /// Left feature rail: a vertical, tappable list of features (scrolls if it
  /// can't all fit; content switches on tap — no swipe).
  Widget _featureRail() {
    return Container(
      width: 78,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SingleChildScrollView(
        child: Column(children: [
          const SizedBox(height: 8),
          for (var i = 0; i < _navFeatures.length; i++)
            _featureRailItem(i, _navFeatures[i].$1, _navFeatures[i].$2),
          const SizedBox(height: 8),
        ]),
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
        child: Column(children: [
          _badgedIcon(icon, label, color: fg, size: 26),
          const SizedBox(height: 3),
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10.5,
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
        ]),
      ),
    );
  }

  Widget _featureBody(List<Job> mine, List<Job> pending, List<Job> active,
      List<Job> completed) {
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
      case 'Feedback':
        return _feedbackPage();
      case 'Supply':
        return _stubPage(Icons.inventory_2, 'Supply',
            'Parts ordering, NSN lookup, requisition status.');
      case 'Training':
        return _stubPage(
            Icons.school, 'Training', 'Qualifications + PQS tracking.');
      default:
        return _stubPage(
            Icons.how_to_reg, 'Muster', 'Personnel accountability + muster.');
    }
  }

  /// CSMP: the corrective-maintenance views as tap-only sub-tabs (no swipe).
  /// INBOX = my action · PENDING = in routing · ACTIVE = approved/in work ·
  /// COMPLETED = closed.
  Widget _csmpView(List<Job> mine, List<Job> pending, List<Job> active,
      List<Job> completed) {
    return DefaultTabController(
      length: 4,
      child: Column(children: [
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
      ]),
    );
  }

  Widget _stubPage(IconData icon, String title, String blurb) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: Colors.grey),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('$blurb\n\nComing soon.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
        ]),
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('No watchbill set up yet.',
                style: TextStyle(color: Colors.grey)),
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
          ]),
        ),
      );
    }
    final ev = evos.firstWhere((e) => e.id == _evolutionId,
        orElse: () => evos.first);
    final day = startOfDay(DateTime.now().millisecondsSinceEpoch) +
        _watchDayOffset * 86400000;
    final roles = ev.roles.toList()..sort((a, b) => a.order.compareTo(b.order));
    return Column(children: [
      // Evolution selector + edit / new (admins).
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
        child: Row(children: [
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              underline: const SizedBox.shrink(),
              value: ev.id,
              items: [
                for (final e in evos)
                  DropdownMenuItem(
                    value: e.id,
                    child: Text(e.name,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis),
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
        ]),
      ),
      Row(children: [
        IconButton(
            onPressed: () => setState(() => _watchDayOffset--),
            icon: const Icon(Icons.chevron_left)),
        Expanded(
          child: Center(
            child: Text('${weekdayLabel(day)}  ${_shortDate(day)}',
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ),
        ),
        IconButton(
            onPressed: () => setState(() => _watchDayOffset++),
            icon: const Icon(Icons.chevron_right)),
        if (_watchDayOffset != 0)
          TextButton(
              onPressed: () => setState(() => _watchDayOffset = 0),
              child: const Text('Today')),
      ]),
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
        child: ListView(children: [
          for (final r in roles)
            if (r.rotating)
              _billRotatingGroup(day, ev, r)
            else
              _billSlotTile(day, ev, r, '', r.name, 'whole day'),
        ]),
      ),
    ]);
  }

  /// A rotating role — a header + one row per section shift.
  Widget _billRotatingGroup(int day, Evolution ev, EvolutionRole r) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child:
            Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      for (final s in ev.shifts)
        _billSlotTile(day, ev, r, s.id, 'Sec ${s.label}', '${s.start}-${s.end}'),
    ]);
  }

  /// One fillable bill slot (a standing role, or one shift of a rotating role).
  Widget _billSlotTile(int day, Evolution ev, EvolutionRole r, String shiftId,
      String label, String sub) {
    final pid = _store.billAssignee(day, ev.id, r.id, shiftId);
    final unqual =
        pid != null && pid.isNotEmpty && !_store.isQualified(pid, r.stationId);
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 58,
        child: Text(label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      title: (pid == null || pid.isEmpty)
          ? const Text('— unassigned', style: TextStyle(color: Colors.grey))
          : Row(children: [
              Flexible(
                child: Text(_billPersonLabel(pid),
                    style: TextStyle(
                        color: unqual ? _duOrange : null,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 6),
              _qualMark(pid, r.stationId),
            ]),
      subtitle: Text(sub, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      trailing: _canManageWatch ? const Icon(Icons.edit, size: 18) : null,
      onTap: _canManageWatch
          ? () => _openBillAssign(day, ev, r, shiftId, label)
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
          borderRadius: BorderRadius.circular(4)),
      child: Text(txt,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  void _openBillAssign(
      int day, Evolution ev, EvolutionRole r, String shiftId, String slot) {
    final qualified = _store.qualifiedFor(r.stationId)
      ..sort((a, b) => _billPersonLabel(a).compareTo(_billPersonLabel(b)));
    final current = _store.billAssignee(day, ev.id, r.id, shiftId);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('${r.name} · $slot',
                  style: Theme.of(ctx).textTheme.titleMedium),
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
          ]),
        ),
      ),
    );
  }

  /// PQS — each work-center member's progress across the whole qualification
  /// tree (designations first, then watch stations, knowledge, letters).
  Widget _pqsPage() {
    final quals = _store.qualifications.values.toList()..sort(_qualSort);
    final people = _watchPeople();
    if (quals.isEmpty) {
      return const Center(
          child: Text('Load the qualification set first (BILL tab).',
              style: TextStyle(color: Colors.grey)));
    }
    if (people.isEmpty) {
      return const Center(
          child: Text('No people in your work center yet.',
              style: TextStyle(color: Colors.grey)));
    }
    return ListView(children: [
      for (final (pid, name) in people)
        ExpansionTile(
          title: Text(name),
          subtitle: Text(_qualSummary(pid)),
          children: [for (final q in quals) _qualRow(pid, q)],
        ),
    ]);
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
          q, _store.quals[PersonQual.makeId(pid, q.id)], qualifiedIds);
      subtitle = Text(
        '$done/${q.prereqIds.length} prereqs${ready ? ' · ready to board' : ''}',
        style: TextStyle(
            fontSize: 11, color: ready ? Colors.green : Colors.grey),
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
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
        child: Text(stage.label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ),
    ]);
  }

  void _openQualSet(String pid, Qualification qual) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final pq = _store.quals[PersonQual.makeId(pid, qual.id)];
        final stage = pq?.stage ?? QualStage.notStarted;
        final missing = qual.type == QualType.designation
            ? missingPrereqs(qual, _store.qualifiedIdsFor(pid))
                .map((id) => _store.qualifications[id]?.abbr ?? id)
                .toList()
            : <String>[];
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('${_personName(pid)} · ${qual.abbr}',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              if (missing.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Prereqs remaining: ${missing.join(', ')}',
                      style:
                          const TextStyle(color: Colors.orange, fontSize: 12)),
                ),
              for (final l in QualStage.values)
                ListTile(
                  leading: Icon(Icons.circle, size: 14, color: _qualColors[l]),
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
                        _setQual(pid, qual.id, QualStage.qualified,
                            qualifier: v);
                        setS(() {});
                      }
                    : null,
              ),
              const SizedBox(height: 8),
            ]),
          ),
        );
      }),
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
      final dc = checks
          .where((c) =>
              c.periodicity == Periodicity.daily ||
              (c.scheduledForMs != null &&
                  isSameDay(c.scheduledForMs!, dayMs)))
          .toList()
        ..sort(byStatus);
      final dj = active.where(
          (j) => j.scheduledForMs != null && isSameDay(j.scheduledForMs!, dayMs));
      return [
        for (final c in dc) _draggableTile(check: c, dayMs: dayMs),
        for (final j in dj) _draggableTile(job: j, dayMs: dayMs),
      ];
    }

    // Pool = checks not placed this week (daily checks are excluded — they're
    // already on every day) + active jobs not placed this week.
    final poolChecks = checks
        .where((c) =>
            c.periodicity != Periodicity.daily && !thisWeek(c.scheduledForMs))
        .toList()
      ..sort(byStatus);
    final pool = <Widget>[
      for (final c in poolChecks) _draggableTile(check: c),
      for (final j in active)
        if (!thisWeek(j.scheduledForMs)) _draggableTile(job: j),
    ];

    return ListView(children: [
      _scheduleHeader(weekStart),
      if (checks.isEmpty && _canManageSked)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: OutlinedButton.icon(
            onPressed: _seedBicyclePms,
            icon: const Icon(Icons.pedal_bike),
            label: const Text('No PMS checks yet — load example: Bicycle PMS'),
          ),
        ),
      _scheduleGroup('Unscheduled', pool,
          empty: 'Nothing waiting — all placed on a day.',
          tint: false,
          targetDayMs: null),
      for (final d in days)
        _scheduleGroup('${weekdayLabel(d)}   ${_shortDate(d)}', forDay(d),
            empty: '—', tint: d == today, targetDayMs: d),
    ]);
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
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Add PMS check (${_workcenter})',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextField(
                    controller: mip,
                    decoration: const InputDecoration(
                        labelText: 'MIP number (e.g. 5921/023-14)')),
                const SizedBox(height: 12),
                TextField(
                    controller: title,
                    decoration:
                        const InputDecoration(labelText: 'What the check covers')),
                const SizedBox(height: 12),
                TextField(
                    controller: ein,
                    decoration: const InputDecoration(labelText: 'Equipment EIN')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<Periodicity>(
                      initialValue: per,
                      decoration:
                          const InputDecoration(labelText: 'Periodicity'),
                      items: Periodicity.values
                          .map((p) => DropdownMenuItem(
                              value: p,
                              child: Text('${p.label} (${p.code})')))
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
                      decoration: const InputDecoration(labelText: 'Est. min'),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                    'MRC code: ${per.code}-${int.tryParse(seq.text.trim()) ?? 1}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
        child: Row(children: [
          Text('Week of ${_shortDate(weekStart)}',
              style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (_canManageSked)
            const Text('drag onto a day · tap to assign',
                style: TextStyle(color: Colors.grey, fontSize: 11)),
        ]),
      );

  /// A board section (the Unscheduled pool or one day). Doubles as a drop
  /// target: dropping an item here assigns it to [targetDayMs] (null = pool /
  /// unschedule). Highlights while an item is dragged over it.
  Widget _scheduleGroup(String title, List<Widget> tiles,
      {required String empty, required bool tint, int? targetDayMs}) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<_SchedDrag>(
      onAcceptWithDetails: (d) => _scheduleItemForDay(
          check: d.data.check, job: d.data.job, dayMs: targetDayMs),
      builder: (ctx, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: hovering
                ? scheme.primary.withValues(alpha: 0.30)
                : (tint
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: tint ? scheme.onPrimaryContainer : null)),
              const Spacer(),
              if (tiles.isNotEmpty)
                Text('${tiles.length}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
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
        ]);
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
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(check != null ? Icons.event_repeat : Icons.construction,
              size: 16),
          const SizedBox(width: 8),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ]),
      ),
    );
    final dragging = Opacity(opacity: 0.35, child: tile);
    final desktop = {
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux
    }.contains(Theme.of(context).platform);
    return desktop
        ? Draggable<_SchedDrag>(
            data: data,
            feedback: feedback,
            childWhenDragging: dragging,
            child: tile)
        : LongPressDraggable<_SchedDrag>(
            data: data,
            feedback: feedback,
            childWhenDragging: dragging,
            child: tile);
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
              color: _checkDot(check, dayMs, now), shape: BoxShape.circle),
        ),
        title: Text(check.title.isEmpty
            ? '${check.mip} ${check.mrcCode}'
            : check.title),
        subtitle: Text([
          'MIP ${check.mip}',
          check.mrcCode,
          if (check.ein.isNotEmpty) check.ein,
          _dueText(check, now),
          if (check.assignedTo.isNotEmpty) 'asgd: ${check.assignedTo}',
        ].join('  ·  ')),
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
      subtitle: Text([
        'Job',
        'PRI ${j.priority}',
        if (j.ein.isNotEmpty) j.ein,
        if (j.assignedTo.isNotEmpty) 'asgd: ${j.assignedTo}',
      ].join('  ·  ')),
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
    final people = _store.accounts.values
        .where((a) => a.workcenterId == wc)
        .map((a) => a.name)
        .toSet()
        .toList()
      ..sort();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
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
                  child: Text('ASSIGN TO',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontWeight: FontWeight.w600)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(spacing: 6, children: [
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
                  ]),
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
                    child: Text('DAY',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                            fontWeight: FontWeight.w600)),
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
                        _scheduleItemForDay(check: check, job: job, dayMs: null);
                        Navigator.pop(ctx);
                      },
                    ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      }),
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
      return Center(child: Text(emptyText, style: const TextStyle(color: Colors.grey)));
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
              '${j.ein.isEmpty ? '—' : j.ein} · ${j.workcenter} · orig ${j.originator}'),
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
        child: Text('CASREPs are visible to DIVO, 3MC, DH, and Port Engineer.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey)),
      );
    }
    final active = _casreps.values
        .where((c) => c.type != CasrepType.cancel)
        .toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final cancelled = _casreps.values
        .where((c) => c.type == CasrepType.cancel)
        .toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final all = [...active, ...cancelled];
    if (all.isEmpty) {
      return const Center(
        child: Text('No CASREPs filed yet.',
            style: TextStyle(color: Colors.grey)),
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
                decoration: cancelled ? TextDecoration.lineThrough : null),
          ),
          subtitle: Text('${c.hull}  ·  ${opImpactLabel[c.opImpact]}  ·  ETR: ${c.etr.isEmpty ? 'TBD' : c.etr}'),
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
            Row(children: [
              _Badge('CR-${c.number}'),
              const SizedBox(width: 8),
              Expanded(
                child: Text(c.wuc.isEmpty ? '(no WUC)' : c.wuc,
                    style: Theme.of(ctx).textTheme.titleLarge),
              ),
              _Badge(c.type.name.toUpperCase(),
                  color: c.type == CasrepType.cancel
                      ? Colors.grey
                      : c.type == CasrepType.initial
                          ? _duOrange
                          : Colors.orange.shade700),
            ]),
            const SizedBox(height: 4),
            Text('${c.hull}  ·  ${opImpactLabel[c.opImpact]}  ·  ETR: ${c.etr.isEmpty ? 'TBD' : c.etr}',
                style: const TextStyle(color: Colors.grey)),
            if (job != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Job: ${job.title.isEmpty ? c.jobId : job.title}',
                    style: const TextStyle(color: Colors.grey)),
              ),
            const Divider(height: 20),
            Text(c.narrative),
            if (c.partsNeeded.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Parts/assist: ${c.partsNeeded}',
                  style: const TextStyle(fontStyle: FontStyle.italic)),
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
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openCasrepDialog(job ?? _jobs.values.first, existing: c);
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
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _duOrange),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  void _openCasrepDialog(Job job, {Casrep? existing}) {
    final hullCtrl = TextEditingController(text: existing?.hull ?? '');
    final wucCtrl = TextEditingController(text: existing?.wuc ?? '');
    final narrativeCtrl =
        TextEditingController(text: existing?.narrative ?? job.symptom);
    final etrCtrl = TextEditingController(text: existing?.etr ?? '');
    final partsCtrl = TextEditingController(text: existing?.partsNeeded ?? '');
    // New CASREP: default the category from the job's priority (editable).
    OpImpact impact = existing?.opImpact ?? casrepImpactForPriority(job.priority);

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
                Text('EIN: ${job.ein.isEmpty ? '—' : job.ein}  ·  P${job.priority}',
                    style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 16),
                TextField(
                  controller: hullCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Hull designator',
                      hintText: 'e.g. DDG-51'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: wucCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Work Unit Code (WUC)',
                      hintText: 'e.g. HM000'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<OpImpact>(
                  value: impact,
                  decoration:
                      const InputDecoration(labelText: 'Operational impact'),
                  items: OpImpact.values
                      .map((o) => DropdownMenuItem(
                          value: o, child: Text(opImpactLabel[o]!)))
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
                      hintText: 'e.g. 72 HRS, AWAITING PARTS'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: partsCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Parts / assistance required (optional)',
                      hintText: 'NSN, nomenclature, or request type'),
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
                    _snack(existing == null
                        ? 'CASREP CR-${c.number} filed and syncing'
                        : 'CASREP CR-${c.number} updated');
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
    final peers = _presence.values.where((p) {
      final ls = _lastSeenMs[p.nodeId];
      return ls != null && now - ls <= _kStaleWindowMs;
    }).toList()
      ..sort((a, b) {
        final ao = _online(a.nodeId) ? 0 : 1;
        final bo = _online(b.nodeId) ? 0 : 1;
        if (ao != bo) return ao - bo; // online first
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final Widget list = peers.isEmpty
        ? const Center(
            child: Text('No other nodes seen yet.',
                style: TextStyle(color: Colors.grey)))
        : ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final p = peers[i];
        final online = _online(p.nodeId);
        final (icon, tlabel) = _transportFor(p.nodeId);
        return ListTile(
          leading: Icon(icon,
              color:
                  online ? Theme.of(context).colorScheme.primary : Colors.grey),
          title: Row(children: [
            Flexible(
              child: Text(p.name.isEmpty ? p.nodeId.substring(0, 8) : p.name,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 6),
            _Badge(p.role.tag, off: p.role.offShip),
          ]),
          subtitle: Text('$tlabel · ${p.workcenter}'),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: online ? Colors.green : Colors.grey,
                      shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Text(online ? 'Online' : 'Offline',
                    style: TextStyle(
                        color: online ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.w600)),
              ]),
              if (!online)
                Text(_sinceText(p.nodeId),
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        );
      },
    );
    return Column(children: [
      _meshHeader(),
      Expanded(child: list),
    ]);
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
          child: Column(children: [
            const Text('Join the mesh',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 2),
            const Text('Have personnel scan this to connect',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            if (token == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text('Resolving network address…',
                    style: TextStyle(color: Colors.grey)),
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
          ]),
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
              TextField(controller: ein, decoration: const InputDecoration(labelText: 'Equipment (EIN)')),
              TextField(controller: symptom, decoration: const InputDecoration(labelText: 'Symptom'), maxLines: 2),
              const SizedBox(height: 8),
              Row(children: [
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
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
              Row(children: [
                Expanded(
                  child: Text(job.title.isEmpty ? '(untitled)' : job.title,
                      style: Theme.of(ctx).textTheme.titleLarge),
                ),
                _StageChip(job: job),
              ]),
              const SizedBox(height: 4),
              Text('${job.id}  ·  EIN ${job.ein.isEmpty ? '—' : job.ein}  ·  '
                  '${job.workcenter}  ·  P${job.priority}'),
              const SizedBox(height: 8),
              if (job.symptom.isNotEmpty) Text(job.symptom),
              const Divider(height: 24),
              Text('Chain of custody', style: Theme.of(ctx).textTheme.titleSmall),
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
              onPressed: onTap, icon: Icon(icon), label: Text(label)),
        );

    Widget approveReturn(String approveLabel, VoidCallback onReturn) =>
        Row(children: [
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
        ]);

    switch (job.phase) {
      case JobPhase.approval:
        if (job.approver == _role) {
          final next = nextInChain(job.approver);
          rows.add(approveReturn(
              next == null ? 'Approve (DIVO)' : 'Approve → ${next.tag}',
              () => _promptReturn(ctx, job)));
          if (_role == Role.divo) {
            rows.add(const SizedBox(height: 8));
            rows.add(wide('Request off-ship assistance (TA)', Icons.sailing, () {
              _requestTa(job);
              pop();
            }));
          }
        }
        break;
      case JobPhase.ta:
        if (_role == Role.portEngineer) {
          rows.add(Row(children: [
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
                  ctx, 'Decline TA', 'Decline', (c) => _declineTa(job, c)),
              icon: const Icon(Icons.close),
              label: const Text('Decline'),
            ),
          ]));
        }
        break;
      case JobPhase.execution:
        if (_role == Role.technician) {
          rows.add(wide(job.inWork ? 'Mark complete' : 'Start work',
              job.inWork ? Icons.done_all : Icons.play_arrow, () {
            job.inWork ? _markComplete(job) : _startWork(job);
            pop();
          }));
        }
        if (_role == Role.divo && !job.taRequested) {
          rows.add(const SizedBox(height: 8));
          rows.add(wide('Request off-ship assistance (TA)', Icons.sailing, () {
            _requestTa(job);
            pop();
          }));
        }
        break;
      case JobPhase.closeout:
        if (job.approver == _role) {
          final next = nextInChain(job.approver);
          rows.add(Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  _approve(job);
                  pop();
                },
                icon: const Icon(Icons.check),
                label: Text(next == null
                    ? 'Approve close-out (DIVO)'
                    : 'Confirm → ${next.tag}'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _promptAction(ctx, 'Reject close-out', 'Reject',
                  (c) => _rejectCloseout(job, c)),
              icon: const Icon(Icons.undo),
              label: const Text('Reject'),
            ),
          ]));
        }
        break;
      case JobPhase.closed:
        break;
    }
    // DIVO can generate or update a CASREP on any active job.
    if (_role == Role.divo && job.phase != JobPhase.closed) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      final existing = _casrepForJob(job.id);
      rows.add(SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () {
            pop();
            _openCasrepDialog(job, existing: existing);
          },
          icon: const Icon(Icons.assignment_late_outlined),
          label: Text(existing == null ? 'Generate CASREP' : 'Update CASREP'),
        ),
      ));
    }
    if (rows.isEmpty) return const [];
    return [const Divider(height: 24), ...rows];
  }

  /// Generic comment dialog: runs [onSubmit] with the entered text, then closes
  /// the dialog and the detail sheet ([sheetCtx]).
  void _promptAction(BuildContext sheetCtx, String title, String submitLabel,
      void Function(String) onSubmit) {
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
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
    final verb = {
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
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Badge(e.role.tag, off: e.role.offShip),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${e.actor} $verb', style: const TextStyle(fontWeight: FontWeight.w500)),
            if (e.comment.isNotEmpty)
              Text('“${e.comment}”', style: const TextStyle(fontStyle: FontStyle.italic)),
            Text(stamp, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ),
      ]),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
  const _StartScreen({required this.onHost, required this.onJoin});
  final Future<void> Function() onHost;
  final Future<void> Function() onJoin;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Align(
              alignment: Alignment.topRight, child: themeToggleButton(context)),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Grapheion',
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  const Text('Corrective-maintenance mesh',
                      style: TextStyle(color: Colors.grey)),
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
                  const Text(
                    "Scan your admin's QR to join the unit mesh.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 28),
                  TextButton(
                    onPressed: onHost,
                    child: const Text('Set up a new mesh instead'),
                  ),
                ]),
              ),
            ),
          ),
        ]),
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
  }) onCreate;

  @override
  Widget build(BuildContext context) {
    // Bootstrap: the host with no accounts yet creates the first admin.
    if (isHost && accounts.isEmpty) {
      return Scaffold(
        appBar: AppBar(
            title: _kratosTitle(context, 'Set up admin'),
            actions: [_resetButton(), themeToggleButton(context)]),
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
                    onSubmit: (name, rate, role, wc, pin) => onSignIn(onCreate(
                        name: name,
                        rate: rate,
                        role: role,
                        workcenterId: wc,
                        pin: pin)),
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
          actions: [_resetButton(), themeToggleButton(context)]),
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
                'Create your own profile — your admin can adjust it later'),
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
            child: Text('grapheion · build 2026.06',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ),
        ),
      );

  void _promptKratos(BuildContext context) {
    final ctrl = TextEditingController();
    String? error;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
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
            decoration: InputDecoration(labelText: 'Passphrase', errorText: error),
            onSubmitted: (_) => attempt(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(onPressed: attempt, child: const Text('Unlock')),
          ],
        );
      }),
    );
  }

  void _selfRegister(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
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
                      pin: pin);
                  Navigator.pop(ctx);
                  onSignIn(a);
                },
              ),
            ),
          ),
        ),
      ),
    ));
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
                  child: const Text('Cancel')),
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
  const _AdminScreen(
      {required this.accounts,
      required this.org,
      required this.onCreate,
      required this.onUpdate});
  final List<Account> accounts;
  final OrgChart org;
  final Account Function({
    required String name,
    required String rate,
    required Role role,
    required String workcenterId,
    required String pin,
  }) onCreate;
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
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
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
                      pin: pin);
                  setState(() => _accounts = [..._accounts, a]
                    ..sort((x, y) => x.name.compareTo(y.name)));
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
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
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
                    .map((r) => DropdownMenuItem(value: r, child: Text(r.title)))
                    .toList(),
                onChanged: (r) => setS(() => role = r ?? role),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: wcs.any((w) => w.id == wc) ? wc : null,
                decoration: const InputDecoration(labelText: 'Work center'),
                items: wcs
                    .map((w) => DropdownMenuItem(
                        value: w.id, child: Text('${w.id} · ${w.name}')))
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
          label: const Text('Add person')),
      body: _accounts.isEmpty
          ? const Center(
              child: Text('No accounts yet.',
                  style: TextStyle(color: Colors.grey)))
          : ListView(
              children: [
                for (final a in _accounts)
                  ListTile(
                    leading: _Badge(a.role.tag),
                    title: Text(a.rate.isEmpty ? a.name : '${a.rate} ${a.name}'),
                    subtitle: Text(
                        '${a.role.title} · ${widget.org.pathOf(a.workcenterId)} · sees ${scopeLabel(a.role)}'),
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
          String name, String rate, Role role, String workcenterId, String pin)
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
    final wc =
        widget.org.workcenters.isEmpty ? _wcText.text.trim() : (_wc ?? '');
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
            decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 12),
        TextField(
            controller: _rate,
            decoration:
                const InputDecoration(labelText: 'Rate / rank (e.g. MM2)')),
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
                helperText: 'Org chart not synced yet — type your work center'),
          )
        else
          DropdownButtonFormField<String>(
            initialValue: _wc,
            decoration: const InputDecoration(labelText: 'Work center'),
            items: wcs
                .map((w) => DropdownMenuItem(
                    value: w.id, child: Text('${w.id} · ${w.name}')))
                .toList(),
            onChanged: (v) => setState(() => _wc = v),
          ),
        const SizedBox(height: 12),
        Row(children: [
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
        ]),
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
      child: Text(text,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
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
            off: job.approver.offShip);
      case JobPhase.ta:
        return const _Badge('TA · PORT ENG', off: true);
      case JobPhase.execution:
        return _Badge(job.inWork ? 'IN WORK' : 'APPROVED',
            color: Colors.teal);
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
    const colors = {1: _duOrange, 2: Colors.orange, 3: Colors.amber, 4: Colors.green};
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
  final MobileScannerController _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
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
      body: Stack(alignment: Alignment.center, children: [
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
          child: Text("Point at the DIVO's join QR",
              style: TextStyle(color: Colors.white, fontSize: 16)),
        ),
      ]),
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
            .map((s) => WatchShift(
                id: s.id, label: s.label, start: s.start, end: s.end))
            .toList();
    _roles = (e?.roles ?? [])
        .map((r) => EvolutionRole(
            id: r.id,
            stationId: r.stationId,
            name: r.name,
            rotating: r.rotating,
            order: r.order))
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
        WatchShift(id: 's${i + 1}', label: t[i][0], start: t[i][1], end: t[i][2])
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
    widget.onSave(Evolution(
      id: widget.initial?.id ??
          'ev-${DateTime.now().microsecondsSinceEpoch}',
      name: nm,
      inPort: _inPort,
      shifts: _shifts,
      roles: _roles,
      order: widget.initial?.order ?? 0,
    ));
    Navigator.pop(context);
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final hasRotating = _roles.any((r) => r.rotating);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'New evolution' : 'Edit evolution'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
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
                color: Theme.of(context).colorScheme.primary),
            title: Text(r.name),
            subtitle: Text(
                '${_stationName(r.stationId)} · ${r.rotating ? 'Rotating' : 'Standing'}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => setState(() => _roles.remove(r)),
            ),
            onTap: () => _editRole(r),
          ),
        const SizedBox(height: 16),
        _sectionHeader('Rotation shifts', () => _editShift(null)),
        _hint(hasRotating
            ? 'Rotating roles are split across these shifts; standing roles ignore them.'
            : 'Only used once a role is set to Rotating.'),
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
      ]),
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
    String? stationId = existing?.stationId ??
        (_stations.isNotEmpty ? _stations.first.id : null);
    bool rotating = existing?.rotating ?? false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(existing == null ? 'Add role' : 'Edit role'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Role name',
                    hintText: 'e.g. Officer of the Deck'),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: stationId,
                    hint: const Text('Watch station'),
                    items: [
                      for (final s in _stations)
                        DropdownMenuItem(
                            value: s.id,
                            child: Text(s.name,
                                overflow: TextOverflow.ellipsis)),
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
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: rotating,
                onChanged: (v) => setD(() => rotating = v),
                title: const Text('Rotating'),
                subtitle: const Text('Sectioned across the shifts'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final nm = nameCtrl.text.trim();
                if (nm.isEmpty || stationId == null) return;
                setState(() {
                  if (existing == null) {
                    _roles.add(EvolutionRole(
                      id: 'r-${DateTime.now().microsecondsSinceEpoch}',
                      stationId: stationId!,
                      name: nm,
                      rotating: rotating,
                      order: _roles.length,
                    ));
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
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Station name'),
          ),
          TextField(
            controller: abbrCtrl,
            textCapitalization: TextCapitalization.characters,
            decoration:
                const InputDecoration(labelText: 'Abbreviation (optional)'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final nm = nameCtrl.text.trim();
              if (nm.isEmpty) return;
              Navigator.pop(c, widget.onCreateStation(nm, abbrCtrl.text.trim()));
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _editShift(WatchShift? existing) {
    final labelCtrl =
        TextEditingController(text: existing?.label ?? '${_shifts.length + 1}');
    final startCtrl = TextEditingController(text: existing?.start ?? '');
    final endCtrl = TextEditingController(text: existing?.end ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add shift' : 'Edit shift'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: labelCtrl,
            decoration: const InputDecoration(labelText: 'Section label'),
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: startCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Start (0630)'),
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
          ]),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              setState(() {
                if (existing == null) {
                  _shifts.add(WatchShift(
                    id: 's${DateTime.now().microsecondsSinceEpoch}',
                    label: labelCtrl.text.trim(),
                    start: startCtrl.text.trim(),
                    end: endCtrl.text.trim(),
                  ));
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
