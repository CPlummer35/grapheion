// Supply requisitions — the logistics loop with an approval chain. A work center
// requests a part (often off a PMS discrepancy or corrective job); the DIVO
// approves it to release it to Supply; Supply approves (= orders the part), then
// receives and issues it back. Either approver can reject with a reason. One
// request per id; synced LWW.

/// Lifecycle of a supply request.
enum SupplyStatus {
  requested, // WC submitted — awaiting DIVO approval
  divoApproved, // DIVO released it — awaiting Supply
  ordered, // Supply approved + ordered the part
  received, // part received
  issued, // issued back to the WC (closed)
  rejected, // rejected by DIVO or Supply (see rejectReason)
}

extension SupplyStatusInfo on SupplyStatus {
  String get token => name;

  String get label => switch (this) {
    SupplyStatus.requested => 'Awaiting DIVO',
    SupplyStatus.divoApproved => 'Awaiting Supply',
    SupplyStatus.ordered => 'On order',
    SupplyStatus.received => 'Received',
    SupplyStatus.issued => 'Issued',
    SupplyStatus.rejected => 'Rejected',
  };

  /// Still in the pipeline (not yet issued or rejected).
  bool get open =>
      this != SupplyStatus.issued && this != SupplyStatus.rejected;

  bool get awaitingDivo => this == SupplyStatus.requested;
  bool get awaitingSupply => this == SupplyStatus.divoApproved;
}

SupplyStatus supplyStatusFromToken(String t) => SupplyStatus.values.firstWhere(
  (s) => s.name == t,
  orElse: () => SupplyStatus.requested,
);

class SupplyRequest {
  final String id;
  String part; // what's needed, e.g. "Bicycle chain"
  String nsn; // National Stock Number (optional)
  int qty;
  String ein; // equipment it's for
  String workcenter; // requesting work center
  String requestedBy;
  String reason; // why (e.g. "PMS discrepancy: chain wear > 0.75%")
  int priority; // 1 (highest) .. 4 (routine)
  SupplyStatus status;
  String divoBy; // DIVO who approved ('' = not yet)
  String orderedBy; // supply person who ordered/handled it ('' = none yet)
  String rejectedBy; // DIVO or supply who rejected ('' = not rejected)
  String rejectReason;
  String checkId; // linked PMS check ('' = none)
  String jobId; // linked corrective job ('' = none)
  final int createdAtMs;
  int updatedAtMs;

  SupplyRequest({
    required this.id,
    required this.part,
    this.nsn = '',
    this.qty = 1,
    this.ein = '',
    required this.workcenter,
    required this.requestedBy,
    this.reason = '',
    this.priority = 3,
    this.status = SupplyStatus.requested,
    this.divoBy = '',
    this.orderedBy = '',
    this.rejectedBy = '',
    this.rejectReason = '',
    this.checkId = '',
    this.jobId = '',
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  static String makeId(int nowMs) => 'REQ-$nowMs';

  Map<String, dynamic> toJson() => {
    'id': id,
    'part': part,
    'nsn': nsn,
    'qty': qty,
    'ein': ein,
    'workcenter': workcenter,
    'requestedBy': requestedBy,
    'reason': reason,
    'priority': priority,
    'status': status.token,
    'divoBy': divoBy,
    'orderedBy': orderedBy,
    'rejectedBy': rejectedBy,
    'rejectReason': rejectReason,
    'checkId': checkId,
    'jobId': jobId,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory SupplyRequest.fromJson(Map<String, dynamic> j) => SupplyRequest(
    id: j['id'] as String,
    part: (j['part'] ?? '') as String,
    nsn: (j['nsn'] ?? '') as String,
    qty: (j['qty'] ?? 1) as int,
    ein: (j['ein'] ?? '') as String,
    workcenter: (j['workcenter'] ?? '') as String,
    requestedBy: (j['requestedBy'] ?? '') as String,
    reason: (j['reason'] ?? '') as String,
    priority: (j['priority'] ?? 3) as int,
    status: supplyStatusFromToken((j['status'] ?? 'requested') as String),
    divoBy: (j['divoBy'] ?? '') as String,
    orderedBy: (j['orderedBy'] ?? '') as String,
    rejectedBy: (j['rejectedBy'] ?? '') as String,
    rejectReason: (j['rejectReason'] ?? '') as String,
    checkId: (j['checkId'] ?? '') as String,
    jobId: (j['jobId'] ?? '') as String,
    createdAtMs: (j['createdAtMs'] ?? 0) as int,
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}
