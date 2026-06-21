// Grapheion — the corrective-maintenance approval chain of command.
//
// Standard shipboard path: the maintenance technician originates a job, which
// then climbs the chain rung by rung, the last rung being OFF-SHIP at the port
// engineer (reached over the mesh relay). Each device logs in as one role; the
// device whose role owns a job's current stage may approve (advance) or return
// (send it back down with a comment).

/// A role in the maintenance chain of command.
enum Role {
  technician, // originator — the maintenance person who finds the discrepancy
  wcs, // Work Center Supervisor
  lpo, // Leading Petty Officer
  divo, // Division Officer
  threeMC, // 3-M Coordinator — screens the job into the CSMP
  dh, // Department Head (universal — CHENG/WEPS/OPS/CSO/SUPPO)
  portEngineer, // OFF-SHIP — Regional Maintenance Center; reached over the relay
}

extension RoleInfo on Role {
  /// Full title for the UI.
  String get title {
    switch (this) {
      case Role.technician:
        return 'Maintenance Technician';
      case Role.wcs:
        return 'Work Center Supervisor';
      case Role.lpo:
        return 'Leading Petty Officer';
      case Role.divo:
        return 'Division Officer';
      case Role.threeMC:
        return '3-M Coordinator';
      case Role.dh:
        return 'Department Head';
      case Role.portEngineer:
        return 'Port Engineer (off-ship)';
    }
  }

  /// Short tag for chips/badges.
  String get tag {
    switch (this) {
      case Role.technician:
        return 'TECH';
      case Role.wcs:
        return 'WCS';
      case Role.lpo:
        return 'LPO';
      case Role.divo:
        return 'DIVO';
      case Role.threeMC:
        return '3MC';
      case Role.dh:
        return 'DH';
      case Role.portEngineer:
        return 'PORT ENG';
    }
  }

  /// True for the off-ship rung (its node reaches the ship only over the relay).
  bool get offShip => this == Role.portEngineer;

  /// Stable wire token for JSON. Keyed on the enum name, so do not reorder or
  /// rename variants without a migration.
  String get token => name;
}

Role roleFromToken(String t) =>
    Role.values.firstWhere((r) => r.name == t, orElse: () => Role.technician);

/// On-ship approval ladder a job climbs after the technician submits it
/// (WCS → LPO → DIVO). The same three rungs are reused for the close-out chain.
/// The Port Engineer is NOT on this ladder — the job reaches the PE only when
/// the DIVO raises a Technical Assistance (TA) request for off-ship help.
const List<Role> kApprovalChain = [
  Role.wcs,
  Role.lpo,
  Role.divo,
];

/// The role one rung up from [current], or null if [current] is the last rung
/// (the port engineer — approving there accepts the job off-ship).
Role? nextInChain(Role current) {
  final i = kApprovalChain.indexOf(current);
  if (i < 0 || i + 1 >= kApprovalChain.length) return null;
  return kApprovalChain[i + 1];
}

/// The owner one rung down from [current] — i.e. who a Return sends it back to.
/// Returning from the first chain stage (WCS) sends it to the originating
/// technician.
Role prevOwner(Role current) {
  final i = kApprovalChain.indexOf(current);
  if (i <= 0) return Role.technician;
  return kApprovalChain[i - 1];
}
