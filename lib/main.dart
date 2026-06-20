// Grapheion — mesh-synced corrective-maintenance approval chain (POC).
//
// Each device logs in as one role in the chain of command. A maintenance
// technician originates a job; it then climbs the chain (WCS -> LPO -> DIVO ->
// 3MC -> CHENG) and finally crosses off-ship to the Port Engineer over the mesh
// relay. Jobs and their audit log sync as peat documents; the next approver is
// notified on each hand-off.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:peat_flutter/peat_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain/chain.dart';
import 'domain/job.dart';
import 'notifications.dart';

// POC unit credentials: every grapheion node on the same LAN/relay with this
// app id + key forms one mesh ("the ship"). Replace the key for a real unit.
const _kAppId = 'grapheion';
const _kSharedKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _kJobs = 'jobs';
const _kLog = 'joblog';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PeatFlutterNode.initialize();
  PeatNotifications.instance.init();
  runApp(const GrapheionApp());
}

class GrapheionApp extends StatelessWidget {
  const GrapheionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grapheion',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E5E8C)),
        useMaterial3: true,
      ),
      home: const HomePage(),
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
  String _name = '';
  Role? _role;
  String _workcenter = 'MP01';
  String? _error;

  final Map<String, Job> _jobs = {};
  final Map<String, List<JobEvent>> _events = {};
  int _peers = 0;

  @override
  void initState() {
    super.initState();
    _restoreIdentity();
  }

  Future<void> _restoreIdentity() async {
    final p = await SharedPreferences.getInstance();
    final role = p.getString('role');
    final name = p.getString('name');
    final wc = p.getString('workcenter');
    if (role != null && name != null && name.isNotEmpty) {
      _name = name;
      _role = roleFromToken(role);
      _workcenter = wc ?? 'MP01';
      await _startNode();
    } else {
      setState(() {});
    }
  }

  Future<void> _login(String name, Role role, String workcenter) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('name', name);
    await p.setString('role', role.token);
    await p.setString('workcenter', workcenter);
    _name = name;
    _role = role;
    _workcenter = workcenter;
    await _startNode();
  }

  Future<void> _startNode() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final node = PeatFlutterNode.create(NodeConfig(
        appId: _kAppId,
        sharedKey: _kSharedKey,
        bindAddress: null,
        storagePath: '${dir.path}/grapheion',
        transport: const TransportConfigFFI(
          enableBle: false, // v0: Iroh/WiFi/relay mesh; BLE radio comes later
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
    } catch (e) {
      setState(() => _error = '$e');
    }
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
  }

  void _onChange(DocumentChange change) {
    final node = _node;
    if (node == null) return;
    if (change.collection == _kJobs) {
      final raw = node.getRaw(_kJobs, change.docId);
      if (raw == null) return;
      try {
        final job = Job.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        final wasMine = _jobs[job.id]?.approver == _role;
        _jobs[job.id] = job;
        // A remote action just handed this job to MY stage → alert.
        if (change.origin.isRemote &&
            job.approver == _role &&
            job.status != JobStatus.accepted &&
            !wasMine) {
          PeatNotifications.instance.showRemoteChange(
            collection: job.title.isEmpty ? 'a job' : job.title,
            preview: 'awaiting your ${_role!.tag} action',
            peerId: change.origin.peerId,
          );
        }
        if (mounted) setState(() {});
      } catch (_) {}
    } else if (change.collection == _kLog) {
      final raw = node.getRaw(_kLog, change.docId);
      if (raw == null) return;
      try {
        _ingestEvent(JobEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>));
        if (mounted) setState(() {});
      } catch (_) {}
    }
  }

  void _ingestEvent(JobEvent ev) {
    final list = _events.putIfAbsent(ev.jobId, () => []);
    if (list.any((e) => e.docId == ev.docId)) return;
    list.add(ev);
    list.sort((a, b) => a.tsMs.compareTo(b.tsMs));
  }

  // --- Writes (sync over the mesh) -----------------------------------------

  void _saveJob(Job job) =>
      _node!.putRaw(_kJobs, job.id, jsonEncode(job.toJson()));

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
    _node!.putRaw(_kLog, ev.docId, jsonEncode(ev.toJson()));
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

  void _approve(Job job) {
    job.approve(DateTime.now().millisecondsSinceEpoch);
    _saveJob(job);
    _appendEvent(job, job.status == JobStatus.accepted ? 'accept' : 'approve', '');
    setState(() {});
  }

  void _returnDown(Job job, String comment) {
    job.returnDown(DateTime.now().millisecondsSinceEpoch);
    _saveJob(job);
    _appendEvent(job, 'return', comment);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_role == null) return _LoginScreen(onLogin: _login);
    if (_error != null) {
      return Scaffold(body: Center(child: Text('Failed to start: $_error')));
    }
    if (_node == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final mine = _jobs.values
        .where((j) => j.approver == _role && j.status != JobStatus.accepted)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final board = _jobs.values.toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));

    _peers = _node!.peerCount;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Grapheion'),
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
                    Text('$_name · $_workcenter',
                        style: const TextStyle(color: Colors.white)),
                    const Spacer(),
                    Icon(Icons.hub,
                        size: 16, color: Colors.white.withValues(alpha: 0.9)),
                    const SizedBox(width: 4),
                    Text('$_peers',
                        style: const TextStyle(color: Colors.white)),
                  ]),
                  const TabBar(tabs: [
                    Tab(text: 'INBOX'),
                    Tab(text: 'BOARD'),
                  ]),
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
          _jobList(board, emptyText: 'No jobs yet. Originate one.'),
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
        final canAct = job.approver == _role && job.status != JobStatus.accepted;
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
              if (canAct) ...[
                const Divider(height: 24),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        _approve(job);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.check),
                      label: Text(nextInChain(job.approver) == null
                          ? 'Accept (off-ship)'
                          : 'Approve → ${nextInChain(job.approver)!.tag}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _promptReturn(ctx, job),
                    icon: const Icon(Icons.undo),
                    label: const Text('Return'),
                  ),
                ]),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _eventTile(JobEvent e) {
    final t = DateTime.fromMillisecondsSinceEpoch(e.tsMs);
    final stamp =
        '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final verb = {
          'originate': 'originated',
          'approve': 'approved',
          'accept': 'accepted off-ship',
          'return': 'returned',
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

class _LoginScreen extends StatefulWidget {
  const _LoginScreen({required this.onLogin});
  final Future<void> Function(String name, Role role, String workcenter) onLogin;
  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  final _name = TextEditingController();
  final _wc = TextEditingController(text: 'MP01');
  Role _role = Role.technician;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Grapheion', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text('Sign in as your role in the chain',
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name / rate')),
              const SizedBox(height: 12),
              TextField(controller: _wc, decoration: const InputDecoration(labelText: 'Work center')),
              const SizedBox(height: 12),
              DropdownButtonFormField<Role>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: Role.values
                    .map((r) => DropdownMenuItem(value: r, child: Text(r.title)))
                    .toList(),
                onChanged: (r) => setState(() => _role = r ?? Role.technician),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final n = _name.text.trim();
                    if (n.isEmpty) return;
                    widget.onLogin(n, _role, _wc.text.trim().isEmpty ? 'MP01' : _wc.text.trim());
                  },
                  child: const Text('Enter Grapheion'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// --- Small widgets ----------------------------------------------------------

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.off = false});
  final String text;
  final bool off;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: off ? Colors.deepOrange : const Color(0xFF2E5E8C),
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
    if (job.status == JobStatus.accepted) {
      return const _Badge('ACCEPTED', off: true);
    }
    final label = job.status == JobStatus.returned
        ? '↩ ${job.approver.tag}'
        : job.approver.tag;
    return _Badge(label, off: job.approver.offShip);
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
