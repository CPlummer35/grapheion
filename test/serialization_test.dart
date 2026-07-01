// Logic tests: every synced model survives a JSON round-trip (the wire format
// for both Iroh and BLE), and role tokens map correctly.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/casrep.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/job.dart';
import 'package:grapheion/domain/org.dart';

void main() {
  group('Job round-trip', () {
    test('a job through TA preserves all fields', () {
      final j = Job.originate(
        id: 'JOB-9',
        title: 'Gyro fault',
        ein: 'EIN-9',
        symptom: 'drift',
        priority: 1,
        originator: 'tech',
        workcenter: 'CP02',
        nowMs: 100,
      );
      j.approve(200);
      j.approve(300);
      j.approve(400); // execution
      j.requestTa(500);
      final back = Job.fromJson(j.toJson());
      expect(back.id, 'JOB-9');
      expect(back.workcenter, 'CP02');
      expect(back.priority, 1);
      expect(back.phase, JobPhase.ta);
      expect(back.approver, Role.portEngineer);
      expect(back.taRequested, isTrue);
    });
  });

  group('JobEvent round-trip', () {
    test('an audit entry preserves actor + role + action', () {
      final e = JobEvent(
        jobId: 'JOB-9',
        seq: 3,
        actor: 'LT Smith',
        role: Role.divo,
        action: 'approved',
        comment: 'looks good',
        tsMs: 999,
      );
      final back = JobEvent.fromJson(e.toJson());
      expect(back.jobId, 'JOB-9');
      expect(back.role, Role.divo);
      expect(back.action, 'approved');
      expect(back.docId, e.docId);
    });
  });

  group('Account round-trip + org entities', () {
    test('an account survives a round-trip (incl. the DH role)', () {
      final a = Account(
        id: 'acct-1',
        name: 'Plummdogg',
        rate: 'MM2',
        role: Role.dh,
        workcenterId: 'CP01',
        pinSalt: 'salt',
        pinHash: 'hash',
        createdAtMs: 1,
      );
      final back = Account.fromJson(a.toJson());
      expect(back.role, Role.dh);
      expect(back.workcenterId, 'CP01');
      expect(back.name, 'Plummdogg');
    });

    test('org entities round-trip', () {
      final w = WorkCenter(
        id: 'CP01',
        name: 'Main Propulsion',
        divisionId: 'M',
      );
      final back = WorkCenter.fromJson(w.toJson());
      expect(back.id, 'CP01');
      expect(back.divisionId, 'M');
    });
  });

  group('role tokens', () {
    test('every role round-trips through its token', () {
      for (final r in Role.values) {
        expect(roleFromToken(r.token), r, reason: '${r.name} token');
      }
    });
    test('an unknown / legacy token falls back to technician', () {
      expect(roleFromToken('cheng'), Role.technician); // legacy, pre-DH rename
      expect(roleFromToken('bogus'), Role.technician);
    });
  });

  group('CasrepType token', () {
    test('round-trips', () {
      for (final t in CasrepType.values) {
        expect(casrepTypeFromToken(casrepTypeToken(t)), t);
      }
    });
  });
}
