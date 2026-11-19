import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import 'attachments.dart';
import 'frames.dart';

enum LiveKind { user, agent, thinking, tool, notice, permission, fill, unsupported }

class LiveItem {
  LiveItem(this.kind, this.text,
      {this.key,
      this.status,
      this.requestId,
      this.detail,
      this.fill,
      this.images = const [],
      this.files = const []});
  final LiveKind kind;
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
  String text;

  /// A user message sent into the running turn (`steer: true`), and whether
  /// the daemon confirmed it went in ([steered]).
  bool steer = false;
  bool steered = false;
  final String? key; // segmentId / toolCallId
  String? status;
  final String? requestId;
  final String? detail;
  bool answered = false;
  bool? allowed;
}

enum ChatConn { connecting, ready, lost, readOnly, failed }

/// A message sent while a turn was running: it goes out when that turn ends.
/// Held in memory only, with its attachments.
class QueuedMessage {
  QueuedMessage._(this.seq, this.text, this.images, this.files);

  /// Send order across queued and steered messages.
  final int seq;
  final String text;
  final List<ImageAttachment> images;
  final List<UploadedFile> files;
}

enum ComposerNoteKind {
  /// Queued messages were dropped: the connection was lost.
  queueLost,

  /// Queued messages were dropped: the conversation can't be written to.
  queueReadOnly,

  /// A message sent into the running turn was refused: the agent is paused.
  steerPaused,

  /// A message sent into the running turn was refused.
  steerRefused,

  /// The running turn's stream could not be picked up on a new connection,
  /// and the turn may still be running.
  turnLost,

  /// A message nobody answered before the connection dropped: it may never
  /// have arrived.
  turnUnconfirmed,

  /// A message sent again after a reconnect was refused: the agent is busy.
  turnBusy,
}

/// Something that happened to a message the person sent, shown above the box.
class ComposerNote {
  const ComposerNote(this.kind, [this.count = 1]);
  final ComposerNoteKind kind;
  final int count;
}

/// A steer waiting for the daemon's verdict.
class _Steer {
  _Steer(this.item, this.frame, this.seq, this.socket);
  final LiveItem item;
  final String frame;
  final int seq;

  /// The connection the frame last went out on.
  int socket;

