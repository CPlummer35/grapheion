// Logic tests for the feedback model + the Kratos role's permissions.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/feedback.dart';
import 'package:grapheion/domain/org.dart';

void main() {
  test('FeedbackNote round-trips', () {
    final f = FeedbackNote(
      id: 'fb-1',
      text: 'The SKED drag-and-drop is slick',
      fromName: 'LTJG Smith',
      fromRole: Role.divo,
      context: 'SKED',
      read: false,
      createdAtMs: 123,
    );
    final back = FeedbackNote.fromJson(f.toJson());
    expect(back.text, 'The SKED drag-and-drop is slick');
    expect(back.fromName, 'LTJG Smith');
    expect(back.fromRole, Role.divo);
    expect(back.context, 'SKED');
    expect(back.read, isFalse);
    expect(back.createdAtMs, 123);
  });

  group('Kratos role', () {
    test('round-trips through the role token', () {
      expect(roleFromToken(Role.kratos.token), Role.kratos);
      expect(Role.kratos.tag, 'KRATOS');
      expect(Role.kratos.title, 'Kratos');
    });
    test('has the highest authority — admin + ship-wide visibility', () {
      final acct = Account(
        id: 'a',
        name: 'Owner',
        rate: '',
        role: Role.kratos,
        workcenterId: 'CP01',
        pinSalt: 's',
        pinHash: 'h',
        createdAtMs: 0,
      );
      expect(acct.isAdmin, isTrue);
      expect(scopeForRole(Role.kratos), Scope.ship);
    });
    test('an unknown role token survives a round-trip (no downgrade)', () {
      // A client that doesn't recognise a role must NOT clobber it on re-sync.
      final back = Account.fromJson({
        'id': 'a',
        'name': 'X',
        'rate': '',
        'role': 'someFutureRole',
        'workcenterId': 'CP01',
        'pinSalt': 's',
        'pinHash': 'h',
        'createdAtMs': 0,
      });
      expect(back.role, Role.technician); // display fallback
      expect(back.toJson()['role'], 'someFutureRole'); // token preserved
    });
    test('binds to a device and round-trips that binding', () {
      final k = Account(
        id: 'a',
        name: 'Kratos',
        rate: '',
        role: Role.kratos,
        workcenterId: 'CP01',
        pinSalt: 's',
        pinHash: 'h',
        boundNodeId: 'node-xyz',
        createdAtMs: 0,
      );
      final back = Account.fromJson(k.toJson());
      expect(back.boundNodeId, 'node-xyz');
      expect(back.role, Role.kratos);
    });
  });
}
