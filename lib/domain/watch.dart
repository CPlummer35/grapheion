// Grapheion — Qualifications (PQS), the qualification tree, and Watchbills.
//
// ONE Qualification model spans everything a person can be qualified for: watch
// stations (which feed the watchbill), knowledge quals (3M, DC…), letter quals
// (CDO, EOOW, TAO), and capstone designations (SWO). Designations sit atop a
// PREREQUISITE TREE of the others, so the app can tell a JO exactly what's
// blocking their board. A PersonQual tracks one person's progress on one qual.
// PQS line-item detail comes later — this scaffolds types + prereqs + stages.
// All three entities sync over the mesh.

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
QualType qualTypeFromToken(String s) => QualType.values
    .firstWhere((t) => t.name == s, orElse: () => QualType.watchStation);

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
QualStage qualStageFromToken(String s) => QualStage.values
    .firstWhere((q) => q.name == s, orElse: () => QualStage.notStarted);


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
        prereqIds:
            (j['prereqIds'] as List?)?.map((e) => e as String).toList(),
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

  WatchShift(
      {required this.id,
      required this.label,
      required this.start,
      required this.end});

  Map<String, dynamic> toJson() =>
      {'id': id, 'label': label, 'start': start, 'end': end};

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
  int order;

  Evolution({
    required this.id,
    required this.name,
    this.inPort = true,
    List<WatchShift>? shifts,
    List<EvolutionRole>? roles,
    this.order = 0,
  })  : shifts = shifts ?? [],
        roles = roles ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'inPort': inPort,
        'shifts': shifts.map((s) => s.toJson()).toList(),
        'roles': roles.map((r) => r.toJson()).toList(),
        'order': order,
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
        order: (j['order'] ?? 0) as int,
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
          int dayMs, String evolutionId, String roleId, String shiftId) =>
      '${startOfDay(dayMs)}|$evolutionId|$roleId|$shiftId';

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

  BillSlot(
      {required this.roleId,
      required this.shiftId,
      required this.stationId,
      required this.standing});

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
                standing: false)
        else
          BillSlot(
              roleId: r.id,
              shiftId: '',
              stationId: r.stationId,
              standing: true),
    ];

/// Auto-fill a bill: assign qualified people to [slots], never double-booking a
/// person into overlapping watches (a standing watch overlaps everything; two
/// rotating watches overlap only if they share a shift), spreading load evenly.
/// Returns slot.key -> personId; slots with no eligible person are left out.
Map<String, String> autoFillBill({
  required List<BillSlot> slots,
  required List<String> people,
  required bool Function(String personId, String stationId) isQualified,
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
    final cands = people
        .where((p) => isQualified(p, s.stationId) && free(p, s))
        .toList()
      ..sort((a, b) => load[a]!.compareTo(load[b]!));
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
