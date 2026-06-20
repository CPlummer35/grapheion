// Grapheion — the job (corrective-maintenance work item) and its append-only
// event log. Both are synced as peat documents; the event log is the audit
// trail (who did what, when) and merges cleanly across the mesh.

import 'chain.dart';

/// Lifecycle status of a job as it moves through the chain.
/// - inChain:  awaiting the current approver's action (climbing)
/// - returned: sent back down for rework; the current owner must fix/re-approve
/// - accepted: the port engineer accepted it off-ship (end of this POC's chain)
enum JobStatus { inChain, returned, accepted }

String jobStatusToken(JobStatus s) => s.name;
JobStatus jobStatusFromToken(String t) =>
    JobStatus.values.firstWhere((s) => s.name == t, orElse: () => JobStatus.inChain);

/// A corrective-maintenance work item (the deferred 2-Kilo / CSMP record).
class Job {
  final String id;
  String title;
  String ein; // equipment identification number
  String symptom; // description of the discrepancy
  int priority; // 1 (highest) .. 4
  final String originator; // person who created it
  final String workcenter; // e.g. "MP01"
  Role approver; // the role whose action is currently pending
  JobStatus status;
  final int createdAtMs;
  int updatedAtMs;

  Job({
    required this.id,
    required this.title,
    required this.ein,
    required this.symptom,
    required this.priority,
    required this.originator,
    required this.workcenter,
    required this.approver,
    required this.status,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  /// A freshly-originated job: submitted to the first chain stage (WCS).
  factory Job.originate({
    required String id,
    required String title,
    required String ein,
    required String symptom,
    required int priority,
    required String originator,
    required String workcenter,
    required int nowMs,
  }) {
    return Job(
      id: id,
      title: title,
      ein: ein,
      symptom: symptom,
      priority: priority,
      originator: originator,
      workcenter: workcenter,
      approver: kApprovalChain.first,
      status: JobStatus.inChain,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
    );
  }

  /// Advance the job: the current approver signs off. Moving past the last rung
  /// (port engineer) marks it accepted off-ship.
  void approve(int nowMs) {
    final next = nextInChain(approver);
    if (next == null) {
      status = JobStatus.accepted; // port engineer accepted it
    } else {
      approver = next;
      status = JobStatus.inChain;
    }
    updatedAtMs = nowMs;
  }

  /// Send the job one rung back down for rework, with the reviewer's comment
  /// carried in the event log.
  void returnDown(int nowMs) {
    approver = prevOwner(approver);
    status = JobStatus.returned;
    updatedAtMs = nowMs;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'ein': ein,
        'symptom': symptom,
        'priority': priority,
        'originator': originator,
        'workcenter': workcenter,
        'approver': approver.token,
        'status': jobStatusToken(status),
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
      };

  factory Job.fromJson(Map<String, dynamic> j) => Job(
        id: j['id'] as String,
        title: (j['title'] ?? '') as String,
        ein: (j['ein'] ?? '') as String,
        symptom: (j['symptom'] ?? '') as String,
        priority: (j['priority'] ?? 3) as int,
        originator: (j['originator'] ?? '') as String,
        workcenter: (j['workcenter'] ?? '') as String,
        approver: roleFromToken((j['approver'] ?? 'wcs') as String),
        status: jobStatusFromToken((j['status'] ?? 'inChain') as String),
        createdAtMs: (j['createdAtMs'] ?? 0) as int,
        updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
      );
}

/// One entry in a job's append-only audit log.
class JobEvent {
  final String jobId;
  final int seq; // monotonically increasing per job
  final String actor; // person name
  final Role role; // role acting
  final String action; // 'originate' | 'approve' | 'return' | 'accept'
  final String comment;
  final int tsMs;

  JobEvent({
    required this.jobId,
    required this.seq,
    required this.actor,
    required this.role,
    required this.action,
    required this.comment,
    required this.tsMs,
  });

  /// Document id: jobId + zero-padded seq so the log sorts correctly and two
  /// nodes never collide on the same (jobId, seq).
  String get docId => '$jobId-${seq.toString().padLeft(4, '0')}';

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'seq': seq,
        'actor': actor,
        'role': role.token,
        'action': action,
        'comment': comment,
        'tsMs': tsMs,
      };

  factory JobEvent.fromJson(Map<String, dynamic> j) => JobEvent(
        jobId: j['jobId'] as String,
        seq: (j['seq'] ?? 0) as int,
        actor: (j['actor'] ?? '') as String,
        role: roleFromToken((j['role'] ?? 'technician') as String),
        action: (j['action'] ?? '') as String,
        comment: (j['comment'] ?? '') as String,
        tsMs: (j['tsMs'] ?? 0) as int,
      );
}
