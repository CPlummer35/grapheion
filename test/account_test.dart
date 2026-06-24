// Logic tests for account PIN auth + admin capability.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/org.dart';

Account _acct(Role role, {String pin = '1234'}) {
  const salt = 'abc123';
  return Account(
    id: 'a1',
    name: 'Tester',
    rate: 'MM2',
    role: role,
    workcenterId: 'CP01',
    pinSalt: salt,
    pinHash: hashPin(salt, pin),
    createdAtMs: 0,
  );
}

void main() {
  group('PIN', () {
    test('accepts the correct PIN', () {
      expect(_acct(Role.wcs, pin: '4242').checkPin('4242'), isTrue);
    });
    test('rejects a wrong PIN', () {
      expect(_acct(Role.wcs, pin: '4242').checkPin('0000'), isFalse);
    });
    test('the hash is salted (same PIN, different salt → different hash)', () {
      expect(hashPin('saltA', '1234'), isNot(hashPin('saltB', '1234')));
    });
  });

  group('admin capability', () {
    test('DIVO and 3-M Coordinator are admins', () {
      expect(_acct(Role.divo).isAdmin, isTrue);
      expect(_acct(Role.threeMC).isAdmin, isTrue);
    });
    test('everyone else is not', () {
      for (final r in [
        Role.technician,
        Role.wcs,
        Role.lpo,
        Role.dh,
        Role.portEngineer,
      ]) {
        expect(_acct(r).isAdmin, isFalse, reason: r.name);
      }
    });
  });
}
