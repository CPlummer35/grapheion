// Grapheion — demo feedback, as a two-way thread. Anyone using the demo starts
// a note; the Kratos owner and the submitter then exchange messages on it. Each
// note is one synced peat document, so the whole conversation rides the mesh
// (incl. the Iroh relay) between the demo phones and the owner's macOS.

import 'chain.dart';

/// One message in a feedback thread.
class FeedbackMessage {
  final bool fromOwner; // true = Kratos/owner, false = the submitter
  final String text;
  final int atMs;

  FeedbackMessage(
      {required this.fromOwner, required this.text, required this.atMs});

  Map<String, dynamic> toJson() => {'o': fromOwner, 't': text, 'at': atMs};

  factory FeedbackMessage.fromJson(Map<String, dynamic> j) => FeedbackMessage(
        fromOwner: (j['o'] ?? false) as bool,
        text: (j['t'] ?? '') as String,
        atMs: (j['at'] ?? 0) as int,
      );
}

class FeedbackNote {
  final String id;
  final String fromId; // submitter's account id (routes the thread to them)
  final String fromName; // submitter's display name
  final Role fromRole; // submitter's role
  final String context; // the feature/screen they started it from
  final List<FeedbackMessage> messages; // chronological; [0] = original note
  bool readByOwner; // Kratos has seen the latest message
  bool readBySubmitter; // the submitter has seen the latest message
  final int createdAtMs;

  FeedbackNote({
    required this.id,
    required this.fromId,
    required this.fromName,
    required this.fromRole,
    required this.context,
    required this.messages,
    this.readByOwner = false,
    this.readBySubmitter = true,
    required this.createdAtMs,
  });

  String get preview => messages.isEmpty ? '' : messages.first.text;
  FeedbackMessage? get lastMessage => messages.isEmpty ? null : messages.last;
  bool get hasOwnerReply => messages.any((m) => m.fromOwner);
  int get lastActivityMs => lastMessage?.atMs ?? createdAtMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromId': fromId,
        'fromName': fromName,
        'fromRole': fromRole.token,
        'context': context,
        'messages': messages.map((m) => m.toJson()).toList(),
        'readByOwner': readByOwner,
        'readBySubmitter': readBySubmitter,
        'createdAtMs': createdAtMs,
      };

  factory FeedbackNote.fromJson(Map<String, dynamic> j) => FeedbackNote(
        id: j['id'] as String,
        fromId: (j['fromId'] ?? '') as String,
        fromName: (j['fromName'] ?? '') as String,
        fromRole: roleFromToken((j['fromRole'] ?? 'technician') as String),
        context: (j['context'] ?? '') as String,
        messages: ((j['messages'] as List?) ?? [])
            .map((e) => FeedbackMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
        readByOwner: (j['readByOwner'] ?? false) as bool,
        readBySubmitter: (j['readBySubmitter'] ?? true) as bool,
        createdAtMs: (j['createdAtMs'] ?? 0) as int,
      );
}
