import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../auth/oidc_session.dart';
import 'approvals.dart';
import 'models.dart';

class ApiException implements Exception {
  ApiException(this.status, [this.code]);
  final int status;
  final String? code;
  @override
  String toString() => 'ApiException($status)';
}

class NetworkException implements Exception {}

/// The server answered, but not with JSON (typically a web page).
class BadResponseException implements Exception {}

/// Thin HTTP client. It never logs URLs, headers or bodies.
class ApiClient {
  ApiClient(this.apiBase, this.key, {this.onUnauthorized, this.session}) {
    _http
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'AgentConnect/1.0';
  }

  final String apiBase;
  final String key;
  final void Function()? onUnauthorized;

  /// Set for browser accounts: supplies and refreshes the access token.
  final OidcSession? session;
  final HttpClient _http = HttpClient();

  Uri uri(String path, [Map<String, String?>? query]) {
    final base = Uri.parse(apiBase);
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && v.isNotEmpty) q[k] = v;
    });
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
        path: '$basePath$path', queryParameters: q.isEmpty ? null : q);
  }

  /// Sets the Bearer header (API key or access token) and returns the
  /// credential used, so a 401 can be matched to it.
  Future<String> authorize(HttpClientRequest req) async {
    final cred = session != null ? await session!.accessToken() : key;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $cred');
    req.headers.set(HttpHeaders.userAgentHeader, 'AgentConnect/1.0');
    return cred;
  }

  /// After a 401: true when a refreshed token is ready for one retry.
  Future<bool> recoverFromUnauthorized(String used) async =>
      session != null && await session!.refreshAfter401(used);

  Future<dynamic> request(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
  }) async {
    var retried = false;
    while (true) {
    try {
      final req = await _http.openUrl(method, uri(path, query));
      final used = await authorize(req);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      final status = res.statusCode;
      if (status == 401) {
        if (!retried && await recoverFromUnauthorized(used)) {
          retried = true;
          continue;
        }
        onUnauthorized?.call();
        throw ApiException(401);
      }
      if (status >= 400) {
        String? code;
        try {
          code = asStr(asMap(jsonDecode(text))['code']);
        } catch (_) {}
        throw ApiException(status, code);
      }
      if (text.isEmpty) return null;
      try {
        return jsonDecode(text);
      } on FormatException {
        throw BadResponseException();
      }
    } on SocketException {
      throw NetworkException();
    } on TimeoutException {
      throw NetworkException();
    } on TlsException {
      throw NetworkException();
    } on HttpException {
      throw NetworkException();
    } on RefreshNetworkError {
      throw NetworkException();
    }
    }
  }

  Future<Me> me() async => Me.fromJson(await request('GET', '/me'));

  Future<List<Org>> orgs() async =>
      asList(await request('GET', '/orgs')).map(Org.fromJson).toList();

  Future<List<Agent>> agents(String org) async =>
      asList(await request('GET', '/orgs/$org/agents'))
          .map(Agent.fromJson)
          .toList();

  Future<ConversationPage> conversations(String org,
      {String? cursor, String? triggeredBy, int limit = 30}) async {
    final j = await request('GET', '/orgs/$org/sessions', query: {
      'limit': '$limit',
      'cursor': cursor,
      'triggeredBy': triggeredBy,
    });
    return ConversationPage.fromJson(j);
  }

  Future<List<SessionRow>> awaitingSessions(String org) async {
    final j = await request('GET', '/orgs/$org/sessions', query: {
      'view': 'flat',
      'activityState': 'awaiting_permission',
      'limit': '200',
    });
    return asList(asMap(j)['sessions']).map(SessionRow.fromJson).toList();
  }

  Future<MessagePage> messages(String org, String sessionId,
      {String? cursor, int limit = 50}) async {
    final j = await request('GET', '/orgs/$org/sessions/$sessionId/messages',
        query: {'limit': '$limit', 'cursor': cursor});
    return MessagePage.fromJson(j);
  }

  Future<ToolBodyChunk> toolBody(
      String org, String sessionId, String toolCallId,
      {int offset = 0}) async {
    final j = await request('GET', '/orgs/$org/sessions/$sessionId/tool-body',
        query: {'toolCallId': toolCallId, 'offset': '$offset'});
    return ToolBodyChunk.fromJson(j);
  }

  Future<List<Approval>> agentApprovals(String org, String agentId) async {
    final j =
        await request('GET', '/orgs/$org/agents/$agentId/permission-requests');
    return asList(asMap(j)['requests']).map(Approval.fromJson).toList();
  }

  Future<List<Approval>> sessionApprovals(String org, String sessionId) async {
    final j = await request(
        'GET', '/orgs/$org/sessions/$sessionId/permission-requests');
    return asList(asMap(j)['requests'])
        .map((e) => Approval.fromJson(e)..viaSession = true)
        .toList();
  }

  Future<void> decide(String org, Approval a, ApprovalOption o) async {
    final base = a.viaSession
        ? '/orgs/$org/sessions/${a.sessionId}'
        : '/orgs/$org/agents/${a.agentId}';
    await request('POST', '$base/permission-requests/${a.id}/decision', body: {
      'decision': o.isAllow ? 'allow' : 'deny',
      if (o.id.isNotEmpty) 'optionId': o.id,
    });
  }

  Future<WebchatGrant> newChatGrant(String org, String agentId) async {
    final j = await request('POST', '/orgs/$org/agents/$agentId/webchat/token',
        body: {'protocol': 'legacy'});
    return WebchatGrant.fromJson(j);
  }

  Future<WebchatGrant> continueChatGrant(String org, String sessionId) async {
    final j = await request(
        'POST', '/orgs/$org/sessions/$sessionId/webchat/token',
        body: {'protocol': 'legacy'});
    return WebchatGrant.fromJson(j);
  }

  void close() => _http.close(force: true);
}
