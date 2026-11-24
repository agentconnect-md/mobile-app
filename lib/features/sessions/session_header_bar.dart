import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/approvals.dart';
import '../../core/api/models.dart';
import '../../core/approvals_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../approvals/approval_card.dart';
import '../nav.dart';
import 'session_tile.dart';

/// One agent in the conversation, for the people menu.
class HeaderAgent {
  const HeaderAgent({required this.session, this.agent, this.focused = false});
  final SessionRow session;
  final Agent? agent;

  /// Its session is the one shown (and whose workspace the panel reads).
  final bool focused;
}

/// The Mac's conversation header, as the web console's session page has it:
/// one row with the state, the title and where it happens (a link to the
/// platform), then the people in it, approval requests waiting, details,
/// share and the side panel's button.
class SessionHeaderBar extends StatelessWidget implements PreferredSizeWidget {
  const SessionHeaderBar({
    super.key,
    required this.title,
    required this.state,
    required this.source,
    this.place,
    this.url,
    this.coordinator = false,
    this.parentId,
    this.parentTitle,
    this.agents = const [],
    this.people = const [],
    this.onFocus,
    this.approvals = const [],
    this.controller,
    this.onDetails,
    this.onShare,
    this.trailing,
    this.meta,
    this.actions = const [],
    this.compact = false,
  });

  /// A thread's header, as the console's thread panel draws it: a 13 pt title.
  final bool compact;

  /// Short facts after the title where a conversation has its place ("8 replies").
  final String? meta;

  /// More buttons before Details and Share (a thread's: open its page, open in Slack, close).
  final List<Widget> actions;
  final String title;
  final ActivityState state;
  final String source;
  final String? place;
  final String? url;
  final bool coordinator;

  /// A task's page: the conversation it belongs to.
  final String? parentId;
  final String? parentTitle;
  final List<HeaderAgent> agents;

  /// The people who wrote in it: (id, name).
  final List<(String, String)> people;

  /// Shows another agent's session of the conversation.
  final ValueChanged<String>? onFocus;
  final List<Approval> approvals;
  final ApprovalsController? controller;
  final VoidCallback? onDetails;
  final VoidCallback? onShare;

  /// The side panel's button.
  final Widget? trailing;

  static const height = 52.0;

  @override
  Size get preferredSize => const Size.fromHeight(height + 1);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final stateText = switch (state) {
      ActivityState.working => l.stateRunning,
      ActivityState.awaiting => l.stateWaiting,
      ActivityState.idle => l.stateIdle,
    };
    final placeText = place ?? sourceName(l, source);
    final link = url;
    final platform = sourceName(l, source);
    // The console's chip: 24 high, 12 pt, a link's color when it opens the platform.
    Widget chip = Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SourceGlyph(source, size: 12),
        const SizedBox(width: 4),
        Flexible(
          child: Text(placeText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: link != null ? p.link : p.secondary)),
        ),
      ]),
    );
    if (link != null) {
      chip = Tooltip(
        message: place != null && platform.isNotEmpty ? l.openPlaceIn(placeText, platform) : l.openIn(platform),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
          child: chip,
        ),
      );
    }
    final pending = approvals.length;
    return Material(
      color: p.canvas,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: height + 1,
          padding: EdgeInsets.only(left: (ModalRoute.of(context)?.canPop ?? false) ? 10 : 16, right: 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.hairline))),
          child: Row(children: [
            // Pushed over another page (a thread over its conversation): back, as the console's chevron.
            if (ModalRoute.of(context)?.canPop ?? false) ...[
              HeaderButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: AppIcons.chevronLeft,
              ),
              const SizedBox(width: 6),
            ],
            Tooltip(
              message: stateText,
              child: Semantics(label: stateText, child: StatusDot(color: sessionDot(p, state), size: 9)),
            ),
            const SizedBox(width: 10),
            Flexible(
              flex: 3,
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: compact
                      ? const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)
                      : const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.17)),
            ),
            if (parentId case final parent?)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: HeaderButton(
                  tooltip: l.taskOfOpen(parentTitle?.trim().isNotEmpty == true ? parentTitle!.trim() : l.untitled),
                  onPressed: () => openSessionPage(context, parent),
                  icon: AppIcons.subdirectoryArrowRight,
                ),
              ),
            const SizedBox(width: 10),
            if (meta case final m? when m.isNotEmpty)
              Flexible(
                flex: 2,
                child: Text(m, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
              )
            else if (placeText.isNotEmpty)
              Flexible(flex: 2, child: chip),
            const Spacer(),
            if (coordinator)
              Tooltip(
                message: l.coordinatorTip,
                child: SizedBox.square(
                  dimension: 26,
                  child: Icon(AppIcons.hubOutlined, size: 15, color: p.tertiary, semanticLabel: l.coordinatorTip),
                ),
              ),
            if (agents.isNotEmpty) _People(agents: agents, people: people, onFocus: onFocus),
            if (pending > 0 && controller != null) _Requests(approvals: approvals, controller: controller!),
            for (final w in [
              ...actions,
              if (onDetails != null) HeaderButton(tooltip: l.details, onPressed: onDetails, icon: AppIcons.infoOutline),
              if (onShare != null) HeaderButton(tooltip: l.shareSession, onPressed: onShare, icon: AppIcons.iosShare),
              ?trailing,
            ]) ...[const SizedBox(width: 4), w],
          ]),
        ),
      ),
    );
  }
}

