import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

// The Sessions filter, as in the design and the web console: Agent / Integration /
// Channel / Trigger, each listing what `/sessions/facets` says the list can be
// narrowed by. Four dropdowns sit under the app bar; each opens a sheet with a
// search field and one radio row per value.

/// What an option shows in front of its label.
sealed class FilterMark {
  const FilterMark();
}

class AgentMark extends FilterMark {
  const AgentMark({this.agent, required this.name});
  final Agent? agent;
  final String name;
}

/// A platform glyph; [source] as in [sourceOf] (slack, github, chat, …).
class SourceMark extends FilterMark {
  const SourceMark(this.source);
  final String source;
}

class IconMark extends FilterMark {
  const IconMark(this.icon);
  final IconData icon;
}

/// A person's initials in a round avatar.
class PersonMark extends FilterMark {
  const PersonMark(this.name);
  final String name;
}

/// Trigger options are listed under these headers.
enum TriggerGroup { agents, people, schedules, events }

class FilterOption {
  const FilterOption(this.value, this.label, this.mark, {this.group});
  final String value;
  final String label;
  final FilterMark mark;
  final TriggerGroup? group;
}

/// Glyph for a facet's `integration` (a platform, or a code host for hooks).
String integrationSource(String integration) => switch (integration) {
      'gitlab' || 'gitea' => 'github',
      _ => sourceOf(integration),
    };

IconData? _integrationIcon(String integration) => switch (integration) {
      'schedule' => Icons.timer_outlined,
      'dream' => Icons.nights_stay_outlined,
      'hook' => Icons.webhook,
      _ => null,
    };

FilterMark _integrationMark(String integration) {
  final icon = _integrationIcon(integration);
  return icon != null ? IconMark(icon) : SourceMark(integrationSource(integration));
}

String _hookLabel(AppLocalizations l, String? kind) => switch (kind) {
      'github' => l.sourceGitHub,
      'gitlab' => 'GitLab',
      'gitea' => 'Gitea',
      _ => l.filterWebhook,
    };

String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _schedule(AppLocalizations l, String id) =>
    '${l.filterSchedule} ${id.length > 8 ? id.substring(0, 8) : id}';

/// Integration names as the console's `platName`, with the app's "Web chat".
String integrationLabel(AppLocalizations l, String integration) {
  final x = integration.toLowerCase();
  return switch (x) {
    'webchat' || 'playground' => l.webChat,
    'slack' => l.sourceSlack,
    'telegram' => l.sourceTelegram,
    'discord' => l.sourceDiscord,
    'feishu' || 'lark' => l.sourceFeishu,
    'github' || 'gitlab' || 'gitea' => _hookLabel(l, x),
    'hook' => l.filterWebhook,
    'dream' => l.filterMemoryDream,
    '' => l.sourceSlack,
    _ when x.contains('sched') => l.filterSchedule,
    _ => _capitalized(integration),
  };
}

/// Channel names as the console's `sessionChannelLabel`.
String channelLabel(AppLocalizations l, ChannelFacet c) {
  if (c.value.startsWith('cron:')) return c.name?.trim().isNotEmpty == true ? c.name!.trim() : _schedule(l, c.value.substring(5));
  final name = c.name?.trim();
  switch (c.platform) {
    case 'webchat':
      return l.webChat;
    case 'dream':
      return l.filterMemory;
    case 'hook':
      return name != null && name.isNotEmpty ? name : _hookLabel(l, c.integration);
  }
  if (name != null && name.isNotEmpty) {
    final sigil = c.platform == 'slack' || c.platform == 'discord' ? '#' : '';
    return name.startsWith('@') ? name : '$sigil$name';
  }
  if (c.platform == 'slack' && c.value.startsWith('D')) {
    final who = c.triggeredByName?.trim();
    return who != null && who.isNotEmpty ? '@$who' : l.filterDm;
  }
  return c.value;
}

int _byLabel(FilterOption a, FilterOption b) => a.label.toLowerCase().compareTo(b.label.toLowerCase());