  /// It went out on more than one.
  bool resent = false;
}

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

  /// Messages waiting for the running turn to end, oldest first.
  List<QueuedMessage> get queue => List.unmodifiable(_queue);
  final List<QueuedMessage> _queue = [];

  /// What became of a message that didn't go out; cleared by the next send.
  ComposerNote? note;

  /// The running turn takes a message sent now (`output.status.steerable`).
  bool get steerable => busy && _steerable;
  bool _steerable = false;
  int _seq = 0;
  int _socket = 0;

  /// Steers awaiting a verdict, by their turn id.
  final Map<String, _Steer> _steers = {};

  /// Every steer sent, settled or not: their own acks and `done` never start
  /// or end the turn that is running.
  final Set<String> _steerIds = {};

  /// Steers the daemon ran as turns of their own instead, waiting for the
  /// running turn to end, oldest first: turn id to the connection its stream
  /// is on (0 when unknown).
  final Map<String, int> _ownTurns = {};

  /// The running turn's frame until the daemon answers it, and when it first
  /// went out. On a new connection an unanswered turn is sent again under the
  /// same turn id; an answered one is resumed.
  String? _unacked;
  DateTime? _unackedAt;

  /// The unanswered turn went out again on a later connection.
  bool _resent = false;

  /// The connection the running turn was last put on (sent or resumed); 0
  /// before the first.
  int _turnSocket = 0;

  /// Resumes sent for the running turn: the daemon only takes one numbered
  /// above the last (`generation`).
  int _resumeGen = 0;

  /// A resume waits for its verdict on this connection. [_attaching]: it
  /// checks a `busy` answer to a turn sent again. [_lenient]: the relay asked
  /// for it (`resync`), so "not now" leaves the turn running.
  bool _resuming = false;
  bool _attaching = false;
  bool _lenient = false;

  /// Tests: the wall clock.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

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
        _dropQueue(ComposerNoteKind.queueReadOnly);
      } else if (e.status == 503) {
        offline = true;
        conn = ChatConn.failed;
        _dropQueue(ComposerNoteKind.queueLost);
      } else {
        error = e;
        conn = ChatConn.failed;
        _dropQueue(ComposerNoteKind.queueLost);
      }
      notifyListeners();
    } catch (e) {
      error = e;
      conn = ChatConn.failed;
      _dropQueue(ComposerNoteKind.queueLost);
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
    _socket++;
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
    // Verdicts asked for on that connection never come.
    _resuming = _attaching = _lenient = false;
    if (conn == ChatConn.readOnly) return;
    conn = ChatConn.lost;
    _dropQueue(ComposerNoteKind.queueLost);
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
          _forget();
          _dropQueue(ComposerNoteKind.queueReadOnly);
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
          _turnSocket = _socket;
          _unackedAt = clock();
        }
        // A steer nobody answered rides the new connection under the same turn
        // id: the daemon confirms a copy it already took, never runs it twice.
        for (final s in _steers.values) {
          if (s.socket == _socket) continue;
          s.socket = _socket;
          s.resent = true;
          _write(s.frame);
        }
        _recover();
      case AckFrame(turnId: final id?) when _steerIds.contains(id):
        final s = _steers.remove(id);
        if (s != null) _settleSteer(id, s, f);
      // A turn sent again after a reconnect and answered `busy`: the first copy
      // may be the turn that is running (its ack was lost), or the agent is
      // busy with something else. A resume finds that turn's stream, or doesn't.
      case AckFrame(accepted: false, reason: 'busy', turnId: final id?) when busy && _resent && id == _turnId:
        _attaching = true;
        _resume();
      case AckFrame(:final accepted, :final turnId):
        if (!accepted) {
          busy = false;
          _forget();
        } else if (turnId != null) {
          _turnId = turnId;
          _unacked = null;
        }
      case ResumedFrame(:final accepted, :final turnId, :final reason):
        // Only the verdict this connection waits for, on the turn still running.
        if (!_resuming || (turnId != null && turnId != _turnId)) break;
        final attaching = _attaching, lenient = _lenient;
        _resuming = _attaching = _lenient = false;
        if (accepted) {
          // The stream is on this connection: what was missed comes replayed.
          _unacked = null;
        } else if (lenient && (reason == 'stream_stale' || reason == 'no_agent')) {
          // Not now (no daemon link yet, or a newer resume holds the stream).
        } else if (attaching && reason == 'stream_not_found') {
          // No stream: `busy` was the answer to this message, which never ran.
          _loseTurn(ComposerNoteKind.turnBusy);
        } else if (reason == 'stream_not_found') {
          // The daemon holds no stream for it. An answered turn is over, and
          // the reload shows it; an unanswered one may never have arrived.
          _loseTurn(_unacked == null ? null : ComposerNoteKind.turnUnconfirmed);
        } else {
          _loseTurn(ComposerNoteKind.turnLost);
        }
      // A steered message's own stream ends at once; the running turn goes on.
      case DoneFrame(turnId: final id?, :final stopReason) when id != _turnId && _steerIds.contains(id):
        final s = _steers.remove(id);
        if (s != null) {
          if (joinedTurnStopReasons.contains(stopReason)) {
            s.item.steered = true;
          } else {
            s.item.steer = false;
          }
        }
        _ownTurns.remove(id);
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
        if (st?.steerable != null) _steerable = st!.steerable!;
        if (f.turnId == _turnId) _unacked = null;
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
      case DoneFrame():
        for (final o in _orderer.flush()) {
          _apply(o);
        }
        busy = false;
        statusLine = null;
        waitingApproval = false;
        _turnId = null;
        _forget();
        _nextOwnTurn();
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
        if (_resuming && _lenient) {
          // The relay couldn't deliver a resume it asked for: the turn goes on.
          _resuming = _lenient = false;
          break;
        }
        if (_resuming) {
          // The resume itself failed (no daemon link, or a relay without it).
          _loseTurn(ComposerNoteKind.turnLost);
        } else {
          busy = false;
          statusLine = null;
          _forget();
        }
        error = StateError('frame');
      // The agent's daemon relinked to the relay: what it streamed meanwhile
      // never got here, so ask for it again.
      case OtherFrame(type: 'resync'):
        if (busy && _ready && _turnId != null && _unacked == null && participants <= 1) {
          _lenient = true;
          _resume();
        }
      case OtherFrame():
        break;
    }
    _drain();
    notifyListeners();
  }

  /// The daemon's verdict on a message sent into the running turn.
  void _settleSteer(String id, _Steer s, AckFrame ack) {
    if (!ack.accepted) {
      items.remove(s.item);
      if (ack.reason == 'busy') {
        // The definite "not into this turn": it waits its turn instead, at
        // the place it was sent.
        final at = _queue.indexWhere((q) => q.seq > s.seq);
        _queue.insert(at < 0 ? _queue.length : at, QueuedMessage._(s.seq, s.item.text, const [], const []));
      } else {
        note = ComposerNote(
            ack.reason == 'paused' ? ComposerNoteKind.steerPaused : ComposerNoteKind.steerRefused);
      }
    } else if (ack.steered) {
      s.item.steered = true;
    } else {
      // The turn had ended: the message runs as a turn of its own, and
      // nothing more goes into the ended one.
      s.item.steer = false;
      _steerable = false;
      // Its stream is on the connection the message went out on, if only one.
      final on = s.resent ? 0 : s.socket;
      if (busy) {
        _ownTurns[id] = on;
      } else {
        _openTurn(id, on);
      }
    }
  }

  /// A turn the daemon started for a message already shown. Its stream is on
  /// connection [socket] (0: unknown): from another one it is resumed.
  void _openTurn(String id, int socket) {
    busy = true;
    _steerable = false;
    _orderer = OutputOrderer();
    _segments.clear();
    _turnId = id;
    _forget();
    _turnSocket = socket;
    if (_ready) _recover();
  }

  /// The oldest message the daemon ran as a turn of its own takes over.
  void _nextOwnTurn() {
    if (_ownTurns.isEmpty) return;
    final id = _ownTurns.keys.first;
    _openTurn(id, _ownTurns.remove(id)!);
  }

  /// How long after it went out an unanswered turn may be sent again. The
  /// daemon answers a second copy `busy` while it still holds the first one's
  /// stream: as long as that turn runs and five minutes after
  /// (`WEBCHAT_REPLAY_TTL_MS`). Past that a copy would run the turn twice.
  static const _resendWindow = Duration(minutes: 4);

  /// Puts the running turn on a new connection: an unanswered one is sent
  /// again under the same turn id, an answered one is resumed.
  void _recover() {
    if (!busy || _turnId == null || _turnSocket == _socket) return;
    _turnSocket = _socket;
    // A room's turn streams from each agent on its own; this chat follows one
    // stream, so it can't say where each stopped.
    if (participants > 1) {
      return _loseTurn(_unacked == null ? ComposerNoteKind.turnLost : ComposerNoteKind.turnUnconfirmed);
    }
    final frame = _unacked;
    final at = _unackedAt;
    if (frame != null && at != null && clock().difference(at) < _resendWindow) {
      _resent = true;
      _write(frame);
    } else {
      _resume();
    }
  }

  /// Asks the daemon to send the running turn's stream on this connection,
  /// replayed after the last output applied here. `resumed` is its verdict.
  void _resume() {
    _resuming = true;
    _write(_encode({
      'type': 'resume',
      'turnId': _turnId,
      'generation': ++_resumeGen,
      'afterIndex': _orderer.applied,
    }));
  }

  /// The running turn can't be followed any more: it ends here, with a note
  /// unless it is known to be over. The transcript reload that follows shows
  /// what the agent saved.
  void _loseTurn(ComposerNoteKind? why) {
    busy = false;
    statusLine = null;
    waitingApproval = false;
    _turnId = null;
    _forget();
    if (why != null) note = ComposerNote(why);
    _nextOwnTurn();
  }

  /// Clears what was kept to recover the turn that ended (or to start one).
  void _forget() {
    _unacked = null;
    _unackedAt = null;
    _resent = false;
    _turnSocket = 0;
    _resumeGen = 0;
    _resuming = _attaching = _lenient = false;
  }

  /// Sends the oldest queued message once nothing is running.
  void _drain() {
    if (busy || !_ready || _queue.isEmpty || _steers.isNotEmpty) return;
    final q = _queue.removeAt(0);
    _start(q.text, q.images, q.files);
  }

  void _dropQueue(ComposerNoteKind why) {
    if (_queue.isEmpty) return;
    note = ComposerNote(why, _queue.length);
    _queue.clear();
  }

  /// Frames of another thread (or of the root, in a thread) aren't this chat's.
  bool _mine(String? frameThread) => anyThread || frameThread == thread;

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
      case UnsupportedEvent():
        if (!items.any((i) => i.kind == LiveKind.unsupported)) {
          items.add(LiveItem(LiveKind.unsupported, ''));
        }
    }
  }

  /// Sends a turn. [images] travel inline (one at most, within the image
  /// budget); [files] were uploaded first and are named by upload id.
  ///
  /// While a turn is running the message goes into that turn when the runtime
  /// takes one ([steerable]); otherwise it waits in [queue], with its
  /// attachments, and goes out when the turn ends.
  void send(String text, {List<ImageAttachment> images = const [], List<UploadedFile> files = const []}) {
    final t = text.trim();
    if (t.isEmpty && images.isEmpty && files.isEmpty) return;
    note = null;
    // An unanswered steer may yet become a turn: nothing overtakes it.
    if (busy || _queue.isNotEmpty || _steers.isNotEmpty) {
      suggestion = null;
      if (_canSteer && images.isEmpty && files.isEmpty) {
        _steer(t);
      } else {
        _queue.add(QueuedMessage._(++_seq, t, images, files));
      }
    } else {
      _start(t, images, files);
    }
    notifyListeners();
  }

  /// Text only (a steer carries no attachment), nothing already waiting, one
  /// agent, and never across threads.
  bool get _canSteer =>
      steerable && _ready && _queue.isEmpty && participants <= 1 && thread == null && !anyThread;

  void _steer(String t) {
    final id = newTurnId();
    final item = LiveItem(LiveKind.user, t)..steer = true;
    items.add(item);
    final frame = _encode({'text': t, 'turnId': id, 'steer': true});
    _steers[id] = _Steer(item, frame, ++_seq, _socket);
    _steerIds.add(id);
    _write(frame);
  }

  /// Takes a queued message back before it goes out.
  void cancelQueued(QueuedMessage q) {
    if (_queue.remove(q)) notifyListeners();
  }

  void dismissNote() {
    if (note == null) return;
    note = null;
    notifyListeners();
  }

  void _start(String t, List<ImageAttachment> images, List<UploadedFile> files) {
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
    _steerable = false;
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
    _forget();
    _unacked = frame;
    if (_ready) {
      _write(frame);
      _turnSocket = _socket;
      _unackedAt = clock();
    } else {
      _pendingSend = frame;
    }
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
    _socket++;
    conn = ChatConn.ready;
  }

  /// Tests: the connection closed.
  @visibleForTesting
  void debugClosed() => _onClosed();

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
