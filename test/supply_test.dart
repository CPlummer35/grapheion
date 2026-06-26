// Logic tests for supply requisitions (the model + status lifecycle).

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/supply.dart';

void main() {
  group('supply status', () {
    test('token round-trips; unknown defaults to requested', () {
      for (final s in SupplyStatus.values) {
        expect(supplyStatusFromToken(s.token), s);
      }
      expect(supplyStatusFromToken('bogus'), SupplyStatus.requested);
    });

    test('awaiting + open flags drive the chain', () {
      expect(SupplyStatus.requested.awaitingDivo, isTrue);
      expect(SupplyStatus.divoApproved.awaitingSupply, isTrue);
      expect(SupplyStatus.ordered.open, isTrue);
      expect(SupplyStatus.received.open, isTrue);
      expect(SupplyStatus.issued.open, isFalse);
      expect(SupplyStatus.rejected.open, isFalse);
    });
  });

  group('supply request', () {
    test('round-trips with the chain + link fields', () {
      final r = SupplyRequest(
        id: 'REQ-1',
        part: 'Bicycle chain',
        nsn: '1234',
        qty: 2,
        ein: 'BIKE-1',
        workcenter: 'CP01',
        requestedBy: 'MM2 Smith',
        reason: 'PMS BCYL/001-26 W-1: chain wear > 0.75%',
        priority: 2,
        status: SupplyStatus.divoApproved,
        divoBy: 'LT Jones',
        checkId: 'pms-bike-002',
        jobId: 'JOB-9',
        createdAtMs: 10,
        updatedAtMs: 20,
      );
      final back = SupplyRequest.fromJson(r.toJson());
      expect(back.part, 'Bicycle chain');
      expect(back.qty, 2);
      expect(back.status, SupplyStatus.divoApproved);
      expect(back.divoBy, 'LT Jones');
      expect(back.checkId, 'pms-bike-002');
      expect(back.jobId, 'JOB-9');
      expect(back.priority, 2);
    });

    test('a legacy/minimal record decodes with safe defaults', () {
      final back = SupplyRequest.fromJson({
        'id': 'REQ-x',
        'part': 'widget',
        'workcenter': 'CP01',
        'requestedBy': 'me',
      });
      expect(back.qty, 1);
      expect(back.status, SupplyStatus.requested);
      expect(back.priority, 3);
    });
  });
}