/// The options for one facet, without "All", in display order (triggers
/// grouped: agents, people, schedules, events). [selected] is kept even when
/// the facets don't list it (stale facets), so the active value never disappears.
List<FilterOption> filterOptions(
  AppLocalizations l,
  SessionFacet facet,
  SessionFacets f, {
  List<Agent> agents = const [],
  String? userId,
  String? userName,
  String? selected,
}) {
  final byId = {for (final a in agents) a.id: a};
  final List<FilterOption> opts;
  switch (facet) {
    case SessionFacet.agent:
      final ids = f.agents.toSet();
      opts = [
        for (final a in agents)
          if (ids.contains(a.id)) FilterOption(a.id, a.label, AgentMark(agent: a, name: a.label)),
        for (final id in f.agents)
          if (!byId.containsKey(id) && f.agentNames[id] != null)
            FilterOption(id, f.agentNames[id]!, AgentMark(name: f.agentNames[id]!)),
      ];
    case SessionFacet.integration:
      opts = [
        for (final i in f.integrations.toSet()) FilterOption(i, integrationLabel(l, i), _integrationMark(i)),
      ];
    case SessionFacet.channel:
      final seen = <String>{};
      opts = [
        for (final c in f.channels)
          if (seen.add(c.platform == 'webchat' ? SessionFilters.webchatChannel : c.value))
            FilterOption(
              c.platform == 'webchat' ? SessionFilters.webchatChannel : c.value,
              channelLabel(l, c),
              c.value.startsWith('cron:') ? const IconMark(Icons.timer_outlined) : _integrationMark(c.integration),
            ),
      ];
    case SessionFacet.trigger:
      final agentOpts = <FilterOption>[];
      final people = <FilterOption>[];
      final hooks = <FilterOption>[];
      final schedules = <FilterOption>[];
      final seen = <String>{};
      for (final t in f.triggers) {
        final v = t.filterValue;
        if (!seen.add(v)) continue;
        final name = t.name?.trim();
        final named = name != null && name.isNotEmpty;
        if (t.value.startsWith('cron:')) {
          schedules.add(FilterOption(v, named ? name : _schedule(l, t.value.substring(5)),
              const IconMark(Icons.timer_outlined),
              group: TriggerGroup.schedules));
        } else if (t.value.startsWith('hook:')) {
          final kind = t.hookKind ?? 'webhook';
          final source = _hookLabel(l, kind);
          hooks.add(FilterOption(v, named ? '$source · $name' : source,
              kind == 'webhook' ? const IconMark(Icons.webhook) : const SourceMark('github'),
              group: TriggerGroup.events));
        } else if (byId[t.value] case final a?) {
          agentOpts.add(FilterOption(v, a.label, AgentMark(agent: a, name: a.label), group: TriggerGroup.agents));
        } else {
          final self = t.value == '@you' ||
              (userId != null && userId.isNotEmpty && t.value == userId) ||
              (userName != null && userName.isNotEmpty && t.value == userName);
          final who = named ? name : (self && userName != null && userName.isNotEmpty ? userName : t.value);
          people.add(FilterOption(v, self ? l.filterMe(who) : who, PersonMark(who), group: TriggerGroup.people));
        }
      }
      opts = [
        ...(agentOpts..sort(_byLabel)),
        ...(people..sort(_byLabel)),
        ...(schedules..sort(_byLabel)),
        ...(hooks..sort(_byLabel)),
      ];
  }
  if (selected != null && !opts.any((o) => o.value == selected)) {
    opts.add(FilterOption(selected, selected, const IconMark(Icons.filter_alt_outlined)));
  }
  return opts;
}

/// Filter state for the Sessions tab: the active values, the facets for them,
/// and how many conversations match.
class SessionFilterController extends ChangeNotifier {
  SessionFilterController(this.client, this.orgId);
  final ApiClient client;
  final String orgId;

  SessionFilters _filters = const SessionFilters();
  SessionFilters get filters => _filters;
  SessionFacets? facets;
  Object? facetsError;
  bool facetsLoading = false;
  int? total;
  int _gen = 0;

  void set(SessionFilters f) {
    if (f == _filters) return;
    _filters = f;
    total = null;
    notifyListeners();
    loadFacets();
  }

  void pick(SessionFacet facet, String value) => set(_filters.with_(facet, value.isEmpty ? null : value));

  void setTotal(int? t) {
    if (t == total) return;
    total = t;
    notifyListeners();
  }

  Future<void> loadFacets() async {
    final gen = ++_gen;
    facetsLoading = true;
    notifyListeners();
    try {
      final f = await client.sessionFacets(orgId, _filters);
      if (gen != _gen) return;
      facets = f;
      facetsError = null;
    } catch (e) {
      if (gen != _gen) return;
      facetsError = e;
    }
    facetsLoading = false;
    notifyListeners();
  }
}


