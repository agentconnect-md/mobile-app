import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/new_conversation_sheet.dart';
import 'conversation_detail_screen.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  bool _mine = false;
  List<Conversation> _items = [];
  String? _cursor;
  bool _degraded = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  StreamSubscription<dynamic>? _sub;
  Timer? _debounce;
  AppState? _app;
  int _gen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    if (_app != app || _liveKey != app.live) {
      _app = app;
      _liveKey = app.live;
      _sub?.cancel();
      _sub = app.live?.events.listen((e) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 600), () {
          if (mounted) _load(silent: true);
        });
      });
      _load();
    }
  }

  Object? _liveKey;

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final app = _app!;
    final acc = app.current;
    if (acc == null) return;
    final gen = ++_gen;
    if (!silent) setState(() => _loading = true);
    try {
      final page = await app.client.conversations(acc.orgId,
          triggeredBy: _mine ? acc.userId : null);
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
    final app = _app!;
    final acc = app.current!;
    setState(() => _loadingMore = true);
    try {
      final page = await app.client.conversations(acc.orgId,
          cursor: _cursor, triggeredBy: _mine ? acc.userId : null);
      if (!mounted) return;
      final keys = _items.map((c) => c.key).toSet();
      setState(() {
        _items = [..._items, ...page.conversations.where((c) => !keys.contains(c.key))];
        _cursor = page.nextCursor;
        _degraded = _degraded || page.degraded;
      });
    } catch (_) {
      // keep what we have; the user can scroll again
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _setMine(bool v) {
    if (_mine == v) return;
    setState(() => _mine = v);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.conversationsTitle),
        actions: [
          IconButton(
            tooltip: l.newConversation,
            icon: const Icon(Icons.edit_square),
            onPressed: () => showNewConversationSheet(context),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                  minimumSize: const Size(48, 40),
                  selectedBackgroundColor: p.accent,
                  selectedForegroundColor: Theme.of(context).colorScheme.onPrimary),
              segments: [
                ButtonSegment(value: false, label: Text(l.filterAll)),
                ButtonSegment(value: true, label: Text(l.filterMine)),
              ],
              selected: {_mine},
              onSelectionChanged: (s) => _setMine(s.first),
            ),
          ),
        ),
      ),
      body: _body(l, p),
    );
  }

  Widget _body(AppLocalizations l, Palette p) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      if (isUnauthorized(_error!)) return const SizedBox();
      return RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (c, box) => ListView(children: [
            SizedBox(
              height: box.maxHeight,
              child: StateView(
                icon: Icons.cloud_off,
                title: l.convErrorTitle,
                body: _error is NetworkException ? l.errNetwork : l.pullToRetry,
                actionLabel: l.tryAgain,
                onAction: _load,
              ),
            ),
          ]),
        ),
      );
    }
    final banner = _degraded
        ? Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AppCard(
              leftBar: p.amberBar,
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Icon(Icons.info_outline, color: p.amberText),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(l.degradedBanner,
                        style: TextStyle(color: p.amberText, fontWeight: FontWeight.w600))),
              ]),
            ),
          )
        : null;
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (c, box) => ListView(padding: const EdgeInsets.all(16), children: [
            ?banner,
            SizedBox(
              height: box.maxHeight - 40,
              child: _mine
                  ? StateView(
                      icon: Icons.filter_list_off,
                      title: l.filteredEmptyTitle,
                      body: l.filteredEmptyBody,
                      actionLabel: l.showAll,
                      onAction: () => _setMine(false))
                  : StateView(
                      icon: Icons.chat_bubble_outline,
                      title: l.convEmptyTitle,
                      body: l.convEmptyBody,
                      actionLabel: l.newConversation,
                      onAction: () => showNewConversationSheet(context)),
            ),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _more();
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: _items.length + 1 + (banner != null ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (c, i) {
            if (banner != null) {
              if (i == 0) return banner;
              i--;
            }
            if (i == _items.length) {
              return _loadingMore
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Center(
                          child: Text(l.loadingMore,
                              style: TextStyle(color: p.secondary))))
                  : const SizedBox();
            }
            return ConversationCard(conversation: _items[i]);
          },
        ),
      ),
    );
  }
}

class ConversationCard extends StatelessWidget {
  const ConversationCard({super.key, required this.conversation});
  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final c = conversation;
    final st = c.state;
    final waiting = st == ActivityState.awaiting;
    final agents = {for (final s in c.sessions) s.agentName}.where((e) => e.isNotEmpty).join(', ');
    return AppCard(
      leftBar: waiting ? p.amberBar : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ConversationDetailScreen(conversation: c))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(c.title ?? l.untitled,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(relativeTime(c.lastActivity),
              style: TextStyle(color: p.secondary, fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        Text(agents, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.secondary, fontSize: 14)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          Chip8(sourceName(l, c.source)),
          Chip8(stateName(l, st),
              fg: waiting
                  ? p.amberText
                  : st == ActivityState.working
                      ? p.accent
                      : p.secondary,
              bg: waiting ? p.amberBg : null),
        ]),
      ]),
    );
  }
}
