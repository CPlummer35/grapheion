// Logic tests for role-scoped visibility (who sees which jobs) over the org
// chart.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/org.dart';

void main() {
  // Seed org: ENG dept → M Division (CP01, CP02) + A Division (EA01).
  final org = seedOrgChart();

  bool sees(Role role, String viewerWc, String jobWc, {bool ta = false}) =>
      canSeeJob(
          role: role,
          viewerWorkcenterId: viewerWc,
          jobWorkcenterId: jobWc,
          jobHasTa: ta,
          org: org);

  group('scopeForRole', () {
    test('maps each role to the right scope', () {
      expect(scopeForRole(Role.technician), Scope.workcenter);
      expect(scopeForRole(Role.wcs), Scope.workcenter);
      expect(scopeForRole(Role.lpo), Scope.division);
      expect(scopeForRole(Role.divo), Scope.division);
      expect(scopeForRole(Role.dh), Scope.department);
      expect(scopeForRole(Role.threeMC), Scope.ship);
      expect(scopeForRole(Role.portEngineer), Scope.offship);
    });
  });

  group('org chart lookups', () {
    test('work center resolves to its division and department', () {
      expect(org.divisionOf('CP01')?.id, 'M');
      expect(org.divisionOf('EA01')?.id, 'A');
      expect(org.departmentOf('CP01')?.id, 'ENG');
      expect(org.departmentOf('EA01')?.id, 'ENG');
    });
    test('an unknown work center resolves to nothing', () {
      expect(org.divisionOf('ZZ99'), isNull);
    });
  });

  group('canSeeJob', () {
    test('WCS sees only their own work center', () {
      expect(sees(Role.wcs, 'CP01', 'CP01'), isTrue);
      expect(sees(Role.wcs, 'CP01', 'CP02'), isFalse, reason: 'same div, diff WC');
      expect(sees(Role.wcs, 'CP01', 'EA01'), isFalse);
    });

    test('DIVO/LPO see every work center in their division', () {
      expect(sees(Role.divo, 'CP01', 'CP01'), isTrue);
      expect(sees(Role.divo, 'CP01', 'CP02'), isTrue, reason: 'both M Division');
      expect(sees(Role.divo, 'CP01', 'EA01'), isFalse, reason: 'A Division');
      expect(sees(Role.lpo, 'CP02', 'CP01'), isTrue);
    });

    test('DH sees the whole department (all divisions)', () {
      expect(sees(Role.dh, 'CP01', 'CP01'), isTrue);
      expect(sees(Role.dh, 'CP01', 'EA01'), isTrue,
          reason: 'M and A are both Engineering');
    });

    test('3-M Coordinator sees the whole ship', () {
      expect(sees(Role.threeMC, 'CP01', 'EA01'), isTrue);
      expect(sees(Role.threeMC, 'EA01', 'CP01'), isTrue);
    });

    test('Port Engineer sees only TA-flagged jobs', () {
      expect(sees(Role.portEngineer, 'CP01', 'CP01', ta: false), isFalse);
      expect(sees(Role.portEngineer, 'CP01', 'CP01', ta: true), isTrue);
    });
  });
}
