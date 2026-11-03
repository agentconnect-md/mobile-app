import 'dart:async';
import 'dart:convert';

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
import '../chat/chat_composer.dart';
import 'transcript.dart';

class ConversationDetailScreen extends StatefulWidget {
  const ConversationDetailScreen({super.key, required this.conversation});
  final Conversation conversation;
  @override
  State<ConversationDetailScreen> createState() => _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
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
      if (e.sessionId != null && !ids.contains(e.sessionId)) return;
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

  Set<String> get _agentIds =>
      widget.conversation.sessions.map((s) => s.agentId).toSet();

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
      final page = await app.client
          .messages(app.current!.orgId, _session.sessionId, cursor: _older);
      if (!mounted) return;
      final merged = <int, ApiMessage>{};
      // Rebuild from API messages is not possible for existing items, so merge items.
      final older = buildTranscript(page.messages, _agentIds);
      final have = _items.map((e) => e.seq).toSet();
      merged.clear();
      setState(() {
        _items = [...older.where((o) => !have.contains(o.seq)), ..._items]
          ..sort((a, b) => a.seq.compareTo(b.seq));
        _older = page.nextCursor;
      });
    } catch (_) {
      // ignore; the button stays available
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _switch(SessionRow s) {
    setState(() => _session = s);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final conv = widget.conversation;
    final title = _session.title?.trim().isNotEmpty == true
        ? _session.title!.trim()
        : (conv.title ?? l.untitled);
    final url = _session.threadUrl ?? conv.threadUrl;
    final canReply = _session.isWebchat && !_offline;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        actions: [
          if (url != null)
            IconButton(
              tooltip: l.openIn(sourceName(l, conv.source)),
              icon: const Icon(Icons.open_in_new),
              onPressed: () => launchUrl(Uri.parse(url),
                  mode: LaunchMode.externalApplication),
            ),
        ],
      ),
      body: Column(children: [
        if (conv.sessions.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final s in conv.sessions)
                    ButtonSegment(value: s.sessionId, label: Text(s.agentName)),
                ],
                selected: {_session.sessionId},
                onSelectionChanged: (v) =>
                    _switch(conv.sessions.firstWhere((s) => s.sessionId == v.first)),
              ),
            ),
          ),
        Expanded(child: _content(l, p, url, conv)),
        if (canReply)
          ChatComposer(
            key: ValueKey(_session.sessionId),
            agentId: _session.agentId,
            agentName: _session.agentName,
            sessionId: _session.sessionId,
            onTurnDone: () => _load(silent: true),
          )
        else if (!_offline && !_loading)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: p.sunken,
            child: SafeArea(
              top: false,
              child: Text(l.readOnlyFooter,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.secondary, fontSize: 14)),
            ),
          ),
      ]),
    );
  }

  Widget _content(AppLocalizations l, Palette p, String? url, Conversation conv) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_offline) {
      return StateView(
        icon: Icons.cloud_off,
        title: l.offlineTitle(_session.agentName),
        body: l.offlineBody,
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    }
    if (_error != null && _items.isEmpty) {
      return StateView(
        icon: Icons.error_outline,
        title: errorText(l, _error!),
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    }
    if (_items.isEmpty) {
      return StateView(icon: Icons.chat_bubble_outline, title: l.noMessages);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: _items.length + (_older != null ? 1 : 0),
        itemBuilder: (c, i) {
          if (_older != null) {
            if (i == 0) {
              return Center(
                child: TextButton(
                  onPressed: _loadOlder,
                  child: Text(_loadingOlder ? l.loadingShort : l.loadingMore),
                ),
              );
            }
            i--;
          }
          return TranscriptTile(
            item: _items[i],
            sessionId: _session.sessionId,
            agentName: _session.agentName,
          );
        },
      ),
    );
  }
}

class TranscriptTile extends StatelessWidget {
  const TranscriptTile(
      {super.key, required this.item, required this.sessionId, required this.agentName});
  final TranscriptItem item;
  final String sessionId;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    switch (item.kind) {
      case ItemKind.user:
        return Bubble(text: item.text, mine: true, label: item.sender);
      case ItemKind.agent:
        return Bubble(text: item.text, mine: false, label: agentName);
      case ItemKind.reasoning:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(item.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: p.secondary, fontStyle: FontStyle.italic, fontSize: 14)),
        );
      case ItemKind.tool:
        return ToolCallTile(item: item, sessionId: sessionId);
      case ItemKind.other:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(l.unsupported,
              style: TextStyle(color: p.secondary, fontSize: 14)),
        );
    }
  }
}

class Bubble extends StatelessWidget {
  const Bubble({super.key, required this.text, required this.mine, this.label});
  final String text;
  final bool mine;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final bg = mine ? p.ink : p.surface;
    final fg = mine ? p.canvas : p.ink;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: mine ? null : Border.all(color: p.hairline),
        ),
        child: SelectableText(text, style: TextStyle(color: fg, fontSize: 16)),
      ),
    );
  }
}

/// Collapsed "Used {tool}"; expands to a preview; "Show full" loads the rest.
class ToolCallTile extends StatefulWidget {
  const ToolCallTile({super.key, required this.item, required this.sessionId});
  final TranscriptItem item;
  final String sessionId;
  @override
  State<ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<ToolCallTile> {
  bool _open = false;
  bool _loading = false;
  bool _failed = false;
  String? _full;

  String _preview() {
    final b = widget.item.body;
    if (b == null) return '';
    try {
      final m = asMap(jsonDecode(b));
      final raw = m['rawInput'];
      if (raw != null) return const JsonEncoder.withIndent('  ').convert(raw);
    } catch (_) {}
    return b;
  }

  Future<void> _showFull() async {
    final id = widget.item.toolCallId;
    if (id == null) return;
    final app = AppScope.read(context);
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final buf = StringBuffer();
      int? off = 0;
      var guard = 0;
      while (off != null && guard++ < 50) {
        final c = await app.client
            .toolBody(app.current!.orgId, widget.sessionId, id, offset: off);
        buf.write(c.data);
        off = c.nextOffset;
      }
      var text = buf.toString();
      try {
        final m = asMap(jsonDecode(text));
        final raw = m['rawInput'];
        if (raw != null) text = const JsonEncoder.withIndent('  ').convert(raw);
      } catch (_) {}
      if (mounted) setState(() => _full = text);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final it = widget.item;
    final failed = it.toolStatus == 'failed';
    final name = it.text.isEmpty ? '…' : it.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: p.sunken,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.hairline),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  Icon(failed ? Icons.error_outline : Icons.build_outlined,
                      size: 18, color: failed ? p.error : p.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(l.usedTool(name),
                        maxLines: _open ? 4 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: monoFamily,
                            fontFamilyFallback: monoFallback,
                            fontSize: 13,
                            color: p.ink)),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: p.secondary),
                ]),
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(_full ?? _preview(),
                    style: TextStyle(
                        fontFamily: monoFamily,
                        fontFamilyFallback: monoFallback,
                        fontSize: 12,
                        color: p.secondary)),
                if (it.truncated && _full == null)
                  TextButton(
                    onPressed: _loading ? null : _showFull,
                    child: Text(_loading ? l.loadingShort : l.showFull),
                  ),
                if (_failed)
                  Text(l.loadRestFailed, style: TextStyle(color: p.error, fontSize: 13)),
              ]),
            ),
        ]),
      ),
    );
  }
}
