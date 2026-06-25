// Grapheion — SKED: Planned Maintenance System (PMS) scheduling.
//
// PMS hierarchy: a MIP (Maintenance Index Page, e.g. "5921/023-14") covers one
// system/equipment and lists its MRCs (Maintenance Requirement Cards). Each MRC
// is one task at one periodicity, identified within the MIP by its periodicity
// code + sequence — e.g. "M-1", "D-2", "R-1". Calendar schedule state derives
// from periodicity + last-done, so it recomputes itself. Synced over the mesh.

import 'schedule.dart' show startOfDay;

const _day = 86400000; // ms per day

/// PMS periodicity (Navy Table 7-1 subset). `situational` (R) is non-calendar —
/// performed as required, with no fixed due date.
enum Periodicity {
  daily, // D
  weekly, // W
  biweekly, // 2W
  monthly, // M
  quarterly, // Q
  semiannual, // S
  annual, // A
  situational, // R — as required (no calendar due)
}

extension PeriodicityInfo on Periodicity {
  /// Short PMS code (D / W / 2W / M / Q / S / A / R).
  String get code {
    switch (this) {
      case Periodicity.daily:
        return 'D';
      case Periodicity.weekly:
        return 'W';
      case Periodicity.biweekly:
        return '2W';
      case Periodicity.monthly:
        return 'M';
      case Periodicity.quarterly:
        return 'Q';
      case Periodicity.semiannual:
        return 'S';
      case Periodicity.annual:
        return 'A';
      case Periodicity.situational:
        return 'R';
    }
  }

  String get label {
    switch (this) {
      case Periodicity.daily:
        return 'Daily';
      case Periodicity.weekly:
        return 'Weekly';
      case Periodicity.biweekly:
        return 'Bi-weekly';
      case Periodicity.monthly:
        return 'Monthly';
      case Periodicity.quarterly:
        return 'Quarterly';
      case Periodicity.semiannual:
        return 'Semi-annual';
      case Periodicity.annual:
        return 'Annual';
      case Periodicity.situational:
        return 'Situational (as req\'d)';
    }
  }

  /// Interval length in days. Situational has no calendar interval (0).
  int get days {
    switch (this) {
      case Periodicity.daily:
        return 1;
      case Periodicity.weekly:
        return 7;
      case Periodicity.biweekly:
        return 14;
      case Periodicity.monthly:
        return 30;
      case Periodicity.quarterly:
        return 91;
      case Periodicity.semiannual:
        return 182;
      case Periodicity.annual:
        return 365;
      case Periodicity.situational:
        return 0;
    }
  }

  /// Whether it recurs on the calendar (false for situational/as-required).
  bool get isCalendar => this != Periodicity.situational;
}

String periodicityToken(Periodicity p) => p.name;
Periodicity periodicityFromToken(String s) => Periodicity.values.firstWhere(
  (p) => p.name == s,
  orElse: () => Periodicity.monthly,
);

/// Derived calendar state of a check at a given moment.
enum PmsStatus { scheduled, due, overdue, deferred }

/// One MRC (Maintenance Requirement Card) + its scheduling state.
class PmsCheck {
  final String id;
  String mip; // Maintenance Index Page number, e.g. "5921/023-14"
  int seq; // MRC sequence within the MIP for this periodicity (the n in "M-1")
  String title;
  String ein; // equipment identification number
  String workcenter; // responsible work center
  Periodicity periodicity;
  int estMinutes; // estimated man-minutes
  int? lastDoneMs; // last accomplishment (null = never)
  String lastBy; // who last accomplished it
  List<int> doneDays; // day-start ms of every day it was accomplished
  String assignedTo; // person the WCS assigned ('' = unassigned)
  int? scheduledForMs; // WCS-assigned day (null = unplaced); daily = every day
  List<MrcStep> steps; // the MRC procedure (empty = a simple sign-off check)
  int? deferredUntilMs; // deferred until this day (null = not deferred)
  String deferReason; // why it was deferred (parts/ops/access/…)
  final int createdAtMs;
  int updatedAtMs;

  PmsCheck({
    required this.id,
    required this.mip,
    required this.seq,
    required this.title,
    required this.ein,
    required this.workcenter,
    required this.periodicity,
    required this.estMinutes,
    required this.lastDoneMs,
    required this.lastBy,
    List<int>? doneDays,
    this.assignedTo = '',
    this.scheduledForMs,
    List<MrcStep>? steps,
    this.deferredUntilMs,
    this.deferReason = '',
    required this.createdAtMs,
    required this.updatedAtMs,
  }) : doneDays = doneDays ?? [],
       steps = steps ?? [];

