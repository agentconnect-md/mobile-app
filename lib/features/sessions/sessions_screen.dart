import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/agent_picker.dart';
import '../nav.dart';
import 'session_filters.dart';
import 'session_tile.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// Conversations, newest first, with paging and the design's filter: Agent /
/// Integration / Channel / Trigger dropdowns, the match count and "Clear all".
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  SessionFilterController? _filter;
  List<Conversation> _items = [];
  String? _cursor;
  bool _degraded = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  StreamSubscription<dynamic>? _sub;
  Timer? _debounce;
  bool _started = false;
  int _gen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final app = AppScope.read(context);
    final acc = app.current;
    if (acc != null) _filter = SessionFilterController(app.client, acc.orgId)..addListener(_onFilter);
    _sub = app.live?.events.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 700), () {
        if (mounted) {
          _load(silent: true);
          _filter?.loadFacets();
        }
      });
    });
    _load();
    _filter?.loadFacets();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    _filter?.dispose();
    super.dispose();
  }

  SessionFilters _applied = const SessionFilters();
  SessionFilters get _filters => _filter?.filters ?? const SessionFilters();

  void _onFilter() {
    if (!mounted) return;
    if (_filters != _applied) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _load({bool silent = false}) async {
    final app = AppScope.read(context);
    final acc = app.current;
    if (acc == null) return;
    final gen = ++_gen;
    final filters = _filters;
    final changed = filters != _applied;
    _applied = filters;
    setState(() {
      _loadingMore = false;
      if (!silent) _loading = true;
      if (changed) {
        _items = [];
        _cursor = null;
        _error = null;
        _degraded = false;
      }
    });
    try {
      final page = await app.client.conversations(acc.orgId, filters: filters);
      if (!mounted || gen != _gen) return;
      _filter?.setTotal(page.total);
      setState(() {
        _items = page.conversations;
        _cursor = page.nextCursor;
        _degraded = page.degraded;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      if (silent && _items.isNotEmpty) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _more() async {
    if (_loading || _loadingMore || _cursor == null) return;
    final app = AppScope.read(context);
    final gen = _gen;
    setState(() => _loadingMore = true);
    try {
      final page = await app.client
          .conversations(app.current!.orgId, cursor: _cursor, filters: _applied);
      if (!mounted || gen != _gen) return;
      final keys = _items.map((c) => c.key).toSet();
      setState(() {
        _items = [..._items, ...page.conversations.where((c) => !keys.contains(c.key))];
        _cursor = page.nextCursor;
        _degraded = _degraded || page.degraded;
      });
    } catch (_) {
      // keep what we have
    } finally {
      if (mounted && gen == _gen) setState(() => _loadingMore = false);
    }
  }

  Future<void> _newChat() async {
    final a = await pickAgent(context);
    if (a != null && mounted) openNewChat(context, a);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final previews = app.previews;
    final filters = _filters;
    final shown = _items;
    Widget list;
    if (_loading && _items.isEmpty) {
      list = const Padding(padding: EdgeInsets.all(40), child: Center(child: Spinner()));
    } else if (_error != null && _items.isEmpty) {
      list = StateView(
        icon: AppIcons.cloudOff,
        title: l.convErrorTitle,
        body: _error is NetworkException ? l.errNetwork : l.pullToRetry,
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    } else if (shown.isEmpty) {
      list = !filters.active
          ? StateView(
              icon: AppIcons.chatBubbleOutline,
              title: l.convEmptyTitle,
              body: l.convEmptyBody,
              actionLabel: l.newChat,
              onAction: _newChat)
          : StateView(
              icon: AppIcons.filterListOff,
              title: l.filteredEmptyTitle,
              body: l.filteredEmptyBody,
              actionLabel: l.showAll,
              onAction: () => _filter?.set(const SessionFilters()));
    } else {
      list = ListenableBuilder(
        listenable: previews ?? ValueNotifier(0),
        builder: (context, _) => GroupCard(children: [
          for (final c in shown)
            SessionTile(conversation: c, preview: true, onTap: () => openConversation(context, c)),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        toolbarHeight: rootAppBarHeight,
        title: rootTitle(l.sessionsTitle),
        actions: [
          IconButton(tooltip: l.newChat, onPressed: _newChat, icon: Icon(AppIcons.editSquare)),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator.adaptive(
        onRefresh: () async {
          await Future.wait([_load(), if (_filter != null) _filter!.loadFacets()]);
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _more();
            return false;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (_filter != null) ...[
                SessionFilterBar(
                  ctl: _filter!,
                  who: FilterContext(
                    agents: app.orgData?.agents ?? const [],
                    userId: app.current?.userId,
                    userName: app.current?.userName,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              if (_degraded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppCard(
                    leftBar: p.paused,
                    padding: const EdgeInsets.all(12),
                    child: Text(l.degradedBanner, style: TextStyle(color: p.paused, fontWeight: FontWeight.w500)),
                  ),
                ),
              list,
              if (_loadingMore)
                const Padding(padding: EdgeInsets.all(16), child: Center(child: Spinner())),
            ],
          ),
        ),
      ),
    );
  }
}
