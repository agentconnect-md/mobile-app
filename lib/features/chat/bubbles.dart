import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/console_links.dart';
import '../../core/share_links.dart';
import '../../core/webchat/attachments.dart';
import '../../core/webchat/chat_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../../core/api/workspace.dart';
import '../sessions/task_widgets.dart';
import '../sessions/thread_widgets.dart';
import 'attachment_views.dart';
import '../sessions/transcript.dart';
import 'fill_card.dart';
import 'new_divider.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';
import '../../ui/platform.dart';

/// One thing shown in a conversation, from the stored transcript or the live
/// stream. Consecutive tool calls are grouped into "Ran N commands".
sealed class Entry {
  const Entry();
}

class UserEntry extends Entry {
  const UserEntry(this.text, this.name,
      {this.postId, this.seq, this.images = const [], this.files = const [], this.onReplyInThread});
  final String text;
  final String? name;
  final String? postId;
  final List<ImageAttachment> images;
  final List<MarkedFile> files;

  /// Transcript seq (null for live messages): what a message link names.
  final int? seq;

  /// Long press offers "Reply in thread" (a root of a threaded conversation).
  final VoidCallback? onReplyInThread;
}

class AgentEntry extends Entry {
  const AgentEntry(this.text,
      {this.postId, this.seq, this.images = const [], this.files = const [], this.onReplyInThread});
  final String text;
  final String? postId;
  final int? seq;
  final List<ImageAttachment> images;
  final List<MarkedFile> files;
  final VoidCallback? onReplyInThread;
}

/// The footer under a thread's root: replies, repliers, last reply, task.
class ThreadFooterEntry extends Entry {
  const ThreadFooterEntry(this.summary, this.onOpen);
  final ThreadSummary summary;
  final VoidCallback onOpen;
}

/// "Replied to a thread: `<task title>`" under a message handed to a task.
class HandedEntry extends Entry {
  const HandedEntry(this.title, this.onOpen);
  final String? title;
  final VoidCallback onOpen;
}

/// "In thread: `<first words of the root>`" where the agent answered in a thread.
class InThreadEntry extends Entry {
  const InThreadEntry(this.excerpt, this.onOpen);
  final String? excerpt;
  final VoidCallback onOpen;
}

/// The seq a message link names, for entries that have one.
int? entrySeq(Entry e) => switch (e) {
      UserEntry(:final seq) => seq,
      AgentEntry(:final seq) => seq,
      _ => null,
    };

/// A task the agent started, under the message that started it.
class TaskEntry extends Entry {
  const TaskEntry(this.task, this.onOpen);
  final AgentTask task;
  final VoidCallback? onOpen;
}

class ReasoningEntry extends Entry {
  const ReasoningEntry(this.text);
  final String text;
}

class ToolEntry extends Entry {
  const ToolEntry({required this.title, this.status, this.body, this.truncated = false, this.toolCallId});
  final String title;
  final String? status;
  final String? body;
  final bool truncated;
  final String? toolCallId;
}

class NoticeEntry extends Entry {
  const NoticeEntry(this.text);
  final String text;
}

class UnsupportedEntry extends Entry {
  const UnsupportedEntry();
}

class TimeEntry extends Entry {
  const TimeEntry(this.text);
  final String text;
}

/// "New": above the first message that arrived since the conversation was
/// last read on this device.
class NewDividerEntry extends Entry {
  const NewDividerEntry();
}

/// In-stream approval from the live chat (answered with a choice frame).
class LivePermissionEntry extends Entry {
  const LivePermissionEntry(this.item);
  final LiveItem item;
}

/// A Fill card from the live chat (answered with `fill_submit`).
class FillEntry extends Entry {
  const FillEntry(this.item);
  final LiveItem item;
}

class _ToolGroupEntry extends Entry {
  const _ToolGroupEntry(this.tools);
  final List<ToolEntry> tools;
}

List<Entry> entriesFromTranscript(List<TranscriptItem> items) => [
      for (final i in items)
        switch (i.kind) {
          ItemKind.user =>
            UserEntry(i.text, i.senderName, postId: i.postId, seq: i.seq, images: i.images, files: i.files),
          ItemKind.agent => AgentEntry(i.text, postId: i.postId, seq: i.seq, images: i.images, files: i.files),
          ItemKind.reasoning => ReasoningEntry(i.text),
          ItemKind.tool => ToolEntry(
              title: i.text,
              status: i.toolStatus,
              body: i.body,
              truncated: i.truncated,
              toolCallId: i.toolCallId),
          ItemKind.other => const UnsupportedEntry(),
        },
    ];

