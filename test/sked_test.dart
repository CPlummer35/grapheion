// Logic tests for the SKED (PMS) scheduling model — periodicity, due-date
// derivation, and the scheduled/due/overdue state machine.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/sked.dart';

const _day = 86400000;

PmsCheck _weekly({int created = 1000}) => PmsCheck.create(
      id: 'P1',
      mip: '5921/023-14',
      seq: 1,
      title: 'Lube main shaft bearing',
      ein: 'EIN-1',
      workcenter: 'CP01',
      periodicity: Periodicity.weekly,
      estMinutes: 30,
      nowMs: created,
    );

void main() {
  group('periodicity', () {
    test('codes, labels and intervals', () {
      expect(Periodicity.weekly.code, 'W');
      expect(Periodicity.biweekly.code, '2W');
      expect(Periodicity.quarterly.label, 'Quarterly');
      expect(Periodicity.daily.days, 1);
      expect(Periodicity.weekly.days, 7);
      expect(Periodicity.annual.days, 365);
    });
    test('token round-trips', () {
      for (final p in Periodicity.values) {
        expect(periodicityFromToken(periodicityToken(p)), p);
      }
    });
  });

  group('due-date derivation', () {
    test('a new check is due one interval after creation', () {
      final c = _weekly(created: 1000);
      expect(c.neverDone, isTrue);
      expect(c.nextDueMs, 1000 + 7 * _day);
      expect(c.daysUntilDue(1000), 7);
    });
    test('after accomplishment, the cycle resets from when it was done', () {
      final c = _weekly(created: 1000)..accomplish('MM2 Smith', 100 * _day);
      expect(c.lastDoneMs, 100 * _day);
      expect(c.lastBy, 'MM2 Smith');
      expect(c.neverDone, isFalse);
      expect(c.nextDueMs, 100 * _day + 7 * _day);
    });
  });

  group('status state machine', () {
    test('scheduled well before due', () {
      final c = _weekly(created: 0);
      expect(c.statusAt(1 * _day), PmsStatus.scheduled);
    });
    test('due within the heads-up window (last fifth of the period)', () {
      final c = _weekly(created: 0); // due at day 7; window ~1.4 days
      expect(c.statusAt(6 * _day + _day ~/ 2), PmsStatus.due);
    });
    test('overdue once past due', () {
      final c = _weekly(created: 0);
      expect(c.statusAt(8 * _day), PmsStatus.overdue);
    });
    test('accomplishing it clears an overdue state', () {
      final c = _weekly(created: 0);
      expect(c.statusAt(30 * _day), PmsStatus.overdue);
      c.accomplish('tech', 30 * _day);
      expect(c.statusAt(30 * _day), PmsStatus.scheduled);
    });
  });

  group('MIP / MRC identity', () {
    test('MRC code is periodicity code + sequence', () {
      expect(_weekly().mrcCode, 'W-1');
      final m = PmsCheck.create(
        id: 'P2',
        mip: '5921/023-14',
        seq: 3,
        title: 'x',
        ein: '',
        workcenter: 'CP01',
        periodicity: Periodicity.monthly,
        estMinutes: 10,
        nowMs: 0,
      );
      expect(m.mrcCode, 'M-3');
    });
  });

  group('situational (R)', () {
    final r = PmsCheck.create(
      id: 'R1',
      mip: '5921/023-14',
      seq: 1,
      title: 'Replace pads when worn',
      ein: '',
      workcenter: 'CP01',
      periodicity: Periodicity.situational,
      estMinutes: 20,
      nowMs: 0,
    );
    test('code R, non-calendar, never due', () {
      expect(r.periodicity.code, 'R');
      expect(r.periodicity.isCalendar, isFalse);
      expect(r.statusAt(9999 * _day), PmsStatus.scheduled);
    });
  });

  group('per-day accomplishment', () {
    test('doneOn tracks each performed day independently', () {
      final c = _weekly(created: 0);
      final d1 = DateTime(2026, 6, 15, 9).millisecondsSinceEpoch;
      final d2 = DateTime(2026, 6, 16, 9).millisecondsSinceEpoch;
      c.accomplish('tech', d1);
      expect(c.doneOn(d1), isTrue);
      expect(c.doneOn(d2), isFalse);
      c.accomplish('tech', d2);
      expect(c.doneOn(d1), isTrue); // earlier day still recorded
      expect(c.doneOn(d2), isTrue);
    });
  });

  group('round-trip', () {
    test('serializes and parses back identically', () {
      final c = _weekly(created: 1000)
        ..accomplish('MM2 Smith', 50 * _day)
        ..assignedTo = 'FN Jones'
        ..scheduledForMs = 99 * _day;
      final back = PmsCheck.fromJson(c.toJson());
      expect(back.mip, '5921/023-14');
      expect(back.mrcCode, 'W-1');
      expect(back.periodicity, Periodicity.weekly);
      expect(back.estMinutes, 30);
      expect(back.lastDoneMs, 50 * _day);
      expect(back.lastBy, 'MM2 Smith');
      expect(back.assignedTo, 'FN Jones');
      expect(back.doneDays, c.doneDays);
      expect(back.workcenter, 'CP01');
      expect(back.scheduledForMs, 99 * _day);
    });
    test('a never-done check round-trips with a null lastDone', () {
      final back = PmsCheck.fromJson(_weekly().toJson());
      expect(back.lastDoneMs, isNull);
      expect(back.neverDone, isTrue);
    });
    test('reads the legacy "mrc" field as the MIP number', () {
      final back = PmsCheck.fromJson({
        'id': 'L1',
        'mrc': '4421/039-01',
        'periodicity': 'monthly',
      });
      expect(back.mip, '4421/039-01');
      expect(back.seq, 1);
    });
  });
}
