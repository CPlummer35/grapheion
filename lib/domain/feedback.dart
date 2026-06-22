// Grapheion — demo feedback. Anyone using the demo can submit a note; only the
// Kratos super-user can read them and reply. A note is just a synced peat
// document, so it (and Kratos's reply) ride the mesh — incl. the Iroh relay —
// between the demo phones and the owner's macOS.

import 'chain.dart';

class FeedbackNote {
  final String id;
  final String text;
  final String fromId; // submitter's account id (routes the reply back to them)
  final String fromName; // submitter's display name
  final Role fromRole; // submitter's role
  final String context; // the feature/screen they were on when they sent it
  bool read; // Kratos has seen it
  String response; // Kratos's reply ('' = none yet)
  int? respondedAtMs; // when Kratos replied (null = no reply)
  final int createdAtMs;

  FeedbackNote({
    required this.id,
    required this.text,
    required this.fromId,
    required this.fromName,
    required this.fromRole,
    required this.context,
    this.read = false,
    this.response = '',
    this.respondedAtMs,
    required this.createdAtMs,
  });

  bool get hasResponse => response.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'fromId': fromId,
        'fromName': fromName,
        'fromRole': fromRole.token,
        'context': context,
        'read': read,
        'response': response,
        'respondedAtMs': respondedAtMs,
        'createdAtMs': createdAtMs,
      };

  factory FeedbackNote.fromJson(Map<String, dynamic> j) => FeedbackNote(
        id: j['id'] as String,
        text: (j['text'] ?? '') as String,
        fromId: (j['fromId'] ?? '') as String,
        fromName: (j['fromName'] ?? '') as String,
        fromRole: roleFromToken((j['fromRole'] ?? 'technician') as String),
        context: (j['context'] ?? '') as String,
        read: (j['read'] ?? false) as bool,
        response: (j['response'] ?? '') as String,
        respondedAtMs: j['respondedAtMs'] as int?,
        createdAtMs: (j['createdAtMs'] ?? 0) as int,
      );
}
