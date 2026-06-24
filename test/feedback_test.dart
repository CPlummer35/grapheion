// Logic tests for the feedback model + the Kratos role's permissions.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/feedback.dart';
import 'package:grapheion/domain/org.dart';

void main() {
  test('FeedbackNote thread round-trips', () {
    final f = FeedbackNote(
      id: 'fb-1',
      fromId: 'acct-7',
      fromRate: 'LTJG',
      fromRole: Role.divo,
      context: 'SKED',
      messages: [
        FeedbackMessage(fromOwner: false, text: 'SKED is slick', atMs: 100),
        FeedbackMessage(
          fromOwner: true,
          text: 'Thanks — glad it lands',
          atMs: 200,
        ),
        FeedbackMessage(fromOwner: false, text: 'one nit though…', atMs: 300),
      ],
      readByOwner: false,
      readBySubmitter: true,
      createdAtMs: 100,
    );
    final back = FeedbackNote.fromJson(f.toJson());
    expect(back.fromId, 'acct-7');
    expect(back.fromRate, 'LTJG');
    expect(back.context, 'SKED');
    expect(back.messages.length, 3);
    expect(back.preview, 'SKED is slick');
    expect(back.lastMessage?.text, 'one nit though…');
    expect(back.lastMessage?.fromOwner, isFalse);
    expect(back.hasOwnerReply, isTrue);
    expect(back.lastActivityMs, 300);
    expect(back.readByOwner, isFalse);
  });
  test('a fresh thread is just the submitter message, no owner reply', () {
    final f = FeedbackNote(
      id: 'fb-2',
      fromId: 'a',
      fromRate: 'BM3',
      fromRole: Role.technician,
      context: '',
      messages: [FeedbackMessage(fromOwner: false, text: 'x', atMs: 5)],
      createdAtMs: 5,
    );
    expect(f.hasOwnerReply, isFalse);
    final back = FeedbackNote.fromJson(f.toJson());
    expect(back.messages.single.text, 'x');
    expect(back.lastActivityMs, 5);
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
