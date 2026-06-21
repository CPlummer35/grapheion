// Grapheion — Watchbills + PQS qualification.
//
// PQS says who is QUALIFIED for a watch station; the watchbill ASSIGNS qualified
// people to stations across the day's watch periods. They're built together so
// the watchbill can refuse to post an unqualified watchstander — that constraint
// is the point. In-port watchbill first. All three entities sync over the mesh.

import 'schedule.dart' show startOfDay;

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

  /// Clock range, e.g. "0000-0400".
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

/// PQS progress for a person on a watch station.
enum QualLevel { notStarted, inProgress, qualified }

extension QualLevelInfo on QualLevel {
  String get label {
    switch (this) {
      case QualLevel.notStarted:
        return 'Not started';
      case QualLevel.inProgress:
        return 'In progress';
      case QualLevel.qualified:
        return 'Qualified';
    }
  }
}

String qualLevelToken(QualLevel q) => q.name;
QualLevel qualLevelFromToken(String s) => QualLevel.values
    .firstWhere((q) => q.name == s, orElse: () => QualLevel.notStarted);

/// A watch station — a post that needs a qualified watchstander.
class WatchStation {
  final String id;
  String name; // e.g. "Petty Officer of the Watch"
  String abbr; // short label, e.g. "POOW"
  bool inPort; // in-port vs underway station
  int order; // display order on the bill

  WatchStation({
    required this.id,
    required this.name,
    required this.abbr,
    this.inPort = true,
    this.order = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'abbr': abbr,
        'inPort': inPort,
        'order': order,
      };

  factory WatchStation.fromJson(Map<String, dynamic> j) => WatchStation(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        abbr: (j['abbr'] ?? '') as String,
        inPort: (j['inPort'] ?? true) as bool,
        order: (j['order'] ?? 0) as int,
      );
}

/// A person's PQS qualification for one watch station.
class Qual {
  final String id; // "{personId}|{stationId}"
  final String personId; // account id
  final String stationId;
  QualLevel level;
  bool qualifier; // qualified AND authorized to sign others off
  int updatedAtMs;

  Qual({
    required this.id,
    required this.personId,
    required this.stationId,
    required this.level,
    this.qualifier = false,
    required this.updatedAtMs,
  });

  static String makeId(String personId, String stationId) =>
      '$personId|$stationId';

  bool get isQualified => level == QualLevel.qualified;

  Map<String, dynamic> toJson() => {
        'id': id,
        'personId': personId,
        'stationId': stationId,
        'level': qualLevelToken(level),
        'qualifier': qualifier,
        'updatedAtMs': updatedAtMs,
      };

  factory Qual.fromJson(Map<String, dynamic> j) => Qual(
        id: j['id'] as String,
        personId: (j['personId'] ?? '') as String,
        stationId: (j['stationId'] ?? '') as String,
        level: qualLevelFromToken((j['level'] ?? 'notStarted') as String),
        qualifier: (j['qualifier'] ?? false) as bool,
        updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
      );
}

/// One watchbill cell: a person posted to a station for a watch period on a
/// given (in-port) day.
class WatchAssignment {
  final String id; // "{dayMs}|{stationId}|{period}"
  final int dayMs; // startOfDay of the watch day
  final String stationId;
  final WatchPeriod period;
  String personId; // account id posted to the watch
  int updatedAtMs;

  WatchAssignment({
    required this.id,
    required this.dayMs,
    required this.stationId,
    required this.period,
    required this.personId,
    required this.updatedAtMs,
  });

  static String makeId(int dayMs, String stationId, WatchPeriod period) =>
      '${startOfDay(dayMs)}|$stationId|${period.name}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'dayMs': dayMs,
        'stationId': stationId,
        'period': watchPeriodToken(period),
        'personId': personId,
        'updatedAtMs': updatedAtMs,
      };

  factory WatchAssignment.fromJson(Map<String, dynamic> j) => WatchAssignment(
        id: j['id'] as String,
        dayMs: (j['dayMs'] ?? 0) as int,
        stationId: (j['stationId'] ?? '') as String,
        period: watchPeriodFromToken((j['period'] ?? 'mid') as String),
        personId: (j['personId'] ?? '') as String,
        updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
      );
}