  factory PmsCheck.create({
    required String id,
    required String mip,
    required int seq,
    required String title,
    required String ein,
    required String workcenter,
    required Periodicity periodicity,
    required int estMinutes,
    required int nowMs,
    List<MrcStep>? steps,
  }) => PmsCheck(
    id: id,
    mip: mip,
    seq: seq,
    title: title,
    ein: ein,
    workcenter: workcenter,
    periodicity: periodicity,
    estMinutes: estMinutes,
    lastDoneMs: null,
    lastBy: '',
    steps: steps,
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
  );

  /// The MRC code within its MIP: periodicity code + sequence, e.g. "M-1".
  String get mrcCode => '${periodicity.code}-$seq';

  /// When the next accomplishment is due (calendar checks only).
  int get nextDueMs => (lastDoneMs ?? createdAtMs) + periodicity.days * _day;

  bool get neverDone => lastDoneMs == null;

  /// Record an accomplishment. [forDayMs] is the day it was performed (defaults
  /// to now) — tracked per-day so daily checks reflect each day independently.
  void accomplish(String by, int nowMs, {int? forDayMs}) {
    final key = startOfDay(forDayMs ?? nowMs);
    if (!doneDays.contains(key)) doneDays.add(key);
    lastDoneMs = nowMs;
    lastBy = by;
    updatedAtMs = nowMs;
  }

  /// Whether it was accomplished on [dayMs]'s calendar day.
  bool doneOn(int dayMs) => doneDays.contains(startOfDay(dayMs));

  /// Whether the check is currently deferred at [nowMs].
  bool deferredAt(int nowMs) =>
      deferredUntilMs != null && nowMs < deferredUntilMs!;

  /// Defer the check until [untilMs] with a [reason]; clears with [clearDeferral].
  void defer(String reason, int untilMs, int nowMs) {
    deferReason = reason;
    deferredUntilMs = untilMs;
    updatedAtMs = nowMs;
  }

  void clearDeferral(int nowMs) {
    deferReason = '';
    deferredUntilMs = null;
    updatedAtMs = nowMs;
  }

  /// Calendar state at [nowMs]. A deferral masks the due/overdue state until it
  /// lapses; situational checks have no due date.
  PmsStatus statusAt(int nowMs) {
    if (deferredAt(nowMs)) return PmsStatus.deferred;
    if (!periodicity.isCalendar) return PmsStatus.scheduled;
    final next = nextDueMs;
    if (nowMs > next) return PmsStatus.overdue;
    final window = (periodicity.days * _day) ~/ 5;
    if (nowMs >= next - window) return PmsStatus.due;
    return PmsStatus.scheduled;
  }

  /// Days until due (negative if overdue). Meaningless for situational checks.
  int daysUntilDue(int nowMs) => ((nextDueMs - nowMs) / _day).floor();

  Map<String, dynamic> toJson() => {
    'id': id,
    'mip': mip,
    'seq': seq,
    'title': title,
    'ein': ein,
    'workcenter': workcenter,
    'periodicity': periodicityToken(periodicity),
    'estMinutes': estMinutes,
    'lastDoneMs': lastDoneMs,
    'lastBy': lastBy,
    'doneDays': doneDays,
    'assignedTo': assignedTo,
    'scheduledForMs': scheduledForMs,
    'steps': steps.map((s) => s.toJson()).toList(),
    'deferredUntilMs': deferredUntilMs,
    'deferReason': deferReason,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory PmsCheck.fromJson(Map<String, dynamic> j) => PmsCheck(
    id: j['id'] as String,
    // Back-compat: older docs used a free-text 'mrc' field for the number.
    mip: (j['mip'] ?? j['mrc'] ?? '') as String,
    seq: (j['seq'] ?? 1) as int,
    title: (j['title'] ?? '') as String,
    ein: (j['ein'] ?? '') as String,
    workcenter: (j['workcenter'] ?? '') as String,
    periodicity: periodicityFromToken(
      (j['periodicity'] ?? 'monthly') as String,
    ),
    estMinutes: (j['estMinutes'] ?? 0) as int,
    lastDoneMs: j['lastDoneMs'] as int?,
    lastBy: (j['lastBy'] ?? '') as String,
    doneDays: (j['doneDays'] as List?)?.map((e) => e as int).toList(),
    assignedTo: (j['assignedTo'] ?? '') as String,
    scheduledForMs: j['scheduledForMs'] as int?,
    steps: (j['steps'] as List?)
        ?.map((e) => MrcStep.fromJson(e as Map<String, dynamic>))
        .toList(),
    deferredUntilMs: j['deferredUntilMs'] as int?,
    deferReason: (j['deferReason'] ?? '') as String,
    createdAtMs: (j['createdAtMs'] ?? 0) as int,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}

/// One step of an MRC procedure — what the maintainer does + the standard it
/// must meet. Per-accomplishment outcomes are captured in [StepResult].
class MrcStep {
  final String id; // stable within the check
  String text; // the procedure step
  String standard; // standard / tolerance to meet ('' = none)

  MrcStep({required this.id, this.text = '', this.standard = ''});

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'standard': standard};

  factory MrcStep.fromJson(Map<String, dynamic> j) => MrcStep(
    id: j['id'] as String,
    text: (j['text'] ?? '') as String,
    standard: (j['standard'] ?? '') as String,
  );
}

/// The outcome of one [MrcStep] during an accomplishment.
class StepResult {
  final String stepId;
  bool sat; // SAT (meets standard) / UNSAT (a discrepancy)
  String reading; // optional captured reading / note for this step

