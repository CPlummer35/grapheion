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

  group('evolution + watchbill', () {
    Evolution ev() => Evolution(
          id: 'ev',
          name: 'In-Port Duty',
          shifts: [
            WatchShift(id: 's1', label: '1', start: '0630', end: '1130'),
            WatchShift(id: 's2', label: '2', start: '1130', end: '1630'),
          ],
          roles: [
            EvolutionRole(
                id: 'r-cdo', stationId: 'cdo', name: 'CDO', rotating: false),
            EvolutionRole(
                id: 'r-poow', stationId: 'poow', name: 'POOW', rotating: true),
          ],
        );

    test('evolutionSlots: standing -> 1 slot, rotating -> one per shift', () {
      final slots = evolutionSlots(ev());
      expect(slots.length, 3); // CDO (1) + POOW (2 shifts)
      expect(slots.where((s) => s.standing).length, 1);
      expect(slots.where((s) => s.shiftId == 's1').length, 1);
    });

    test('evolution round-trips', () {
      final back = Evolution.fromJson(ev().toJson());
      expect(back.roles.length, 2);
      expect(back.shifts.length, 2);
      expect(back.roles.firstWhere((r) => r.id == 'r-poow').rotating, isTrue);
    });

    test('BillEntry id keyed by day/evolution/role/shift', () {
      final day = DateTime(2026, 6, 21, 14).millisecondsSinceEpoch;
      expect(BillEntry.makeId(day, 'ev', 'r-poow', 's1'),
          '${startOfDay(day)}|ev|r-poow|s1');
    });

    test('auto-fill uses only qualified people', () {
      final quals = {
        'a': {'cdo'},
        'b': {'poow'}
      };
      final fill = autoFillBill(
        slots: evolutionSlots(ev()),
        people: ['a', 'b'],
        isQualified: (p, st) => quals[p]?.contains(st) ?? false,
      );
      expect(fill['r-cdo|'], 'a');
      expect(fill['r-poow|s1'], 'b');
    });

    test('a standing watch makes a person unavailable for any rotating shift',
        () {
      // p is the only person and is qualified for everything; takes CDO
      // (standing, filled first) -> then can't take POOW shifts.
      final fill = autoFillBill(
        slots: evolutionSlots(ev()),
        people: ['p'],
        isQualified: (_, __) => true,
      );
      expect(fill['r-cdo|'], 'p');
      expect(fill.containsKey('r-poow|s1'), isFalse);
    });

    test('even load spreads rotating shifts across equally-qualified people',
        () {
      final fill = autoFillBill(
        slots: evolutionSlots(ev()),
        people: ['a', 'b'],
        isQualified: (p, st) => st == 'poow', // both qualified for POOW only
      );
      // CDO unfillable (nobody qualified); the two POOW shifts go to different
      // people rather than doubling one up.
      expect(fill.containsKey('r-cdo|'), isFalse);
      expect({fill['r-poow|s1'], fill['r-poow|s2']}, {'a', 'b'});
    });
  });
}