/// The focused agent's face and up to two people's, opening a menu of the
/// agents (choosing one shows its session) and the people.
class _People extends StatelessWidget {
  const _People({required this.agents, required this.people, this.onFocus});
  final List<HeaderAgent> agents;
  final List<(String, String)> people;
  final ValueChanged<String>? onFocus;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final focused = agents.firstWhere((a) => a.focused, orElse: () => agents.first);
    Widget agentFace(HeaderAgent a, double size) => AgentAvatar(
        iconUrl: a.agent?.iconUrl,
        runtime: a.agent?.runtime,
        name: a.session.agentName,
        size: size,
        showDot: false);
    Widget personFace(String name, double size) => Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.sunken, shape: BoxShape.circle, border: Border.all(color: p.canvas, width: 1.5)),
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w600, color: p.secondary)),
        );
    final names = [for (final a in agents) a.session.agentName, for (final (_, n) in people) n];
    return MenuAnchor(
      alignmentOffset: const Offset(-180, 4),
      menuChildren: [
        _MenuSection(l.headerAgents),
        for (final a in agents)
          MenuItemButton(
            onPressed: agents.length > 1 && !a.focused ? () => onFocus?.call(a.session.sessionId) : null,
            leadingIcon: agentFace(a, 20),
            trailingIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              if (a.focused && agents.length > 1) Icon(AppIcons.check, size: 14, color: p.brandText),
              if (a.agent != null)
                IconButton(
                  tooltip: l.openAgentNamed(a.session.agentName),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => openAgent(context, a.agent!),
                  icon: Icon(AppIcons.northEast, size: 14),
                ),
            ]),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(a.session.agentName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                if (a.focused && (a.agent?.model ?? a.session.model) != null)
                  Text(
                      [a.agent?.model ?? a.session.model, a.agent?.daemonName].whereType<String>().join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 11)),
              ]),
            ),
          ),
        if (people.isNotEmpty) ...[
          _MenuSection(l.headerPeopleSection),
          for (final (_, name) in people)
            MenuItemButton(
              leadingIcon: personFace(name, 20),
              child: Text(name, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ],
      builder: (context, menu, _) => Tooltip(
        message: '${l.headerPeople}: ${names.join(', ')}',
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              agentFace(focused, 22),
              for (final (_, name) in people.take(2))
                Transform.translate(offset: const Offset(-4, 0), child: personFace(name, 22)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MenuSection extends StatelessWidget {
  const _MenuSection(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.pal.tertiary)),
      );
}

/// Approval requests waiting in this conversation: a pill with the count
/// (shield and number, not color alone), opening the requests to decide.
class _Requests extends StatelessWidget {
  const _Requests({required this.approvals, required this.controller});
  final List<Approval> approvals;
  final ApprovalsController controller;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return MenuAnchor(
      alignmentOffset: const Offset(-360, 4),
      menuChildren: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 340),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final a in approvals)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(width: 400, child: ApprovalCard(key: ValueKey(a.id), approval: a, controller: controller)),
                ),
            ]),
          ),
        ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: l.requestsWaiting(approvals.length),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Material(
            color: p.pausedSoft,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => menu.isOpen ? menu.close() : menu.open(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(AppIcons.gppMaybeOutlined, size: 14, color: p.paused),
                  const SizedBox(width: 4),
                  Text('${approvals.length}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.paused)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A header button as the web console draws them: 26 pt square, a 15 pt
/// glyph in a quiet color, a tint on hover; [selected] keeps the tint.
class HeaderButton extends StatelessWidget {
  const HeaderButton(
      {super.key, required this.icon, required this.tooltip, this.onPressed, this.selected = false, this.iconSize = 15, this.badge});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double iconSize;

  /// A count over the glyph (running tasks).
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    Widget glyph = Icon(icon, size: iconSize, color: selected ? p.ink : p.secondary);
    final n = badge;
    if (n != null && n > 0) glyph = Badge(label: Text('$n'), backgroundColor: p.online, child: glyph);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: selected ? p.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox.square(dimension: 26, child: Center(child: glyph)),
          ),
        ),
      ),
    );
  }
}

