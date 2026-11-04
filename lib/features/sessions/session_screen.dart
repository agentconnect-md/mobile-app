import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../approvals/approval_card.dart';
import '../chat/bubbles.dart';
import '../chat/chat_view.dart';
import 'session_tile.dart';
import 'transcript.dart';

/// One conversation: header (agent · place · state, link to the original
/// platform), transcript, approvals waiting in it, and the message box.
/// Several agents in one conversation: a switcher between their sessions.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.conversation});
  final Conversation conversation;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late SessionRow _session = widget.conversation.primary;
  List<TranscriptItem> _items = [];
  String? _older;
  bool _loading = true;
  bool _offline = false;
  Object? _error;
  bool _loadingOlder = false;
  StreamSubscription<dynamic>? _sub;
  Timer? _debounce;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final app = AppScope.read(context);
    _sub = app.live?.events.listen((e) {
      final ids = widget.conversation.sessions.map((s) => s.sessionId);
      if (e.kind != 'connected' && e.sessionId != null && !ids.contains(e.sessionId)) return;
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

  Set<String> get _agentIds => widget.conversation.sessions.map((s) => s.agentId).toSet();

  Future<void> _load({bool silent = false}) async {
    final app = AppScope.read(context);
    if (!silent) setState(() => _loading = true);
    try {
      final page = await app.client.messages(app.current!.orgId, _session.sessionId);
      if (!mounted) return;
      setState(() {
        _items = buildTranscript(page.messages, _agentIds);
        _older = page.nextCursor;
        _offline = false;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (silent && _items.isNotEmpty) return;
      setState(() {
        _loading = false;
        if (e is ApiException && e.status == 503) {
          _offline = true;
        } else {
          _error = e;
        }
      });
    }
  }

  Future<void> _loadOlder() async {
    if (_older == null || _loadingOlder) return;
    final app = AppScope.read(context);
    setState(() => _loadingOlder = true);
    try {
      final page = await app.client.messages(app.current!.orgId, _session.sessionId, cursor: _older);
      if (!mounted) return;
      final older = buildTranscript(page.messages, _agentIds);
      final have = _items.map((e) => e.seq).toSet();
      setState(() {
        _items = [...older.where((o) => !have.contains(o.seq)), ..._items]..sort((a, b) => a.seq.compareTo(b.seq));
        _older = page.nextCursor;
      });
    } catch (_) {
      // the button stays available
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final conv = widget.conversation;
    final s = _session;
    final agent = app.orgData?.agent(s.agentId);
    final title = s.title?.trim().isNotEmpty == true ? s.title!.trim() : (conv.title ?? l.untitled);
    final url = s.threadUrl ?? conv.threadUrl;
    final state = s.state;
    final stateText = switch (state) {
      ActivityState.working => l.stateRunning,
      ActivityState.awaiting => l.stateWaiting,
      ActivityState.idle => l.stateIdle,
    };
    final place = conv.place ?? sourceName(l, conv.source);
    final approvals = app.approvals;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_offline) {
      body = StateView(
          icon: Icons.cloud_off,
          title: l.offlineTitle(s.agentName),
          body: l.offlineBody,
          actionLabel: l.tryAgain,
          onAction: _load);
    } else if (_error != null && _items.isEmpty) {
      body = StateView(
          icon: Icons.error_outline, title: errorText(l, _error!), actionLabel: l.tryAgain, onAction: _load);
    } else {
      final first = _items.isEmpty ? null : _items.first.ts ?? s.lastActivityAt;
      body = ListenableBuilder(
        listenable: approvals ?? ValueNotifier(0),
        builder: (context, _) => ChatView(
          key: ValueKey(s.sessionId),
          agent: agent,
          agentId: s.agentId,
          agentName: s.agentName,
          sessionId: s.sessionId,
          model: agent?.model ?? s.model,
          onTurnDone: () => _load(silent: true),
          header: [
            if (first != null) TimeEntry(listTime(first)),
            ...entriesFromTranscript(_items),
          ],
          headerSliver: _older == null
              ? null
              : Center(
                  child: TextButton(
                      onPressed: _loadOlder, child: Text(_loadingOlder ? l.loadingShort : l.loadingMore))),
          trailing: [
            for (final a in approvals?.forSession(s.sessionId) ?? const [])
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ApprovalCard(key: ValueKey(a.id), approval: a, controller: approvals!),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        toolbarHeight: 60,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(children: [
            StatusDot(color: sessionDot(p, state), size: 8),
            const SizedBox(width: 6),
            Flexible(
              child: Text([s.agentName, place, stateText].where((x) => x.isNotEmpty).join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
            ),
          ]),
        ]),
        actions: [
          if (url != null)
            IconButton(
              tooltip: l.openIn(sourceName(l, conv.source)),
              onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              icon: SourceGlyph(conv.source, size: 18),
            ),
          const SizedBox(width: 4),
        ],
        bottom: conv.sessions.length > 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Segmented<String>(
                    items: [for (final x in conv.sessions) (x.sessionId, x.agentName)],
                    value: s.sessionId,
                    onChanged: (id) {
                      setState(() => _session = conv.sessions.firstWhere((x) => x.sessionId == id));
                      _load();
                    },
                  ),
                ),
              )
            : null,
      ),
      body: body,
    );
  }
}