/// How often [header] holds a user entry with [text].
int userEntryCount(List<Entry> header, String text) {
  final t = text.trim();
  return header.where((e) => e is UserEntry && e.text.trim() == t).length;
}

/// The saved transcript [header] already holds the live chat's last turn: the
/// last message sent live appears more often than the [seenBefore] times it
/// did when it was sent (so an older identical message never counts), with an
/// agent reply after its last occurrence.
bool transcriptHasLiveTurn(List<Entry> header, List<LiveItem> live, {required int seenBefore}) {
  String? sent;
  for (final i in live.reversed) {
    if (i.kind == LiveKind.user) {
      sent = i.text.trim();
      break;
    }
  }
  if (sent == null || userEntryCount(header, sent) <= seenBefore) return false;
  for (var k = header.length - 1; k >= 0; k--) {
    final e = header[k];
    if (e is UserEntry && e.text.trim() == sent) {
      return header.skip(k + 1).any((x) => x is AgentEntry);
    }
  }
  return false;
}

List<Entry> entriesFromLive(List<LiveItem> items, String? myName) => [
      for (final i in items)
        switch (i.kind) {
          LiveKind.user => UserEntry(i.text, myName, images: i.images, files: i.files),
          LiveKind.agent => AgentEntry(i.text, images: i.images, files: i.files),
          LiveKind.thinking => ReasoningEntry(i.text),
          LiveKind.tool => ToolEntry(title: i.text, status: i.status),
          LiveKind.notice => NoticeEntry(i.text),
          LiveKind.permission => LivePermissionEntry(i),
          LiveKind.fill => FillEntry(i),
          LiveKind.unsupported => const UnsupportedEntry(),
        },
    ];

List<Entry> groupTools(List<Entry> input) {
  final out = <Entry>[];
  for (final e in input) {
    if (e is ToolEntry) {
      final last = out.isEmpty ? null : out.last;
      if (last is _ToolGroupEntry) {
        last.tools.add(e);
      } else {
        out.add(_ToolGroupEntry([e]));
      }
    } else if (e is UnsupportedEntry && out.isNotEmpty && out.last is UnsupportedEntry) {
      continue; // one line is enough
    } else {
      out.add(e);
    }
  }
  return out;
}

/// Renders one grouped entry.
class EntryView extends StatelessWidget {
  const EntryView(
      {super.key,
      required this.entry,
      required this.agent,
      this.sessionId,
      this.linkThread,
      this.chat,
      this.highlight = false});
  final Entry entry;
  final Agent? agent;
  final String? sessionId;

  /// The thread these messages are in: their share links name its root.
  final String? linkThread;
  final ChatController? chat;

  /// Briefly marks the message a link landed on.
  final bool highlight;

