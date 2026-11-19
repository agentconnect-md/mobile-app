import '../../core/api/models.dart';
import '../../core/webchat/attachments.dart';

enum ItemKind { user, agent, reasoning, tool, other }

class TranscriptItem {
  TranscriptItem({
    required this.seq,
    required this.kind,
    required this.text,
    this.sender,
    this.toolCallId,
    this.toolStatus,
    this.body,
    this.truncated = false,
    this.senderName,
    this.ts,
    this.postId,
    this.thread,
    this.handedTo,
    this.images = const [],
    this.files = const [],
  });

  /// The thread root this row replies in (`view=roots`); null at the root.
  final String? thread;

  /// The task thread root this message was handed to.
  final String? handedTo;

  final List<ImageAttachment> images;

  /// Files named in the message's `[attached: …]` marker (cut from [text]).
  final List<MarkedFile> files;

  /// Message id; tasks name the message that started them.
  final String? postId;
  final String? senderName;
  final DateTime? ts;
  final int seq;
  final ItemKind kind;
  final String text;
  final String? sender;
  final String? toolCallId;
  final String? toolStatus;
  String? body;
  bool truncated;
}

/// Maps API messages to display items, sorted by seq. [agentIds] are the
/// sender ids that count as agents.
List<TranscriptItem> buildTranscript(
    Iterable<ApiMessage> messages, Set<String> agentIds) {
  final seen = <int>{};
  final out = <TranscriptItem>[];
  final sorted = messages.toList()..sort((a, b) => a.seq.compareTo(b.seq));
  for (final m in sorted) {
    if (!seen.add(m.seq)) continue;
    final ItemKind k;
    switch (m.kind) {
      case 'text':
        k = agentIds.contains(m.sender) ? ItemKind.agent : ItemKind.user;
      case 'reasoning':
        k = ItemKind.reasoning;
      case 'tool':
        k = ItemKind.tool;
      default:
        k = ItemKind.other;
    }
    var text = m.text;
    var files = const <MarkedFile>[];
    if (k == ItemKind.user || k == ItemKind.agent) (text, files) = splitFilesMarker(text);
    out.add(TranscriptItem(
      seq: m.seq,
      kind: k,
      text: text,
      images: m.images,
      files: files,
      sender: m.sender,
      toolCallId: m.toolCallId,
      toolStatus: m.toolStatus,
      body: m.body,
      truncated: m.bodyTruncated,
      senderName: m.senderName,
      ts: m.ts,
      postId: m.postId,
      thread: m.thread,
      handedTo: m.handedTo,
    ));
  }
  return out;
}

/// Merges a refreshed newest page of a thread into [loaded]. The newest page
/// always carries the pinned root (postId [rootId], the thread's lowest seq)
/// plus the newest replies, so the page boundary is the lowest *reply* seq on
/// it: rows loaded earlier below that boundary (older pages) are kept, the
/// rest are replaced by [fresh]. `keptOlder` says whether any older reply
/// survived, so the caller keeps its older-page cursor instead of resetting.
({List<TranscriptItem> items, bool keptOlder}) mergeThreadPage(
    List<TranscriptItem> loaded, List<TranscriptItem> fresh, String rootId) {
  final seqs = fresh.map((e) => e.seq).toSet();
  int? boundary;
  for (final e in fresh) {
    if (e.postId == rootId) continue;
    if (boundary == null || e.seq < boundary) boundary = e.seq;
  }
  final kept = boundary == null
      ? const <TranscriptItem>[]
      : loaded.where((e) => e.postId != rootId && !seqs.contains(e.seq) && e.seq < boundary!).toList();
  return (
    items: [...kept, ...fresh]..sort((a, b) => a.seq.compareTo(b.seq)),
    keptOlder: kept.isNotEmpty,
  );
}

/// Whether a thread's loaded pages reach back to the message [seq] a link
/// names. The root is always on the newest page, so it doesn't count.
bool threadReaches(List<TranscriptItem> items, String rootId, int seq) =>
    items.any((e) => e.seq == seq || (e.postId != rootId && e.seq <= seq));

/// Merges a refreshed newest page of the main timeline into [loaded], so
/// pages loaded with "Load earlier" stay. Rows from the page's lowest seq up
/// are replaced by [fresh] (tool rows change in place); older rows are kept
/// when the page reaches back into them. `keptOlder` is false when [fresh]
/// stands alone: it is the whole conversation ([freshHasOlder] false), nothing
/// older was loaded, or so much arrived that rows may be missing in between;
/// the caller then pages back from the fresh page's own cursor.
({List<TranscriptItem> items, bool keptOlder}) mergeNewestPage(
    List<TranscriptItem> loaded, List<TranscriptItem> fresh,
    {required bool freshHasOlder}) {
  if (fresh.isEmpty || !freshHasOlder || loaded.isEmpty) return (items: fresh, keptOlder: false);
  final boundary = fresh.first.seq;
  final kept = loaded.where((e) => e.seq < boundary).toList();
  // No loaded row at or above the boundary: the page starts past what is loaded.
  if (kept.isEmpty || kept.length == loaded.length) return (items: fresh, keptOlder: false);
  return (items: [...kept, ...fresh], keptOlder: true);
}
