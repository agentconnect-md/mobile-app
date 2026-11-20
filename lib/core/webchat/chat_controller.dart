import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/capability_requests.dart';
import '../api/models.dart';
import 'attachments.dart';
import 'elicit.dart';
import 'frames.dart';

enum LiveKind { user, agent, thinking, tool, notice, permission, fill, elicit, capability, unsupported }

class LiveItem {
  LiveItem(this.kind, this.text,
      {this.key,
      this.status,
      this.requestId,
      this.detail,
      this.fill,
      this.images = const [],
      this.files = const [],
      this.waitTurn});
  final LiveKind kind;

  /// A wait notice ("Starting sandbox…"): the turn it belongs to. It is shown
  /// only until that turn's next notice or first output. Null for every other row.
  final String? waitTurn;
  final List<ImageAttachment> images;
  final List<MarkedFile> files;

  /// A Fill card: descriptors only. The person's values live in the card's
  /// widget state and leave it as soon as they are sent.
  final FillCard? fill;

  /// How the Fill card settled (`fill_resolved`), or null while open.
  String? fillOutcome;

  /// The answer went out; the card waits for its outcome.
  bool fillSent = false;

  /// Why the last answer didn't go out (or was refused); the card keeps its input.
  String? fillError;

  /// A question card: descriptors only. The person's answer lives in the
  /// card's widget state and leaves it as soon as it is sent.
  ElicitCard? elicit;

  /// How the question settled (`elicitation_resolved`), or null while open.
  String? elicitOutcome;

  /// The chosen option's label, as the daemon names it on `accepted`.
  String? elicitLabel;

  /// An answer went out; the daemon settles the card (or refuses the answer).
  bool elicitSent = false;

  /// `not_connected` when the last answer didn't go out.
  String? elicitError;

  /// The turn this item came in (question cards: a card can't outlive its turn).
  String? turnId;

  /// A capability request card; where it stands is read from the request itself.
  CapabilityCard? capability;

  /// How the request ended (`capability_request_resolved`), or null while open.
  String? capabilityStatus;

