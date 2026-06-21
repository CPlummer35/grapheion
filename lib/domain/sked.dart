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
Periodicity periodicityFromToken(String s) => Periodicity.values
    .firstWhere((p) => p.name == s, orElse: () => Periodicity.monthly);

/// Derived calendar state of a check at a given moment.
enum PmsStatus { scheduled, due, overdue }

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
    required this.createdAtMs,
    required this.updatedAtMs,
  }) : doneDays = doneDays ?? [];

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
  }) =>
      PmsCheck(
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

  /// Calendar state at [nowMs]. Situational checks have no due date.
  PmsStatus statusAt(int nowMs) {
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
        periodicity:
            periodicityFromToken((j['periodicity'] ?? 'monthly') as String),
        estMinutes: (j['estMinutes'] ?? 0) as int,
        lastDoneMs: j['lastDoneMs'] as int?,
        lastBy: (j['lastBy'] ?? '') as String,
        doneDays: (j['doneDays'] as List?)?.map((e) => e as int).toList(),
        assignedTo: (j['assignedTo'] ?? '') as String,
        scheduledForMs: j['scheduledForMs'] as int?,
        createdAtMs: (j['createdAtMs'] ?? 0) as int,
        updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
      );
}
