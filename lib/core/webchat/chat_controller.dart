import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import 'frames.dart';

enum LiveKind { user, agent, thinking, tool, notice, permission, unsupported }

class LiveItem {
  LiveItem(this.kind, this.text, {this.key, this.status, this.requestId, this.detail});
  final LiveKind kind;
  String text;
  final String? key; // segmentId / toolCallId
  String? status;
  final String? requestId;
  final String? detail;
  bool answered = false;
  bool? allowed;
}

enum ChatConn { connecting, ready, lost, readOnly, failed }

String newTurnId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int s, int e) =>
      b.sublist(s, e).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

/// One live chat. Everything stays in memory: nothing is logged or persisted.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.client,
    required this.orgId,
    required this.agentId,
    this.sessionId,
  });
  final ApiClient client;
  final String orgId;
  final String agentId;
  final String? sessionId;

  final List<LiveItem> items = [];
  ChatConn conn = ChatConn.connecting;
  bool busy = false;
  bool offline = false;
  bool forbidden = false;
  Object? error;
  String? title;
  String? statusLine; // Thinking / Using tool / Waiting for approval, as a code
  String? statusTool;
  bool waitingApproval = false;

  WebSocket? _ws;
  bool _disposed = false;
  bool _ready = false;
  String? _turnId;
  OutputOrderer _orderer = OutputOrderer();
  String? _pendingSend;
  int _attempt = 0;
  Timer? _retry;
  final Map<String, LiveItem> _segments = {};
  final Map<String, LiveItem> _tools = {};

  Future<void> connect() async {
    if (_disposed) return;
    conn = ChatConn.connecting;
    notifyListeners();
    try {
      final grant = sessionId != null
          ? await client.continueChatGrant(orgId, sessionId!)
          : await client.newChatGrant(orgId, agentId);
      await _open(grant);
    } on ApiException catch (e) {
      if (e.status == 403 || e.status == 409) {
        conn = ChatConn.readOnly;
      } else if (e.status == 503) {
        offline = true;
        conn = ChatConn.failed;
      } else {
        error = e;
        conn = ChatConn.failed;
      }
      notifyListeners();
    } catch (e) {
      error = e;
      conn = ChatConn.failed;
      notifyListeners();
      _scheduleRetry();
    }
  }

  Future<void> _open(WebchatGrant g) async {
    final ws = await WebSocket.connect(g.socketUri().toString(),
        headers: {'User-Agent': 'AgentConnect/1.0'});
    if (_disposed) {
      ws.close();
      return;
    }
    _ws = ws;
    _ready = false;
    ws.listen(
      (data) {
        if (data is String) _onFrame(data);
      },
      onDone: _onClosed,
      onError: (_) => _onClosed(),
      cancelOnError: true,
    );
  }

  void _onClosed() {
    if (_disposed) return;
    _ws = null;
    _ready = false;
    if (conn == ChatConn.readOnly) return;
    conn = ChatConn.lost;
    notifyListeners();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    final secs = min(30, pow(2, _attempt).toInt());
    _attempt++;
    _retry = Timer(Duration(seconds: secs), () {
      if (!_disposed) _reconnect();
    });
  }

  Future<void> _reconnect() async {
    // A fresh credential for the same conversation.
    try {
      final grant = sessionId != null
          ? await client.continueChatGrant(orgId, sessionId!)
          : await client.newChatGrant(orgId, agentId);
      await _open(grant);
    } catch (_) {
      if (!_disposed) {
        conn = ChatConn.lost;
        notifyListeners();
        _scheduleRetry();
      }
    }
  }

  void _onFrame(String raw) {
    final f = decodeFrame(raw);
    if (f == null) return;
    switch (f) {
      case ReadyFrame():
        _ready = true;
        _attempt = 0;
        conn = ChatConn.ready;
        final p = _pendingSend;
        if (p != null) {
          _pendingSend = null;
          _write(p);
        }
      case AckFrame(:final accepted, :final turnId):
        if (!accepted) {
          busy = false;
        } else if (turnId != null) {
          _turnId = turnId;
        }
      case OutputFrame():
        for (final o in _orderer.add(f)) {
          _apply(o);
        }
      case PostFrame(:final text, :final fromAgent, :final postId):
        if (fromAgent && !_hasText(text)) {
          items.add(LiveItem(LiveKind.agent, text, key: postId));
        }
      case DoneFrame():
        for (final o in _orderer.flush()) {
          _apply(o);
        }
        busy = false;
        statusLine = null;
        waitingApproval = false;
        _turnId = null;
      case ErrorFrame():
        busy = false;
        statusLine = null;
        error = StateError('frame');
      case OtherFrame():
        break;
    }
    notifyListeners();
  }

  bool _hasText(String t) =>
      items.any((i) => i.kind == LiveKind.agent && i.text == t);

  void _apply(OutputFrame o) {
    final e = o.event;
    if (e == null) return;
    switch (e) {
      case MessageEvent():
        statusLine = null;
        final id = e.segmentId ?? e.postId ?? '_';
        final cur = _segments[id];
        if (cur != null) {
          cur.text += e.text;
        } else {
          final it = LiveItem(LiveKind.agent, e.text, key: id);
          _segments[id] = it;
          items.add(it);
        }
      case ThinkingEvent():
        statusLine = 'thinking';
        final last = items.isNotEmpty ? items.last : null;
        if (last != null && last.kind == LiveKind.thinking) {
          last.text += e.text;
        } else {
          items.add(LiveItem(LiveKind.thinking, e.text));
        }
      case ToolEvent():
        final cur = _tools[e.toolCallId];
        if (cur != null) {
          cur.status = e.status;
          if (e.title != null && e.title!.isNotEmpty) cur.text = e.title!;
        } else if (!e.isUpdate || e.title != null) {
          final it = LiveItem(LiveKind.tool, e.title ?? '',
              key: e.toolCallId, status: e.status);
          _tools[e.toolCallId] = it;
          items.add(it);
        }
        statusLine = 'tool';
        statusTool = cur?.text ?? e.title;
      case SessionInfoEvent():
        if (e.title.isNotEmpty) title = e.title;
      case NoticeEvent():
        if (e.text.isNotEmpty) items.add(LiveItem(LiveKind.notice, e.text));
      case PermissionEvent():
        waitingApproval = true;
        items.add(LiveItem(LiveKind.permission, e.tool,
            requestId: e.requestId, detail: e.detail));
      case UnsupportedEvent():
        if (!items.any((i) => i.kind == LiveKind.unsupported)) {
          items.add(LiveItem(LiveKind.unsupported, ''));
        }
    }
  }

  void send(String text) {
    final t = text.trim();
    if (t.isEmpty || busy) return;
    items.add(LiveItem(LiveKind.user, t));
    busy = true;
    _orderer = OutputOrderer();
    _segments.clear();
    _turnId = newTurnId();
    final frame = _encode({'text': t, 'turnId': _turnId});
    if (_ready) {
      _write(frame);
    } else {
      _pendingSend = frame;
    }
    notifyListeners();
  }

  /// Answers an in-stream approval card.
  void answerPermission(LiveItem item, bool allow) {
    if (item.requestId == null || item.answered) return;
    item.answered = true;
    item.allowed = allow;
    waitingApproval = false;
    _write(_encode({
      'type': 'permission_choice',
      'requestId': item.requestId,
      'allow': allow,
      'agentId': agentId,
    }));
    notifyListeners();
  }

  void cancel() {
    _write('{"type":"cancel"}');
  }

  String _encode(Map<String, Object?> m) => _json(m);

  void _write(String s) {
    try {
      _ws?.add(s);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ws?.close();
    _ws = null;
    super.dispose();
  }
}

String _json(Object? o) => jsonEncode(o);
