import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'chat_view.dart';

/// A new web chat with one agent. The transcript lives in memory only.
class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key, required this.agent, this.firstMessage, this.conversationId});
  final Agent agent;
  final String? firstMessage;

  /// The member's coordinator conversation to chat in (it has no session
  /// yet); null starts a fresh chat.
  final String? conversationId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final a = agent;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: navTitleSpacing(context),
        toolbarHeight: 60,
        title: Column(crossAxisAlignment: navTitleAlign, children: [
          Text(l.newChat, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            StatusDot(color: null, size: 8),
            const SizedBox(width: 6),
            Flexible(
              child: Text('${a.label} · ${l.webChat} · ${l.stateIdle}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
            ),
          ]),
        ]),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: AgentAvatar(iconUrl: a.iconUrl, runtime: a.runtime, name: a.label, size: 24, showDot: false),
          ),
        ],
      ),
      body: ChatView(
        agent: a,
        agentId: a.id,
        agentName: a.label,
        model: a.model,
        firstMessage: firstMessage,
        conversationId: conversationId,
        headerSliver: firstMessage == null
            ? SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.55,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      AgentAvatar(iconUrl: a.iconUrl, runtime: a.runtime, name: a.label, size: 48, showDot: false),
                      const SizedBox(height: 14),
                      Text(a.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      if ((a.description ?? '').isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(a.description!,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: p.secondary, height: 1.4)),
                      ],
                    ]),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
