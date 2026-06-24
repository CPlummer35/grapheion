// A duty-section bulletin — a simple post board scoped to one duty section.
// Each post is one synced peat document so the board rides the mesh.

class BulletinPost {
  final String id;
  final String section; // duty section this post belongs to, e.g. "3"
  final String authorId;
  final String authorName; // snapshot, e.g. "BM3 Davis"
  final String text;
  final int atMs;

  BulletinPost({
    required this.id,
    required this.section,
    required this.authorId,
    required this.authorName,
    required this.text,
    required this.atMs,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'section': section,
    'authorId': authorId,
    'authorName': authorName,
    'text': text,
    'atMs': atMs,
  };

  factory BulletinPost.fromJson(Map<String, dynamic> j) => BulletinPost(
    id: j['id'] as String,
    section: (j['section'] ?? '') as String,
    authorId: (j['authorId'] ?? '') as String,
    authorName: (j['authorName'] ?? '') as String,
    text: (j['text'] ?? '') as String,
    atMs: (j['atMs'] ?? 0) as int,
  );
}