  /// The daemon's line for how it ended.
  String? capabilityText;
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
    this.thread,
    this.anyThread = false,
  });
  final ApiClient client;
  final String orgId;
  final String agentId;
  final String? sessionId;

  /// The thread (root `postId`) this chat writes in; null at the root. Only
  /// frames of this thread are shown, unless [anyThread].
  final String? thread;

  /// A task's own continuation: everything on it is the task's, whatever
  /// thread its frames name.
  final bool anyThread;

  /// The relay doesn't forward `thread` (no `webchat-threads-v1` in `ready`):
  /// a thread chat can't write.
  bool threadsMissing = false;

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

  /// The runtime's predicted next prompt: offered, never sent by itself.
  String? suggestion;

  /// Agents in the conversation, from `ready` (0 until connected).
  int participants = 0;

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
        participants = f.participants;
        features = f.features;
        if (thread != null && !anyThread && !f.features.contains(webchatThreadsFeature)) {
          // Sending would land at the root instead of the thread.
          threadsMissing = true;
          conn = ChatConn.readOnly;
          _pendingSend = null;
          busy = false;
          _ws?.close();
          break;
        }
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
      case OutputFrame(thread: final t) when !_mine(t):
        break;
      case PostFrame(thread: final t) when !_mine(t):
        break;
      // Our own turn ends here even when the agent answered it in a thread
      // (the reload then shows "In thread: …"); other threads' turns don't.
      case DoneFrame(thread: final t, turnId: final id) when !_mine(t) && (id == null || id != _turnId):
        break;
      case OutputFrame():
        final st = f.status;
        if (st != null) run = run == null ? st : run!.merge(st);
        if (f.turnId?.startsWith('fill:') ?? false) {
          // A card handed out on its own (`fill_open`): not part of any turn's stream.
          _apply(f);
        } else {
          for (final o in _orderer.add(f)) {
            _apply(o);
          }
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
      case DoneFrame(:final turnId, :final error):
        for (final o in _orderer.flush()) {
          _apply(o);
        }
        // A question can't outlive its turn; its own settlement can lose the race with `done`.
        final ended = f.turnId;
        if (ended != null) {
          for (final i in items) {
            if (i.kind == LiveKind.elicit && i.elicitOutcome == null && i.turnId == ended) {
              i.elicitOutcome = 'cancelled';
            }
          }
        }
        // A turn that ends cleanly has stopped waiting; after an error the
        // last notice may be all the person was told, so it stays.
        if (error == null) _endWait(turnId ?? _turnId);
        busy = false;
        statusLine = null;
        waitingApproval = false;
        _turnId = null;
      case PromptSuggestionFrame(:final text):
        // A turn that predicts nothing clears the last one.
        suggestion = text;
      case RefusedFrame(:final op, :final reason):
        if (op == 'fill_submit') {
          for (final i in items.reversed) {
            if (i.kind == LiveKind.fill && i.fillSent && i.fillOutcome == null) {
              i.fillSent = false;
              i.fillError = reason.isEmpty ? 'refused' : reason;
              break;
            }
          }
        } else if (reason.isNotEmpty) {
          items.add(LiveItem(LiveKind.notice, reason));
        }
      case ErrorFrame():
        busy = false;
        statusLine = null;
        error = StateError('frame');
      case OtherFrame():
        break;
    }
    notifyListeners();
  }

  /// Frames of another thread (or of the root, in a thread) aren't this chat's.
  bool _mine(String? frameThread) => anyThread || frameThread == thread;

  bool _hasText(String t) =>
      t.isNotEmpty && items.any((i) => i.kind == LiveKind.agent && i.text == t);

  /// Takes the turn's wait notice off the list (see [NoticeEvent]).
  void _endWait(String? turnId) {
    final turn = turnId ?? '';
    items.removeWhere((i) => i.kind == LiveKind.notice && i.waitTurn == turn);
  }

  void _apply(OutputFrame o) {
    final e = o.event;
    if (e == null) return;
    // Output is the wait ending; a standing notice leaves the wait as it is.
    if (e is! NoticeEvent || !e.standing) _endWait(o.turnId);
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
        if (e.text.isNotEmpty) {
          items.add(LiveItem(LiveKind.notice, e.text, waitTurn: e.standing ? null : (o.turnId ?? '')));
        }
        // A refused answer is said in a notice and leaves its card open.
        for (final i in items) {
          if (i.kind == LiveKind.elicit && i.elicitOutcome == null) i.elicitSent = false;
        }
      case PermissionEvent():
        waitingApproval = true;
        items.add(LiveItem(LiveKind.permission, e.tool,
            requestId: e.requestId, detail: e.detail));
      case FillRequestEvent(:final card):
        if (!items.any((i) => i.kind == LiveKind.fill && i.fill?.requestId == card.requestId)) {
          items.add(LiveItem(LiveKind.fill, card.origin, requestId: card.requestId, fill: card));
        }
      case FillResolvedEvent(:final requestId, :final outcome):
        for (final i in items) {
          if (i.kind == LiveKind.fill && i.requestId == requestId) {
            i.fillOutcome = outcome;
            i.fillError = null;
          }
        }
      case ElicitationEvent(:final card):
        if (!items.any((i) => i.kind == LiveKind.elicit && i.requestId == card.requestId)) {
          items.add(LiveItem(LiveKind.elicit, card.message, requestId: card.requestId)
            ..elicit = card
            ..turnId = o.turnId);
        }
      case ElicitationResolvedEvent(:final requestId, :final outcome, :final label):
        for (final i in items) {
          if (i.kind == LiveKind.elicit && i.requestId == requestId) {
            i.elicitOutcome = outcome;
            if (label != null) i.elicitLabel = label;
            i.elicitError = null;
          }
        }
      case CapabilityRequestEvent(:final card):
        final it = LiveItem(LiveKind.capability, card.summary, requestId: card.requestId)..capability = card;
        final at = items.indexWhere((i) => i.kind == LiveKind.capability && i.requestId == card.requestId);
        // Asked again (a declined request reopened): the card opens again in place.
        if (at >= 0) {
          items[at] = it;
        } else {
          items.add(it);
        }
      case CapabilityResolvedEvent(:final requestId, :final status, :final text):
        for (final i in items) {
          if (i.kind == LiveKind.capability && i.requestId == requestId) {
            i.capabilityStatus = status;
            i.capabilityText = text;
          }
        }
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
    suggestion = null;
    busy = true;
    _orderer = OutputOrderer();
    _segments.clear();
    _turnId = newTurnId();
    final frame = _encode({
      'text': t,
      'turnId': _turnId,
      if (thread != null) 'thread': thread,
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

  /// Answers a Fill card: [values] (`{field, value}` / `{field, checked}`) or
  /// [cancel]. The values go straight onto the socket and are not kept here.
  /// False when the chat isn't connected: nothing was sent.
  bool answerFill(LiveItem item, {List<Map<String, Object>>? values, bool cancel = false}) {
    final id = item.requestId;
    if (id == null || item.fillSent || item.fillOutcome != null) return false;
    if (!_ready || (_ws == null && _testWrite == null)) {
      item.fillError = 'not_connected';
      notifyListeners();
      return false;
    }
    _write(_encode({
      'type': 'fill_submit',
      'requestId': id,
      if (cancel) 'cancel': true else 'values': values ?? const [],
      'agentId': agentId,
    }));
    item.fillSent = true;
    item.fillError = null;
    if (cancel) item.fillOutcome = 'cancelled';
    notifyListeners();
    return true;
  }

  /// Answers a question card with [value]: a picked option or typed text, a
  /// number, a multi-select's list, a form's value per field, or null to
  /// dismiss (a consent card takes its own URL back). The answer goes
  /// straight onto the socket and is not kept here; the daemon settles the
  /// card, so a refused answer leaves it open. False when the chat isn't
  /// connected: nothing was sent.
  bool answerElicit(LiveItem item, Object? value) {
    final id = item.requestId;
    if (id == null || item.elicit == null || item.elicitSent || item.elicitOutcome != null) return false;
    if (!_ready || (_ws == null && _testWrite == null)) {
      item.elicitError = 'not_connected';
      notifyListeners();
      return false;
    }
    _write(_encode({'type': 'elicitation_choice', 'requestId': id, 'value': value, 'agentId': agentId}));
    item.elicitSent = true;
    item.elicitError = null;
    notifyListeners();
    return true;
  }

  /// Opens a question card again after an answer that got no verdict.
  void reopenElicit(LiveItem item) {
    if (!item.elicitSent || item.elicitOutcome != null) return;
    item.elicitSent = false;
    notifyListeners();
  }

  /// Asks for a Fill card asked on a chat platform (a console link's
  /// `?fill=<requestId>`). The daemon answers on its own `fill:` stream, and
  /// only for the person who asked; anyone else gets a refusal. Sent once the
  /// chat is ready.
  void openFill(String requestId) {
    final f = _encode({'type': 'fill_open', 'requestId': requestId, 'agentId': agentId});
    if (_ready) {
      _write(f);
    } else {
      _pendingRun.add(f);
    }
  }

  /// Run settings for the session's next turn. Optimistic: the next status
  /// snapshot confirms. Callers must have write access (403 otherwise).
  void setModel(String model) => _runChange({'type': 'set_model', 'model': model},
      RunStatus(model: model));
  void setEffort(String effort) => _runChange({'type': 'set_effort', 'effort': effort},
      RunStatus(effort: effort));
  void setPermissionMode(String mode) => _runChange(
      {'type': 'set_permission_mode', 'permissionMode': mode}, RunStatus(permissionMode: mode));

  void setFast(bool on) => _runChange({'type': 'set_fast', 'fastMode': on}, RunStatus(fastMode: on));

  /// Drops the offered next prompt (the person sent something else).
  void clearSuggestion() {
    if (suggestion == null) return;
    suggestion = null;
    notifyListeners();
  }

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

  void Function(String)? _testWrite;

  /// Tests: a connected chat whose outgoing frames go to [write].
  @visibleForTesting
  void debugConnect(void Function(String) write) {
    _testWrite = write;
    _ready = true;
    conn = ChatConn.ready;
  }

  /// Tests: handles [raw] as a server frame.
  @visibleForTesting
  void debugFrame(String raw) => _onFrame(raw);

  void _write(String s) {
    final t = _testWrite;
    if (t != null) return t(s);
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
