import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../api/api_client.dart';
import '../api/models.dart';
import 'sse_parser.dart';

class LiveEvent {
  const LiveEvent(this.kind, {this.sessionId, this.state});
  /// 'connected' (fresh connection: refresh everything), 'session',
  /// 'session-activity' or 'session-state'.
  final String kind;
  final String? sessionId;
  final String? state;
}

/// Org event stream. Reconnects with exponential backoff and every 5 minutes.
/// Events carry no ids, so every (re)connect emits 'connected' and listeners
/// reload what is visible. Event payloads are never logged or stored.
class LiveUpdates {
  LiveUpdates(this.client, this.orgId);
  final ApiClient client;
  final String orgId;
  final _controller = StreamController<LiveEvent>.broadcast();
  Stream<LiveEvent> get events => _controller.stream;

  bool _running = false;
  int _attempt = 0;
  HttpClient? _http;
  Timer? _cycle;
  Timer? _retry;

  void start() {
    if (_running) return;
    _running = true;
    _attempt = 0;
    _connect();
  }

  void stop() {
    _running = false;
    _cycle?.cancel();
    _retry?.cancel();
    _http?.close(force: true);
    _http = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  Future<void> _connect() async {
    if (!_running) return;
    final http = HttpClient()..userAgent = 'AgentConnect/1.0';
    _http = http;
    var gotData = false;
    try {
      final req = await http.getUrl(client.uri('/orgs/$orgId/stream'));
      client.authorize(req);
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final res = await req.close();
      if (res.statusCode == 401) {
        client.onUnauthorized?.call();
        return;
      }
      if (res.statusCode != 200) throw ApiException(res.statusCode);
      gotData = true;
      _attempt = 0;
      _controller.add(const LiveEvent('connected'));
      _cycle?.cancel();
      _cycle = Timer(const Duration(minutes: 5), () {
        http.close(force: true);
      });
      await for (final e in parseSse(res)) {
        _controller.add(decodeLiveEvent(e) ?? const LiveEvent('other'));
      }
    } catch (_) {
      // fall through to the reconnect below
    } finally {
      http.close(force: true);
      _cycle?.cancel();
    }
    if (!_running) return;
    final delay = gotData && _attempt == 0
        ? const Duration(seconds: 1)
        : Duration(seconds: min(60, pow(2, _attempt).toInt()));
    _attempt++;
    _retry = Timer(delay, _connect);
  }
}

LiveEvent? decodeLiveEvent(SseEvent e) {
  if (e.event != 'session' &&
      e.event != 'session-activity' &&
      e.event != 'session-state') {
    return null;
  }
  Map<String, dynamic> m = {};
  try {
    m = asMap(jsonDecode(e.data));
  } catch (_) {}
  return LiveEvent(e.event,
      sessionId: asStr(m['sessionId']), state: asStr(m['state']));
}
