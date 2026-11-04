import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../auth/http_fetch.dart';
import '../auth/oauth_session.dart';

export '../auth/http_fetch.dart' show NetworkException;
import 'approvals.dart';
import 'models.dart';
import 'workspace.dart';

class ApiException implements Exception {
  ApiException(this.status, [this.code, this.message]);
  final int status;
  final String? code;

  /// Server message (never shown verbatim; used to tell a read-only grant apart).
  final String? message;

  /// 403 because the sign-in was granted without write access.
  bool get readOnlyGrant =>
      status == 403 && (message?.contains('read-only') ?? false);
  @override
  String toString() => 'ApiException($status)';
}

/// The server answered, but not with JSON (typically a web page).
class BadResponseException implements Exception {}

/// Thin HTTP client. It never logs URLs, headers or bodies.
class ApiClient {
  ApiClient(this.apiBase, this.tokens, {this.onUnauthorized}) {
    _http
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'AgentConnect-iOS/1.0';
  }

  final String apiBase;

  /// The only source of credentials (see `core/auth`).
  final TokenProvider tokens;
  final void Function()? onUnauthorized;
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
      path: '$basePath$path',
      queryParameters: q.isEmpty ? null : q,
    );
  }

  /// Sets the Bearer header and returns the token used, so a 401 can be
  /// matched to it. Throws [SignInEnded] when the sign-in is gone.
  Future<String> authorize(HttpClientRequest req) async {
    final String cred;
    try {
      cred = await tokens.accessToken();
    } on SignInEnded {
      onUnauthorized?.call();
      throw ApiException(401);
    }
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $cred');
    req.headers.set(HttpHeaders.userAgentHeader, 'AgentConnect-iOS/1.0');
    return cred;
  }

  /// After a 401: true when a refreshed token is ready for one retry.
  Future<bool> recoverFromUnauthorized(String used) =>
      tokens.refreshAfter401(used);

  Future<dynamic> request(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
  }) async {
    final bytes = await _send(method, path, query: query, body: body);
    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw BadResponseException();
    }
  }

  /// A raw response body (file downloads); errors as [request].
  Future<Uint8List> requestBytes(String path, {Map<String, String?>? query}) =>
      _send('GET', path, query: query, accept: '*/*', timeout: const Duration(seconds: 90));

  Future<Uint8List> _send(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
    String accept = 'application/json',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    var retried = false;
    while (true) {
      try {
        final req = await _http.openUrl(method, uri(path, query));
        final used = await authorize(req);
        req.headers.set(HttpHeaders.acceptHeader, accept);
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.add(utf8.encode(jsonEncode(body)));
        }
        final res = await req.close().timeout(const Duration(seconds: 30));
        final builder = BytesBuilder(copy: false);
        await res.forEach(builder.add).timeout(timeout);
        final bytes = builder.takeBytes();
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
          String? message;
          try {
            final m = asMap(jsonDecode(utf8.decode(bytes)));
            code = asStr(m['code']);
            message = asStr(m['message']);
          } catch (_) {}
          throw ApiException(status, code, message);
        }
        return bytes;
      } on SocketException {
        throw NetworkException();
      } on TimeoutException {
        throw NetworkException();
      } on TlsException {
        throw NetworkException();
      } on HttpException {
        throw NetworkException();
      }
    }
  }

  Future<Me> me() async => Me.fromJson(await request('GET', '/me'));

  Future<List<Org>> orgs() async =>
      asList(await request('GET', '/orgs')).map(Org.fromJson).toList();

  /// Status of `GET /orgs/{org}/agents` without throwing: used to find the one
  /// organization a sign-in is bound to (other orgs answer 404).
  Future<int> probeOrg(String org) async {
    try {
      await request('GET', '/orgs/$org/agents');
      return 200;
    } on ApiException catch (e) {
      return e.status;
    }
  }

  Future<List<Machine>> machines(String org) async =>
      asList(await request('GET', '/orgs/$org/daemons'))
          .map(Machine.fromJson)
          .where((m) => m.id.isNotEmpty)
          .toList();

  Future<List<Agent>> agents(String org) async =>
      asList(await request('GET', '/orgs/$org/agents'))
          .map(Agent.fromJson)
          .toList();

  Future<ConversationPage> conversations(
    String org, {
    String? cursor,
    String? triggeredBy,
    String? platform,
    int limit = 30,
  }) async {
    final j = await request(
      'GET',
      '/orgs/$org/sessions',
      query: {
        'limit': '$limit',
        'cursor': cursor,
        'triggeredBy': triggeredBy,
        'platform': platform,
      },
    );
    return ConversationPage.fromJson(j);
  }

  Future<List<SessionRow>> awaitingSessions(String org) async {
    final j = await request(
      'GET',
      '/orgs/$org/sessions',
      query: {
        'view': 'flat',
        'activityState': 'awaiting_permission',
        'limit': '200',
      },
    );
    return asList(asMap(j)['sessions']).map(SessionRow.fromJson).toList();
  }

  Future<MessagePage> messages(
    String org,
    String sessionId, {
    String? cursor,
    int limit = 50,
  }) async {
    final j = await request(
      'GET',
      '/orgs/$org/sessions/$sessionId/messages',
      query: {'limit': '$limit', 'cursor': cursor},
    );
    return MessagePage.fromJson(j);
  }

  Future<ToolBodyChunk> toolBody(
    String org,
    String sessionId,
    String toolCallId, {
    int offset = 0,
  }) async {
    final j = await request(
      'GET',
      '/orgs/$org/sessions/$sessionId/tool-body',
      query: {'toolCallId': toolCallId, 'offset': '$offset'},
    );
    return ToolBodyChunk.fromJson(j);
  }

  Future<List<Approval>> agentApprovals(String org, String agentId) async {
    final j = await request(
      'GET',
      '/orgs/$org/agents/$agentId/permission-requests',
    );
    return asList(asMap(j)['requests']).map(Approval.fromJson).toList();
  }

  Future<List<Approval>> sessionApprovals(String org, String sessionId) async {
    final j = await request(
      'GET',
      '/orgs/$org/sessions/$sessionId/permission-requests',
    );
    return asList(asMap(j)['requests'])
        .map((e) => Approval.fromJson(e)..viaSession = true)
        .toList();
  }

  Future<void> decide(String org, Approval a, ApprovalOption o) async {
    final base = a.viaSession
        ? '/orgs/$org/sessions/${a.sessionId}'
        : '/orgs/$org/agents/${a.agentId}';
    await request(
      'POST',
      '$base/permission-requests/${a.id}/decision',
      body: {
        'decision': o.isAllow ? 'allow' : 'deny',
        if (o.id.isNotEmpty) 'optionId': o.id,
      },
    );
  }

  Future<WebchatGrant> newChatGrant(String org, String agentId) async {
    final j = await request(
      'POST',
      '/orgs/$org/agents/$agentId/webchat/token',
      body: {'protocol': 'legacy'},
    );
    return WebchatGrant.fromJson(j);
  }

  /// Resumes a webchat conversation, as the web console does: the
  /// conversation-scoped mint first (it accepts any participant agent), the
  /// per-agent mint on 404 (a server that predates the conversation route).
  Future<WebchatGrant> resumeChatGrant(String org, String agentId, String conversationId) async {
    try {
      return WebchatGrant.fromJson(await request(
        'POST',
        '/orgs/$org/webchat/conversations/token',
        body: {'conversationId': conversationId, 'protocol': 'legacy'},
      ));
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
    }
    return WebchatGrant.fromJson(await request(
      'POST',
      '/orgs/$org/agents/$agentId/webchat/token',
      body: {'conversationId': conversationId, 'protocol': 'legacy'},
    ));
  }

  /// Continues a session of another origin (hook, Slack…) or a delegated task.
  Future<WebchatGrant> continueChatGrant(String org, String sessionId) async {
    final j = await request(
      'POST',
      '/orgs/$org/sessions/$sessionId/webchat/token',
      body: {'protocol': 'legacy'},
    );
    return WebchatGrant.fromJson(j);
  }

  /// Tasks a conversation started (newest first). 409 when the daemon is too old.
  Future<List<AgentTask>> tasks(String org, String agentId, String parentSessionId) async {
    final j = await request('GET', '/orgs/$org/agents/$agentId/assistant/subsessions',
        query: {'parentSessionId': parentSessionId, 'limit': '50'});
    return asList(asMap(j)['subsessions']).map(AgentTask.fromJson).toList();
  }

  Future<DirPage> files(String org, String agentId, {String? sessionId, String path = '', String? cursor}) async =>
      DirPage.fromJson(await request('GET', '/orgs/$org/agents/$agentId/workspace/files',
          query: {'sessionId': sessionId, 'path': path.isEmpty ? null : path, 'limit': '200', 'cursor': cursor}));

  /// One slice of a text file (64 KiB from [offset]).
  Future<FileSlice> file(String org, String agentId, String path, {String? sessionId, int offset = 0}) async =>
      FileSlice.fromJson(await request('GET', '/orgs/$org/agents/$agentId/workspace/file',
          query: {'sessionId': sessionId, 'path': path, 'offset': offset > 0 ? '$offset' : null}));

  /// A file's original bytes (images, PDFs; up to 8 MiB, 413 above).
  Future<Uint8List> fileBytes(String org, String agentId, String path, {String? sessionId}) =>
      requestBytes('/orgs/$org/agents/$agentId/workspace/file/download',
          query: {'sessionId': sessionId, 'path': path});

  Future<GitStatus> gitStatus(String org, String agentId, {String? sessionId}) async =>
      GitStatus.fromJson(await request('GET', '/orgs/$org/agents/$agentId/workspace/gitstatus',
          query: {'sessionId': sessionId}));

  /// Stages [paths], then commits them. Needs edit access to the agent.
  Future<CommitResult> commit(String org, String agentId, List<String> paths, String message,
      {String? sessionId}) async {
    await request('POST', '/orgs/$org/agents/$agentId/workspace/gitstage',
        query: {'sessionId': sessionId}, body: {'paths': paths});
    return CommitResult.fromJson(await request('POST', '/orgs/$org/agents/$agentId/workspace/gitcommit',
        query: {'sessionId': sessionId}, body: {'message': message}));
  }

  /// Models a runtime on a daemon advertises (from the daemon's runtime profiles).
  Future<List<String>> runtimeModels(String org, String daemonId, String? runtime) async {
    final j = asMap(await request('GET', '/orgs/$org/daemons/$daemonId'));
    for (final p in asList(j['runtimeProfiles'])) {
      final m = asMap(p);
      if (runtime == null || asStr(m['runtime']) == runtime || asStr(m['aliasOf']) == runtime) {
        return asList(m['models'])
            .map((x) => x is String ? x : asStr(asMap(x)['id']) ?? asStr(asMap(x)['name']) ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      }
    }
    return const [];
  }

  void close() => _http.close(force: true);
}
