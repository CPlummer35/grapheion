// Grapheion — accounts, the managed org chart, and role-scoped visibility.
//
// Org hierarchy: Department → Division → Work Center → person (Account). An
// admin (DIVO / 3-M Coordinator) defines the chart and assigns people. Each
// screen then filters jobs to what the signed-in account's role is allowed to
// see (UI-level visibility — the mesh still syncs every doc to every node; this
// is not cryptographic access control).

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chain.dart';

// --- Org chart entities -----------------------------------------------------

class Department {
  final String id;
  String name;
  Department({required this.id, required this.name});
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory Department.fromJson(Map<String, dynamic> j) =>
      Department(id: j['id'] as String, name: (j['name'] ?? '') as String);
}

class Division {
  final String id;
  String name;
  String departmentId;
  Division({required this.id, required this.name, required this.departmentId});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'departmentId': departmentId};
  factory Division.fromJson(Map<String, dynamic> j) => Division(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        departmentId: (j['departmentId'] ?? '') as String,
      );
}

class WorkCenter {
  final String id; // also the code shown to users, e.g. "CP01"
  String name;
  String divisionId;
  WorkCenter({required this.id, required this.name, required this.divisionId});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'divisionId': divisionId};
  factory WorkCenter.fromJson(Map<String, dynamic> j) => WorkCenter(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        divisionId: (j['divisionId'] ?? '') as String,
      );
}

/// In-memory view of the synced org chart, assembled from the per-entity
/// collections. Provides the work-center → division → department lookups the
/// visibility scoping needs.
class OrgChart {
  final Map<String, Department> departments;
  final Map<String, Division> divisions;
  final Map<String, WorkCenter> workcenters;

  OrgChart({
    Map<String, Department>? departments,
    Map<String, Division>? divisions,
    Map<String, WorkCenter>? workcenters,
  })  : departments = departments ?? {},
        divisions = divisions ?? {},
        workcenters = workcenters ?? {};

  Division? divisionOf(String workcenterId) {
    final wc = workcenters[workcenterId];
    return wc == null ? null : divisions[wc.divisionId];
  }

  Department? departmentOf(String workcenterId) {
    final div = divisionOf(workcenterId);
    return div == null ? null : departments[div.departmentId];
  }

  /// Work centers belonging to a division.
  List<WorkCenter> workcentersIn(String divisionId) =>
      workcenters.values.where((w) => w.divisionId == divisionId).toList();

  /// "CP01 · M Division · Engineering" for display.
  String pathOf(String workcenterId) {
    final wc = workcenters[workcenterId];
    if (wc == null) return workcenterId;
    final div = divisions[wc.divisionId];
    final dept = div == null ? null : departments[div.departmentId];
    return [wc.id, div?.name, dept?.name].whereType<String>().join(' · ');
  }
}

/// A seed org chart so a freshly-bootstrapped mesh isn't empty. The admin can
/// extend it. (Generic placeholder structure — not a specific unit.)
OrgChart seedOrgChart() {
  final departments = <String, Department>{};
  final divisions = <String, Division>{};
  final workcenters = <String, WorkCenter>{};

  void dept(String id, String name) =>
      departments[id] = Department(id: id, name: name);
  void div(String id, String name, String deptId) {
    divisions[id] = Division(id: id, name: name, departmentId: deptId);
    // One work center per division as the default assignment target (the
    // watchbill + PQS hang off work centers).
    workcenters['$id-WC'] = WorkCenter(id: '$id-WC', name: name, divisionId: id);
  }

  // CO -> XO -> Department Head -> DIVO.
  dept('EXEC', 'Executive');
  div('X', 'X (Admin)', 'EXEC');
  div('NAV', 'Navigation', 'EXEC');
  div('MED', 'Medical', 'EXEC');

  dept('OPS', 'Operations');
  div('OI', 'OI (CIC)', 'OPS');
  div('OC', 'OC (Comms)', 'OPS');
  div('OW', 'OW (EW)', 'OPS');

  dept('CSYS', 'Combat Systems');
  div('CA', 'CA (Aegis)', 'CSYS');
  div('CE', 'CE (Electronics)', 'CSYS');
  div('CG', 'CG (Ordnance)', 'CSYS');

  dept('WEPS', 'Weapons');
  div('1ST', '1st (Deck)', 'WEPS');
  div('GUN', 'G (Gunnery)', 'WEPS');
  div('ASW', 'AS (Anti-Submarine)', 'WEPS');

  dept('ENG', 'Engineering');
  div('EA', 'A (Auxiliaries)', 'ENG');
  div('EE', 'E (Electrical)', 'ENG');
  div('EM', 'M (Main Propulsion)', 'ENG');
  div('ER', 'R (Repair / DC)', 'ENG');

  dept('SUP', 'Supply');
  div('S1', 'S-1 (Logistics)', 'SUP');
  div('S2', 'S-2 (Food Service)', 'SUP');
  div('S3', 'S-3 (Services)', 'SUP');
  div('S4', 'S-4 (Disbursing)', 'SUP');

  return OrgChart(
    departments: departments,
    divisions: divisions,
    workcenters: workcenters,
  );
}