String facetName(AppLocalizations l, SessionFacet f) => switch (f) {
      SessionFacet.agent => l.filterAgent,
      SessionFacet.integration => l.filterIntegration,
      SessionFacet.channel => l.filterChannel,
      SessionFacet.trigger => l.filterTrigger,
    };

String _sheetTitle(AppLocalizations l, SessionFacet f) => switch (f) {
      SessionFacet.agent => l.filterByAgent,
      SessionFacet.integration => l.filterByIntegration,
      SessionFacet.channel => l.filterByChannel,
      SessionFacet.trigger => l.filterByTrigger,
    };

String _allLabel(AppLocalizations l, SessionFacet f) => switch (f) {
      SessionFacet.agent => l.allAgents,
      SessionFacet.integration => l.allIntegrations,
      SessionFacet.channel => l.allChannels,
      SessionFacet.trigger => l.allTriggers,
    };

String _searchHint(AppLocalizations l, SessionFacet f) => switch (f) {
      SessionFacet.agent => l.searchAgents,
      SessionFacet.integration => l.searchIntegrations,
      SessionFacet.channel => l.searchChannels,
      SessionFacet.trigger => l.searchTriggers,
    };

String _groupName(AppLocalizations l, TriggerGroup g) => switch (g) {
      TriggerGroup.agents => l.agentsTitle,
      TriggerGroup.people => l.filterGroupPeople,
      TriggerGroup.schedules => l.filterGroupSchedules,
      TriggerGroup.events => l.filterGroupEvents,
    };

/// Who the filter labels need: the org's agents and the signed-in user.
class FilterContext {
  const FilterContext({this.agents = const [], this.userId, this.userName});
  final List<Agent> agents;
  final String? userId;
  final String? userName;
}

/// The four dropdowns under the app bar, then "N sessions" and "Clear all".
class SessionFilterBar extends StatelessWidget {
  const SessionFilterBar({super.key, required this.ctl, required this.who});
  final SessionFilterController ctl;
  final FilterContext who;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final facets = ctl.facets ?? const SessionFacets();
        FilterOption? selectedOf(SessionFacet f) {
          final v = ctl.filters.of(f);
          if (v == null) return null;
          return filterOptions(l, f, facets,
                  agents: who.agents, userId: who.userId, userName: who.userName, selected: v)
              .firstWhere((o) => o.value == v);
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            for (final (i, f) in SessionFacet.values.indexed) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: _Dropdown(
                  label: facetName(l, f),
                  selected: selectedOf(f),
                  onTap: () => showFacetSheet(context, ctl, f, who),
                ),
              ),
            ],
          ]),
          SizedBox(
            height: 36,
            child: Row(children: [
              if (ctl.total != null) Text(l.sessionCount(ctl.total!), style: mono(context, size: 12)),
              const Spacer(),
              if (ctl.filters.active)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => ctl.set(const SessionFilters()),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                    child: Text(l.clearAll,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.brandText)),
                  ),
                ),
            ]),
          ),
        ]);
      },
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({required this.label, required this.selected, required this.onTap});
  final String label;
  final FilterOption? selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final on = selected != null;
    return Semantics(
      button: true,
      label: on ? '$label: ${selected!.label}' : label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.only(left: 10, right: 6),
          decoration: BoxDecoration(
            color: on ? p.brandSoft : p.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: on ? p.accent : p.border),
          ),
          child: Row(children: [
            if (on) ...[
              SizedBox(width: 15, height: 15, child: Center(child: FilterMarkView(selected!.mark, size: 13))),
              const SizedBox(width: 5),
            ],
            Expanded(
              child: Text(on ? selected!.label : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500, color: on ? p.brandText : p.ink)),
            ),
            Icon(Icons.keyboard_arrow_down, size: 16, color: on ? p.brandText : p.secondary),
          ]),
        ),
      ),
    );
  }
}

/// "Filter by agent": a search field, "All agents", then one radio row per
/// value (triggers under group headers). A pick applies and closes the sheet.
Future<void> showFacetSheet(BuildContext context, SessionFilterController ctl, SessionFacet facet, FilterContext who) {
  if (ctl.facets == null || ctl.facetsError != null) ctl.loadFacets();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => _FacetSheet(ctl: ctl, facet: facet, who: who),
  );
}

