// Logic tests for CASREP category derivation from job priority and the related
// helpers.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/casrep.dart';

void main() {
  group('priority → CASREP category (severity-aligned)', () {
    test('pri 1 = CAT 4 (loss of a primary mission)', () {
      expect(casrepImpactForPriority(1), OpImpact.c4);
      expect(casrepCategoryLabel(1), 'CAT 4');
    });
    test('pri 2 = CAT 3', () {
      expect(casrepImpactForPriority(2), OpImpact.c3);
      expect(casrepCategoryLabel(2), 'CAT 3');
    });
    test('pri 3 = CAT 2 (least severe)', () {
      expect(casrepImpactForPriority(3), OpImpact.c2);
      expect(casrepCategoryLabel(3), 'CAT 2');
    });
  });

  group('CASREP eligibility', () {
    test('priorities 1–3 warrant a CASREP', () {
      expect(casrepEligible(1), isTrue);
      expect(casrepEligible(2), isTrue);
      expect(casrepEligible(3), isTrue);
    });
    test('priority 4 does not', () {
      expect(casrepEligible(4), isFalse);
    });
  });

  group('round-trip', () {
    test('a CASREP serializes and parses back identically', () {
      final c = Casrep(
        id: 'c1',
        jobId: 'JOB-1',
        number: '003',
        type: CasrepType.initial,
        hull: 'DDG-51',
        wuc: '24110',
        opImpact: casrepImpactForPriority(1),
        etr: '72 HRS',
        narrative: 'seal leak',
        partsNeeded: 'NSN 1234',
        originator: 'DIVO',
        createdAtMs: 1000,
        updatedAtMs: 2000,
      );
      final back = Casrep.fromJson(c.toJson());
      expect(back.id, c.id);
      expect(back.number, '003');
      expect(back.type, CasrepType.initial);
      expect(back.opImpact, OpImpact.c4);
      expect(back.hull, 'DDG-51');
      expect(back.etr, '72 HRS');
    });
  });
}
