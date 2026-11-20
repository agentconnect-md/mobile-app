import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

Color? sessionDot(Palette p, ActivityState s) => switch (s) {
      ActivityState.working => p.online,
      ActivityState.awaiting => p.paused,
      ActivityState.idle => null,
    };

/// "deploy-bot · #deploys" (agent · where).
String sessionMeta(AppLocalizations l, Conversation c) {
  final agents = <String>{for (final s in c.sessions) if (s.agentName.isNotEmpty) s.agentName};
  final where = c.place ?? sourceName(l, c.source);
  return [agents.join(', '), where].where((x) => x.isNotEmpty).join(' · ');
}

/// One conversation row: avatar with state dot, title, agent · place, time,
/// and (in Sessions) the last reply.
class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.conversation, this.preview = false, this.onTap});
  final Conversation conversation;
  final bool preview;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final c = conversation;
    final s = c.primary;
    final agent = app.orgData?.agent(s.agentId);
    final title = c.title ?? l.untitled;
    final previewText = preview ? app.previews?.of(s) : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(crossAxisAlignment: preview ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
          AgentAvatar(
            iconUrl: agent?.iconUrl,
            runtime: agent?.runtime ?? s.runtime,
            name: s.agentName,
            size: 30,
            dot: sessionDot(p, c.state),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 8),
                Text(listTime(c.lastActivity), style: mono(context, size: 12)),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                if (preview) ...[SourceGlyph(c.source, size: 11), const SizedBox(width: 5)],
                Expanded(
                  child: Text(sessionMeta(l, c),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
                ),
              ]),
              if (preview && s.coordinator)
                Text(l.sessionCoordinator, style: TextStyle(fontSize: 12, color: p.brandText)),
              if (previewText != null) ...[
                const SizedBox(height: 3),
                Text(previewText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: p.secondary)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