class _FacetSheet extends StatefulWidget {
  const _FacetSheet({required this.ctl, required this.facet, required this.who});
  final SessionFilterController ctl;
  final SessionFacet facet;
  final FilterContext who;
  @override
  State<_FacetSheet> createState() => _FacetSheetState();
}

class _FacetSheetState extends State<_FacetSheet> {
  String _query = '';

  void _pick(String value) {
    widget.ctl.pick(widget.facet, value);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final ctl = widget.ctl;
    final facet = widget.facet;
    final who = widget.who;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final f = ctl.facets;
        final value = ctl.filters.of(facet) ?? '';
        final q = _query.trim().toLowerCase();
        final options = f == null
            ? const <FilterOption>[]
            : filterOptions(l, facet, f,
                    agents: who.agents, userId: who.userId, userName: who.userName, selected: ctl.filters.of(facet))
                .where((o) => q.isEmpty || o.label.toLowerCase().contains(q))
                .toList();
        final rows = <Widget>[];
        TriggerGroup? group;
        var card = <Widget>[];
        void flush() {
          if (card.isNotEmpty) rows.add(GroupCard(children: card));
          card = [];
        }

        for (final o in options) {
          if (o.group != group && o.group != null) {
            flush();
            group = o.group;
            rows.add(Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
              child: Text(_groupName(l, o.group!).toUpperCase(),
                  style: mono(context, size: 10.5, weight: FontWeight.w600).copyWith(letterSpacing: 0.84)),
            ));
          }
          card.add(_OptionRow(
              mark: FilterMarkView(o.mark),
              label: o.label,
              monoLabel: facet == SessionFacet.channel,
              selected: o.value == value,
              onTap: () => _pick(o.value)));
        }
        flush();

        Widget body;
        if (f == null && ctl.facetsError != null) {
          body = StateView(
              icon: Icons.cloud_off, title: l.filtersErrorTitle, actionLabel: l.tryAgain, onAction: ctl.loadFacets);
        } else if (f == null) {
          body = const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
        } else {
          body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (q.isEmpty) ...[
              GroupCard(children: [
                _OptionRow(
                  mark: Icon(Icons.layers_outlined, size: 18, color: p.secondary),
                  label: _allLabel(l, facet),
                  strong: true,
                  selected: value.isEmpty,
                  onTap: () => _pick(''),
                ),
              ]),
              const SizedBox(height: 8),
            ],
            ...rows,
            if (options.isEmpty && q.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Center(child: Text(l.noMatches, style: TextStyle(color: p.secondary))),
              ),
          ]);
        }

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 6, 8),
                child: Row(children: [
                  Expanded(
                      child: Text(_sheetTitle(l, facet),
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, color: p.secondary),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: _searchHint(l, facet),
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20, color: p.tertiary),
                    filled: true,
                    fillColor: p.surface,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.border)),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.paddingOf(context).bottom),
                  child: body,
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.mark,
    required this.label,
    required this.selected,
    required this.onTap,
    this.strong = false,
    this.monoLabel = false,
  });
  final Widget mark;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool strong;
  final bool monoLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final style = TextStyle(fontSize: 15, fontWeight: strong ? FontWeight.w600 : FontWeight.w400, color: p.ink);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              SizedBox(width: 20, height: 20, child: Center(child: mark)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoLabel ? mono(context, size: 14, color: p.ink) : style),
              ),
              const SizedBox(width: 8),
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20, color: selected ? p.accent : p.borderStrong),
            ]),
          ),
        ),
      ),
    );
  }
}

class FilterMarkView extends StatelessWidget {
  const FilterMarkView(this.mark, {super.key, this.size = 17});
  final FilterMark mark;
  final double size;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return switch (mark) {
      AgentMark(:final agent, :final name) =>
        AgentAvatar(iconUrl: agent?.iconUrl, runtime: agent?.runtime, name: name, size: size, showDot: false),
      SourceMark(:final source) => SourceGlyph(source, size: size - 3),
      IconMark(:final icon) => Icon(icon, size: size, color: p.secondary),
      PersonMark(:final name) => _Initials(name: name, size: size + 3),
    };
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.size});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final parts = name.replaceAll('@', '').split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final initials = parts.isEmpty
        ? '?'
        : (parts.length == 1 ? parts.first.substring(0, 1) : '${parts.first[0]}${parts.last[0]}').toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: p.sunken, shape: BoxShape.circle, border: Border.all(color: p.border)),
      child: Text(initials, style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w600, color: p.secondary)),
    );
  }
}
