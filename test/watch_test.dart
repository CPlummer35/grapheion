// Logic tests for the Qualification tree + Watchbill model.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/schedule.dart';
import 'package:grapheion/domain/watch.dart';

Qualification _q(
  String id,
  QualType type, {
  List<String>? prereqs,
  int? hours,
}) => Qualification(
  id: id,
  name: id,
  abbr: id,
  type: type,
  prereqIds: prereqs,
  hoursRequired: hours,
);

PersonQual _pq(
  String person,
  String qual,
  QualStage stage, {
  int percent = 0,
  int hours = 0,
}) => PersonQual(
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
    test('type / stage tokens', () {
      for (final t in QualType.values) {
        expect(qualTypeFromToken(qualTypeToken(t)), t);
      }
      for (final s in QualStage.values) {
        expect(qualStageFromToken(qualStageToken(s)), s);
      }
      expect(qualStageFromToken('bogus'), QualStage.notStarted);
    });
  });

  group('Qualification', () {
    test('round-trips with type, prereqs, hours', () {
      final q = _q(
        'swo',
        QualType.designation,
        prereqs: ['ood-uw', 'cicwo'],
        hours: 100,
      );
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
      final pq = _pq(
        'acct-1',
        'ood-uw',
        QualStage.qualified,
        percent: 100,
        hours: 120,
      );
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
    final swo = _q(
      'swo',
      QualType.designation,
      prereqs: ['ood-uw', 'cicwo', '3m'],
      hours: 100,
    );

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
      expect(
        readyToBoard(
          swo,
          _pq('a', 'swo', QualStage.inProgress, percent: 80, hours: 120),
          all,
        ),
        isFalse,
      );
      // 100% but short on hours
      expect(
        readyToBoard(
          swo,
          _pq('a', 'swo', QualStage.inProgress, percent: 100, hours: 50),
          all,
        ),
        isFalse,
      );
      // prereqs missing
      expect(
        readyToBoard(
          swo,
          _pq('a', 'swo', QualStage.inProgress, percent: 100, hours: 120),
          {'ood-uw'},
        ),
        isFalse,
      );
      // everything in place
      expect(
        readyToBoard(
          swo,
          _pq('a', 'swo', QualStage.inProgress, percent: 100, hours: 120),
          all,
        ),
        isTrue,
      );
      // already qualified
      expect(
        readyToBoard(
          swo,
          _pq('a', 'swo', QualStage.qualified, percent: 100, hours: 120),
          all,
        ),
        isFalse,
      );
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
          id: 'r-cdo',
          stationId: 'cdo',
          name: 'CDO',
          rotating: false,
        ),
        EvolutionRole(
          id: 'r-poow',
          stationId: 'poow',
          name: 'POOW',
          rotating: true,
        ),
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
      expect(
        BillEntry.makeId(day, 'ev', 'r-poow', 's1'),
        '${startOfDay(day)}|ev|r-poow|s1',
      );
    });

    test('auto-fill uses only qualified people', () {
      final quals = {
        'a': {'cdo'},
        'b': {'poow'},
      };
      final fill = autoFillBill(
        slots: evolutionSlots(ev()),
        people: ['a', 'b'],
        isQualified: (p, st) => quals[p]?.contains(st) ?? false,
      );
      expect(fill['r-cdo|'], 'a');
      expect(fill['r-poow|s1'], 'b');
    });

    test(
      'a standing watch makes a person unavailable for any rotating shift',
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
      },
    );

    test(
      'even load spreads rotating shifts across equally-qualified people',
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
      },
    );

    test('auto-fill gives a night watch to whoever has stood it least', () {
      // A single rotating mid; both qualified. priorLoad models the stood-log
      // night history. Whoever has stood it MORE is passed over.
      Evolution mid() => Evolution(
        id: 'ev-mid',
        name: 'Mid',
        shifts: [WatchShift(id: 'mid', label: 'mid', start: '2200', end: '0200')],
        roles: [
          EvolutionRole(
            id: 'r-ood',
            stationId: 'ood',
            name: 'OOD',
            rotating: true,
          ),
        ],
      );
      Map<String, String> fillWith(Map<String, int> prior) => autoFillBill(
        slots: evolutionSlots(mid()),
        people: ['a', 'b'],
        isQualified: (_, __) => true,
        priorLoad: (p, _) => prior[p] ?? 0,
      );
      // The choice follows the history, not id order: it flips when the
      // burden flips, proving priorLoad actually drives the spread.
      expect(fillWith({'a': 3, 'b': 1})['r-ood|mid'], 'b');
      expect(fillWith({'a': 1, 'b': 3})['r-ood|mid'], 'a');
    });
  });

  group('duty sections', () {
    final people = [for (var i = 1; i <= 10; i++) 'p$i'];
    // Everyone holds 'A'; only p1 + p2 hold the scarce station 'B'.
    bool qual(String p, String st) =>
        st == 'A' ? true : (st == 'B' && (p == 'p1' || p == 'p2'));

    test('partitions everyone into balanced fifths', () {
      final a = assignDutySections(
        people: people,
        requiredStations: ['A', 'B'],
        isQualified: qual,
        sections: 5,
      );
      expect(a.length, 10);
      expect(a.values.every((s) => s >= 1 && s <= 5), isTrue);
      final sizes = [
        for (var s = 1; s <= 5; s++) a.values.where((v) => v == s).length,
      ];
      expect(sizes.reduce((x, y) => x + y), 10);
      expect(sizes.reduce((x, y) => x > y ? x : y), 2, reason: 'even fifths');
    });

    test('spreads the scarce station, covers the common one everywhere', () {
      final a = assignDutySections(
        people: people,
        requiredStations: ['A', 'B'],
        isQualified: qual,
      );
      final gaps = dutySectionGaps(
        assignment: a,
        requiredStations: ['A', 'B'],
        isQualified: qual,
      );
      expect(gaps.values.any((m) => m.contains('A')), isFalse);
      expect(a['p1'] != a['p2'], isTrue);
    });

    test('flags coverage gaps when too few are qualified', () {
      final a = assignDutySections(
        people: people,
        requiredStations: ['A', 'B'],
        isQualified: qual,
      );
      final gaps = dutySectionGaps(
        assignment: a,
        requiredStations: ['A', 'B'],
        isQualified: qual,
      );
      expect(gaps.values.where((m) => m.contains('B')).length, 3);
    });
  });

  group('watch-stood log', () {
    test('round-trips and keys by the bill slot', () {
      final day = DateTime(2026, 6, 24, 14).millisecondsSinceEpoch;
      final w = WatchStood(
        id: WatchStood.makeId(day, 'ev-inport', 'r-oodip', 's4'),
        personId: 'acct-7',
        stationName: 'Officer of the Deck (In-Port)',
        evolutionName: 'In-Port Duty',
        timeLabel: '2130-0130',
        dayMs: startOfDay(day),
        atMs: 1000,
      );
      expect(w.id, '${startOfDay(day)}|ev-inport|r-oodip|s4');
      final back = WatchStood.fromJson(w.toJson());
      expect(back.personId, 'acct-7');
      expect(back.stationName, 'Officer of the Deck (In-Port)');
      expect(back.timeLabel, '2130-0130');
      expect(back.atMs, 1000);
    });

    test('carries the recording section (defaults to empty)', () {
      final day = DateTime(2026, 6, 24).millisecondsSinceEpoch;
      final w = WatchStood(
        id: WatchStood.makeId(day, 'ev', 'r', 's'),
        personId: 'p',
        stationName: 'S',
        evolutionName: 'E',
        timeLabel: '',
        dayMs: startOfDay(day),
        section: '3',
        atMs: 1,
      );
      expect(WatchStood.fromJson(w.toJson()).section, '3');
      // Legacy records without the field decode to ''.
      final legacy = Map<String, dynamic>.from(w.toJson())..remove('section');
      expect(WatchStood.fromJson(legacy).section, '');
    });
  });

  group('duty-day events', () {
    test('round-trips and keys by day + section + type', () {
      final day = DateTime(2026, 6, 24, 9).millisecondsSinceEpoch;
      final e = DutyDayEvent(
        id: DutyDayEvent.makeId(day, '1', 'Class A Fire'),
        dayMs: startOfDay(day),
        section: '1',
        type: 'Class A Fire',
        note: 'Galley range, out in 4 min',
        atMs: 1234,
      );
      expect(e.id, '${startOfDay(day)}|1|Class A Fire');
      final back = DutyDayEvent.fromJson(e.toJson());
      expect(back.section, '1');
      expect(back.type, 'Class A Fire');
      expect(back.note, 'Galley range, out in 4 min');
      expect(back.atMs, 1234);
    });

    test('the preset list includes the common duty-day events', () {
      expect(kDutyDayEventTypes, contains('Class A Fire'));
      expect(kDutyDayEventTypes, contains('AT/FP Event'));
      expect(kDutyDayEventTypes, contains('Other'));
    });
  });
}
