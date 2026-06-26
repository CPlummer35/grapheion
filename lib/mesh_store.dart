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

import 'domain/bulletin.dart';
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
const kPmsDone = 'pmsdone'; // signed MRC accomplishments (one per check + day)
const kQualifications = 'qualifications'; // qual tree nodes (watch/knowledge/…)
const kQuals = 'quals'; // PQS progress (person x qualification)
const kEvolutions = 'evolutions'; // evolutions (role sets, e.g. In-Port Duty)
const kBill = 'watchbill'; // bill entries (day x evolution x role x shift)
const kBulletin = 'bulletin'; // duty-section bulletin posts
const kStood = 'stood'; // append-only watch-stood log
const kEvents = 'events'; // duty-day events logged when a watchbill is recorded
const kRouting = 'routing'; // watchbill approval chain — one per duty section
const kFeedback =
    'feedback'; // demo feedback (anyone writes, only Kratos reads)

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
  final Map<String, PmsAccomplishment> pmsDone = {};
  final Map<String, Qualification> qualifications = {};
  final Map<String, PersonQual> quals = {}; // keyed by PersonQual.makeId
  final Map<String, Evolution> evolutions = {};
  final Map<String, BillEntry> bill = {}; // keyed by BillEntry.makeId
  final Map<String, BulletinPost> bulletin = {};
  final Map<String, WatchStood> stood = {};
  final Map<String, DutyDayEvent> dutyEvents = {};
  final Map<String, WatchbillRouting> routing = {};
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
  void applyDoc(
    String coll,
    String docId,
    String raw, {
    required bool remote,
    String? peer,
  }) {
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
        final old = accounts[acct.id];
        // Last-write-wins by updatedAtMs: ignore a stale re-broadcast (a device
        // still holding a pre-edit copy), so an account field can't ping-pong —
        // e.g. a duty-section assignment flickering back to "unassigned".
        if (old == null || acct.updatedAtMs >= old.updatedAtMs) {
          accounts[acct.id] = acct;
          if (account?.id == acct.id) {
            // Our own account was edited remotely (admin reassigned role / work
            // center / duty section) — adopt the newer copy live.
            account = acct;
          }
        }
        if (account == null) {
          restoreAccount(); // our account may have just arrived (first sign-in)
        }
      } else if (coll == kCasreps) {
        casreps[docId] = Casrep.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } else if (coll == kPmsChecks) {
        final c = PmsCheck.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        final old = pmsChecks[docId];
        if (old == null || c.updatedAtMs >= old.updatedAtMs) {
          pmsChecks[docId] = c; // LWW — a stale rebroadcast can't revert it
        }
      } else if (coll == kPmsDone) {
        final a = PmsAccomplishment.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        final old = pmsDone[docId];
        if (old == null || a.updatedAtMs >= old.updatedAtMs) {
          pmsDone[docId] = a; // LWW
          if (remote) _notifyForPms(old, a, peer);
        }
      } else if (coll == kQualifications) {
        qualifications[docId] = Qualification.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } else if (coll == kQuals) {
        quals[docId] = PersonQual.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } else if (coll == kEvolutions) {
        evolutions[docId] = Evolution.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } else if (coll == kBill) {
        final e = BillEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        final old = bill[docId];
        // Last-write-wins: a stale (older) update must not overwrite a newer
        // one, or the BLE gossip oscillates — two devices that disagree on a
        // slot keep clobbering each other every cycle (assigned↔unassigned).
        if (old == null || e.updatedAtMs >= old.updatedAtMs) {
          bill[docId] = e;
        }
      } else if (coll == kBulletin) {
        final p = BulletinPost.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (p.text.isEmpty) {
          bulletin.remove(docId); // tombstone (a deleted post)
        } else {
          bulletin[docId] = p;
        }
      } else if (coll == kStood) {
        final w = WatchStood.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        final old = stood[docId];
        if (old == null || w.atMs >= old.atMs) stood[docId] = w; // LWW
      } else if (coll == kEvents) {
        final ev = DutyDayEvent.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (ev.type.isEmpty) {
          dutyEvents.remove(docId); // tombstone (a cleared event)
        } else {
          final old = dutyEvents[docId];
          if (old == null || ev.atMs >= old.atMs) dutyEvents[docId] = ev; // LWW
        }
      } else if (coll == kRouting) {
        final r = WatchbillRouting.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        final old = routing[docId];
        if (old == null || r.updatedAtMs >= old.updatedAtMs) {
          routing[docId] = r; // LWW — a stale rebroadcast can't revert status
          if (remote) _notifyForRouting(old, r, peer);
        }
      } else if (coll == kFeedback) {
        final note = FeedbackNote.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (note.messages.isEmpty) {
          feedback.remove(docId); // tombstone — a delete
        } else {
          final prev = feedback[docId];
          feedback[docId] = note;
          // A new message in the thread → notify the other side.
          if (remote && note.messages.length > (prev?.messages.length ?? 0)) {
            final last = note.lastMessage!;
            if (last.fromOwner) {
              // owner replied — notify the submitter (their note)
              if (role != Role.kratos && note.fromId == account?.id) {
                onNotify('Reply to your feedback', last.text, peer);
              }
            } else if (role == Role.kratos) {
              // submitter wrote — notify Kratos
              onNotify(
                'New feedback',
                '${note.fromRate.isEmpty ? note.fromRole.tag : note.fromRate}: ${last.text}',
                peer,
              );
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Feedback threads, most-recently-active first (for the Kratos inbox).
  List<FeedbackNote> feedbackNewestFirst() =>
      feedback.values.toList()
        ..sort((a, b) => b.lastActivityMs.compareTo(a.lastActivityMs));

  /// Threads with an unread message for Kratos (drives the rail badge).
  int get unreadFeedback => feedback.values.where((f) => !f.readByOwner).length;

  /// A duty section's bulletin posts, oldest first.
  List<BulletinPost> bulletinForSection(String section) =>
      bulletin.values.where((p) => p.section == section).toList()
        ..sort((a, b) => a.atMs.compareTo(b.atMs));

  /// The approval-chain status for a section's current watchbill — a fresh
  /// Draft routing if none has been created yet.
  WatchbillRouting routingFor(String section) =>
      routing[WatchbillRouting.makeId(section)] ??
      WatchbillRouting(id: WatchbillRouting.makeId(section), section: section);

  /// Duty-day events logged for one recorded day + section, type-sorted.
  /// [dayMs] is a normalized start-of-day (as stored on records).
  List<DutyDayEvent> eventsForDay(int dayMs, String section) =>
      dutyEvents.values
          .where((e) => e.dayMs == dayMs && e.section == section)
          .toList()
        ..sort((a, b) => a.type.compareTo(b.type));

  /// Distinct calendar days a section has a recorded watchbill for (from the
  /// stood-log), newest first — backs the duty-section HISTORY tab.
  List<int> recordedDutyDays(String section) {
    final days = <int>{
      for (final w in stood.values)
        if (w.section == section) w.dayMs,
    };
    return days.toList()..sort((a, b) => b.compareTo(a));
  }

  /// The stood watches for one recorded day + section, by time then station.
  /// [dayMs] is a normalized start-of-day (as stored on records).
  List<WatchStood> stoodForDay(int dayMs, String section) =>
      stood.values
          .where((w) => w.dayMs == dayMs && w.section == section)
          .toList()
        ..sort((a, b) {
          final t = a.timeLabel.compareTo(b.timeLabel);
          return t != 0 ? t : a.stationName.compareTo(b.stationName);
        });

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
  /// Who is posted to [roleId]/[shiftId] on [dayMs]'s instance of [evolutionId]
  /// (null/'' if unassigned).
  String? billAssignee(
    int dayMs,
    String evolutionId,
    String roleId,
    String shiftId,
  ) => bill[BillEntry.makeId(dayMs, evolutionId, roleId, shiftId)]?.personId;

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

  /// The signed accomplishment of [checkId] on [dayMs]'s day, if any.
  PmsAccomplishment? accomplishmentFor(String checkId, int dayMs) =>
      pmsDone[PmsAccomplishment.makeId(checkId, dayMs)];

  /// The most recent accomplishment of [checkId] across all days.
  PmsAccomplishment? latestAccomplishment(String checkId) {
    PmsAccomplishment? best;
    for (final a in pmsDone.values) {
      if (a.checkId != checkId) continue;
      if (best == null || a.atMs > best.atMs) best = a;
    }
    return best;
  }

  /// Signed accomplishments awaiting a supervisor spot-check, newest first;
  /// scoped to checks the viewer can see (and optionally one [workcenter]).
  List<PmsAccomplishment> pendingVerifications({String? workcenter}) {
    final out = <PmsAccomplishment>[];
    for (final a in pmsDone.values) {
      if (!a.awaitingVerification) continue;
      final c = pmsChecks[a.checkId];
      if (c == null || !canSeeCheck(c)) continue;
      if (workcenter != null && c.workcenter != workcenter) continue;
      out.add(a);
    }
    out.sort((x, y) => y.atMs.compareTo(x.atMs));
    return out;
  }

  /// Spot-check pings (each device decides if it's the target): the performer
  /// hears when their work is verified or kicked back; a supervisor in the
  /// check's work center hears when a fresh accomplishment needs spot-checking.
  void _notifyForPms(PmsAccomplishment? old, PmsAccomplishment a, String? peer) {
    if (account == null) return;
    final c = pmsChecks[a.checkId];
    final label = c == null
        ? 'an MRC'
        : (c.title.isEmpty ? '${c.mip} ${c.mrcCode}' : c.title);
    if (a.by == name && a.by.isNotEmpty) {
      if (a.verified && (old == null || !old.verified)) {
        onNotify('PMS verified', '$label — spot-checked by ${a.verifiedBy}', peer);
        return;
      }
      if (a.kickedBack && (old == null || old.reworkNote != a.reworkNote)) {
        onNotify('PMS kicked back', '$label: ${a.reworkNote}', peer);
        return;
      }
    }
    if (old == null &&
        a.awaitingVerification &&
        a.by != name &&
        c != null &&
        workcenter == c.workcenter &&
        role != null &&
        role != Role.technician &&
        role != Role.portEngineer) {
      onNotify('PMS awaiting spot-check', '$label — signed by ${a.by}', peer);
    }
  }

  /// PMS compliance at [nowMs]: of the calendar checks in scope, how many are
  /// NOT overdue — the standard "in good standing ÷ total" PM-health number.
  /// Situational (R) checks have no due date and are excluded. Optionally
  /// scoped to a [workcenter]. Returns (ok, total); pct = ok/total (100% if 0).
  (int ok, int total) pmsCompliance(int nowMs, {String? workcenter}) {
    var ok = 0, total = 0;
    for (final c in pmsChecks.values) {
      if (!c.periodicity.isCalendar) continue;
      if (workcenter != null && c.workcenter != workcenter) continue;
      if (!canSeeCheck(c)) continue;
      total++;
      if (c.statusAt(nowMs) != PmsStatus.overdue) ok++;
    }
    return (ok, total);
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

  bool hasCasrep(String jobId) => casreps.values.any(
    (c) => c.jobId == jobId && c.type != CasrepType.cancel,
  );

  Casrep? casrepForJob(String jobId) {
    try {
      return casreps.values.firstWhere(
        (c) => c.jobId == jobId && c.type != CasrepType.cancel,
      );
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
        peer,
      );
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

  /// Watchbill routing pings (each device decides if it's the target): the CDO
  /// hears when a bill is submitted (plan or finalize); the whole section hears
  /// when the plan is approved or the day is recorded; the Section Leader who
  /// submitted hears when it's returned.
  void _notifyForRouting(WatchbillRouting? old, WatchbillRouting r, String? peer) {
    final me = account;
    if (me == null) return;
    // Only on a real transition (status or a fresh return).
    if (old != null &&
        old.status == r.status &&
        old.returnedBy == r.returnedBy) {
      return;
    }
    final section = r.section;
    final inSection = me.dutySection == section;
    final amCdo = inSection && me.dutyPosition == DutyPosition.cdo;
    final amSl = inSection && me.dutyPosition == DutyPosition.sectionLeader;
    final amSubmitter = r.submittedBy.isNotEmpty && me.id == r.submittedBy;
    final justReturned =
        r.returnedBy.isNotEmpty && (old == null || old.returnedBy != r.returnedBy);

    if (justReturned) {
      if (amSubmitter || amSl) {
        onNotify(
          'Watchbill returned — Section $section',
          r.returnedNote.isEmpty ? 'Returned by the CDO' : r.returnedNote,
          peer,
        );
      }
      return;
    }
    switch (r.status) {
      case BillStatus.submitted:
        if (amCdo) {
          onNotify(
            'Watchbill submitted — Section $section',
            'Awaiting your CDO approval',
            peer,
          );
        }
      case BillStatus.finalizing:
        if (amCdo) {
          onNotify(
            'Duty day finalize — Section $section',
            'Awaiting your CDO approval',
            peer,
          );
        }
      case BillStatus.approved:
        if (inSection) {
          onNotify(
            'Watchbill approved — Section $section',
            'Plan approved by the CDO',
            peer,
          );
        }
      case BillStatus.finalized:
        if (inSection) {
          onNotify(
            'Duty day recorded — Section $section',
            'Finalized by the CDO — watch counts updated',
            peer,
          );
        }
      case BillStatus.draft:
        break; // a fresh draft / new cycle is not an approval event
    }
  }

  /// Clear all synced + identity state (for a device reset).
  void clear() {
    jobs.clear();
    events.clear();
    accounts.clear();
    casreps.clear();
    pmsChecks.clear();
    pmsDone.clear();
    qualifications.clear();
    quals.clear();
    evolutions.clear();
    bill.clear();
    bulletin.clear();
    stood.clear();
    dutyEvents.clear();
    routing.clear();
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
