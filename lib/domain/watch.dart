// Grapheion — Qualifications (PQS), the qualification tree, and Watchbills.
//
// ONE Qualification model spans everything a person can be qualified for: watch
// stations (which feed the watchbill), knowledge quals (3M, DC…), letter quals
// (CDO, EOOW, TAO), and capstone designations (SWO). Designations sit atop a
// PREREQUISITE TREE of the others, so the app can tell a JO exactly what's
// blocking their board. A PersonQual tracks one person's progress on one qual.
// PQS line-item detail comes later — this scaffolds types + prereqs + stages.
// All three entities sync over the mesh.

import 'chain.dart' show Role, roleFromToken;
import 'schedule.dart' show startOfDay;

/// What kind of qualification a node is.
enum QualType { watchStation, knowledge, letter, designation }

extension QualTypeInfo on QualType {
  String get label {
    switch (this) {
      case QualType.watchStation:
        return 'Watch station';
      case QualType.knowledge:
        return 'Knowledge';
      case QualType.letter:
        return 'Letter';
      case QualType.designation:
        return 'Designation';
    }
  }
}

String qualTypeToken(QualType t) => t.name;
QualType qualTypeFromToken(String s) => QualType.values.firstWhere(
  (t) => t.name == s,
  orElse: () => QualType.watchStation,
);

/// A person's progress stage on a qualification.
enum QualStage { notStarted, inProgress, boardPending, qualified }

extension QualStageInfo on QualStage {
  String get label {
    switch (this) {
      case QualStage.notStarted:
        return 'Not started';
      case QualStage.inProgress:
        return 'In progress';
      case QualStage.boardPending:
        return 'Board pending';
      case QualStage.qualified:
        return 'Qualified';
    }
  }
}

String qualStageToken(QualStage q) => q.name;
QualStage qualStageFromToken(String s) => QualStage.values.firstWhere(
  (q) => q.name == s,
  orElse: () => QualStage.notStarted,
);

/// A qualification definition — a node in the qual tree.
class Qualification {
  final String id;
  String name; // e.g. "Officer of the Deck (Underway)"
  String abbr; // short label, e.g. "OOD U/W"
  QualType type;
  List<String> prereqIds; // qualifications that must be 'qualified' first
  int? hoursRequired; // e.g. OOD hours (null = none)
  bool inPort; // watch-station: postable on the in-port bill
  int order; // display order

  Qualification({
    required this.id,
    required this.name,
    required this.abbr,
    required this.type,
    List<String>? prereqIds,
    this.hoursRequired,
    this.inPort = true,
    this.order = 0,
  }) : prereqIds = prereqIds ?? [];

  bool get isWatchStation => type == QualType.watchStation;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'abbr': abbr,
    'type': qualTypeToken(type),
    'prereqIds': prereqIds,
    'hoursRequired': hoursRequired,
    'inPort': inPort,
    'order': order,
  };

  factory Qualification.fromJson(Map<String, dynamic> j) => Qualification(
    id: j['id'] as String,
    name: (j['name'] ?? '') as String,
    abbr: (j['abbr'] ?? '') as String,
    type: qualTypeFromToken((j['type'] ?? 'watchStation') as String),
    prereqIds: (j['prereqIds'] as List?)?.map((e) => e as String).toList(),
    hoursRequired: j['hoursRequired'] as int?,
    inPort: (j['inPort'] ?? true) as bool,
    order: (j['order'] ?? 0) as int,
  );
}

/// A person's progress on one qualification.
class PersonQual {
  final String id; // "{personId}|{qualId}"
  final String personId; // account id
  final String qualId;
  QualStage stage;
  int percent; // 0-100 PQS line-item rollup (placeholder until items exist)
  int hoursLogged; // toward Qualification.hoursRequired
  bool qualifier; // qualified AND authorized to sign others off
  int updatedAtMs;

  PersonQual({
    required this.id,
    required this.personId,
    required this.qualId,
    required this.stage,
    this.percent = 0,
    this.hoursLogged = 0,
    this.qualifier = false,
    required this.updatedAtMs,
  });

  static String makeId(String personId, String qualId) => '$personId|$qualId';

  bool get isQualified => stage == QualStage.qualified;

  Map<String, dynamic> toJson() => {
    'id': id,
    'personId': personId,
    'qualId': qualId,
    'stage': qualStageToken(stage),
    'percent': percent,
    'hoursLogged': hoursLogged,
    'qualifier': qualifier,
    'updatedAtMs': updatedAtMs,
  };

