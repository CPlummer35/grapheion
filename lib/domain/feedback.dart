// Grapheion — demo feedback. Anyone using the demo can submit a note; only the
// Kratos super-user can read them. A note is just a synced peat document, so it
// rides the mesh (incl. the Iroh relay) to the owner's macOS like anything else.

import 'chain.dart';

class FeedbackNote {
  final String id;
  final String text;
  final String fromName; // submitter's display name
  final Role fromRole; // submitter's role
  final String context; // the feature/screen they were on when they sent it
  bool read; // Kratos has seen it
  final int createdAtMs;

  FeedbackNote({
    required this.id,
    required this.text,
    required this.fromName,
    required this.fromRole,
    required this.context,
    this.read = false,
    required this.createdAtMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'fromName': fromName,
        'fromRole': fromRole.token,
        'context': context,
        'read': read,
        'createdAtMs': createdAtMs,
      };

  factory FeedbackNote.fromJson(Map<String, dynamic> j) => FeedbackNote(
        id: j['id'] as String,
        text: (j['text'] ?? '') as String,
        fromName: (j['fromName'] ?? '') as String,
        fromRole: roleFromToken((j['fromRole'] ?? 'technician') as String),
        context: (j['context'] ?? '') as String,
        read: (j['read'] ?? false) as bool,
        createdAtMs: (j['createdAtMs'] ?? 0) as int,
      );
}