  Widget _message(BuildContext context, String text, VoidCallback? onReplyInThread, Widget child) {
    final p = context.pal;
    final seq = entrySeq(entry);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () =>
          showMessageMenu(context,
              text: text, sessionId: sessionId, seq: seq, thread: linkThread, onReplyInThread: onReplyInThread),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: highlight ? p.accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final e = entry;
    return switch (e) {
      UserEntry() => _message(context, e.text, e.onReplyInThread,
          _UserBubble(text: e.text, name: e.name, images: e.images, files: e.files)),
      AgentEntry() => _message(context, e.text, e.onReplyInThread,
          _AgentMessage(text: e.text, agent: agent, images: e.images, files: e.files)),
      ThreadFooterEntry() => ThreadFooter(summary: e.summary, agent: agent, onOpen: e.onOpen),
      HandedEntry() => ThreadLink(icon: AppIcons.subdirectoryArrowRight, text: l.repliedToThread(e.title ?? l.untitled), onOpen: e.onOpen),
      InThreadEntry() => ThreadLink(icon: AppIcons.forumOutlined, text: l.inThread(e.excerpt ?? '…'), onOpen: e.onOpen),
      ReasoningEntry() => Padding(
          padding: const EdgeInsets.fromLTRB(42, 2, 16, 6),
          child: Text(e.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.tertiary, fontStyle: FontStyle.italic, fontSize: 13)),
        ),
      _ToolGroupEntry() => ToolGroup(tools: e.tools, sessionId: sessionId),
      NoticeEntry() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Center(child: Text(e.text, textAlign: TextAlign.center, style: mono(context, size: 12))),
        ),
      UnsupportedEntry() => Padding(
          padding: const EdgeInsets.fromLTRB(42, 4, 16, 4),
          child: Text(l.unsupported, style: TextStyle(color: p.secondary, fontSize: 13)),
        ),
      TimeEntry() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(child: Text(e.text, style: mono(context, size: 12))),
        ),
      NewDividerEntry() => const NewDivider(),
      LivePermissionEntry() => _LivePermission(item: e.item, chat: chat, agent: agent),
      FillEntry() => FillCardView(key: ValueKey('fill:${e.item.requestId}'), item: e.item, chat: chat),
      TaskEntry() => TaskCard(task: e.task, onOpen: e.onOpen),
      ToolEntry() => ToolGroup(tools: [e], sessionId: sessionId),
    };
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, this.name, this.images = const [], this.files = const []});
  final String text;
  final String? name;
  final List<ImageAttachment> images;
  final List<MarkedFile> files;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (name != null && name!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: Text(name!, style: TextStyle(fontSize: 12, color: p.tertiary)),
          ),
        if (text.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: p.sunken,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: SelectableText(text, style: TextStyle(fontSize: 15, color: p.ink, height: 1.4)),
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
          child: AttachmentCards(images: images, files: files, alignEnd: true),
        ),
      ]),
    );
  }
}

class _AgentMessage extends StatelessWidget {
  const _AgentMessage({required this.text, required this.agent, this.images = const [], this.files = const []});
  final String text;
  final Agent? agent;
  final List<ImageAttachment> images;
  final List<MarkedFile> files;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final a = agent;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AgentAvatar(iconUrl: a?.iconUrl, runtime: a?.runtime, name: a?.label ?? '', size: 26, showDot: false),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a?.label ?? '',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.agentName)),
            const SizedBox(height: 4),
            if (text.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: p.agentBubble,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.agentBubbleBorder),
                  ),
                  child: SelectableText(text, style: TextStyle(fontSize: 15, color: p.ink, height: 1.4)),
                ),
              ),
            AttachmentCards(images: images, files: files),
          ]),
        ),
      ]),
    );
  }
}

/// "> Ran 2 commands": collapsed by default; each command shows its output
/// preview; a truncated body loads the rest on demand.
class ToolGroup extends StatefulWidget {
  const ToolGroup({super.key, required this.tools, this.sessionId});
  final List<ToolEntry> tools;
  final String? sessionId;
  @override
  State<ToolGroup> createState() => _ToolGroupState();
}

class _ToolGroupState extends State<ToolGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final failed = widget.tools.any((t) => t.status == 'failed');
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 0, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_open ? AppIcons.expandMore : AppIcons.chevronRight, size: 18, color: p.tertiary),
                const SizedBox(width: 4),
                Text(l.ranCommands(widget.tools.length),
                    style: TextStyle(fontSize: 14, color: failed ? p.error : p.secondary)),
              ]),
            ),
          ),
        ),
        if (_open)
          Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Column(children: [
              for (var i = 0; i < widget.tools.length; i++) ...[
                if (i > 0) Divider(height: 1, color: p.hairline),
                _ToolRow(tool: widget.tools[i], sessionId: widget.sessionId),
              ],
            ]),
          ),
      ]),
    );
  }
}

