// Logic tests for the corrective-maintenance approval flow. Pure domain — no
// UI, no mesh — so it's fast and deterministic.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/job.dart';

Job _make({int priority = 2}) => Job.originate(
  id: 'JOB-1',
  title: 'Main pump seal leak',
  ein: 'EIN-1',
  symptom: 'leak',
  priority: priority,
  originator: 'MM2 Tester',
  workcenter: 'CP01',
  nowMs: 1000,
);

void main() {
  group('originate', () {
    test('a new job starts in the approval phase, owned by WCS', () {
      final j = _make();
      expect(j.phase, JobPhase.approval);
      expect(j.approver, Role.wcs);
      expect(j.returned, isFalse);
      expect(j.inWork, isFalse);
      expect(j.taRequested, isFalse);
    });

    Job by(Role r) => Job.originate(
      id: 'J',
      title: 't',
      ein: 'e',
      symptom: 's',
      priority: 2,
      originator: 'X',
      originatorRole: r,
      workcenter: 'CP01',
      nowMs: 1,
    );

    test('the ladder starts at the rung above the submitter', () {
      expect(by(Role.technician).approver, Role.wcs);
      expect(by(Role.wcs).approver, Role.lpo);
      expect(by(Role.lpo).approver, Role.divo, reason: 'LPO → straight to DIVO');
    });

    test('a DIVO (or above) submission needs no approval → execution', () {
      expect(by(Role.divo).phase, JobPhase.execution);
      expect(by(Role.dh).phase, JobPhase.execution);
    });
  });

  group('approve', () {
    test('walks the ladder WCS → LPO → DIVO → execution', () {
      final j = _make();
      j.approve(2000);
      expect(j.approver, Role.lpo, reason: 'WCS approval hands to LPO');
      expect(j.phase, JobPhase.approval);

      j.approve(3000);
      expect(j.approver, Role.divo, reason: 'LPO approval hands to DIVO');
      expect(j.phase, JobPhase.approval);

      j.approve(4000);
      expect(
        j.phase,
        JobPhase.execution,
        reason: 'DIVO approval drops the job into execution',
      );
      expect(j.approver, Role.technician);
    });

    test('clears a prior return flag', () {
      final j = _make()..returnDown(2000);
      expect(j.returned, isTrue);
      j.approve(3000);
      expect(j.returned, isFalse);
    });

    test('stamps updatedAtMs on each action', () {
      final j = _make();
      j.approve(5000);
      expect(j.updatedAtMs, 5000);
    });
  });

  group('return', () {
    test('sends the job one rung back down the ladder', () {
      final j = _make()..approve(2000); // now at LPO
      j.returnDown(3000);
      expect(j.approver, Role.wcs);
      expect(j.returned, isTrue);
    });

    test('returning from WCS goes back to the originating technician', () {
      final j = _make(); // at WCS
      j.returnDown(2000);
      expect(j.approver, Role.technician);
    });
  });

  group('chain helpers', () {
    test('the approval ladder is exactly WCS → LPO → DIVO', () {
      expect(kApprovalChain, [Role.wcs, Role.lpo, Role.divo]);
    });
    test('nextInChain returns null past DIVO (off-ship is via TA only)', () {
      expect(nextInChain(Role.wcs), Role.lpo);
      expect(nextInChain(Role.lpo), Role.divo);
      expect(nextInChain(Role.divo), isNull);
    });
    test('firstApproverAfter starts above the submitter', () {
      expect(firstApproverAfter(Role.technician), Role.wcs);
      expect(firstApproverAfter(Role.wcs), Role.lpo);
      expect(firstApproverAfter(Role.lpo), Role.divo);
      expect(firstApproverAfter(Role.divo), isNull, reason: 'top of the ladder');
      expect(firstApproverAfter(Role.dh), isNull, reason: 'above the ladder');
    });
  });
}
