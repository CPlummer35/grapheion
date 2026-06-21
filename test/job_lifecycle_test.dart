// Logic tests for the rest of the job lifecycle: TA (off-ship assistance),
// execution, and the close-out ladder.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/job.dart';

Job _approved() {
  // Walk a fresh job through WCS→LPO→DIVO into execution.
  final j = Job.originate(
    id: 'JOB-2',
    title: 'SSDG fault',
    ein: 'EIN-2',
    symptom: 'fault',
    priority: 1,
    originator: 'tech',
    workcenter: 'CP01',
    nowMs: 1000,
  );
  j.approve(2000); // LPO
  j.approve(3000); // DIVO
  j.approve(4000); // execution
  return j;
}

void main() {
  group('TA (Technical Assistance — DIVO requests off-ship help)', () {
    test('requestTa moves the job off-ship to the Port Engineer', () {
      final j = _approved();
      j.requestTa(5000);
      expect(j.phase, JobPhase.ta);
      expect(j.approver, Role.portEngineer);
      expect(j.taRequested, isTrue);
    });

    test('engageTa brings it back on-ship into execution', () {
      final j = _approved()..requestTa(5000);
      j.engageTa(6000);
      expect(j.phase, JobPhase.execution);
      expect(j.approver, Role.technician);
      expect(j.taRequested, isTrue, reason: 'history flag stays set');
    });

    test('declineTa continues on-ship, flagged returned', () {
      final j = _approved()..requestTa(5000);
      j.declineTa(6000);
      expect(j.phase, JobPhase.execution);
      expect(j.returned, isTrue);
    });
  });

  group('execution', () {
    test('startWork marks the job in-work', () {
      final j = _approved();
      j.startWork(5000);
      expect(j.inWork, isTrue);
      expect(j.phase, JobPhase.execution);
    });

    test('markComplete opens the close-out ladder at WCS', () {
      final j = _approved()..startWork(5000);
      j.markComplete(6000);
      expect(j.phase, JobPhase.closeout);
      expect(j.approver, Role.wcs);
      expect(j.returned, isFalse);
    });
  });

  group('close-out ladder (WCS → LPO → DIVO → closed)', () {
    test('approving the close-out walks the same three rungs, then closes', () {
      final j = _approved()
        ..startWork(5000)
        ..markComplete(6000); // closeout @ WCS

      j.approve(7000);
      expect(j.approver, Role.lpo);
      expect(j.phase, JobPhase.closeout);

      j.approve(8000);
      expect(j.approver, Role.divo);

      j.approve(9000);
      expect(j.phase, JobPhase.closed);
      expect(j.isClosed, isTrue);
    });

    test('rejectCloseout kicks it back to the work center for rework', () {
      final j = _approved()
        ..startWork(5000)
        ..markComplete(6000);
      j.rejectCloseout(7000);
      expect(j.phase, JobPhase.execution);
      expect(j.inWork, isTrue);
      expect(j.returned, isTrue);
    });
  });
}
