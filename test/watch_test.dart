// Logic tests for the Qualification tree + Watchbill model.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/schedule.dart';
import 'package:grapheion/domain/watch.dart';

Qualification _q(String id, QualType type,
        {List<String>? prereqs, int? hours}) =>
    Qualification(
        id: id,
        name: id,
        abbr: id,
        type: type,
        prereqIds: prereqs,
        hoursRequired: hours);

PersonQual _pq(String person, String qual, QualStage stage,
        {int percent = 0, int hours = 0}) =>
    PersonQual(
      id: PersonQual.makeId(person, qual),
      personId: person,
      qualId: qual,
      stage: stage,
      percent: percent,
      hoursLogged: hours,
      updatedAtMs: 0,
    );

void main() {
  group('enums round-trip', () {
    test('type / stage / period tokens', () {
      for (final t in QualType.values) {
        expect(qualTypeFromToken(qualTypeToken(t)), t);
      }
      for (final s in QualStage.values) {
        expect(qualStageFromToken(qualStageToken(s)), s);
      }
      for (final p in WatchPeriod.values) {
        expect(watchPeriodFromToken(watchPeriodToken(p)), p);
      }
      expect(qualStageFromToken('bogus'), QualStage.notStarted);
    });
  });

  group('watch periods', () {
    test('labels + ranges', () {
      expect(WatchPeriod.mid.range, '0000-0400');
      expect(WatchPeriod.dog1.label, '1st Dog');
      expect(WatchPeriod.evening.range, '2000-2400');
    });
  });

  group('Qualification', () {
    test('round-trips with type, prereqs, hours', () {
      final q = _q('swo', QualType.designation,
          prereqs: ['ood-uw', 'cicwo'], hours: 100);
      final back = Qualification.fromJson(q.toJson());
      expect(back.type, QualType.designation);
      expect(back.prereqIds, ['ood-uw', 'cicwo']);
      expect(back.hoursRequired, 100);
      expect(back.isWatchStation, isFalse);
    });
    test('watch-station type is flagged', () {
      expect(_q('poow', QualType.watchStation).isWatchStation, isTrue);
    });
  });

  group('PersonQual', () {
    test('stable id, isQualified, round-trip', () {
      final pq = _pq('acct-1', 'ood-uw', QualStage.qualified,
          percent: 100, hours: 120);
      expect(pq.id, 'acct-1|ood-uw');
      expect(pq.isQualified, isTrue);
      final back = PersonQual.fromJson(pq.toJson());
      expect(back.stage, QualStage.qualified);
      expect(back.percent, 100);
      expect(back.hoursLogged, 120);
    });
    test('board-pending is not yet qualified', () {
      expect(_pq('a', 'b', QualStage.boardPending).isQualified, isFalse);
    });
  });

  group('qualification tree', () {
    final swo = _q('swo', QualType.designation,
        prereqs: ['ood-uw', 'cicwo', '3m'], hours: 100);

    test('prereqsMet / missingPrereqs', () {
      final none = <String>{};
      expect(prereqsMet(swo, none), isFalse);
      expect(missingPrereqs(swo, none), ['ood-uw', 'cicwo', '3m']);
      final partial = {'ood-uw', '3m'};
      expect(missingPrereqs(swo, partial), ['cicwo']);
      final all = {'ood-uw', 'cicwo', '3m'};
      expect(prereqsMet(swo, all), isTrue);
    });

    test('readyToBoard needs prereqs + 100% + hours, and not already done', () {
      final all = {'ood-uw', 'cicwo', '3m'};
      // prereqs done but line items incomplete
      expect(readyToBoard(swo, _pq('a', 'swo', QualStage.inProgress, percent: 80, hours: 120), all), isFalse);
      // 100% but short on hours
      expect(readyToBoard(swo, _pq('a', 'swo', QualStage.inProgress, percent: 100, hours: 50), all), isFalse);
      // prereqs missing
      expect(readyToBoard(swo, _pq('a', 'swo', QualStage.inProgress, percent: 100, hours: 120), {'ood-uw'}), isFalse);
      // everything in place
      expect(readyToBoard(swo, _pq('a', 'swo', QualStage.inProgress, percent: 100, hours: 120), all), isTrue);
      // already qualified
      expect(readyToBoard(swo, _pq('a', 'swo', QualStage.qualified, percent: 100, hours: 120), all), isFalse);
    });
  });

  group('WatchAssignment', () {
    test('id keyed by day-start/qual/period; legacy stationId reads back', () {
      final day = DateTime(2026, 6, 20, 13).millisecondsSinceEpoch;
      expect(WatchAssignment.makeId(day, 'poow', WatchPeriod.morning),
          '${startOfDay(day)}|poow|morning');
      final back = WatchAssignment.fromJson({
        'id': 'x',
        'dayMs': day,
        'stationId': 'poow', // v1 key
        'period': 'mid',
        'personId': 'acct-1',
      });
      expect(back.qualId, 'poow');
    });
  });
}
