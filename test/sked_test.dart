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

  group('MRC steps + signed accomplishment', () {
    test('procedure steps round-trip on the check', () {
      final c = _weekly()
        ..steps = [
          MrcStep(id: 's1', text: 'Check pressure', standard: '80–100 psi'),
          MrcStep(id: 's2', text: 'Inspect tread'),
        ];
      final back = PmsCheck.fromJson(c.toJson());
      expect(back.steps.length, 2);
      expect(back.steps.first.text, 'Check pressure');
      expect(back.steps.first.standard, '80–100 psi');
      expect(back.steps[1].standard, '');
    });

    test('a legacy check with no steps decodes to an empty list', () {
      final back = PmsCheck.fromJson({
        'id': 'L',
        'mip': 'X',
        'periodicity': 'monthly',
      });
      expect(back.steps, isEmpty);
    });

    test('accomplishment keys by check + day (same day → same id)', () {
      expect(
        PmsAccomplishment.makeId('c1', 5 * _day + 3600000),
        PmsAccomplishment.makeId('c1', 5 * _day + 7200000),
      );
    });

    test('an UNSAT step flags a discrepancy; round-trips with results', () {
      final a = PmsAccomplishment(
        id: PmsAccomplishment.makeId('c1', 5 * _day),
        checkId: 'c1',
        dayMs: 5 * _day,
        by: 'MM2 Smith',
        atMs: 5 * _day + 3600000,
        results: [
          StepResult(stepId: 's1', sat: true, reading: '90 psi'),
          StepResult(stepId: 's2', sat: false, reading: 'cut in casing'),
        ],
        note: 'sidewall cut',
        jobId: 'JOB-9',
        updatedAtMs: 5 * _day + 3600000,
      );
      expect(a.hasDiscrepancy, isTrue);
      final back = PmsAccomplishment.fromJson(a.toJson());
      expect(back.by, 'MM2 Smith');
      expect(back.results.length, 2);
      expect(back.results[1].sat, isFalse);
      expect(back.results[1].reading, 'cut in casing');
      expect(back.note, 'sidewall cut');
      expect(back.jobId, 'JOB-9');
      expect(back.hasDiscrepancy, isTrue);
    });

    test('all-SAT results have no discrepancy', () {
      final a = PmsAccomplishment(
        id: 'x',
        checkId: 'c',
        dayMs: 0,
        by: 'b',
        atMs: 0,
        results: [StepResult(stepId: 's1', sat: true)],
        updatedAtMs: 0,
      );
      expect(a.hasDiscrepancy, isFalse);
    });

    test('spot-check state: awaiting → verified / kicked back, round-trips', () {
      final a = PmsAccomplishment(
        id: 'x',
        checkId: 'c',
        dayMs: 0,
        by: 'tech',
        atMs: 0,
        updatedAtMs: 0,
      );
      expect(a.awaitingVerification, isTrue);
      a
        ..verifiedBy = 'WCS Jones'
        ..verifiedAtMs = 5;
      expect(a.verified, isTrue);
      expect(a.awaitingVerification, isFalse);
      final back = PmsAccomplishment.fromJson(a.toJson());
      expect(back.verifiedBy, 'WCS Jones');
      expect(back.verifiedAtMs, 5);

      final k = PmsAccomplishment(
        id: 'y',
        checkId: 'c',
        dayMs: 0,
        by: 'tech',
        atMs: 0,
        reworkNote: 'redo it',
        updatedAtMs: 0,
      );
      expect(k.kickedBack, isTrue);
      expect(k.awaitingVerification, isFalse);
      expect(PmsAccomplishment.fromJson(k.toJson()).reworkNote, 'redo it');
    });
  });

  group('deferral', () {
    test('a deferral masks the due state until it lapses, then clears', () {
      final now = 100 * _day;
      final c = _weekly(created: now - 30 * _day); // overdue weekly, never done
      expect(c.statusAt(now), PmsStatus.overdue);
      c.defer('Awaiting parts', now + 10 * _day, now);
      expect(c.statusAt(now), PmsStatus.deferred);
      expect(c.deferReason, 'Awaiting parts');
      // once the deferral lapses the real (overdue) state returns
      expect(c.statusAt(now + 11 * _day), PmsStatus.overdue);
      c.clearDeferral(now);
      expect(c.statusAt(now), PmsStatus.overdue);
      expect(c.deferredUntilMs, isNull);
    });

    test('deferral round-trips', () {
      final c = _weekly()..defer('No access', 5 * _day, 0);
      final back = PmsCheck.fromJson(c.toJson());
      expect(back.deferReason, 'No access');
      expect(back.deferredUntilMs, 5 * _day);
    });
  });
}
