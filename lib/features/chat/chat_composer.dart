import 'package:flutter/material.dart';

import '../../core/auth/app_state.dart';
import '../../core/webchat/chat_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';

/// Composer plus live reply stream shown under a transcript.
/// Live items live in memory only and vanish with the screen.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.agentId,
    required this.agentName,
    this.sessionId,
    this.onTurnDone,
  });
  final String agentId;
  final String agentName;
  final String? sessionId;
  final VoidCallback? onTurnDone;
  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _text = TextEditingController();
  ChatController? _chat;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_chat == null) {
      final app = AppScope.read(context);
      _chat = ChatController(
        client: app.client,
        orgId: app.current!.orgId,
        agentId: widget.agentId,
        sessionId: widget.sessionId,
      )..connect();
    }
  }

  @override
  void dispose() {
    _chat?.dispose();
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final t = _text.text;
    if (t.trim().isEmpty) return;
    _chat!.send(t);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: _chat!,
      builder: (context, _) {
        final c = _chat!;
        if (c.conn == ChatConn.readOnly) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: p.sunken,
            child: SafeArea(
                top: false,
                child: Text(l.readOnlyFooter,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.secondary))),
          );
        }
        final status = c.conn == ChatConn.connecting
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
        return Column(mainAxisSize: MainAxisSize.min, children: [
          if (c.items.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.45),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                children: [for (final i in c.items) LiveTile(item: i, chat: c)],
              ),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(status,
                    style: TextStyle(color: p.secondary, fontSize: 13)),
              ),
            ),
          Container(
            decoration: BoxDecoration(
                color: p.surface, border: Border(top: BorderSide(color: p.hairline))),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SafeArea(
              top: false,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                        hintText: l.composerHint(widget.agentName),
                        isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                c.busy
                    ? OutlinedButton(onPressed: c.cancel, child: Text(l.stop))
                    : FilledButton(onPressed: _send, child: Text(l.send)),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

class LiveTile extends StatelessWidget {
  const LiveTile({super.key, required this.item, required this.chat});
  final LiveItem item;
  final ChatController chat;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    switch (item.kind) {
      case LiveKind.user:
      case LiveKind.agent:
        final mine = item.kind == LiveKind.user;
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            constraints:
                BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? p.ink : p.surface,
              borderRadius: BorderRadius.circular(16),
              border: mine ? null : Border.all(color: p.hairline),
            ),
            child: SelectableText(item.text,
                style: TextStyle(color: mine ? p.canvas : p.ink, fontSize: 16)),
          ),
        );
      case LiveKind.thinking:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(item.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: p.secondary, fontStyle: FontStyle.italic, fontSize: 14)),
        );
      case LiveKind.tool:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(Icons.build_outlined, size: 16, color: p.secondary),
            const SizedBox(width: 8),
            Expanded(
                child: Text(l.usedTool(item.text),
                    style: TextStyle(
                        fontFamily: monoFamily,
                        fontFamilyFallback: monoFallback,
                        fontSize: 13,
                        color: p.secondary))),
          ]),
        );
      case LiveKind.notice:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(item.text, style: TextStyle(color: p.secondary, fontSize: 14)),
        );
      case LiveKind.unsupported:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(l.unsupported, style: TextStyle(color: p.secondary, fontSize: 14)),
        );
      case LiveKind.permission:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: p.amberBg, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.text,
                style: TextStyle(
                    fontFamily: monoFamily,
                    fontFamilyFallback: monoFallback,
                    color: p.amberText,
                    fontWeight: FontWeight.w700)),
            if ((item.detail ?? '').isNotEmpty)
              Text(item.detail!,
                  style: TextStyle(
                      fontFamily: monoFamily,
                      fontFamilyFallback: monoFallback,
                      fontSize: 12,
                      color: p.amberText)),
            const SizedBox(height: 8),
            if (item.answered)
              Text(item.allowed == true ? l.allowedOnce : l.denied,
                  style: TextStyle(color: p.amberText))
            else
              Row(children: [
                Expanded(
                    child: FilledButton(
                        onPressed: () => chat.answerPermission(item, true),
                        child: Text(l.approve))),
                const SizedBox(width: 8),
                Expanded(
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: p.ink, foregroundColor: p.canvas),
                        onPressed: () => chat.answerPermission(item, false),
                        child: Text(l.deny))),
              ]),
          ]),
        );
    }
  }
}
