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
  final eng = Department(id: 'ENG', name: 'Engineering');
  final mdiv = Division(id: 'M', name: 'M Division', departmentId: 'ENG');
  final adiv = Division(id: 'A', name: 'A Division', departmentId: 'ENG');
  return OrgChart(
    departments: {'ENG': eng},
    divisions: {'M': mdiv, 'A': adiv},
    workcenters: {
      'CP01': WorkCenter(id: 'CP01', name: 'Main Propulsion', divisionId: 'M'),
      'CP02': WorkCenter(id: 'CP02', name: 'Aux Machinery', divisionId: 'M'),
      'EA01': WorkCenter(id: 'EA01', name: 'A-Gang', divisionId: 'A'),
    },
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
