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
import 'package:pointycastle/export.dart'
    show GCMBlockCipher, AESEngine, AEADParameters, KeyParameter;
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:peat_flutter/peat_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain/chain.dart';
import 'domain/job.dart';
import 'domain/org.dart';
import 'notifications.dart';

// POC unit credentials: every grapheion node on the same LAN/relay with this
// app id + key forms one mesh ("the ship"). Replace the key for a real unit.
const _kAppId = 'grapheion';
const _kJobs = 'jobs';
const _kLog = 'joblog';
const _kPresence = 'presence';
const _kDepts = 'departments'; // managed org chart (synced like jobs)
const _kDivs = 'divisions';
const _kWcs = 'workcenters';
const _kAccounts = 'accounts'; // synced personnel directory (PIN-protected)

/// A peer is "online" if we've heard a presence beat from it within this window.
const _kOnlineWindowMs = 30 * 1000;

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
  grapheionThemeMode.value = tm == 'light'
      ? ThemeMode.light
      : tm == 'dark'
          ? ThemeMode.dark
          : ThemeMode.system;
  runApp(const GrapheionApp());
}

const _kSeed = Color(0xFF2E5E8C); // brand navy

/// App-wide theme mode (light/dark/system), toggled from the app bar and
/// persisted. `system` by default, so it follows the OS until the user picks.
final ValueNotifier<ThemeMode> grapheionThemeMode =
    ValueNotifier(ThemeMode.system);

