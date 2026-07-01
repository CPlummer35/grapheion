// Tests for the MeshStore inbound-apply + query logic — the code that has
// hosted the live regressions. A spy captures notifications.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/boards.dart';
import 'package:grapheion/domain/casrep.dart';
import 'package:grapheion/domain/chain.dart';
import 'package:grapheion/domain/job.dart';
import 'package:grapheion/domain/org.dart';
import 'package:grapheion/domain/sked.dart';
import 'package:grapheion/domain/supply.dart';
import 'package:grapheion/domain/watch.dart';
import 'package:grapheion/mesh_store.dart';

Account _acct(String id, String name, Role role, {String wc = 'CP01'}) =>
    Account(
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
      jsonEncode(
        Job.originate(
          id: id,
          title: 'Pump leak',
          ein: 'EIN',
          symptom: 'leak',
          priority: priority,
          originator: 'tech',
          workcenter: wc,
          nowMs: 1,
        ).toJson(),
      );

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
      store.applyDoc(
        kAccounts,
        'me',
        jsonEncode(_acct('me', 'Plummdogg', Role.wcs).toJson()),
        remote: true,
      );
      expect(store.role, Role.wcs, reason: 'adopted live, no re-sign-in');
      expect(store.name, 'Plummdogg');
    });
    test('an edit to SOMEONE ELSE does not change my identity', () {
      store.account = _acct('me', 'Me', Role.lpo);
      store.applyDoc(
        kAccounts,
        'other',
        jsonEncode(_acct('other', 'Other', Role.divo).toJson()),
        remote: true,
      );
      expect(store.role, Role.lpo);
      expect(store.accounts['other']?.role, Role.divo);
    });
    test('apply is last-write-wins — a stale rebroadcast cannot oscillate it', () {
      String appyJson(String section, int updated) => jsonEncode(
        (_acct('appy', 'Appy', Role.lpo)
              ..dutySection = section
              ..updatedAtMs = updated)
            .toJson(),
      );
      store.account = _acct('appy', 'Appy', Role.lpo);
      // Assigned to section 1 (newer write) — adopted live.
      store.applyDoc(kAccounts, 'appy', appyJson('1', 2), remote: true);
      expect(store.accounts['appy']!.dutySection, '1');
      expect(store.account!.dutySection, '1', reason: 'adopted live');
      // A stale re-broadcast (older updatedAtMs) must NOT revert it.
      store.applyDoc(kAccounts, 'appy', appyJson('', 1), remote: true);
      expect(store.accounts['appy']!.dutySection, '1', reason: 'stale ignored');
      expect(store.account!.dutySection, '1');
      // A genuinely newer un-assign does apply.
      store.applyDoc(kAccounts, 'appy', appyJson('', 3), remote: true);
      expect(store.accounts['appy']!.dutySection, '');
    });
  });

  group(
    'applyDoc: CASREP must not touch accounts (the phantom-account bug)',
    () {
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
    },
  );

  group('applyDoc: presence', () {
    test('records a peer but skips our own beat', () {
      store.myNodeId = 'self';
      store.applyDoc(
        kPresence,
        'peer1',
        jsonEncode({
          'nodeId': 'peer1',
          'name': 'A',
          'role': 'wcs',
          'workcenter': 'CP01',
          'hb': 5,
        }),
        remote: true,
      );
      store.applyDoc(
        kPresence,
        'self',
        jsonEncode({
          'nodeId': 'self',
          'name': 'Me',
          'role': 'divo',
          'workcenter': 'CP01',
          'hb': 6,
        }),
        remote: true,
      );
      expect(store.presence.keys, ['peer1']);
      expect(store.presence['peer1']!.role, Role.wcs);
    });
  });

  group('ingestEvent dedups', () {
    test('the same audit entry is not added twice', () {
      final e = JobEvent(
        jobId: 'J1',
        seq: 1,
        actor: 'x',
        role: Role.wcs,
        action: 'a',
        comment: '',
        tsMs: 1,
      );
      store.ingestEvent(e);
      store.ingestEvent(e);
      expect(store.events['J1']!.length, 1);
    });
  });

  group('queries reflect identity + org', () {
    test('canSee falls back to see-all until the org syncs', () {
      store.account = _acct('me', 'Me', Role.wcs, wc: 'CP01');
      final job = Job.fromJson(
        jsonDecode(jobJson('J1', wc: 'EA01')) as Map<String, dynamic>,
      );
      expect(store.canSee(job), isTrue, reason: 'no org yet -> no filter');
    });
    test('with org synced, a WCS is scoped to its work center', () {
      final seed = seedOrgChart();
      store.org.departments.addAll(seed.departments);
      store.org.divisions.addAll(seed.divisions);
      store.org.workcenters.addAll(seed.workcenters);
      store.account = _acct('me', 'Me', Role.wcs, wc: 'CP01');
      final inWc = Job.fromJson(
        jsonDecode(jobJson('J1', wc: 'CP01')) as Map<String, dynamic>,
      );
      final otherWc = Job.fromJson(
        jsonDecode(jobJson('J2', wc: 'EA01')) as Map<String, dynamic>,
      );
      expect(store.canSee(inWc), isTrue);
      expect(store.canSee(otherWc), isFalse);
    });
  });

  group('restoreAccount', () {
    test('adopts the pending account once it syncs in', () {
      store.pendingAccountId = 'me';
      store.applyDoc(
        kAccounts,
        'me',
        jsonEncode(_acct('me', 'Me', Role.lpo).toJson()),
        remote: true,
      );
      expect(store.account?.id, 'me', reason: 'auto-signed in on sync');
    });
  });

  group(
    'watchbill bill entries — last-write-wins (gossip oscillation guard)',
    () {
      String id() => BillEntry.makeId(0, 'ev', 'r-poow', 's1');
      String entryJson(String person, int t) => jsonEncode(
        BillEntry(
          id: id(),
          dayMs: 0,
          evolutionId: 'ev',
          roleId: 'r-poow',
          shiftId: 's1',
          personId: person,
          updatedAtMs: t,
        ).toJson(),
      );

      test('a newer assignment wins over an older one', () {
        store.applyDoc(kBill, id(), entryJson('alice', 100), remote: true);
        store.applyDoc(kBill, id(), entryJson('bob', 200), remote: true);
        expect(store.billAssignee(0, 'ev', 'r-poow', 's1'), 'bob');
      });

      test('a stale empty tombstone does NOT clobber a newer assignment', () {
        // The bug: a re-gossiped older "unassigned" kept wiping a fresh assignment.
        store.applyDoc(kBill, id(), entryJson('alice', 200), remote: true);
        store.applyDoc(
          kBill,
          id(),
          entryJson('', 100),
          remote: true,
        ); // older empty
        expect(
          store.billAssignee(0, 'ev', 'r-poow', 's1'),
          'alice',
          reason: 'older unassign must be ignored',
        );
      });

      test('a newer unassign does clear an older assignment', () {
        store.applyDoc(kBill, id(), entryJson('alice', 100), remote: true);
        store.applyDoc(
          kBill,
          id(),
          entryJson('', 200),
          remote: true,
        ); // newer empty
        expect(store.billAssignee(0, 'ev', 'r-poow', 's1'), '');
      });
    },
  );

  group('applyDoc: duty-day events + history queries', () {
    String evJson(
      int day,
      String section,
      String type, {
      String note = '',
      int atMs = 1,
    }) => jsonEncode(
      DutyDayEvent(
        id: DutyDayEvent.makeId(day, section, type),
        dayMs: day,
        section: section,
        type: type,
        note: note,
        atMs: atMs,
      ).toJson(),
    );

    String stoodJson(
      int day,
      String section,
      String role,
      String person, {
      String time = '',
    }) => jsonEncode(
      WatchStood(
        id: '$day|$section|ev|$role|s',
        personId: person,
        stationName: role,
        evolutionName: 'In-Port',
        timeLabel: time,
        dayMs: day,
        section: section,
        atMs: 1,
      ).toJson(),
    );

    test('applies an event and surfaces it scoped to day + section', () {
      final id = DutyDayEvent.makeId(100, '1', 'Flooding');
      store.applyDoc(kEvents, id, evJson(100, '1', 'Flooding'), remote: true);
      expect(store.eventsForDay(100, '1').map((e) => e.type), ['Flooding']);
      expect(store.eventsForDay(100, '2'), isEmpty); // other section
      expect(store.eventsForDay(200, '1'), isEmpty); // other day
    });

    test('LWW by atMs; empty-type record tombstones', () {
      final id = DutyDayEvent.makeId(100, '1', 'Flooding');
      store.applyDoc(
        kEvents,
        id,
        evJson(100, '1', 'Flooding', note: 'a', atMs: 2),
        remote: true,
      );
      store.applyDoc(
        kEvents,
        id,
        evJson(100, '1', 'Flooding', note: 'stale', atMs: 1),
        remote: true,
      );
      expect(store.eventsForDay(100, '1').single.note, 'a', reason: 'older loses');
      store.applyDoc(
        kEvents,
        id,
        jsonEncode(
          DutyDayEvent(
            id: id,
            dayMs: 100,
            section: '1',
            type: '',
            note: '',
            atMs: 3,
          ).toJson(),
        ),
        remote: true,
      );
      expect(store.eventsForDay(100, '1'), isEmpty, reason: 'tombstoned');
    });

    test('recordedDutyDays + stoodForDay group the stood-log by section/day', () {
      store.applyDoc(
        kStood,
        '100|1|ev|ood|s',
        stoodJson(100, '1', 'ood', 'alice', time: '2200-0200'),
        remote: true,
      );
      store.applyDoc(
        kStood,
        '200|1|ev|ood|s',
        stoodJson(200, '1', 'ood', 'bob'),
        remote: true,
      );
      store.applyDoc(
        kStood,
        '100|2|ev|ood|s',
        stoodJson(100, '2', 'ood', 'carol'),
        remote: true,
      );
      expect(store.recordedDutyDays('1'), [200, 100], reason: 'newest first');
      expect(store.recordedDutyDays('2'), [100]);
      expect(store.stoodForDay(100, '1').map((w) => w.personId), ['alice']);
      expect(store.stoodForDay(100, '2').map((w) => w.personId), ['carol']);
    });
  });

  group('applyDoc: watchbill routing notifications', () {
    String routingJson(
      String section,
      BillStatus status, {
      String submittedBy = '',
      String returnedBy = '',
      String note = '',
    }) => jsonEncode(
      WatchbillRouting(
        id: WatchbillRouting.makeId(section),
        section: section,
        status: status,
        submittedBy: submittedBy,
        returnedBy: returnedBy,
        returnedNote: note,
        updatedAtMs: 1,
      ).toJson(),
    );

    test('the CDO of the section is pinged on submit', () {
      store.account = _acct('cdo', 'CDO', Role.lpo)
        ..dutySection = '1'
        ..dutyPosition = DutyPosition.cdo;
      store.applyDoc(
        kRouting,
        '1',
        routingJson('1', BillStatus.submitted, submittedBy: 'sl'),
        remote: true,
      );
      expect(notes, isNotEmpty);
    });

    test('a plain watchstander is NOT pinged on submit', () {
      store.account = _acct('ws', 'WS', Role.lpo)..dutySection = '1';
      store.applyDoc(
        kRouting,
        '1',
        routingJson('1', BillStatus.submitted, submittedBy: 'sl'),
        remote: true,
      );
      expect(notes, isEmpty);
    });

    test('the section leader hears the return reason', () {
      store.account = _acct('sl', 'SL', Role.lpo)
        ..dutySection = '1'
        ..dutyPosition = DutyPosition.sectionLeader;
      store.applyDoc(
        kRouting,
        '1',
        routingJson(
          '1',
          BillStatus.draft,
          submittedBy: 'sl',
          returnedBy: 'cdo',
          note: 'fix the POOW',
        ),
        remote: true,
      );
      expect(notes.last, contains('fix the POOW'));
    });

    test('the whole section hears on approve', () {
      store.account = _acct('m', 'M', Role.technician)..dutySection = '1';
      store.applyDoc(
        kRouting,
        '1',
        routingJson('1', BillStatus.approved),
        remote: true,
      );
      expect(notes, isNotEmpty);
    });

    test('a local change does not notify', () {
      store.account = _acct('cdo', 'CDO', Role.lpo)
        ..dutySection = '1'
        ..dutyPosition = DutyPosition.cdo;
      store.applyDoc(
        kRouting,
        '1',
        routingJson('1', BillStatus.submitted, submittedBy: 'sl'),
        remote: false,
      );
      expect(notes, isEmpty);
    });
  });

  group('pmsCompliance', () {
    PmsCheck mk(String id, Periodicity p, int? lastDays, {required int now}) {
      const day = 86400000;
      return PmsCheck(
        id: id,
        mip: 'M',
        seq: 1,
        title: id,
        ein: '',
        workcenter: 'CP01',
        periodicity: p,
        estMinutes: 0,
        lastDoneMs: lastDays == null ? null : now - lastDays * day,
        lastBy: '',
        createdAtMs: now - 500 * day,
        updatedAtMs: now,
      );
    }

    test('counts not-overdue ÷ total; situational excluded', () {
      final now = 1000 * 86400000;
      store.pmsChecks['a'] = mk('a', Periodicity.weekly, 1, now: now); // ok
      store.pmsChecks['b'] = mk('b', Periodicity.weekly, 30, now: now); // overdue
      store.pmsChecks['c'] = mk('c', Periodicity.situational, null, now: now);
      final (ok, total) = store.pmsCompliance(now);
      expect(total, 2, reason: 'situational has no due date');
      expect(ok, 1, reason: 'the 30-day-old weekly is overdue');
    });

    test('empty (no calendar checks) reads as 0 of 0', () {
      final (ok, total) = store.pmsCompliance(1000 * 86400000);
      expect(total, 0);
      expect(ok, 0);
    });
  });

  group('spot-check (pmsDone)', () {
    PmsCheck chk() => PmsCheck(
      id: 'c',
      mip: 'M',
      seq: 1,
      title: 'Chain',
      ein: '',
      workcenter: 'CP01',
      periodicity: Periodicity.weekly,
      estMinutes: 0,
      lastDoneMs: null,
      lastBy: '',
      createdAtMs: 0,
      updatedAtMs: 0,
    );

    test('awaiting accomplishments surface; verified ones drop off', () {
      store.pmsChecks['c'] = chk();
      final a = PmsAccomplishment(
        id: 'c|0',
        checkId: 'c',
        dayMs: 0,
        by: 'tech',
        atMs: 1,
        updatedAtMs: 1,
      );
      store.pmsDone[a.id] = a;
      expect(store.pendingVerifications().length, 1);
      a.verifiedBy = 'WCS';
      expect(store.pendingVerifications(), isEmpty);
    });

    test('the performer is pinged when their check is kicked back', () {
      store.account = _acct('tech', 'Tech', Role.technician);
      store.pmsChecks['c'] = chk();
      final a = PmsAccomplishment(
        id: 'c|0',
        checkId: 'c',
        dayMs: 0,
        by: 'Tech',
        atMs: 1,
        reworkNote: 'redo it',
        updatedAtMs: 1,
      );
      store.applyDoc(kPmsDone, a.id, jsonEncode(a.toJson()), remote: true);
      expect(notes.last, contains('redo it'));
    });
  });

  group('boards', () {
    BoardCloseout co({String summary = '', int updated = 1}) => BoardCloseout(
      id: BoardCloseout.makeId(1000, 'div-1'),
      weekStartMs: 1000,
      divisionId: 'div-1',
      closedBy: 'DIVO',
      closedAtMs: 1,
      total: 5,
      complete: 3,
      summary: summary,
      updatedAtMs: updated,
    );

    test('the DH is pinged when a board is closed', () {
      store.account = _acct('dh', 'DH', Role.dh);
      store.applyDoc(kBoards, co().id, jsonEncode(co().toJson()), remote: true);
      expect(notes, isNotEmpty);
    });

    test('a technician is not pinged', () {
      store.account = _acct('t', 'T', Role.technician);
      store.applyDoc(kBoards, co().id, jsonEncode(co().toJson()), remote: true);
      expect(notes, isEmpty);
    });

    test('apply is last-write-wins', () {
      store.applyDoc(
        kBoards,
        co().id,
        jsonEncode(co(summary: 'NEW', updated: 100).toJson()),
        remote: true,
      );
      store.applyDoc(
        kBoards,
        co().id,
        jsonEncode(co(summary: 'OLD', updated: 50).toJson()),
        remote: true,
      );
      expect(store.boardCloseouts[co().id]!.summary, 'NEW');
    });
  });

  group('pmschecks LWW', () {
    PmsCheck c(String title, int updated) => PmsCheck(
      id: 'c',
      mip: 'M',
      seq: 1,
      title: title,
      ein: '',
      workcenter: 'CP01',
      periodicity: Periodicity.weekly,
      estMinutes: 0,
      lastDoneMs: null,
      lastBy: '',
      createdAtMs: 0,
      updatedAtMs: updated,
    );

    test('evolutions apply is LWW — an edit does not revert', () {
      Evolution ev(String name, int updated) =>
          Evolution(id: 'ev', name: name, updatedAtMs: updated);
      store.applyDoc(
        kEvolutions,
        'ev',
        jsonEncode(ev('EDITED', 100).toJson()),
        remote: true,
      );
      expect(store.evolutions['ev']!.name, 'EDITED');
      store.applyDoc(
        kEvolutions,
        'ev',
        jsonEncode(ev('OLD', 50).toJson()),
        remote: true,
      );
      expect(
        store.evolutions['ev']!.name,
        'EDITED',
        reason: 'stale rebroadcast must not revert the edit',
      );
    });

    test('a stale rebroadcast cannot revert a fresher check (reload guard)', () {
      store.applyDoc(
        kPmsChecks,
        'c',
        jsonEncode(c('NEW', 100).toJson()),
        remote: true,
      );
      expect(store.pmsChecks['c']!.title, 'NEW');
      store.applyDoc(
        kPmsChecks,
        'c',
        jsonEncode(c('OLD', 50).toJson()),
        remote: true,
      );
      expect(
        store.pmsChecks['c']!.title,
        'NEW',
        reason: 'older updatedAtMs must not overwrite',
      );
      expect(store.pmsChecks['c']!.updatedAtMs, 100);
    });
  });

  group('supply', () {
    SupplyRequest req(SupplyStatus s, {String by = 'tech', int updated = 1}) =>
        SupplyRequest(
          id: 'REQ-1',
          part: 'chain',
          workcenter: 'CP01',
          requestedBy: by,
          status: s,
          createdAtMs: 1,
          updatedAtMs: updated,
        );

    test('order authority: Kratos yes, a plain technician no', () {
      store.account = _acct('k', 'K', Role.kratos);
      expect(store.canProcessSupply, isTrue);
      store.account = _acct('t', 'T', Role.technician);
      expect(store.canProcessSupply, isFalse, reason: 'not in supply dept');
    });

    test('a DIVO is pinged on a new request (not self-pinged)', () {
      store.account = _acct('divo', 'DIVO', Role.divo);
      store.applyDoc(
        kSupply,
        'REQ-1',
        jsonEncode(req(SupplyStatus.requested, by: 'tech').toJson()),
        remote: true,
      );
      expect(notes, isNotEmpty);
    });

    test('the requester hears when the part is ordered', () {
      store.account = _acct('tech', 'Tech', Role.technician);
      store.supplyRequests['REQ-1'] = req(SupplyStatus.divoApproved, by: 'Tech');
      final before = notes.length;
      store.applyDoc(
        kSupply,
        'REQ-1',
        jsonEncode(req(SupplyStatus.ordered, by: 'Tech', updated: 2).toJson()),
        remote: true,
      );
      expect(notes.length, greaterThan(before), reason: 'requester pinged');
      expect(notes.last, contains('chain'));
    });

    test('requestsForJob links parts to their job', () {
      SupplyRequest r(String id, String job) => SupplyRequest(
        id: id,
        part: id,
        workcenter: 'CP01',
        requestedBy: 'x',
        jobId: job,
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      store.supplyRequests['REQ-1'] = r('REQ-1', 'JOB-9');
      store.supplyRequests['REQ-2'] = r('REQ-2', 'JOB-OTHER');
      expect(store.requestsForJob('JOB-9').map((x) => x.id), ['REQ-1']);
      expect(store.requestsForJob(''), isEmpty);
    });

    test('supply apply is last-write-wins', () {
      store.applyDoc(
        kSupply,
        'REQ-1',
        jsonEncode(req(SupplyStatus.ordered, updated: 100).toJson()),
        remote: true,
      );
      store.applyDoc(
        kSupply,
        'REQ-1',
        jsonEncode(req(SupplyStatus.requested, updated: 50).toJson()),
        remote: true,
      );
      expect(store.supplyRequests['REQ-1']!.status, SupplyStatus.ordered);
    });
  });
}
