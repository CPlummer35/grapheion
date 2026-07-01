// Tests for the evolution watchbill approval chain — the bill climbs the
// command ladder DH → XO → CO, in two phases (plan, then record-with-events).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/org.dart';
import 'package:grapheion/domain/watch.dart';
import 'package:grapheion/mesh_store.dart';

Account _acct(String id, String name, Role role) => Account(
  id: id,
  name: name,
  rate: 'LT',
  role: role,
  workcenterId: 'CP01',
  pinSalt: 's',
  pinHash: 'h',
  createdAtMs: 0,
);

void main() {
  group('command ladder', () {
    test('nextCommand climbs DH → XO → CO → null', () {
      expect(kCommandChain, [Role.dh, Role.xo, Role.co]);
      expect(nextCommand(Role.dh), Role.xo);
      expect(nextCommand(Role.xo), Role.co);
      expect(nextCommand(Role.co), isNull); // CO is the top — approving certifies
      expect(nextCommand(Role.divo), isNull); // not on the command ladder
    });
  });

  group('EvolutionRouting', () {
    test('JSON round-trips (incl. currentRung + approvals)', () {
      final r = EvolutionRouting(
        id: EvolutionRouting.makeId('sea-anchor', 1000),
        evolutionId: 'sea-anchor',
        dayMs: 1000,
        status: BillStatus.submitted,
        currentRung: Role.xo,
        submittedBy: 'coord',
        approvals: ['DH · LT Smith'],
        updatedAtMs: 5,
      );
      final back = EvolutionRouting.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
      );
      expect(back.evolutionId, 'sea-anchor');
      expect(back.status, BillStatus.submitted);
      expect(back.currentRung, Role.xo);
      expect(back.approvals, ['DH · LT Smith']);
    });

    test('a fresh routing defaults to Draft at the DH', () {
      final store = MeshStore(onNotify: (_, _, _) {});
      final r = store.evoRoutingFor('gq', 0);
      expect(r.status, BillStatus.draft);
      expect(r.currentRung, Role.dh);
    });
  });

  group('evoRouting apply', () {
    late MeshStore store;
    late List<String> notes;
    setUp(() {
      notes = [];
      store = MeshStore(onNotify: (t, p, peer) => notes.add(p));
    });

    String routingJson(Role rung, BillStatus s, int updated) => jsonEncode(
      EvolutionRouting(
        id: EvolutionRouting.makeId('sea', 0),
        evolutionId: 'sea',
        dayMs: 0,
        status: s,
        currentRung: rung,
        submittedBy: 'coord',
        updatedAtMs: updated,
      ).toJson(),
    );

    test('LWW — a stale rebroadcast cannot revert the rung', () {
      final id = EvolutionRouting.makeId('sea', 0);
      store.applyDoc(
        kEvoRouting,
        id,
        routingJson(Role.xo, BillStatus.submitted, 100),
        remote: true,
      );
      expect(store.evoRouting[id]!.currentRung, Role.xo);
      store.applyDoc(
        kEvoRouting,
        id,
        routingJson(Role.dh, BillStatus.submitted, 50),
        remote: true,
      );
      expect(
        store.evoRouting[id]!.currentRung,
        Role.xo,
        reason: 'stale rebroadcast must not revert the climb',
      );
    });

    test('the pending rung is notified when the bill lands on them', () {
      store.account = _acct('cap', 'Captain', Role.co);
      store.evolutions['sea'] = Evolution(id: 'sea', name: 'Sea & Anchor');
      final id = EvolutionRouting.makeId('sea', 0);
      store.applyDoc(
        kEvoRouting,
        id,
        routingJson(Role.co, BillStatus.submitted, 10),
        remote: true,
      );
      expect(notes.any((n) => n.contains('CO')), isTrue);
    });

    test('a DH is not notified when the bill is waiting on the XO', () {
      store.account = _acct('cheng', 'CHENG', Role.dh);
      store.evolutions['sea'] = Evolution(id: 'sea', name: 'Sea & Anchor');
      final id = EvolutionRouting.makeId('sea', 0);
      store.applyDoc(
        kEvoRouting,
        id,
        routingJson(Role.xo, BillStatus.submitted, 10),
        remote: true,
      );
      expect(notes, isEmpty);
    });
  });
}
