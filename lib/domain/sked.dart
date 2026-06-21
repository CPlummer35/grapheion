// Grapheion — SKED: Planned Maintenance System (PMS) scheduling.
//
// A PMS check is a recurring maintenance requirement (an MRC) a work center
// performs on a piece of equipment at a fixed periodicity. Its schedule state
// (scheduled / due / overdue) is DERIVED from its periodicity + when it was
// last accomplished, so the schedule recomputes itself as time passes — there's
// no stored "status" to drift out of date. Synced over the mesh like jobs.

const _day = 86400000; // ms per day

/// How often a check recurs. Comments give the Navy PMS periodicity code.
enum Periodicity {
  daily, // D
  weekly, // W
  biweekly, // 2W
  monthly, // M
  quarterly, // Q
  semiannual, // S
  annual, // A
}

extension PeriodicityInfo on Periodicity {
  /// Short PMS code (D / W / 2W / M / Q / S / A).
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
    }
  }

  /// Interval length in days (approximate for month-based periods).
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
    }
  }
}

String periodicityToken(Periodicity p) => p.name;
Periodicity periodicityFromToken(String s) => Periodicity.values
    .firstWhere((p) => p.name == s, orElse: () => Periodicity.monthly);

/// Derived schedule state of a check at a given moment.
enum PmsStatus { scheduled, due, overdue }

/// A PMS maintenance requirement (MRC) and its scheduling state.
class PmsCheck {
  final String id;
  String mrc; // MRC/MIP number, e.g. "5921/001-23"
  String title; // what the check covers
  String ein; // equipment identification number
  String workcenter; // responsible work center
  Periodicity periodicity;
  int estMinutes; // estimated man-minutes to perform
  int? lastDoneMs; // last accomplishment (null = never done)
  String lastBy; // who last accomplished it ('' if never)
  int? scheduledForMs; // WCS-assigned day on the weekly schedule (null = none)
  final int createdAtMs;
  int updatedAtMs;

  PmsCheck({
    required this.id,
    required this.mrc,
    required this.title,
    required this.ein,
    required this.workcenter,
    required this.periodicity,
    required this.estMinutes,
    required this.lastDoneMs,
    required this.lastBy,
    this.scheduledForMs,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  factory PmsCheck.create({
    required String id,
    required String mrc,
    required String title,
    required String ein,
    required String workcenter,
    required Periodicity periodicity,
    required int estMinutes,
    required int nowMs,
  }) =>
      PmsCheck(
        id: id,
        mrc: mrc,
        title: title,
        ein: ein,
        workcenter: workcenter,
        periodicity: periodicity,
        estMinutes: estMinutes,
        lastDoneMs: null,
        lastBy: '',
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
      );

  /// When the next accomplishment is due — one interval after it was last done
  /// (or after it was created, if never done).
  int get nextDueMs => (lastDoneMs ?? createdAtMs) + periodicity.days * _day;

  bool get neverDone => lastDoneMs == null;

  /// Record an accomplishment, resetting the cycle.
  void accomplish(String by, int nowMs) {
    lastDoneMs = nowMs;
    lastBy = by;
    updatedAtMs = nowMs;
  }

  /// Schedule state at [nowMs]: overdue once past due, "due" within the
  /// heads-up window (the last fifth of the period) before due, else scheduled.
  PmsStatus statusAt(int nowMs) {
    final next = nextDueMs;
    if (nowMs > next) return PmsStatus.overdue;
    final window = (periodicity.days * _day) ~/ 5;
    if (nowMs >= next - window) return PmsStatus.due;
    return PmsStatus.scheduled;
  }

  /// Days until due (negative if overdue).
  int daysUntilDue(int nowMs) => ((nextDueMs - nowMs) / _day).floor();

  Map<String, dynamic> toJson() => {
        'id': id,
        'mrc': mrc,
        'title': title,
        'ein': ein,
        'workcenter': workcenter,
        'periodicity': periodicityToken(periodicity),
        'estMinutes': estMinutes,
        'lastDoneMs': lastDoneMs,
        'lastBy': lastBy,
        'scheduledForMs': scheduledForMs,
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
      };

  factory PmsCheck.fromJson(Map<String, dynamic> j) => PmsCheck(
        id: j['id'] as String,
        mrc: (j['mrc'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        ein: (j['ein'] ?? '') as String,
        workcenter: (j['workcenter'] ?? '') as String,
        periodicity: periodicityFromToken((j['periodicity'] ?? 'monthly') as String),
        estMinutes: (j['estMinutes'] ?? 0) as int,
        lastDoneMs: j['lastDoneMs'] as int?,
        lastBy: (j['lastBy'] ?? '') as String,
        scheduledForMs: j['scheduledForMs'] as int?,
        createdAtMs: (j['createdAtMs'] ?? 0) as int,
        updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
      );
}
