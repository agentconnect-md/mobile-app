import '../../core/webchat/chat_controller.dart';
import 'bubbles.dart';

/// How a live turn joins the stored transcript.
///
/// While a turn streams, the chat shows its own live copy and the stored rows
/// of that turn stay hidden, so nothing is listed twice. Once the turn is
/// over and the stored transcript holds it, the live copy goes and the stored
/// rows take its place.

/// The highest transcript seq among [entries]; null when none carries one.
int? lastSeq(List<Entry> entries) {
  int? last;
  for (final e in entries) {
    final s = entrySeq(e);
    if (s != null && (last == null || s > last)) last = s;
  }
  return last;
}

/// Whether [items] hold part of a turn (a message, reasoning or a tool call),
/// not only cards and notices.
bool hasTurnContent(List<LiveItem> items) => items.any((i) =>
    i.kind == LiveKind.user || i.kind == LiveKind.agent || i.kind == LiveKind.thinking || i.kind == LiveKind.tool);

/// Where the stored rows of live turns begin in [stored]: the first message
/// after seq [mark] (the last one stored when the live chat began). Entries
/// from there on are the live turns' stored copy; `stored.length` when none
/// is stored yet.
int storedBefore(List<Entry> stored, int mark) {
  final at = stored.indexWhere((e) => (entrySeq(e) ?? mark) > mark);
  return at < 0 ? stored.length : at;
}

/// What to show of [stored] beside the live copy: everything before the live
/// turns' stored rows, and after that only messages from people that the
/// live chat doesn't show itself (someone else writing in the conversation).
List<Entry> storedBesideLive(List<Entry> stored, int mark, List<LiveItem> live) {
  final cut = storedBefore(stored, mark);
  if (cut == stored.length) return stored;
  final sent = {
    for (final i in live)
      if (i.kind == LiveKind.user) i.text.trim(),
  };
  return [
    ...stored.take(cut),
    ...stored.skip(cut).where((e) => e is UserEntry && !sent.contains(e.text.trim())),
  ];
}

/// Whether [tail] (the stored rows after the mark) holds the live turns, so
/// the live copy can go.
///
/// The last thing a turn stores is its reply, so the turn is in when [tail]
/// has the last reply streamed since the last message sent. A turn without a
/// reply (stopped, or answered in a thread) is in when [tail] has the message
/// sent and something after it. [waited] says the chat has been quiet for a
/// while: whatever is stored by then is taken as the turn.
bool liveTurnStored(List<Entry> tail, List<LiveItem> live, {required bool waited}) {
  if (tail.isEmpty) return false;
  String? sent;
  String? reply;
  for (final i in live) {
    if (i.kind == LiveKind.user) {
      sent = i.text.trim();
      reply = null;
    } else if (i.kind == LiveKind.agent && i.text.trim().isNotEmpty) {
      reply = i.text.trim();
    }
  }
  if (reply != null) return waited || tail.any((e) => e is AgentEntry && e.text.trim() == reply);
  if (sent == null) return waited;
  final at = tail.lastIndexWhere((e) => e is UserEntry && e.text.trim() == sent);
  return at >= 0 && (waited || at < tail.length - 1);
}
