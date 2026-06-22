// The synced domain state + the logic that mutates and queries it, extracted
// out of the UI so it can be unit-tested without a mesh node or a widget.
//
// The store is PURE: it holds the collections, applies inbound documents, and
// answers visibility/notification questions. It never talks to the node, BLE,
// or the notification plugin directly — the widget injects those as callbacks
// ([onNotify]) and drives sync in/out. This is exactly where the live bugs have
// lived (account live-adopt, the CASREP→phantom-account double-parse), so it's
// the highest-value thing to have under test.

import 'dart:convert';

import 'domain/casrep.dart';
import 'domain/chain.dart';
import 'domain/feedback.dart';
import 'domain/job.dart';
import 'domain/org.dart';
import 'domain/sked.dart';
import 'domain/watch.dart';

// Synced collection names (shared with the BLE/Iroh wiring in the widget).
const kJobs = 'jobs';
const kLog = 'joblog';
const kPresence = 'presence';
const kDepts = 'departments';
const kDivs = 'divisions';
const kWcs = 'workcenters';
const kAccounts = 'accounts';
const kCasreps = 'casreps';
const kPmsChecks = 'pmschecks'; // SKED / PMS checks
const kQualifications = 'qualifications'; // qual tree nodes (watch/knowledge/…)
const kQuals = 'quals'; // PQS progress (person x qualification)
const kWatchbill = 'watchbill'; // watch assignments (day x station x period)
const kFeedback = 'feedback'; // demo feedback (anyone writes, only Kratos reads)