  factory PersonQual.fromJson(Map<String, dynamic> j) => PersonQual(
    id: j['id'] as String,
    personId: (j['personId'] ?? '') as String,
    qualId: (j['qualId'] ?? '') as String,
    stage: qualStageFromToken((j['stage'] ?? 'notStarted') as String),
    percent: (j['percent'] ?? 0) as int,
    hoursLogged: (j['hoursLogged'] ?? 0) as int,
    qualifier: (j['qualifier'] ?? false) as bool,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}

// --- Qualification-tree logic (pure) --------------------------------------

/// Whether all of [q]'s prerequisites are in [qualifiedIds].
bool prereqsMet(Qualification q, Set<String> qualifiedIds) =>
    q.prereqIds.every(qualifiedIds.contains);

/// [q]'s prerequisites that are not yet qualified.
List<String> missingPrereqs(Qualification q, Set<String> qualifiedIds) =>
    q.prereqIds.where((id) => !qualifiedIds.contains(id)).toList();

/// Whether everything's in place to sit the board for [q] — prerequisites
/// qualified, PQS line items complete, hours met — and it isn't already done.
bool readyToBoard(Qualification q, PersonQual? pq, Set<String> qualifiedIds) {
  if (pq?.isQualified ?? false) return false;
  if (!prereqsMet(q, qualifiedIds)) return false;
  if ((pq?.percent ?? 0) < 100) return false;
  if (q.hoursRequired != null && (pq?.hoursLogged ?? 0) < q.hoursRequired!) {
    return false;
  }
  return true;
}

// --- Evolutions + the watchbill -------------------------------------------
//
// A watchbill fills every role an EVOLUTION requires. In port the evolution is
// the day-to-day duty day. Roles are STANDING (one person the whole evolution)
// or ROTATING (split into the evolution's section SHIFTS). A BillEntry is one
// filled cell. Evolutions are data, so new ones can be defined later.

/// One rotation slot — a "section" stands it — for rotating roles.
class WatchShift {
  final String id; // 's1'…'s5'
  String label; // section label, e.g. "1"
  String start; // "0630"
  String end; // "1130"

  WatchShift({
    required this.id,
    required this.label,
    required this.start,
    required this.end,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'start': start,
    'end': end,
  };

  factory WatchShift.fromJson(Map<String, dynamic> j) => WatchShift(
    id: j['id'] as String,
    label: (j['label'] ?? '') as String,
    start: (j['start'] ?? '') as String,
    end: (j['end'] ?? '') as String,
  );
}

/// A required role in an evolution — a watch station that must be manned.
class EvolutionRole {
  final String id; // unique within the evolution
  String stationId; // the watch-station Qualification id required for it
  String name; // display label
  bool rotating; // false = standing; true = sectioned across the shifts
  int order;