// --- Accounts ---------------------------------------------------------------

/// A persistent user identity (synced across the mesh), signed into with a PIN.
class Account {
  final String id;
  String name;
  String rate; // rate / rank, e.g. "MM2"
  // The role's WIRE TOKEN is the source of truth, not the enum — so a build that
  // doesn't recognise a token (e.g. an older client seeing a newer role) keeps
  // it verbatim instead of silently downgrading it to technician on re-sync.
  String roleToken;
  String workcenterId;
  String pinSalt;
  String pinHash; // sha256("$salt:$pin") — light auth, not a strong KDF
  String boundNodeId; // device this account is locked to ('' = any); Kratos uses it
  String dutySection; // in-port duty section, e.g. "1".."5" ('' = unassigned)
  String billet; // WQSB billet / assigned position (free text, '' = none)
  final int createdAtMs;

  Account({
    required this.id,
    required this.name,
    required this.rate,
    required Role role,
    required this.workcenterId,
    required this.pinSalt,
    required this.pinHash,
    this.boundNodeId = '',
    this.dutySection = '',
    this.billet = '',
    required this.createdAtMs,
  }) : roleToken = role.token;

  /// The role this build understands (falls back to technician for unknown
  /// tokens — but the original token is preserved in [roleToken]).
  Role get role => roleFromToken(roleToken);
  set role(Role r) => roleToken = r.token;

  bool checkPin(String pin) => hashPin(pinSalt, pin) == pinHash;

  /// Roles that may manage the org chart + accounts.
  bool get isAdmin =>
      role == Role.divo || role == Role.threeMC || role == Role.kratos;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rate': rate,
        'role': roleToken, // preserve the original token verbatim
        'workcenterId': workcenterId,
        'pinSalt': pinSalt,
        'pinHash': pinHash,
        'boundNodeId': boundNodeId,
        'dutySection': dutySection,
        'billet': billet,
        'createdAtMs': createdAtMs,
      };

  factory Account.fromJson(Map<String, dynamic> j) {
    final raw = (j['role'] ?? 'technician') as String;
    return Account(
      id: j['id'] as String,
      name: (j['name'] ?? '') as String,
      rate: (j['rate'] ?? '') as String,
      role: roleFromToken(raw),
      workcenterId: (j['workcenterId'] ?? '') as String,
      pinSalt: (j['pinSalt'] ?? '') as String,
      pinHash: (j['pinHash'] ?? '') as String,
      boundNodeId: (j['boundNodeId'] ?? '') as String,
      dutySection: (j['dutySection'] ?? '') as String,
      billet: (j['billet'] ?? '') as String,
      createdAtMs: (j['createdAtMs'] ?? 0) as int,
    )..roleToken = raw; // preserve the exact token, even if unknown to this build
  }
}

String hashPin(String salt, String pin) =>
    sha256.convert(utf8.encode('$salt:$pin')).toString();

// --- Role-scoped visibility -------------------------------------------------

/// How much of the mesh a role may see.
enum Scope { workcenter, division, department, ship, offship }

Scope scopeForRole(Role r) {
  switch (r) {
    case Role.technician:
    case Role.wcs:
      return Scope.workcenter;
    case Role.lpo:
    case Role.divo:
      return Scope.division;
    case Role.dh:
      return Scope.department;
    case Role.threeMC:
      return Scope.ship;
    case Role.kratos:
      return Scope.ship; // sees everything
    case Role.portEngineer:
      return Scope.offship;
  }
}

String scopeLabel(Role r) {
  switch (scopeForRole(r)) {
    case Scope.workcenter:
      return 'work center';
    case Scope.division:
      return 'division';
    case Scope.department:
      return 'department';
    case Scope.ship:
      return 'ship-wide';
    case Scope.offship:
      return 'off-ship (TA only)';
  }
}

/// Whether a viewer with [role] assigned to [viewerWorkcenterId] may see a job
/// that originated in [jobWorkcenterId], given the org chart and whether the
/// job has an active off-ship TA.
bool canSeeJob({
  required Role role,
  required String viewerWorkcenterId,
  required String jobWorkcenterId,
  required bool jobHasTa,
  required OrgChart org,
}) {
  switch (scopeForRole(role)) {
    case Scope.ship:
      return true;
    case Scope.offship:
      return jobHasTa; // the Port Engineer sees only TA'd jobs
    case Scope.workcenter:
      return jobWorkcenterId == viewerWorkcenterId;
    case Scope.division:
      final a = org.divisionOf(jobWorkcenterId)?.id;
      final b = org.divisionOf(viewerWorkcenterId)?.id;
      return a != null && a == b;
    case Scope.department:
      final a = org.departmentOf(jobWorkcenterId)?.id;
      final b = org.departmentOf(viewerWorkcenterId)?.id;
      return a != null && a == b;
  }
}