/// A peer seen on the mesh, from its presence beat.
class Peer {
  Peer({
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

class MeshStore {
  MeshStore({required this.onNotify});

  /// Fired when a synced change warrants a user notification. The widget wires
  /// this to the notification plugin; tests pass a spy.
  final void Function(String title, String preview, String? peer) onNotify;

  // --- Synced state ---------------------------------------------------------
  final Map<String, Job> jobs = {};
  final Map<String, List<JobEvent>> events = {};
  final Map<String, Account> accounts = {};
  final Map<String, Casrep> casreps = {};
  final Map<String, PmsCheck> pmsChecks = {};
  final Map<String, Qualification> qualifications = {};
  final Map<String, PersonQual> quals = {}; // keyed by PersonQual.makeId
  final Map<String, WatchAssignment> watchbill = {};
  final Map<String, FeedbackNote> feedback = {};
  final OrgChart org = OrgChart();
  final Map<String, Peer> presence = {};
  final Map<String, int> lastSeenMs = {}; // local receive time per peer node id

  // --- Identity -------------------------------------------------------------
  Account? account; // the signed-in account; null until sign-in
  String? myNodeId; // set when the node starts (to skip our own presence beats)
  String? pendingAccountId; // last signed-in account, restored once it syncs

  Role? get role => account?.role;
  String get name => account?.name ?? '';
  String get workcenter => account?.workcenterId ?? '';

  /// Re-adopt the last signed-in account once it's present locally.
  void restoreAccount() {
    final id = pendingAccountId;
    if (account == null && id != null && accounts.containsKey(id)) {
      account = accounts[id];
    }
  }

  // --- Apply inbound documents ---------------------------------------------

  /// Apply one inbound document (from Iroh subscribeChanges OR a BLE frame).
  /// Notifies via [onNotify] only for remote changes.
  void applyDoc(String coll, String docId, String raw,
      {required bool remote, String? peer}) {
    try {
      if (coll == kJobs) {
        final job = Job.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        final old = jobs[job.id];
        jobs[job.id] = job;
        if (remote) _notifyForChange(old, job, peer);
      } else if (coll == kLog) {
        ingestEvent(JobEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } else if (coll == kPresence) {
        ingestPresence(raw);
      } else if (coll == kDepts || coll == kDivs || coll == kWcs) {
        applyOrg(coll, raw);
      } else if (coll == kAccounts) {
        final acct = Account.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        accounts[acct.id] = acct;
        if (account?.id == acct.id) {
          // Our own account was edited remotely (admin reassigned role / work
          // center) — adopt it live (role/name/WC derive from `account`).
          account = acct;
        } else {
          restoreAccount(); // our account may have just arrived (first sign-in)
        }
      } else if (coll == kCasreps) {
        casreps[docId] =
            Casrep.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } else if (coll == kPmsChecks) {
        pmsChecks[docId] =
            PmsCheck.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } else if (coll == kQualifications) {
        qualifications[docId] =
            Qualification.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } else if (coll == kQuals) {
        quals[docId] =
            PersonQual.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } else if (coll == kWatchbill) {
        watchbill[docId] =
            WatchAssignment.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } else if (coll == kFeedback) {
        final note =
            FeedbackNote.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (note.text.isEmpty) {
          feedback.remove(docId); // tombstone — a delete
        } else {
          final prev = feedback[docId];
          feedback[docId] = note;
          if (remote) {
            // Kratos: alert it when a new note lands.
            if (prev == null && !note.read && role == Role.kratos) {
              onNotify('New feedback', '${note.fromName}: ${note.text}', peer);
            }
            // Submitter: alert me when a (new) reply to my note arrives.
            final newReply =
                note.hasResponse && note.response != (prev?.response ?? '');
            if (newReply && role != Role.kratos && note.fromId == account?.id) {
              onNotify('Reply to your feedback', note.response, peer);
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Feedback newest first (for the Kratos inbox).
  List<FeedbackNote> feedbackNewestFirst() => feedback.values.toList()
    ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));

  int get unreadFeedback => feedback.values.where((f) => !f.read).length;

  // --- Watchbill / PQS queries ---------------------------------------------

  /// A person's stage on a qualification (notStarted if untracked).
  QualStage qualStage(String personId, String qualId) =>
      quals[PersonQual.makeId(personId, qualId)]?.stage ?? QualStage.notStarted;

  bool isQualified(String personId, String qualId) =>
      qualStage(personId, qualId) == QualStage.qualified;

  /// Account ids qualified for [qualId].
  List<String> qualifiedFor(String qualId) => quals.values
      .where((q) => q.qualId == qualId && q.isQualified)
      .map((q) => q.personId)
      .toList();

  /// The qualification ids a person is fully qualified for (drives the tree).
  Set<String> qualifiedIdsFor(String personId) => quals.values
      .where((q) => q.personId == personId && q.isQualified)
      .map((q) => q.qualId)
      .toSet();

  /// Who is posted to [qualId]/[period] on [dayMs] (null if unassigned).
  String? watchAssignee(int dayMs, String qualId, WatchPeriod period) =>
      watchbill[WatchAssignment.makeId(dayMs, qualId, period)]?.personId;

  void applyOrg(String coll, String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (coll == kDepts) {
        final d = Department.fromJson(m);
        org.departments[d.id] = d;
      } else if (coll == kDivs) {
        final v = Division.fromJson(m);
        org.divisions[v.id] = v;
      } else if (coll == kWcs) {
        final w = WorkCenter.fromJson(m);
        org.workcenters[w.id] = w;
      }
    } catch (_) {}
  }

  void ingestEvent(JobEvent ev) {
    final list = events.putIfAbsent(ev.jobId, () => []);
    if (list.any((e) => e.docId == ev.docId)) return; // dedup
    list.add(ev);
    list.sort((a, b) => a.tsMs.compareTo(b.tsMs));
  }

  void ingestPresence(String raw, {bool fromHeartbeat = false}) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final nid = m['nodeId'] as String;
      if (nid == myNodeId) return; // skip ourselves
      presence[nid] = Peer(
        nodeId: nid,
        name: (m['name'] ?? '') as String,
        role: roleFromToken((m['role'] ?? 'technician') as String),
        workcenter: (m['workcenter'] ?? '') as String,
      );
      lastSeenMs[nid] = fromHeartbeat
          ? (m['hb'] ?? 0) as int
          : DateTime.now().millisecondsSinceEpoch;
    } catch (_) {}
  }

  // --- Queries --------------------------------------------------------------

  /// Whether the signed-in role may see [j] under the org-scoped rules. Until
  /// the org chart has synced (empty) — or before sign-in — don't filter.
  bool canSee(Job j) {
    if (org.workcenters.isEmpty || role == null) return true;
    return canSeeJob(
      role: role!,
      viewerWorkcenterId: workcenter,
      jobWorkcenterId: j.workcenter,
      jobHasTa: j.taRequested,
      org: org,
    );
  }

  /// Whether the signed-in role may see PMS check [c] (same org scoping as
  /// jobs; the off-ship Port Engineer has no PMS checks).
  bool canSeeCheck(PmsCheck c) {
    if (org.workcenters.isEmpty || role == null) return true;
    return canSeeJob(
      role: role!,
      viewerWorkcenterId: workcenter,
      jobWorkcenterId: c.workcenter,
      jobHasTa: false,
      org: org,
    );
  }

  /// Whether [j] is waiting on the signed-in role's action (drives the Inbox).
  bool needsMyAction(Job j) {
    switch (j.phase) {
      case JobPhase.approval:
      case JobPhase.closeout:
        return j.approver == role;
      case JobPhase.ta:
        return role == Role.portEngineer;
      case JobPhase.execution:
        return role == Role.technician;
      case JobPhase.closed:
        return false;
    }
  }

  bool hasCasrep(String jobId) =>
      casreps.values.any((c) => c.jobId == jobId && c.type != CasrepType.cancel);

  Casrep? casrepForJob(String jobId) {
    try {
      return casreps.values
          .firstWhere((c) => c.jobId == jobId && c.type != CasrepType.cancel);
    } catch (_) {
      return null;
    }
  }

  /// Next sequential CASREP number for this mesh (zero-padded to 3 digits).
  String nextCasrepNumber() => (casreps.length + 1).toString().padLeft(3, '0');

  String stageText(Job j) {
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

  // --- Notification policy --------------------------------------------------

  /// The next approver gets a "your turn" ping; the originator hears that their
  /// job advanced, was returned, or was closed; the DIVO is prompted to write a
  /// CASREP for a fresh priority-1–3 job.
  void _notifyForChange(Job? old, Job job, String? peer) {
    final title = job.title.isEmpty ? 'a job' : job.title;
    if (role == Role.divo &&
        casrepEligible(job.priority) &&
        !job.isClosed &&
        !hasCasrep(job.id) &&
        (old == null || old.priority != job.priority)) {
      onNotify(
          title,
          'priority ${job.priority} — write a CASREP (${casrepCategoryLabel(job.priority)})',
          peer);
      return;
    }
    final mineNow = needsMyAction(job);
    final mineBefore = old != null && needsMyAction(old);
    if (mineNow && !mineBefore) {
      onNotify(title, 'awaiting your ${role!.tag} action', peer);
      return;
    }
    if (old != null && job.originator == name) {
      if (job.returned && !old.returned) {
        onNotify(title, 'returned for rework', peer);
      } else if (job.phase == JobPhase.closed && old.phase != JobPhase.closed) {
        onNotify(title, 'closed out', peer);
      } else if (job.phase != old.phase || job.approver != old.approver) {
        onNotify(title, 'approved → ${stageText(job)}', peer);
      }
    }
  }

  /// Clear all synced + identity state (for a device reset).
  void clear() {
    jobs.clear();
    events.clear();
    accounts.clear();
    casreps.clear();
    pmsChecks.clear();
    qualifications.clear();
    quals.clear();
    watchbill.clear();
    feedback.clear();
    org.departments.clear();
    org.divisions.clear();
    org.workcenters.clear();
    presence.clear();
    lastSeenMs.clear();
    account = null;
    myNodeId = null;
    pendingAccountId = null;
  }
}
