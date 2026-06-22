// Logic tests for the feedback model + the Kratos role's permissions.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/feedback.dart';
import 'package:grapheion/domain/org.dart';

void main() {
  test('FeedbackNote round-trips, incl. submitter id + reply', () {
    final f = FeedbackNote(
      id: 'fb-1',
      text: 'The SKED drag-and-drop is slick',
      fromId: 'acct-7',
      fromName: 'LTJG Smith',
      fromRole: Role.divo,
      context: 'SKED',
      read: true,
      response: 'Thanks — glad it lands.',
      respondedAtMs: 456,
      createdAtMs: 123,
    );
    final back = FeedbackNote.fromJson(f.toJson());
    expect(back.text, 'The SKED drag-and-drop is slick');
    expect(back.fromId, 'acct-7');
    expect(back.fromName, 'LTJG Smith');
    expect(back.fromRole, Role.divo);
    expect(back.context, 'SKED');
    expect(back.read, isTrue);
    expect(back.hasResponse, isTrue);
    expect(back.response, 'Thanks — glad it lands.');
    expect(back.respondedAtMs, 456);
    expect(back.createdAtMs, 123);
  });
  test('a fresh note has no response', () {
    final f = FeedbackNote(
      id: 'fb-2',
      text: 'x',
      fromId: 'a',
      fromName: 'n',
      fromRole: Role.technician,
      context: '',
      createdAtMs: 0,
    );
    expect(f.hasResponse, isFalse);
    expect(FeedbackNote.fromJson(f.toJson()).respondedAtMs, isNull);
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