ThemeData _grapheionTheme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: _kSeed, brightness: brightness),
      useMaterial3: true,
      // Keep the brand navy app bar in both modes so the white header reads.
      appBarTheme: const AppBarTheme(
        backgroundColor: _kSeed,
        foregroundColor: Colors.white,
      ),
    );

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
  // Identity is the signed-in account; _name/_role/_workcenter mirror it so the
  // rest of the app keeps working unchanged.
  Account? _account;
  String _name = '';
  Role? _role;
  String _workcenter = 'CP01';
  String? _error;

  final Map<String, Account> _accounts = {}; // synced personnel directory
  bool _isMeshHost = false; // minted the key -> bootstraps the first admin
  String? _pendingAccountId; // last signed-in account, restored once it syncs

  final Map<String, Job> _jobs = {};
  final OrgChart _org = OrgChart(); // synced org chart; drives role visibility
  final Map<String, List<JobEvent>> _events = {};
  int _peers = 0;

  // Mesh presence: who else is on the net, how they're reachable, and when we
  // last heard from them.
  final Map<String, _Peer> _presence = {};
  final Map<String, int> _lastSeenMs = {}; // local receive time per peer node id
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
    _pendingAccountId = p.getString('accountId');
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

  /// Adopt [a] as the signed-in identity and mirror it into _name/_role/_wc.
  void _setAccount(Account a) {
    _account = a;
    _name = a.name;
    _role = a.role;
    _workcenter = a.workcenterId;
    _pendingAccountId = a.id;
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
    _node!.putRaw(_kAccounts, id, json);
    _bleBroadcast(_kAccounts, id, json);
    if (mounted) setState(() {});
    return a;
  }

  /// Admin action: persist an edited account (e.g. adjusting a self-registered
  /// person's role / work center).
  void _updateAccount(Account a) {
    _accounts[a.id] = a;
    final json = jsonEncode(a.toJson());
    _node!.putRaw(_kAccounts, a.id, json);
    _bleBroadcast(_kAccounts, a.id, json);
    // If we edited our own account, mirror the change into the live identity.
    if (_account?.id == a.id) {
      _role = a.role;
      _workcenter = a.workcenterId;
      _name = a.name;
    }
    if (mounted) setState(() {});
  }

  /// Sign out of the account but stay in the mesh (node + key live on).
  Future<void> _signOut() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('accountId');
    setState(() {
      _account = null;
      _pendingAccountId = null;
      _role = null;
      _name = '';
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
    _account = null;
    _pendingAccountId = null;
    _role = null;
    _name = '';
    _workcenter = 'CP01';
    _accounts.clear();
    _jobs.clear();
    _events.clear();
    _presence.clear();
    _lastSeenMs.clear();
    _transport.clear();
    _org.departments.clear();
    _org.divisions.clear();
    _org.workcenters.clear();
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
            _bleBroadcast(_kJobs, job.id, jsonEncode(job.toJson()));
          }
          // Re-broadcast the small org chart so late BLE joiners converge.
          for (final d in _org.departments.values) {
            _bleBroadcast(_kDepts, d.id, jsonEncode(d.toJson()));
          }
          for (final v in _org.divisions.values) {
            _bleBroadcast(_kDivs, v.id, jsonEncode(v.toJson()));
          }
          for (final w in _org.workcenters.values) {
            _bleBroadcast(_kWcs, w.id, jsonEncode(w.toJson()));
          }
          for (final a in _accounts.values) {
            _bleBroadcast(_kAccounts, a.id, jsonEncode(a.toJson()));
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
    final json = jsonEncode({
      'nodeId': node.nodeId,
      'name': _name,
      'role': _role!.token,
      'workcenter': _workcenter,
      'hb': DateTime.now().millisecondsSinceEpoch,
    });
    node.putRaw(_kPresence, node.nodeId, json);
    _bleBroadcast(_kPresence, node.nodeId, json);
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
    if (!(Platform.isIOS || Platform.isMacOS)) return; // native bridge is Apple
    try {
      final bleNodeId = int.parse(node.nodeId.substring(0, 8), radix: 16);
      _bleChannel.invokeMethod('startBle', {
        'nodeId': bleNodeId,
        'callsign': _name.isEmpty ? 'grapheion' : _name,
      }).catchError((_) => null);
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
      _bleChannel.invokeMethod('bleTx', env).catchError((_) => null);
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
      _applyDoc(coll, id, docRaw, remote: true, peer: null);
      _node?.putRaw(coll, id, docRaw); // persist + re-bridge over Iroh
      // Visibility for BLE testing — a grapheion doc just crossed over Bluetooth.
      if (coll == _kJobs || coll == _kLog) debugPrint('[BLE-RX] $coll · $id');
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

  void _loadExisting(PeatFlutterNode node) {
    for (final id in node.listDocuments(_kJobs)) {
      final raw = node.getRaw(_kJobs, id);
      if (raw != null) {
        try {
          _jobs[id] = Job.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {}
      }
    }
    for (final id in node.listDocuments(_kLog)) {
      final raw = node.getRaw(_kLog, id);
      if (raw != null) {
        try {
          _ingestEvent(JobEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    for (final id in node.listDocuments(_kPresence)) {
      final raw = node.getRaw(_kPresence, id);
      if (raw != null) _ingestPresence(node, raw, fromHeartbeat: true);
    }
    for (final id in node.listDocuments(_kDepts)) {
      final raw = node.getRaw(_kDepts, id);
      if (raw != null) _applyOrg(_kDepts, raw);
    }
    for (final id in node.listDocuments(_kDivs)) {
      final raw = node.getRaw(_kDivs, id);
      if (raw != null) _applyOrg(_kDivs, raw);
    }
    for (final id in node.listDocuments(_kWcs)) {
      final raw = node.getRaw(_kWcs, id);
      if (raw != null) _applyOrg(_kWcs, raw);
    }
    for (final id in node.listDocuments(_kAccounts)) {
      final raw = node.getRaw(_kAccounts, id);
      if (raw != null) {
        try {
          _accounts[id] =
              Account.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {}
      }
    }
  }

  /// Fold one org-chart entity into the in-memory [_org].
  void _applyOrg(String coll, String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (coll == _kDepts) {
        final d = Department.fromJson(m);
        _org.departments[d.id] = d;
      } else if (coll == _kDivs) {
        final v = Division.fromJson(m);
        _org.divisions[v.id] = v;
      } else if (coll == _kWcs) {
        final w = WorkCenter.fromJson(m);
        _org.workcenters[w.id] = w;
      }
    } catch (_) {}
  }

  void _ingestPresence(PeatFlutterNode node, String raw, {bool fromHeartbeat = false}) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final nid = m['nodeId'] as String;
      if (nid == node.nodeId) return; // skip ourselves
      _presence[nid] = _Peer(
        nodeId: nid,
        name: (m['name'] ?? '') as String,
        role: roleFromToken((m['role'] ?? 'technician') as String),
        workcenter: (m['workcenter'] ?? '') as String,
      );
      // Live beats use local receive time (skew-proof); a cold-loaded doc seeds
      // from the peer's own heartbeat until a live beat refreshes it.
      _lastSeenMs[nid] = fromHeartbeat
          ? (m['hb'] ?? 0) as int
          : DateTime.now().millisecondsSinceEpoch;
    } catch (_) {}
  }

  void _onChange(DocumentChange change) {
    final node = _node;
    if (node == null) return;
    final raw = node.getRaw(change.collection, change.docId);
    if (raw == null) return;
    _applyDoc(change.collection, change.docId, raw,
        remote: change.origin.isRemote, peer: change.origin.peerId);
    if (mounted) setState(() {});
  }

  /// Apply an incoming document — from Iroh (subscribeChanges) OR a BLE frame —
  /// to the in-memory model, notifying on remote changes.
  void _applyDoc(String coll, String docId, String raw,
      {required bool remote, String? peer}) {
    try {
      if (coll == _kJobs) {
        final job = Job.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        final old = _jobs[job.id];
        _jobs[job.id] = job;
        if (remote) _notifyForChange(old, job, peer);
      } else if (coll == _kLog) {
        _ingestEvent(JobEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } else if (coll == _kPresence) {
        _ingestPresence(_node!, raw); // live beat -> local receive time
      } else if (coll == _kDepts || coll == _kDivs || coll == _kWcs) {
        _applyOrg(coll, raw);
      } else if (coll == _kAccounts) {
        _accounts[docId] =
            Account.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        _restoreAccount(); // our account may have just arrived
      }
    } catch (_) {}
  }

  void _ingestEvent(JobEvent ev) {
    final list = _events.putIfAbsent(ev.jobId, () => []);
    if (list.any((e) => e.docId == ev.docId)) return;
    list.add(ev);
    list.sort((a, b) => a.tsMs.compareTo(b.tsMs));
  }

  // --- Writes (sync over the mesh) -----------------------------------------

  void _saveJob(Job job) {
    final json = jsonEncode(job.toJson());
    _node!.putRaw(_kJobs, job.id, json);
    _bleBroadcast(_kJobs, job.id, json);
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
      _saveOrgEntity(_kDepts, d.id, jsonEncode(d.toJson()));
    }
    for (final v in seed.divisions.values) {
      _org.divisions[v.id] = v;
      _saveOrgEntity(_kDivs, v.id, jsonEncode(v.toJson()));
    }
    for (final w in seed.workcenters.values) {
      _org.workcenters[w.id] = w;
      _saveOrgEntity(_kWcs, w.id, jsonEncode(w.toJson()));
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
    _ingestEvent(ev);
    final json = jsonEncode(ev.toJson());
    _node!.putRaw(_kLog, ev.docId, json);
    _bleBroadcast(_kLog, ev.docId, json);
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

  /// Whether this job is currently waiting on MY action (for the Inbox).
  bool _needsMyAction(Job j) {
    switch (j.phase) {
      case JobPhase.approval:
      case JobPhase.closeout:
        return j.approver == _role;
      case JobPhase.ta:
        return _role == Role.portEngineer;
      case JobPhase.execution:
        return _role == Role.technician;
      case JobPhase.closed:
        return false;
    }
  }

  // --- Notifications --------------------------------------------------------

  void _notify(String title, String preview, String? peer) =>
      PeatNotifications.instance
          .showRemoteChange(collection: title, preview: preview, peerId: peer);

  /// The next approver gets a "your turn" ping; the originator hears that their
  /// job advanced, was returned, or was closed.
  void _notifyForChange(Job? old, Job job, String? peer) {
    final title = job.title.isEmpty ? 'a job' : job.title;
    final mineNow = _needsMyAction(job);
    final mineBefore = old != null && _needsMyAction(old);
    if (mineNow && !mineBefore) {
      _notify(title, 'awaiting your ${_role!.tag} action', peer);
      return;
    }
    if (old != null && job.originator == _name) {
      if (job.returned && !old.returned) {
        _notify(title, 'returned for rework', peer);
      } else if (job.phase == JobPhase.closed && old.phase != JobPhase.closed) {
        _notify(title, 'closed out', peer);
      } else if (job.phase != old.phase || job.approver != old.approver) {
        _notify(title, 'approved → ${_stageText(job)}', peer);
      }
    }
  }

  String _stageText(Job j) {
    switch (j.phase) {
      case JobPhase.approval:
        return j.approver.tag;
      case JobPhase.ta:
        return 'off-ship (PE)';
      case JobPhase.execution:
        return j.inWork ? 'in work' : 'approved';
      case JobPhase.closeout:
        return 'closing (${j.approver.tag})';
      case JobPhase.closed:
        return 'closed';
    }
  }

  /// Non-DIVO with no formation key: must scan the DIVO's QR to enter the mesh.
  /// Whether the signed-in role may see [j] under the org-scoped rules. Until
  /// the org chart has synced (empty), don't filter — fall back to see-all.
  bool _canSee(Job j) {
    if (_org.workcenters.isEmpty) return true;
    return canSeeJob(
      role: _role!,
      viewerWorkcenterId: _workcenter,
      jobWorkcenterId: j.workcenter,
      jobHasTa: j.taRequested,
      org: _org,
    );
  }

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
        accounts: _accounts.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name)),
        org: _org,
        isHost: _isMeshHost,
        onSignIn: _setAccount,
        onCreate: _createAccount,
        onReset: () => _confirmReset(context),
      );
    }

    // Role-scoped visibility: a WCS/Tech sees their work center, LPO/DIVO their
    // division, CHENG their department, 3MC the ship, the PE only TA'd jobs.
    final mine = _jobs.values.where((j) => _needsMyAction(j) && _canSee(j)).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final board = _jobs.values.where((j) => !j.isClosed && _canSee(j)).toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final completed = _jobs.values.where((j) => j.isClosed && _canSee(j)).toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));

    _peers = _node!.peerCount;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Grapheion'),
          actions: [
            if (_account?.isAdmin ?? false)
              IconButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _AdminScreen(
                    accounts: _accounts.values.toList()
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
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(72),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    _Badge(_role!.tag, off: _role!.offShip),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                          '$_name · $_workcenter · sees ${scopeLabel(_role!)}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white)),
                    ),
                    const Spacer(),
                    Icon(Icons.hub,
                        size: 16, color: Colors.white.withValues(alpha: 0.9)),
                    const SizedBox(width: 4),
                    Text('$_peers',
                        style: const TextStyle(color: Colors.white)),
                  ]),
                  const TabBar(
                    isScrollable: true,
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white70,
                    indicatorColor: Colors.white,
                    tabs: [
                      Tab(text: 'INBOX'),
                      Tab(text: 'BOARD'),
                      Tab(text: 'COMPLETED'),
                      Tab(text: 'MESH'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _openCreate,
          icon: const Icon(Icons.add),
          label: const Text('New job'),
        ),
        body: TabBarView(children: [
          _jobList(mine, emptyText: 'No jobs awaiting your action.'),
          _jobList(board, emptyText: 'No active jobs. Originate one.'),
          _jobList(completed, emptyText: 'No closed jobs yet.'),
          _connectionsPage(),
        ]),
      ),
    );
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

  Widget _connectionsPage() {
    final peers = _presence.values.toList()
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

  /// Mesh-tab header: the mesh host shows the join QR; everyone else a scanner.
  Widget _meshHeader() {
    if (_isMeshHost) {
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

/// Account sign-in: bootstrap the first admin (host) or pick your profile + PIN.
class _SignInScreen extends StatelessWidget {
  const _SignInScreen({
    required this.accounts,
    required this.org,
    required this.isHost,
    required this.onSignIn,
    required this.onCreate,
    required this.onReset,
  });
  final List<Account> accounts;
  final OrgChart org;
  final bool isHost;
  final void Function(Account) onSignIn;
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
            title: const Text('Set up admin'),
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
          title: const Text('Sign in'),
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
        ],
      ),
    );
  }

  Widget _resetButton() => IconButton(
        onPressed: onReset,
        icon: const Icon(Icons.restart_alt),
        tooltip: 'Reset / leave mesh',
      );

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
                roles: Role.values,
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
                roles: Role.values,
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
            child: Text(_err!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}

// --- Models / small widgets -------------------------------------------------

/// A peer seen on the mesh, from its presence beat.
class _Peer {
  _Peer({
    required this.nodeId,
    required this.name,
    required this.role,
    required this.workcenter,
  });
  final String nodeId;
  final String name;
  final Role role;
  final String workcenter;
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
    const colors = {1: Colors.red, 2: Colors.orange, 3: Colors.amber, 4: Colors.green};
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