  StepResult({required this.stepId, this.sat = true, this.reading = ''});

  Map<String, dynamic> toJson() => {
    'stepId': stepId,
    'sat': sat,
    'reading': reading,
  };

  factory StepResult.fromJson(Map<String, dynamic> j) => StepResult(
    stepId: j['stepId'] as String,
    sat: (j['sat'] ?? true) as bool,
    reading: (j['reading'] ?? '') as String,
  );
}

/// A signed accomplishment of an MRC on a given day: who performed it, the
/// per-step results, and any discrepancy job spawned. One per (check, day).
class PmsAccomplishment {
  final String id; // makeId(checkId, dayMs)
  final String checkId;
  final int dayMs; // start-of-day it was performed
  String by; // performer (the signature)
  int atMs;
  List<StepResult> results;
  String note; // overall remarks
  String jobId; // CSMP job spawned from a discrepancy ('' = none)
  String verifiedBy; // WCS/supervisor who spot-checked + verified ('' = pending)
  int verifiedAtMs;
  String reworkNote; // kick-back reason ('' = not returned); non-empty = redo
  int updatedAtMs;

  PmsAccomplishment({
    required this.id,
    required this.checkId,
    required this.dayMs,
    required this.by,
    required this.atMs,
    List<StepResult>? results,
    this.note = '',
    this.jobId = '',
    this.verifiedBy = '',
    this.verifiedAtMs = 0,
    this.reworkNote = '',
    required this.updatedAtMs,
  }) : results = results ?? [];

  static String makeId(String checkId, int dayMs) =>
      '$checkId|${startOfDay(dayMs)}';

  /// Any UNSAT step → the accomplishment found a discrepancy.
  bool get hasDiscrepancy => results.any((r) => !r.sat);

  /// Awaiting a supervisor spot-check (signed, not yet verified or kicked back).
  bool get awaitingVerification => verifiedBy.isEmpty && reworkNote.isEmpty;

  bool get verified => verifiedBy.isNotEmpty;
  bool get kickedBack => reworkNote.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'checkId': checkId,
    'dayMs': dayMs,
    'by': by,
    'atMs': atMs,
    'results': results.map((r) => r.toJson()).toList(),
    'note': note,
    'jobId': jobId,
    'verifiedBy': verifiedBy,
    'verifiedAtMs': verifiedAtMs,
    'reworkNote': reworkNote,
    'updatedAtMs': updatedAtMs,
  };

  factory PmsAccomplishment.fromJson(Map<String, dynamic> j) =>
      PmsAccomplishment(
        id: j['id'] as String,
        checkId: (j['checkId'] ?? '') as String,
        dayMs: (j['dayMs'] ?? 0) as int,
        by: (j['by'] ?? '') as String,
        atMs: (j['atMs'] ?? 0) as int,
        results: (j['results'] as List?)
            ?.map((e) => StepResult.fromJson(e as Map<String, dynamic>))
            .toList(),
        note: (j['note'] ?? '') as String,
        jobId: (j['jobId'] ?? '') as String,
        verifiedBy: (j['verifiedBy'] ?? '') as String,
        verifiedAtMs: (j['verifiedAtMs'] ?? 0) as int,
        reworkNote: (j['reworkNote'] ?? '') as String,
        updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
      );
}
