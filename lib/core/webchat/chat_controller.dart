import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import 'attachments.dart';
import 'frames.dart';

enum LiveKind { user, agent, thinking, tool, notice, permission, unsupported }

class LiveItem {
  LiveItem(this.kind, this.text,
      {this.key, this.status, this.requestId, this.detail, this.images = const [], this.files = const []});
  final LiveKind kind;
  final List<ImageAttachment> images;
  final List<MarkedFile> files;
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
    this.conversationId,
  });
  final ApiClient client;
  final String orgId;
  final String agentId;
  final String? sessionId;

  /// The webchat conversation this chat resumes. Set for a webchat session,
  /// and for a new chat once its first grant names one, so a reconnect lands
  /// in the same conversation instead of starting another.
  String? conversationId;

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

  /// Latest run settings from the session (model / effort / permission).
  RunStatus? run;

  /// The relay's `ready.features`; null until the first `ready`.
  Set<String>? features;

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
      await _open(await _grant());
    } on ApiException catch (e) {
      // A resume answers 404 to someone who may read the conversation but
      // not continue it (not its owner, nor a member who may continue it).
      final resuming = sessionId != null && conversationId != null;
      if (e.status == 403 || e.status == 409 || (resuming && e.status == 404)) {
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

  /// Same choice as the web console: a webchat conversation resumes by its
  /// id; any other session continues by session id; otherwise a new chat.
  Future<WebchatGrant> _grant() async {
    final conv = conversationId;
    final g = conv != null
        ? await client.resumeChatGrant(orgId, agentId, conv)
        : sessionId != null
            ? await client.continueChatGrant(orgId, sessionId!)
            : await client.newChatGrant(orgId, agentId);
    if (sessionId == null) conversationId = g.conversationId;
    return g;
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
      await _open(await _grant());
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
        features = f.features;
        _ready = true;
        _attempt = 0;
        conn = ChatConn.ready;
        for (final r in _pendingRun) {
          _write(r);
        }
        _pendingRun.clear();
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
        final st = f.status;
        if (st != null) run = run == null ? st : run!.merge(st);
        for (final o in _orderer.add(f)) {
          _apply(o);
        }
      case PostFrame(:final text, :final fromAgent, :final postId, :final images):
        final (body, files) = splitFilesMarker(text);
        if (fromAgent && !_hasText(body)) {
          items.add(LiveItem(LiveKind.agent, body, key: postId, images: images, files: files));
        } else if (fromAgent && (images.isNotEmpty || files.isNotEmpty)) {
          // The streamed text is already shown: attach the post's files to it.
          final i = items.lastIndexWhere((x) => x.kind == LiveKind.agent && x.text == body);
          final cur = items[i];
          items[i] = LiveItem(LiveKind.agent, cur.text, key: cur.key, images: images, files: files);
          _segments.updateAll((k, v) => identical(v, cur) ? items[i] : v);
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
      t.isNotEmpty && items.any((i) => i.kind == LiveKind.agent && i.text == t);

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

  /// Sends a turn. [images] travel inline (one at most, within the image
  /// budget); [files] were uploaded first and are named by upload id.
  void send(String text, {List<ImageAttachment> images = const [], List<UploadedFile> files = const []}) {
    final t = text.trim();
    if ((t.isEmpty && images.isEmpty && files.isEmpty) || busy) return;
    items.add(LiveItem(LiveKind.user, t, images: [
      ...images,
      for (final f in files)
        if (f.preview != null) ImageAttachment(name: f.name, mimeType: f.preview!.mimeType, data: f.preview!.data),
    ], files: [
      for (final f in files)
        if (f.preview == null) MarkedFile(f.name, f.mimeType),
    ]));
    busy = true;
    _orderer = OutputOrderer();
    _segments.clear();
    _turnId = newTurnId();
    final frame = _encode({
      'text': t,
      'turnId': _turnId,
      if (images.isNotEmpty) 'attachments': [for (final i in images) i.toJson()],
      if (files.isNotEmpty) 'files': [for (final f in files) f.toJson()],
    });
    if (_ready) {
      _write(frame);
    } else {
      _pendingSend = frame;
    }
    notifyListeners();
  }

  /// Drops the finished live turns once the saved transcript shows them, so
  /// a turn isn't listed twice (transcript above, live copy below). Doesn't
  /// notify: it is called while the view is about to rebuild anyway.
  void dropSettled() {
    if (busy) return;
    items.clear();
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

  /// Run settings for the session's next turn. Optimistic: the next status
  /// snapshot confirms. Callers must have write access (403 otherwise).
  void setModel(String model) => _runChange({'type': 'set_model', 'model': model},
      RunStatus(model: model));
  void setEffort(String effort) => _runChange({'type': 'set_effort', 'effort': effort},
      RunStatus(effort: effort));
  void setPermissionMode(String mode) => _runChange(
      {'type': 'set_permission_mode', 'permissionMode': mode}, RunStatus(permissionMode: mode));

  void _runChange(Map<String, Object?> frame, RunStatus local) {
    run = run == null ? local : run!.merge(local);
    final f = _encode(frame);
    if (_ready) {
      _write(f);
    } else {
      _pendingRun.add(f);
    }
    notifyListeners();
  }

  final List<String> _pendingRun = [];

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
