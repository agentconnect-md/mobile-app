import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/bubbles.dart';
import 'transcript.dart';
import '../../ui/icons.dart';

/// A coordinator conversation's main timeline, as the console draws it with
/// threads: thread replies stay off it, each root gets its thread's footer, a
/// message handed to a task says so, and a run of rows the agent wrote in a
/// thread becomes one "In thread: …" line. [open] opens a thread by root id.
List<Entry> threadedEntries(
  List<TranscriptItem> items,
  Map<String, ThreadSummary> threads,
  void Function(String rootId) open,
) {
  final out = <Entry>[];
  String? lastThread;
  for (final i in items) {
    final t = i.thread;
    if (t != null) {
      if (t != lastThread) out.add(InThreadEntry(threads[t]?.rootExcerpt, () => open(t)));
      lastThread = t;
      continue;
    }
    lastThread = null;
    final root = i.postId;
    VoidCallback? reply;
    if (root != null) reply = () => open(root);
    switch (i.kind) {
      case ItemKind.user:
        out.add(UserEntry(i.text, i.senderName,
            postId: root, seq: i.seq, images: i.images, files: i.files, onReplyInThread: reply));
      case ItemKind.agent:
        out.add(AgentEntry(i.text,
            postId: root, seq: i.seq, images: i.images, files: i.files, onReplyInThread: reply));
      default:
        out.addAll(entriesFromTranscript([i]));
    }
    final handed = i.handedTo;
    if (handed != null) {
      final s = threads[handed];
      out.add(HandedEntry(s?.task?.title ?? s?.rootExcerpt, () => open(handed)));
    }
    final footer = threads[root];
    if (footer != null && (footer.replies > 0 || footer.task != null)) {
      out.add(ThreadFooterEntry(footer, () => open(footer.rootId)));
    }
  }
  return out;
}

String threadTaskStateLabel(AppLocalizations l, ThreadTask t) =>
    t.starting ? l.taskStarting : switch (t.state) {
      'open' => l.taskRunning,
      'failed' => l.taskFailed,
      _ => l.taskDone,
    };

/// Under a root: the holding task (state · title), repliers, "N replies",
/// last reply time and the latest reply's first words.
class ThreadFooter extends StatelessWidget {
  const ThreadFooter({super.key, required this.summary, required this.agent, required this.onOpen});
  final ThreadSummary summary;
  final Agent? agent;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final s = summary;
    final task = s.task;
    final last = s.lastReply;
    final lastText = [
      if (last != null && (last.name ?? '').isNotEmpty) '${last.name}:',
      if ((s.lastReplyExcerpt ?? '').isNotEmpty) s.lastReplyExcerpt!,
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 24, 8),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (task != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    task.running || s.running
                        ? StatusDot(color: p.online, size: 8)
                        : Container(
                            width: 8,
                            height: 8,
                            decoration:
                                BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.idle, width: 1.5)),
                          ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.readable && (task.title ?? '').isNotEmpty ? task.title! : l.taskThread,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(threadTaskStateLabel(l, task), style: TextStyle(fontSize: 12, color: p.tertiary)),
                  ]),
                ),
              Row(children: [
                _Repliers(participants: s.participants, agent: agent),
                if (s.participants.isNotEmpty) const SizedBox(width: 8),
                Icon(AppIcons.reply, size: 15, color: p.brandText),
                const SizedBox(width: 4),
                Text(s.replies > 0 ? l.repliesCount(s.replies) : l.replyInThread,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.brandText)),
                if (s.lastReplyAt != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(l.lastReplyAgo(relativeTime(s.lastReplyAt)),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: p.tertiary)),
                  ),
                ],
              ]),
              if (s.readable && lastText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(lastText,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: p.secondary)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Up to three repliers: the agent's icon, or a person's initial.
class _Repliers extends StatelessWidget {
  const _Repliers({required this.participants, required this.agent});
  final List<ThreadSender> participants;
  final Agent? agent;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final shown = participants.take(3).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    const size = 18.0;
    return SizedBox(
      width: size + (shown.length - 1) * 12,
      height: size,
      child: Stack(children: [
        for (var k = 0; k < shown.length; k++)
          Positioned(
            left: k * 12,
            child: shown[k].sender == agent?.id
                ? AgentAvatar(
                    iconUrl: agent?.iconUrl, runtime: agent?.runtime, name: agent?.label ?? '', size: size, showDot: false)
                : Container(
                    width: size,
                    height: size,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: p.brandSoft, shape: BoxShape.circle, border: Border.all(color: p.surface, width: 1.5)),
                    child: Text(
                      _initial(shown[k].name ?? shown[k].sender),
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: p.brandText),
                    ),
                  ),
          ),
      ]),
    );
  }

  static String _initial(String s) => s.trim().isEmpty ? '?' : s.trim().characters.first.toUpperCase();
}

/// A one-line link into a thread ("Replied to a thread: …", "In thread: …").
class ThreadLink extends StatelessWidget {
  const ThreadLink({super.key, required this.icon, required this.text, required this.onOpen});
  final IconData icon;
  final String text;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 24, 6),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(children: [
            Icon(icon, size: 15, color: p.brandText),
            const SizedBox(width: 6),
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.brandText, fontWeight: FontWeight.w500)),
            ),
          ]),
        ),
      ),
    );
  }
}
