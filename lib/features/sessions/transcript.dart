import '../../core/api/models.dart';

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
  });
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
    out.add(TranscriptItem(
      seq: m.seq,
      kind: k,
      text: m.text,
      sender: m.sender,
      toolCallId: m.toolCallId,
      toolStatus: m.toolStatus,
      body: m.body,
      truncated: m.bodyTruncated,
      senderName: m.senderName,
      ts: m.ts,
    ));
  }
  return out;
}
