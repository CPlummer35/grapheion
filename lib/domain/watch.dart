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

/// In-port watch periods — 4-hour, with the 1600-2000 dog split so the rotation
/// shifts by a period each day.
enum WatchPeriod { mid, morning, forenoon, afternoon, dog1, dog2, evening }

extension WatchPeriodInfo on WatchPeriod {
  String get label {
    switch (this) {
      case WatchPeriod.mid:
        return 'Mid';
      case WatchPeriod.morning:
        return 'Morning';
      case WatchPeriod.forenoon:
        return 'Forenoon';
      case WatchPeriod.afternoon:
        return 'Afternoon';
      case WatchPeriod.dog1:
        return '1st Dog';
      case WatchPeriod.dog2:
        return '2nd Dog';
      case WatchPeriod.evening:
        return 'Evening';
    }
  }

  String get range {
    switch (this) {
      case WatchPeriod.mid:
        return '0000-0400';
      case WatchPeriod.morning:
        return '0400-0800';
      case WatchPeriod.forenoon:
        return '0800-1200';
      case WatchPeriod.afternoon:
        return '1200-1600';
      case WatchPeriod.dog1:
        return '1600-1800';
      case WatchPeriod.dog2:
        return '1800-2000';
      case WatchPeriod.evening:
        return '2000-2400';
    }
  }
}

String watchPeriodToken(WatchPeriod p) => p.name;
WatchPeriod watchPeriodFromToken(String s) => WatchPeriod.values
    .firstWhere((p) => p.name == s, orElse: () => WatchPeriod.mid);

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

/// One watchbill cell: a person posted to a station for a watch period on a
/// given (in-port) day. The station is a watch-station Qualification.
class WatchAssignment {
  final String id; // "{dayMs}|{qualId}|{period}"
  final int dayMs;
  final String qualId; // the watch-station qualification's id
  final WatchPeriod period;
  String personId;
  int updatedAtMs;

  WatchAssignment({
    required this.id,
    required this.dayMs,
    required this.qualId,
    required this.period,
    required this.personId,
    required this.updatedAtMs,
  });

  static String makeId(int dayMs, String qualId, WatchPeriod period) =>
      '${startOfDay(dayMs)}|$qualId|${period.name}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'dayMs': dayMs,
        'qualId': qualId,
        'period': watchPeriodToken(period),
        'personId': personId,
        'updatedAtMs': updatedAtMs,
      };

  factory WatchAssignment.fromJson(Map<String, dynamic> j) => WatchAssignment(
        id: j['id'] as String,
        dayMs: (j['dayMs'] ?? 0) as int,
        // Back-compat: v1 keyed this as 'stationId'.
        qualId: (j['qualId'] ?? j['stationId'] ?? '') as String,
        period: watchPeriodFromToken((j['period'] ?? 'mid') as String),
        personId: (j['personId'] ?? '') as String,
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
