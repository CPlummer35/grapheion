// Grapheion — the job (corrective-maintenance work item) and its append-only
// event log. Both sync as peat documents; the event log is the audit trail.

import 'chain.dart';

/// The phase a job is in; the UI and "whose turn is it" derive from this.
/// - approval:  climbing the WCS -> LPO -> DIVO approval ladder
/// - ta:        DIVO raised a Technical Assistance request; the off-ship Port
///              Engineer is connected and must engage
/// - execution: approved on-ship; the work center performs the work
/// - closeout:  work reported done; climbing the WCS -> LPO -> DIVO close-out
///              ladder
/// - closed:    verified and closed (terminal; lives in the Completed tab)
enum JobPhase { approval, ta, execution, closeout, closed }

String jobPhaseToken(JobPhase p) => p.name;
JobPhase jobPhaseFromToken(String t) => JobPhase.values.firstWhere(
  (p) => p.name == t,
  orElse: () => JobPhase.approval,
);

/// A corrective-maintenance work item (the deferred 2-Kilo / CSMP record).
class Job {
  final String id;
  String title;
  String ein; // equipment identification number
  String symptom;
  int priority; // 1 (highest) .. 4
  final String originator;
  final String workcenter;
  JobPhase phase;
  Role approver; // whose action is pending in the active ladder
  bool returned; // last approval/close-out step was a kick-back
  bool inWork; // execution phase: work has started
  bool taRequested; // a TA was raised at some point (history flag)
  int? scheduledForMs; // WCS-assigned day on the weekly schedule (null = none)
  String assignedTo; // person the WCS assigned on the schedule ('' = none)
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
    required this.phase,
    required this.approver,
    required this.returned,
    required this.inWork,
    required this.taRequested,
    this.scheduledForMs,
    this.assignedTo = '',
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  factory Job.originate({
    required String id,
    required String title,
    required String ein,
    required String symptom,
    required int priority,
    required String originator,
    Role originatorRole = Role.technician,
    required String workcenter,
    required int nowMs,
  }) {
    // Start the ladder at the rung ABOVE the submitter (an LPO's job goes
    // straight to the DIVO). If the submitter is already at/above the top, the
    // job needs no approval and goes straight to execution.
    final first = firstApproverAfter(originatorRole);
    return Job(
      id: id,
      title: title,
      ein: ein,
      symptom: symptom,
      priority: priority,
      originator: originator,
      workcenter: workcenter,
      phase: first == null ? JobPhase.execution : JobPhase.approval,
      approver: first ?? Role.technician, // execution → the tech works it
      returned: false,
      inWork: false,
      taRequested: false,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
    );
  }

  bool get isClosed => phase == JobPhase.closed;

  // --- Approval / close-out ladder (WCS -> LPO -> DIVO) ----------------------

  /// Sign off in the active ladder. Advances the approver; completing the
  /// approval ladder moves to execution, completing the close-out ladder closes
  /// the job.
  void approve(int nowMs) {
    returned = false;
    final next = nextInChain(approver);
    if (phase == JobPhase.approval) {
      if (next == null) {
        phase = JobPhase.execution; // DIVO approved -> work it on-ship
        approver = Role.technician;
      } else {
        approver = next;
      }
    } else if (phase == JobPhase.closeout) {
      if (next == null) {
        phase = JobPhase.closed; // DIVO approved the close-out
      } else {
        approver = next;
      }
    }
    updatedAtMs = nowMs;
  }

  /// Kick the job one rung back down the active ladder for rework.
  void returnDown(int nowMs) {
    approver = prevOwner(approver);
    returned = true;
    updatedAtMs = nowMs;
  }

  // --- TA (off-ship assistance; DIVO only) ----------------------------------

  /// DIVO requests off-ship assistance — connects the Port Engineer.
  void requestTa(int nowMs) {
    phase = JobPhase.ta;
    approver = Role.portEngineer;
    taRequested = true;
    returned = false;
    updatedAtMs = nowMs;
  }

  /// Port Engineer engages the request; the job proceeds on-ship with off-ship
  /// support arranged.
  void engageTa(int nowMs) {
    phase = JobPhase.execution;
    approver = Role.technician;
    updatedAtMs = nowMs;
  }

  /// Port Engineer declines; the job continues on-ship without off-ship help.
  void declineTa(int nowMs) {
    phase = JobPhase.execution;
    approver = Role.technician;
    returned = true;
    updatedAtMs = nowMs;
  }

  // --- Execution ------------------------------------------------------------

  void startWork(int nowMs) {
    inWork = true;
    approver = Role.technician;
    updatedAtMs = nowMs;
  }

  /// Work reported done; opens the close-out ladder at WCS.
  void markComplete(int nowMs) {
    phase = JobPhase.closeout;
    approver = kApprovalChain.first; // WCS
    returned = false;
    updatedAtMs = nowMs;
  }

  /// Close-out rejected (by WCS/LPO/DIVO); back to the work center for rework.
  void rejectCloseout(int nowMs) {
    phase = JobPhase.execution;
    approver = Role.technician;
    inWork = true;
    returned = true;
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
    'phase': jobPhaseToken(phase),
    'approver': approver.token,
    'returned': returned,
    'inWork': inWork,
    'taRequested': taRequested,
    'scheduledForMs': scheduledForMs,
    'assignedTo': assignedTo,
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
    phase: jobPhaseFromToken((j['phase'] ?? 'approval') as String),
    approver: roleFromToken((j['approver'] ?? 'wcs') as String),
    returned: (j['returned'] ?? false) as bool,
    inWork: (j['inWork'] ?? false) as bool,
    taRequested: (j['taRequested'] ?? false) as bool,
    scheduledForMs: j['scheduledForMs'] as int?,
    assignedTo: (j['assignedTo'] ?? '') as String,
    createdAtMs: (j['createdAtMs'] ?? 0) as int,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}

/// One entry in a job's append-only audit log.
class JobEvent {
  final String jobId;
  final int seq;
  final String actor;
  final Role role;
  final String action;
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