  EvolutionRole({
    required this.id,
    required this.stationId,
    required this.name,
    this.rotating = false,
    this.order = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'stationId': stationId,
    'name': name,
    'rotating': rotating,
    'order': order,
  };

  factory EvolutionRole.fromJson(Map<String, dynamic> j) => EvolutionRole(
    id: j['id'] as String,
    stationId: (j['stationId'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    rotating: (j['rotating'] ?? false) as bool,
    order: (j['order'] ?? 0) as int,
  );
}

/// A named event with the roles it requires + (for rotating roles) its shifts.
class Evolution {
  final String id;
  String name;
  bool inPort;
  List<WatchShift> shifts;
  List<EvolutionRole> roles;
  List<String> routesTo; // department ids the filled watchbill routes to
  int order;
  int updatedAtMs; // bumped on every save — drives last-write-wins on sync
  // Transient routing state (set when a manager routes the bill for a day).
  int? routedForDayMs;
  String routedBy;
  int routedAtMs;

  Evolution({
    required this.id,
    required this.name,
    this.inPort = true,
    List<WatchShift>? shifts,
    List<EvolutionRole>? roles,
    List<String>? routesTo,
    this.order = 0,
    this.updatedAtMs = 0,
    this.routedForDayMs,
    this.routedBy = '',
    this.routedAtMs = 0,
  }) : shifts = shifts ?? [],
       roles = roles ?? [],
       routesTo = routesTo ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'inPort': inPort,
    'shifts': shifts.map((s) => s.toJson()).toList(),
    'roles': roles.map((r) => r.toJson()).toList(),
    'routesTo': routesTo,
    'order': order,
    'updatedAtMs': updatedAtMs,
    'routedForDayMs': routedForDayMs,
    'routedBy': routedBy,
    'routedAtMs': routedAtMs,
  };

  factory Evolution.fromJson(Map<String, dynamic> j) => Evolution(
    id: j['id'] as String,
    name: (j['name'] ?? '') as String,
    inPort: (j['inPort'] ?? true) as bool,
    shifts: ((j['shifts'] as List?) ?? [])
        .map((e) => WatchShift.fromJson(e as Map<String, dynamic>))
        .toList(),
    roles: ((j['roles'] as List?) ?? [])
        .map((e) => EvolutionRole.fromJson(e as Map<String, dynamic>))
        .toList(),
    routesTo: ((j['routesTo'] as List?) ?? []).map((e) => e as String).toList(),
    order: (j['order'] ?? 0) as int,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
    routedForDayMs: j['routedForDayMs'] as int?,
    routedBy: (j['routedBy'] ?? '') as String,
    routedAtMs: (j['routedAtMs'] ?? 0) as int,
  );
}

/// One filled cell: a person posted to a role (+ shift, if rotating) on a day's
/// instance of an evolution.
class BillEntry {
  final String id; // '{dayMs}|{evolutionId}|{roleId}|{shiftId}'
  final int dayMs;
  final String evolutionId;
  final String roleId;
  final String shiftId; // '' for standing roles
  String personId;
  int updatedAtMs;

  BillEntry({
    required this.id,
    required this.dayMs,
    required this.evolutionId,
    required this.roleId,
    required this.shiftId,
    required this.personId,
    required this.updatedAtMs,
  });

  static String makeId(
    int dayMs,
    String evolutionId,
    String roleId,
    String shiftId,
  ) => '${startOfDay(dayMs)}|$evolutionId|$roleId|$shiftId';

  Map<String, dynamic> toJson() => {
    'id': id,
    'dayMs': dayMs,
    'evolutionId': evolutionId,
    'roleId': roleId,
    'shiftId': shiftId,
    'personId': personId,
    'updatedAtMs': updatedAtMs,
  };

  factory BillEntry.fromJson(Map<String, dynamic> j) => BillEntry(
    id: j['id'] as String,
    dayMs: (j['dayMs'] ?? 0) as int,
    evolutionId: (j['evolutionId'] ?? '') as String,
    roleId: (j['roleId'] ?? '') as String,
    shiftId: (j['shiftId'] ?? '') as String,
    personId: (j['personId'] ?? '') as String,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}

/// One fillable slot on a bill: a (role, shift) pair + the station it needs.
class BillSlot {
  final String roleId;
  final String shiftId; // '' for standing
  final String stationId;
  final bool standing;

  BillSlot({
    required this.roleId,
    required this.shiftId,
    required this.stationId,
    required this.standing,
  });

  String get key => '$roleId|$shiftId';
}

/// Expand an evolution into its fillable slots — standing roles get one slot,
/// rotating roles one per shift.
List<BillSlot> evolutionSlots(Evolution e) => [
  for (final r in e.roles)
    if (r.rotating)
      for (final s in e.shifts)
        BillSlot(
          roleId: r.id,
          shiftId: s.id,
          stationId: r.stationId,
          standing: false,
        )
    else
      BillSlot(
        roleId: r.id,
        shiftId: '',
        stationId: r.stationId,
        standing: true,
      ),
];

/// Auto-fill a bill: assign qualified people to [slots], never double-booking a
/// person into overlapping watches (a standing watch overlaps everything; two
/// rotating watches overlap only if they share a shift), spreading load evenly.
/// Returns slot.key -> personId; slots with no eligible person are left out.
///
/// [priorLoad], when given, is each person's HISTORICAL burden for a slot —
/// e.g. how many times they've already stood that watch time (the mids/eves)
/// per the stood-log. It's added to the in-bill count so auto-fill spreads the
/// unpopular night watches across days the same way the manual picker does,
/// instead of re-stacking the same person every time it's run.
Map<String, String> autoFillBill({
  required List<BillSlot> slots,
  required List<String> people,
  required bool Function(String personId, String stationId) isQualified,
  int Function(String personId, BillSlot slot)? priorLoad,
}) {
  final result = <String, String>{};
  final load = {for (final p in people) p: 0};
  final standingPeople = <String>{}; // in a standing watch — busy all day
  final shiftPeople = <String, Set<String>>{}; // shiftId -> people busy then

  bool free(String p, BillSlot s) {
    if (standingPeople.contains(p)) return false;
    if (s.standing) return shiftPeople.values.every((set) => !set.contains(p));
    return !(shiftPeople[s.shiftId]?.contains(p) ?? false);
  }

  // Standing slots first (most constraining), then rotating.
  final ordered = [
    ...slots.where((s) => s.standing),
    ...slots.where((s) => !s.standing),
  ];
  for (final s in ordered) {
    final cands =
        people.where((p) => isQualified(p, s.stationId) && free(p, s)).toList()
          ..sort((a, b) {
            // Total burden = already assigned this bill + historical (night)
            // load; least-burdened first, with a stable id tiebreak.
            final la = load[a]! + (priorLoad?.call(a, s) ?? 0);
            final lb = load[b]! + (priorLoad?.call(b, s) ?? 0);
            return la != lb ? la.compareTo(lb) : a.compareTo(b);
          });
    if (cands.isEmpty) continue;
    final pick = cands.first;
    result[s.key] = pick;
    load[pick] = load[pick]! + 1;
    if (s.standing) {
      standingPeople.add(pick);
    } else {
      (shiftPeople[s.shiftId] ??= {}).add(pick);
    }
  }
  return result;
}

// --- Duty sections --------------------------------------------------------
//
// A duty section is one-fifth (1/N) of the whole crew that stands the 24-hour
// in-port duty day. Auto-assignment partitions everyone into N balanced sections
// such that each section can man the whole bill on its own — every required
// station is covered by at least one qualified member of the section.

/// Partition [people] into [sections] balanced duty sections (numbered 1..N)
/// so each section covers every station in [requiredStations] where possible.
/// Greedy: cover the scarcest stations first (spreading their few qualified
/// people across sections), then fill the rest to even out section sizes.
Map<String, int> assignDutySections({
  required List<String> people,
  required List<String> requiredStations,
  required bool Function(String person, String station) isQualified,
  int sections = 5,
}) {
  final assign = <String, int>{};
  final members = {for (var s = 1; s <= sections; s++) s: <String>[]};

  bool covers(int sec, String st) =>
      members[sec]!.any((p) => isQualified(p, st));
  void place(String p, int sec) {
    assign[p] = sec;
    members[sec]!.add(p);
  }

  int qualCount(String st) => people.where((p) => isQualified(p, st)).length;

  // 1. Coverage pass — scarcest stations first, spread across sections.
  final byScarcity = [...requiredStations]
    ..sort((a, b) => qualCount(a).compareTo(qualCount(b)));
  for (final st in byScarcity) {
    for (var sec = 1; sec <= sections; sec++) {
      if (covers(sec, st)) continue;
      String? pick;
      for (final p in people) {
        if (!assign.containsKey(p) && isQualified(p, st)) {
          pick = p;
          break;
        }
      }
      if (pick != null) place(pick, sec); // else: gap (too few qualified)
    }
  }

  // 2. Balance pass — remaining people to the smallest section each time.
  int smallest() => members.entries
      .reduce((a, b) => a.value.length <= b.value.length ? a : b)
      .key;
  for (final p in people) {
    if (!assign.containsKey(p)) place(p, smallest());
  }
  return assign;
}

/// Per-section coverage gaps: stations a section has NOBODY qualified for.
/// Empty map = every section can man the whole bill.
Map<int, List<String>> dutySectionGaps({
  required Map<String, int> assignment,
  required List<String> requiredStations,
  required bool Function(String person, String station) isQualified,
  int sections = 5,
}) {
  final gaps = <int, List<String>>{};
  for (var sec = 1; sec <= sections; sec++) {
    final mem = assignment.entries
        .where((e) => e.value == sec)
        .map((e) => e.key);
    final missing = requiredStations
        .where((st) => !mem.any((p) => isQualified(p, st)))
        .toList();
    if (missing.isNotEmpty) gaps[sec] = missing;
  }
  return gaps;
}

// --- Watch-stood log ------------------------------------------------------
//
// An append-only record of watches actually STOOD — the permanent history,
// independent of the (mutable) bill. Keyed by the bill slot so re-recording a
// duty day updates rather than duplicates; carries name snapshots so counts
// survive a station/evolution being renamed or removed.

class WatchStood {
  final String id; // '{dayMs}|{evolutionId}|{roleId}|{shiftId}'
  final String personId;
  final String stationName; // snapshot
  final String evolutionName; // snapshot
  final String timeLabel; // '2130-0130', or '' for a standing watch
  final int dayMs;
  final String section; // duty section that recorded it ('' = main watchbill)
  int atMs; // recorded-at (last-write-wins)

  WatchStood({
    required this.id,
    required this.personId,
    required this.stationName,
    required this.evolutionName,
    required this.timeLabel,
    required this.dayMs,
    this.section = '',
    required this.atMs,
  });

  static String makeId(
    int dayMs,
    String evolutionId,
    String roleId,
    String shiftId,
  ) => '${startOfDay(dayMs)}|$evolutionId|$roleId|$shiftId';

  Map<String, dynamic> toJson() => {
    'id': id,
    'personId': personId,
    'stationName': stationName,
    'evolutionName': evolutionName,
    'timeLabel': timeLabel,
    'dayMs': dayMs,
    'section': section,
    'atMs': atMs,
  };

  factory WatchStood.fromJson(Map<String, dynamic> j) => WatchStood(
    id: j['id'] as String,
    personId: (j['personId'] ?? '') as String,
    stationName: (j['stationName'] ?? '') as String,
    evolutionName: (j['evolutionName'] ?? '') as String,
    timeLabel: (j['timeLabel'] ?? '') as String,
    dayMs: (j['dayMs'] ?? 0) as int,
    section: (j['section'] ?? '') as String,
    atMs: (j['atMs'] ?? 0) as int,
  );
}

// --- Duty-day events ------------------------------------------------------
//
// Notable events that occurred during a recorded duty day (logged alongside
// the stood watches when the section confirms its watchbill executed). Keyed by
// day + section + type so re-recording updates rather than duplicates.

/// Standard duty-day events offered in the record sheet. Editable — the note
/// field captures anything not on the list (or pick "Other").
const kDutyDayEventTypes = <String>[
  'Class A Fire',
  'Class B Fire',
  'Class C Fire',
  'Flooding',
  'Man Overboard',
  'Medical Emergency',
  'AT/FP Event',
  'Security Alert',
  'Equipment Casualty',
  'Loss of Power',
  'Sortie/Recall',
  'Other',
];

class DutyDayEvent {
  final String id; // '{dayMs}|{section}|{type}'
  final int dayMs;
  final String section;
  final String type; // one of kDutyDayEventTypes
  final String note; // optional free text
  int atMs; // recorded-at (last-write-wins)

  DutyDayEvent({
    required this.id,
    required this.dayMs,
    required this.section,
    required this.type,
    required this.note,
    required this.atMs,
  });

  static String makeId(int dayMs, String section, String type) =>
      '${startOfDay(dayMs)}|$section|$type';

  Map<String, dynamic> toJson() => {
    'id': id,
    'dayMs': dayMs,
    'section': section,
    'type': type,
    'note': note,
    'atMs': atMs,
  };

  factory DutyDayEvent.fromJson(Map<String, dynamic> j) => DutyDayEvent(
    id: j['id'] as String,
    dayMs: (j['dayMs'] ?? 0) as int,
    section: (j['section'] ?? '') as String,
    type: (j['type'] ?? '') as String,
    note: (j['note'] ?? '') as String,
    atMs: (j['atMs'] ?? 0) as int,
  );
}

// --- Watchbill routing (the approval chain) ------------------------------
//
// A section watchbill is built by the Section Leader, routed to the CDO, and
// approved before the duty day; then FINALIZED (events logged) and approved a
// second time — that second approval is what records the watches (counters +
// history). One routing per section; everyone in the section sees the status.

enum BillStatus {
  draft, // SL building the plan (assignments editable)
  submitted, // SL submitted the plan → awaiting CDO
  approved, // CDO approved the plan; the duty day runs
  finalizing, // SL submitted the finalize (events) → awaiting CDO
  finalized, // CDO approved the finalize → watches recorded, in history
}

extension BillStatusInfo on BillStatus {
  String get token => name;

  /// SL may edit the bill assignments only while drafting.
  bool get planEditable => this == BillStatus.draft;

  /// Awaiting a CDO decision (the "in routing" states a watchstander sees).
  bool get inRouting =>
      this == BillStatus.submitted || this == BillStatus.finalizing;
}

BillStatus billStatusFromToken(String t) =>
    BillStatus.values.firstWhere((s) => s.name == t, orElse: () => BillStatus.draft);

class WatchbillRouting {
  final String id; // == section (one routing per section)
  final String section;
  BillStatus status;
  String submittedBy; // account id of the last submitter (Section Leader)
  String approvedBy; // account id of the last approver (CDO)
  String returnedBy; // account id of the CDO who returned it ('' = not returned)
  String returnedNote; // CDO's reason for returning
  int dayMs; // real calendar day being finalized (stamped at finalize-submit)
  int updatedAtMs; // LWW + the timestamp shown in the status chip

  WatchbillRouting({
    required this.id,
    required this.section,
    this.status = BillStatus.draft,
    this.submittedBy = '',
    this.approvedBy = '',
    this.returnedBy = '',
    this.returnedNote = '',
    this.dayMs = 0,
    this.updatedAtMs = 0,
  });

  static String makeId(String section) => section;

  Map<String, dynamic> toJson() => {
    'id': id,
    'section': section,
    'status': status.token,
    'submittedBy': submittedBy,
    'approvedBy': approvedBy,
    'returnedBy': returnedBy,
    'returnedNote': returnedNote,
    'dayMs': dayMs,
    'updatedAtMs': updatedAtMs,
  };

  factory WatchbillRouting.fromJson(Map<String, dynamic> j) => WatchbillRouting(
    id: j['id'] as String,
    section: (j['section'] ?? '') as String,
    status: billStatusFromToken((j['status'] ?? 'draft') as String),
    submittedBy: (j['submittedBy'] ?? '') as String,
    approvedBy: (j['approvedBy'] ?? '') as String,
    returnedBy: (j['returnedBy'] ?? '') as String,
    returnedNote: (j['returnedNote'] ?? '') as String,
    dayMs: (j['dayMs'] ?? 0) as int,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}

/// Approval routing for an EVOLUTION watchbill — one per evolution + calendar
/// day. Mirrors the duty-section [WatchbillRouting] two-phase lifecycle
/// (plan → approved → finalize-with-events → recorded), but the bill climbs the
/// command ladder [kCommandChain]: DH → XO → CO. [currentRung] is whose approval
/// is pending while [status] is submitted (plan) or finalizing (record).
class EvolutionRouting {
  final String id; // '{evolutionId}|{startOfDay(dayMs)}'
  final String evolutionId;
  final int dayMs;
  BillStatus status;
  Role currentRung; // pending approver while submitted/finalizing (dh→xo→co)
  String submittedBy; // account id of the coordinator who submitted
  int submittedAtMs;
  List<String> approvals; // audit trail, e.g. "DH · LT Smith"
  String returnedBy; // account id of the rung that returned it ('' = not)
  String returnedNote;
  int updatedAtMs; // LWW + the timestamp shown in the status chip

  EvolutionRouting({
    required this.id,
    required this.evolutionId,
    required this.dayMs,
    this.status = BillStatus.draft,
    this.currentRung = Role.dh,
    this.submittedBy = '',
    this.submittedAtMs = 0,
    List<String>? approvals,
    this.returnedBy = '',
    this.returnedNote = '',
    this.updatedAtMs = 0,
  }) : approvals = approvals ?? [];

  static String makeId(String evolutionId, int dayMs) =>
      '$evolutionId|${startOfDay(dayMs)}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'evolutionId': evolutionId,
    'dayMs': dayMs,
    'status': status.token,
    'currentRung': currentRung.name,
    'submittedBy': submittedBy,
    'submittedAtMs': submittedAtMs,
    'approvals': approvals,
    'returnedBy': returnedBy,
    'returnedNote': returnedNote,
    'updatedAtMs': updatedAtMs,
  };

  factory EvolutionRouting.fromJson(Map<String, dynamic> j) => EvolutionRouting(
    id: j['id'] as String,
    evolutionId: (j['evolutionId'] ?? '') as String,
    dayMs: (j['dayMs'] ?? 0) as int,
    status: billStatusFromToken((j['status'] ?? 'draft') as String),
    currentRung: roleFromToken((j['currentRung'] ?? 'dh') as String),
    submittedBy: (j['submittedBy'] ?? '') as String,
    submittedAtMs: (j['submittedAtMs'] ?? 0) as int,
    approvals: ((j['approvals'] as List?) ?? [])
        .map((e) => e as String)
        .toList(),
    returnedBy: (j['returnedBy'] ?? '') as String,
    returnedNote: (j['returnedNote'] ?? '') as String,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}