class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.tool, this.sessionId});
  final ToolEntry tool;
  final String? sessionId;
  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _loading = false;
  bool _failed = false;
  String? _full;

  static String pretty(String? b) {
    if (b == null || b.isEmpty) return '';
    try {
      final m = asMap(jsonDecode(b));
      final out = m['rawOutput'] ?? m['output'] ?? m['result'];
      if (out is String) return out;
      final raw = out ?? m['rawInput'];
      if (raw != null) return const JsonEncoder.withIndent('  ').convert(raw);
    } catch (_) {}
    return b;
  }

  Future<void> _showFull() async {
    final id = widget.tool.toolCallId;
    final sid = widget.sessionId;
    if (id == null || sid == null) return;
    final app = AppScope.read(context);
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final buf = StringBuffer();
      int? off = 0;
      var guard = 0;
      while (off != null && guard++ < 50) {
        final c = await app.client.toolBody(app.current!.orgId, sid, id, offset: off);
        buf.write(c.data);
        off = c.nextOffset;
      }
      if (mounted) setState(() => _full = pretty(buf.toString()));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final t = widget.tool;
    final preview = _full ?? pretty(t.body);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('>_', style: mono(context, size: 12, color: t.status == 'failed' ? p.error : p.tertiary)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t.title.isEmpty ? '…' : t.title,
                maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: p.ink)),
          ),
        ]),
        if (preview.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(left: 24),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(6)),
            child: SelectableText(
              _full == null && preview.length > 1200 ? '${preview.substring(0, 1200)}…' : preview,
              style: mono(context, size: 12, color: p.ink),
            ),
          ),
        ],
        if (t.truncated && _full == null && widget.sessionId != null)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: TextButton(onPressed: _loading ? null : _showFull, child: Text(_loading ? l.loadingShort : l.showFull)),
          ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 4),
            child: Text(l.loadRestFailed, style: TextStyle(color: p.error, fontSize: 12)),
          ),
      ]),
    );
  }
}

/// Approval asked inside a live web chat (permission frame).
class _LivePermission extends StatelessWidget {
  const _LivePermission({required this.item, required this.chat, required this.agent});
  final LiveItem item;
  final ChatController? chat;
  final Agent? agent;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final a = agent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppCard(
        leftBar: p.paused,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AgentAvatar(iconUrl: a?.iconUrl, runtime: a?.runtime, name: a?.label ?? '', size: 18, showDot: false),
            const SizedBox(width: 8),
            Expanded(
              child: Text(a?.label ?? '', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            if (item.text.isNotEmpty) Pill(item.text),
          ]),
          if ((item.detail ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(6)),
              child: Text(item.detail!, maxLines: 6, overflow: TextOverflow.ellipsis, style: mono(context, size: 13, color: p.ink)),
            ),
          ],
          const SizedBox(height: 10),
          if (item.answered)
            Row(children: [
              Icon(item.allowed == true ? AppIcons.checkCircleOutline : AppIcons.block,
                  size: 16, color: item.allowed == true ? p.online : p.secondary),
              const SizedBox(width: 6),
              Text(item.allowed == true ? l.allowedOnce : l.denied,
                  style: TextStyle(color: item.allowed == true ? p.online : p.secondary)),
            ])
          else
            Row(children: [
              Expanded(
                  child: OutlinedButton(
                      onPressed: chat == null ? null : () => chat!.answerPermission(item, false), child: Text(l.deny))),
              const SizedBox(width: 6),
              Expanded(
                  child: FilledButton(
                      onPressed: chat == null ? null : () => chat!.answerPermission(item, true), child: Text(l.approve))),
            ]),
        ]),
      ),
    );
  }
}

/// Long press on a message: Reply in thread (on a thread root), Copy, and
/// Share (its console link, when it has a transcript seq and the console is
/// known). A message in a thread links as `?thread=<root>#msg=<seq>`.
Future<void> showMessageMenu(BuildContext context,
    {required String text, String? sessionId, int? seq, String? thread, VoidCallback? onReplyInThread}) async {
  final l = AppLocalizations.of(context);
  final app = AppScope.read(context);
  final canShare = sessionId != null && seq != null && consoleUri(app, '-', 'sessions') != null;
  Haptics.medium();
  final choice = await showActionMenu<String>(context, cancel: l.cancel, actions: [
    if (onReplyInThread != null) MenuAction('reply', AppIcons.forumOutlined, l.replyInThread),
    MenuAction('copy', AppIcons.copyOutlined, l.copyText),
    if (canShare) MenuAction('share', AppIcons.iosShare, l.shareMessage),
  ]);
  switch (choice) {
    case 'reply':
      onReplyInThread?.call();
    case 'copy':
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
      }
    case 'share':
      if (sessionId == null) return;
      final link = sessionLink(app, await currentOrgSlug(app), sessionId, seq: seq, thread: thread);
      if (link == null || !context.mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        uri: link,
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
  }
}
