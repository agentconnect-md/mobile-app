import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/api/workspace.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/bubbles.dart';
import '../../core/webchat/attachments.dart';
import '../chat/chat_view.dart';
import 'transcript.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

String taskStateLabel(AppLocalizations l, AgentTask t) => switch (t.state) {
      'open' => l.taskRunning,
      'failed' => l.taskFailed,
      _ => t.threaded ? l.taskIdle : l.taskDone,
    };

/// "● Find what blocks api 1.5      Running" + "↩ 3 replies".
class TaskCard extends StatelessWidget {
  const TaskCard({super.key, required this.task, this.onOpen});
  final AgentTask task;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final t = task;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 2, 40, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Material(
          color: p.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                t.running
                    ? StatusDot(color: p.online, size: 9)
                    : Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.idle, width: 1.5)),
                      ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(t.title.isEmpty ? l.untitled : t.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                ),
                const SizedBox(width: 8),
                Text(taskStateLabel(l, t), style: TextStyle(fontSize: 12, color: p.tertiary)),
              ]),
            ),
          ),
        ),
        if (t.replies > 0 && onOpen != null)
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(AppIcons.reply, size: 15, color: p.brandText),
                const SizedBox(width: 4),
                Text(l.repliesCount(t.replies),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.brandText)),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Opens a task's own thread as a sheet: its messages and a box whose replies
/// go to that task only.
Future<void> openTaskThread(BuildContext context, AgentTask task, {required Agent? agent, required String agentId, required String agentName}) {
  final app = AppScope.read(context);
  return showAppSheet<void>(
    context: context,
    ownClose: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => AppScope(
      state: app,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.86,
        child: TaskThread(task: task, agent: agent, agentId: agentId, agentName: agentName),
      ),
    ),
  );
}

class TaskThread extends StatefulWidget {
  const TaskThread({super.key, required this.task, required this.agent, required this.agentId, required this.agentName});
  final AgentTask task;
  final Agent? agent;
  final String agentId;
  final String agentName;
  @override
  State<TaskThread> createState() => _TaskThreadState();
}

class _TaskThreadState extends State<TaskThread> {
  List<TranscriptItem> _items = [];
  bool _loading = true;
  Object? _error;
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = AppScope.read(context);
      _sub = app.live?.events.listen((e) {
        if (e.sessionId == widget.task.sessionId || e.kind == 'connected') _load(silent: true);
      });
      _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final id = widget.task.sessionId;
    if (id == null) {
      setState(() => _loading = false);
      return;
    }
    final app = AppScope.read(context);
    try {
      final page = await app.client.messages(app.current!.orgId, id);
      if (!mounted) return;
      setState(() {
        _items = buildTranscript(page.messages, {widget.agentId});
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || (silent && _items.isNotEmpty)) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final t = widget.task;
    final meta = [taskStateLabel(l, t), if (t.startedAt != null) l.startedAgo(relativeTime(t.startedAt))].join(' · ');
    Widget body;
    if (_loading) {
      body = const Center(child: Spinner());
    } else if (_error != null && _items.isEmpty) {
      body = StateView(
        icon: _error is ApiException && (_error as ApiException).status == 503 ? AppIcons.cloudOff : AppIcons.errorOutline,
        title: _error is ApiException && (_error as ApiException).status == 503
            ? l.offlineTitle(widget.agentName)
            : errorText(l, _error!),
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    } else {
      body = ChatView(
        agent: widget.agent,
        agentId: widget.agentId,
        agentName: widget.agentName,
        sessionId: t.sessionId,
        anyThread: true,
        hint: l.replyInTask,
        footnote: l.replyInTaskNote,
        // A task's own thread mirrors nowhere: it takes images and files.
        attachPolicy: AttachPolicy.imagesAndFiles,
        header: entriesFromTranscript(_items),
        onTurnDone: () => _load(silent: true),
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Row(children: [
          IconButton(onPressed: () => Navigator.pop(context), icon: Icon(AppIcons.chevronLeft)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title.isEmpty ? l.untitled : t.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              Row(children: [
                StatusDot(color: t.running ? p.online : null, size: 8),
                const SizedBox(width: 6),
                Flexible(child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12))),
              ]),
            ]),
          ),
          IconButton(onPressed: () => Navigator.pop(context), icon: Icon(AppIcons.close)),
        ]),
      ),
      Divider(height: 1, color: p.hairline),
      Expanded(child: body),
    ]);
  }
}
