// Tests for the MeshStore inbound-apply + query logic — the code that has
// hosted the live regressions. A spy captures notifications.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/casrep.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/job.dart';
import 'package:grapheion/domain/org.dart';
import 'package:grapheion/domain/watch.dart';
import 'package:grapheion/mesh_store.dart';

Account _acct(String id, String name, Role role, {String wc = 'CP01'}) => Account(
      id: id,
      name: name,
      rate: 'MM2',
      role: role,
      workcenterId: wc,
      pinSalt: 's',
      pinHash: 'h',
      createdAtMs: 0,
    );

void main() {
  late MeshStore store;
  late List<String> notes; // captured notification previews

  setUp(() {
    notes = [];
    store = MeshStore(onNotify: (title, preview, peer) => notes.add(preview));
  });

  String jobJson(String id, {int priority = 2, String wc = 'CP01'}) =>
      jsonEncode(Job.originate(
        id: id,
        title: 'Pump leak',
        ein: 'EIN',
        symptom: 'leak',
        priority: priority,
        originator: 'tech',
        workcenter: wc,
        nowMs: 1,
      ).toJson());

  group('applyDoc: jobs', () {
    test('stores a job and notifies on a remote change', () {
      store.account = _acct('me', 'WCS', Role.wcs);
      store.applyDoc(kJobs, 'J1', jobJson('J1'), remote: true);
      expect(store.jobs['J1'], isNotNull);
      expect(notes, isNotEmpty, reason: 'WCS gets a "your turn" ping');
    });
    test('a local change does not notify', () {
      store.account = _acct('me', 'WCS', Role.wcs);
      store.applyDoc(kJobs, 'J1', jobJson('J1'), remote: false);
      expect(notes, isEmpty);
    });
  });

  group('applyDoc: account live-adopt (the regression)', () {
    test('an edit to MY account changes my live role', () {
      store.account = _acct('me', 'Plummdogg', Role.lpo);
      expect(store.role, Role.lpo);
      // Admin reassigns me LPO -> WCS.
      store.applyDoc(kAccounts, 'me',
          jsonEncode(_acct('me', 'Plummdogg', Role.wcs).toJson()),
          remote: true);
      expect(store.role, Role.wcs, reason: 'adopted live, no re-sign-in');
      expect(store.name, 'Plummdogg');
    });
    test('an edit to SOMEONE ELSE does not change my identity', () {
      store.account = _acct('me', 'Me', Role.lpo);
      store.applyDoc(kAccounts, 'other',
          jsonEncode(_acct('other', 'Other', Role.divo).toJson()),
          remote: true);
      expect(store.role, Role.lpo);
      expect(store.accounts['other']?.role, Role.divo);
    });
  });

  group('applyDoc: CASREP must not touch accounts (the phantom-account bug)', () {
    test('a synced CASREP is stored and leaves the directory untouched', () {
      store.account = _acct('me', 'Me', Role.divo);
      final c = Casrep(
        id: 'CR1',
        jobId: 'J1',
        number: '001',
        type: CasrepType.initial,
        hull: 'DDG-51',
        wuc: '24110',
        opImpact: OpImpact.c4,
        etr: '72 HRS',
        narrative: 'leak',
        partsNeeded: '',
        originator: 'DIVO',
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      store.applyDoc(kCasreps, 'CR1', jsonEncode(c.toJson()), remote: true);
      expect(store.casreps['CR1'], isNotNull);
      expect(store.accounts, isEmpty, reason: 'no phantom account injected');
    });
  });

  group('applyDoc: presence', () {
    test('records a peer but skips our own beat', () {
      store.myNodeId = 'self';
      store.applyDoc(kPresence, 'peer1',
          jsonEncode({'nodeId': 'peer1', 'name': 'A', 'role': 'wcs', 'workcenter': 'CP01', 'hb': 5}),
          remote: true);
      store.applyDoc(kPresence, 'self',
          jsonEncode({'nodeId': 'self', 'name': 'Me', 'role': 'divo', 'workcenter': 'CP01', 'hb': 6}),
          remote: true);
      expect(store.presence.keys, ['peer1']);
      expect(store.presence['peer1']!.role, Role.wcs);
    });
  });

  group('ingestEvent dedups', () {
    test('the same audit entry is not added twice', () {
      final e = JobEvent(jobId: 'J1', seq: 1, actor: 'x', role: Role.wcs, action: 'a', comment: '', tsMs: 1);
      store.ingestEvent(e);
      store.ingestEvent(e);
      expect(store.events['J1']!.length, 1);
    });
  });

  group('queries reflect identity + org', () {
    test('canSee falls back to see-all until the org syncs', () {
      store.account = _acct('me', 'Me', Role.wcs, wc: 'CP01');
      final job = Job.fromJson(jsonDecode(jobJson('J1', wc: 'EA01')) as Map<String, dynamic>);
      expect(store.canSee(job), isTrue, reason: 'no org yet -> no filter');
    });
    test('with org synced, a WCS is scoped to its work center', () {
      final seed = seedOrgChart();
      store.org.departments.addAll(seed.departments);
      store.org.divisions.addAll(seed.divisions);
      store.org.workcenters.addAll(seed.workcenters);
      store.account = _acct('me', 'Me', Role.wcs, wc: 'CP01');
      final inWc = Job.fromJson(jsonDecode(jobJson('J1', wc: 'CP01')) as Map<String, dynamic>);
      final otherWc = Job.fromJson(jsonDecode(jobJson('J2', wc: 'EA01')) as Map<String, dynamic>);
      expect(store.canSee(inWc), isTrue);
      expect(store.canSee(otherWc), isFalse);
    });
  });

  group('restoreAccount', () {
    test('adopts the pending account once it syncs in', () {
      store.pendingAccountId = 'me';
      store.applyDoc(kAccounts, 'me',
          jsonEncode(_acct('me', 'Me', Role.lpo).toJson()),
          remote: true);
      expect(store.account?.id, 'me', reason: 'auto-signed in on sync');
    });
  });

  group('watchbill bill entries — last-write-wins (gossip oscillation guard)', () {
    String id() => BillEntry.makeId(0, 'ev', 'r-poow', 's1');
    String entryJson(String person, int t) => jsonEncode(BillEntry(
          id: id(),
          dayMs: 0,
          evolutionId: 'ev',
          roleId: 'r-poow',
          shiftId: 's1',
          personId: person,
          updatedAtMs: t,
        ).toJson());

    test('a newer assignment wins over an older one', () {
      store.applyDoc(kBill, id(), entryJson('alice', 100), remote: true);
      store.applyDoc(kBill, id(), entryJson('bob', 200), remote: true);
      expect(store.billAssignee(0, 'ev', 'r-poow', 's1'), 'bob');
    });

    test('a stale empty tombstone does NOT clobber a newer assignment', () {
      // The bug: a re-gossiped older "unassigned" kept wiping a fresh assignment.
      store.applyDoc(kBill, id(), entryJson('alice', 200), remote: true);
      store.applyDoc(kBill, id(), entryJson('', 100), remote: true); // older empty
      expect(store.billAssignee(0, 'ev', 'r-poow', 's1'), 'alice',
          reason: 'older unassign must be ignored');
    });

    test('a newer unassign does clear an older assignment', () {
      store.applyDoc(kBill, id(), entryJson('alice', 100), remote: true);
      store.applyDoc(kBill, id(), entryJson('', 200), remote: true); // newer empty
      expect(store.billAssignee(0, 'ev', 'r-poow', 's1'), '');
    });
  });
}
