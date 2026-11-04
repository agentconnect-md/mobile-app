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
import 'session_tile.dart';

enum SessionFilter { all, running, webchat }

/// Conversations, newest first, with All / Running / Web chat and paging.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  SessionFilter _filter = SessionFilter.all;
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
    _sub = app.live?.events.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 700), () {
        if (mounted) _load(silent: true);
      });
    });
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  String? get _platform => _filter == SessionFilter.webchat ? 'webchat' : null;

  Future<void> _load({bool silent = false}) async {
    final app = AppScope.read(context);
    final acc = app.current;
    if (acc == null) return;
    final gen = ++_gen;
    if (!silent) setState(() => _loading = true);
    try {
      final page = await app.client.conversations(acc.orgId, platform: _platform);
      if (!mounted || gen != _gen) return;
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
    if (_loadingMore || _cursor == null) return;
    final app = AppScope.read(context);
    setState(() => _loadingMore = true);
    try {
      final page = await app.client
          .conversations(app.current!.orgId, cursor: _cursor, platform: _platform);
      if (!mounted) return;
      final keys = _items.map((c) => c.key).toSet();
      setState(() {
        _items = [..._items, ...page.conversations.where((c) => !keys.contains(c.key))];
        _cursor = page.nextCursor;
        _degraded = _degraded || page.degraded;
      });
    } catch (_) {
      // keep what we have
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _setFilter(SessionFilter f) {
    if (f == _filter) return;
    final reload = (f == SessionFilter.webchat) != (_filter == SessionFilter.webchat);
    setState(() => _filter = f);
    if (reload) _load();
  }

  Future<void> _newChat() async {
    final a = await pickAgent(context);
    if (a != null && mounted) openNewChat(context, a);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final previews = AppScope.of(context).previews;
    final shown = _filter == SessionFilter.running
        ? _items.where((c) => c.state != ActivityState.idle).toList()
        : _items;
    Widget list;
    if (_loading && _items.isEmpty) {
      list = const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
    } else if (_error != null && _items.isEmpty) {
      list = StateView(
        icon: Icons.cloud_off,
        title: l.convErrorTitle,
        body: _error is NetworkException ? l.errNetwork : l.pullToRetry,
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    } else if (shown.isEmpty) {
      list = _filter == SessionFilter.all
          ? StateView(
              icon: Icons.chat_bubble_outline,
              title: l.convEmptyTitle,
              body: l.convEmptyBody,
              actionLabel: l.newChat,
              onAction: _newChat)
          : StateView(
              icon: Icons.filter_list_off,
              title: l.filteredEmptyTitle,
              body: l.filteredEmptyBody,
              actionLabel: l.showAll,
              onAction: () => _setFilter(SessionFilter.all));
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
        title: Text(l.sessionsTitle),
        actions: [
          IconButton(tooltip: l.newChat, onPressed: _newChat, icon: const Icon(Icons.edit_square)),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _more();
            return false;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              FilterPills<SessionFilter>(
                items: [
                  (SessionFilter.all, l.all),
                  (SessionFilter.running, l.filterRunning),
                  (SessionFilter.webchat, l.filterWebchat),
                ],
                value: _filter,
                onChanged: _setFilter,
              ),
              const SizedBox(height: 12),
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
                const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            ],
          ),
        ),
      ),
    );
  }
}
