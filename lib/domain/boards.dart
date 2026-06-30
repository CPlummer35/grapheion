// The weekly PMS "board" close-out — the 3-M ritual where, at the start of a
// work week, the DIVO certifies the prior week's scheduled maintenance for their
// division and accounts to the DH for anything that didn't get done. One
// close-out per division per week; synced LWW.

/// One check that wasn't completed on the board, with the DIVO's explanation.
class BoardIncomplete {
  final String checkId;
  final String label; // MIP/MRC or title snapshot (so it reads even if it moves)
  final String reason; // why it wasn't completed

  BoardIncomplete({
    required this.checkId,
    required this.label,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
    'checkId': checkId,
    'label': label,
    'reason': reason,
  };

  factory BoardIncomplete.fromJson(Map<String, dynamic> j) => BoardIncomplete(
    checkId: (j['checkId'] ?? '') as String,
    label: (j['label'] ?? '') as String,
    reason: (j['reason'] ?? '') as String,
  );
}

class BoardCloseout {
  final String id; // makeId(weekStartMs, divisionId)
  final int weekStartMs; // Monday of the closed week
  final String divisionId;
  String closedBy; // the DIVO who signed it
  int closedAtMs;
  int total; // checks that came due that week
  int complete; // of those, how many were done
  String summary; // overall remark to the DH
  List<BoardIncomplete> incompletes;
  int updatedAtMs;

  BoardCloseout({
    required this.id,
    required this.weekStartMs,
    required this.divisionId,
    required this.closedBy,
    required this.closedAtMs,
    this.total = 0,
    this.complete = 0,
    this.summary = '',
    List<BoardIncomplete>? incompletes,
    required this.updatedAtMs,
  }) : incompletes = incompletes ?? [];

  static String makeId(int weekStartMs, String divisionId) =>
      '$weekStartMs|$divisionId';

  int get incompleteCount => total - complete;

  Map<String, dynamic> toJson() => {
    'id': id,
    'weekStartMs': weekStartMs,
    'divisionId': divisionId,
    'closedBy': closedBy,
    'closedAtMs': closedAtMs,
    'total': total,
    'complete': complete,
    'summary': summary,
    'incompletes': incompletes.map((e) => e.toJson()).toList(),
    'updatedAtMs': updatedAtMs,
  };

  factory BoardCloseout.fromJson(Map<String, dynamic> j) => BoardCloseout(
    id: j['id'] as String,
    weekStartMs: (j['weekStartMs'] ?? 0) as int,
    divisionId: (j['divisionId'] ?? '') as String,
    closedBy: (j['closedBy'] ?? '') as String,
    closedAtMs: (j['closedAtMs'] ?? 0) as int,
    total: (j['total'] ?? 0) as int,
    complete: (j['complete'] ?? 0) as int,
    summary: (j['summary'] ?? '') as String,
    incompletes: (j['incompletes'] as List?)
        ?.map((e) => BoardIncomplete.fromJson(e as Map<String, dynamic>))
        .toList(),
    updatedAtMs: (j['updatedAtMs'] ?? 0) as int,
  );
}
