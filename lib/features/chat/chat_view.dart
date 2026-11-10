import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/webchat/chat_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../home/home_screen.dart' show SendButton;
import 'bubbles.dart';
import 'run_settings.dart';

/// A conversation surface: [header] entries (stored transcript, empty state),
/// then the live chat (in memory only), then the message box.
///
/// The live connection opens on the first send: reading a conversation does
/// not start a chat. A webchat session resumes its conversation; another
/// session continues by its session token; a 403/409 turns the box into a
/// read-only note.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.agent,
    required this.agentId,
    required this.agentName,
    this.sessionId,
    this.conversationId,
    this.header = const [],
    this.headerSliver,
    this.trailing = const [],
    this.firstMessage,
    this.onTurnDone,
    this.model,
    this.hint,
    this.footnote,
    this.runDefaults,
    this.thread,
    this.anyThread = false,
  });

  /// The thread this box writes in (see [ChatController.thread]).
  final String? thread;

  /// A task's own continuation (see [ChatController.anyThread]).
  final bool anyThread;

  /// Message box placeholder (default "Message `agent`…").
  final String? hint;

  /// Small text under the box instead of the run chips ("Goes to this task only").
  final String? footnote;

  /// Shows the model / permission chips and the run settings sheet.
  final RunDefaults? runDefaults;
  final Agent? agent;
  final String agentId;
  final String agentName;
  final String? sessionId;

  /// For a webchat session: the conversation to resume (see [ChatController]).
  final String? conversationId;
  final List<Entry> header;

  /// Shown instead of [header] when set (e.g. the new-chat intro).
  final Widget? headerSliver;

  /// Widgets after the transcript (in-session approval cards).
  final List<Widget> trailing;
  final String? firstMessage;
  final VoidCallback? onTurnDone;
  final String? model;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  ChatController? _chat;
  bool _wasBusy = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    final first = widget.firstMessage;
    if (first != null && first.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(first));
    }
  }

  @override
  void dispose() {
    _chat?.removeListener(_onChat);
    _chat?.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    // The session reloads its transcript when a turn ends; once that includes
    // the live turn, the live copy goes (it would show the turn twice).
    final c = _chat;
    if (c != null &&
        !c.busy &&
        c.items.isNotEmpty &&
        transcriptHasLiveTurn(widget.header, c.items, seenBefore: _sentSeenBefore)) {
      c.dropSettled();
    }
  }

  ChatController _ensure() {
    final existing = _chat;
    if (existing != null) return existing;
    final app = AppScope.read(context);
    final c = ChatController(
      client: app.client,
      orgId: app.current!.orgId,
      agentId: widget.agentId,
      sessionId: widget.sessionId,
      conversationId: widget.conversationId,
      thread: widget.thread,
      anyThread: widget.anyThread,
    )..addListener(_onChat);
    _chat = c;
    c.connect();
    return c;
  }

  void _onChat() {
    final c = _chat!;
    if (_wasBusy && !c.busy) widget.onTurnDone?.call();
    _wasBusy = c.busy;
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  List<String>? _fallbackModels;

  Future<void> _openRun() async {
    final chat = _ensure();
    final d = widget.runDefaults!;
    final a = d.agent;
    if (_fallbackModels == null && a?.daemonId != null) {
      final app = AppScope.read(context);
      try {
        _fallbackModels = await app.client.runtimeModels(app.current!.orgId, a!.daemonId!, a.runtime);
      } catch (_) {
        _fallbackModels = const [];
      }
    }
    if (!mounted) return;
    await showRunSettings(context, chat: chat, defaults: d, fallbackModels: _fallbackModels ?? const []);
  }

  /// How often the transcript already held the last message sent live, when
  /// it was sent: only a newer occurrence is that turn (see [transcriptHasLiveTurn]).
  int _sentSeenBefore = 0;

  void _send([String? text]) {
    final t = (text ?? _text.text).trim();
    if (t.isEmpty) return;
    final chat = _ensure();
    if (!chat.busy) _sentSeenBefore = userEntryCount(widget.header, t);
    chat.send(t);
    if (text == null) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final c = _chat;
    final live = c == null ? const <Entry>[] : entriesFromLive(c.items, app.current?.userName);
    final entries = groupTools([...widget.header, ...live]);
    final status = c == null
        ? null
        : c.conn == ChatConn.connecting && c.busy
            ? l.statusConnecting
            : c.conn == ChatConn.lost
                ? l.statusLost
                : c.waitingApproval
                    ? l.statusWaitingApproval
                    : c.statusLine == 'tool'
                        ? l.usingTool(c.statusTool ?? '')
                        : c.statusLine == 'thinking'
                            ? l.statusThinking
                            : null;
    final readOnly = c?.conn == ChatConn.readOnly;
    return Column(children: [
      Expanded(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            if (widget.headerSliver != null && live.isEmpty) widget.headerSliver!,
            for (final e in entries)
              EntryView(entry: e, agent: widget.agent, sessionId: widget.sessionId, chat: c),
            ...widget.trailing,
            if (status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 6, 0, 0),
                child: Row(children: [
                  SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: p.tertiary)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(status, style: TextStyle(color: p.secondary, fontSize: 13))),
                ]),
              ),
            if (c?.offline == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l.agentOffline(widget.agentName), style: TextStyle(color: p.paused, fontSize: 13)),
              ),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: readOnly
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: p.sunken,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: p.border)),
                  child: Text(l.readOnlyFooter,
                      textAlign: TextAlign.center, style: TextStyle(color: p.secondary, fontSize: 14)),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: p.border),
                    boxShadow: [BoxShadow(color: p.shadow, blurRadius: 3, offset: const Offset(0, 1))],
                  ),
                  padding: const EdgeInsets.fromLTRB(4, 2, 8, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: widget.hint ?? l.messageAgent(widget.agentName),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.fromLTRB(10, 12, 10, 4),
                      ),
                    ),
                    Row(children: [
                      const SizedBox(width: 6),
                      Expanded(
                        child: widget.runDefaults != null && widget.footnote == null
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: RunChips(chat: c, defaults: widget.runDefaults!, onOpen: _openRun),
                              )
                            : Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text(widget.footnote ?? widget.model ?? '',
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
                              ),
                      ),
                      if (c?.busy == true)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(minimumSize: const Size(56, 40)),
                            onPressed: c!.cancel,
                            child: Text(l.stop),
                          ),
                        ),
                      SendButton(enabled: _text.text.trim().isNotEmpty, onPressed: _send),
                    ]),
                  ]),
                ),
        ),
      ),
    ]);
  }
}
