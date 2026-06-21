// Logic tests for the Watchbill + PQS model.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/schedule.dart';
import 'package:grapheion/domain/watch.dart';

void main() {
  group('watch periods', () {
    test('labels + clock ranges', () {
      expect(WatchPeriod.mid.range, '0000-0400');
      expect(WatchPeriod.dog1.label, '1st Dog');
      expect(WatchPeriod.dog2.range, '1800-2000');
      expect(WatchPeriod.evening.range, '2000-2400');
    });
    test('token round-trips', () {
      for (final p in WatchPeriod.values) {
        expect(watchPeriodFromToken(watchPeriodToken(p)), p);
      }
    });
  });

  group('qual level', () {
    test('token round-trips + unknown falls back to notStarted', () {
      for (final q in QualLevel.values) {
        expect(qualLevelFromToken(qualLevelToken(q)), q);
      }
      expect(qualLevelFromToken('bogus'), QualLevel.notStarted);
    });
  });

  group('Qual', () {
    test('stable id + isQualified', () {
      final q = Qual(
        id: Qual.makeId('acct-1', 'sta-poow'),
        personId: 'acct-1',
        stationId: 'sta-poow',
        level: QualLevel.qualified,
        qualifier: true,
        updatedAtMs: 5,
      );
      expect(q.id, 'acct-1|sta-poow');
      expect(q.isQualified, isTrue);
      final back = Qual.fromJson(q.toJson());
      expect(back.level, QualLevel.qualified);
      expect(back.qualifier, isTrue);
      expect(back.personId, 'acct-1');
      expect(back.stationId, 'sta-poow');
    });
    test('in-progress is not qualified', () {
      final q = Qual(
        id: Qual.makeId('a', 'b'),
        personId: 'a',
        stationId: 'b',
        level: QualLevel.inProgress,
        updatedAtMs: 0,
      );
      expect(q.isQualified, isFalse);
    });
  });

  group('WatchAssignment', () {
    test('id is keyed by day-start, station, period', () {
      final day = DateTime(2026, 6, 20, 13, 30).millisecondsSinceEpoch;
      final id = WatchAssignment.makeId(day, 'sta-poow', WatchPeriod.morning);
      expect(id, '${startOfDay(day)}|sta-poow|morning');
    });
    test('round-trips', () {
      final day = DateTime(2026, 6, 20).millisecondsSinceEpoch;
      final a = WatchAssignment(
        id: WatchAssignment.makeId(day, 'sta-poow', WatchPeriod.mid),
        dayMs: day,
        stationId: 'sta-poow',
        period: WatchPeriod.mid,
        personId: 'acct-1',
        updatedAtMs: 7,
      );
      final back = WatchAssignment.fromJson(a.toJson());
      expect(back.period, WatchPeriod.mid);
      expect(back.stationId, 'sta-poow');
      expect(back.personId, 'acct-1');
    });
  });

  group('WatchStation', () {
    test('round-trips', () {
      final s = WatchStation(
          id: 'sta-poow', name: 'Petty Officer of the Watch', abbr: 'POOW', order: 2);
      final back = WatchStation.fromJson(s.toJson());
      expect(back.abbr, 'POOW');
      expect(back.inPort, isTrue);
      expect(back.order, 2);
    });
  });
}
