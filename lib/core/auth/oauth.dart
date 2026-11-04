import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'http_fetch.dart';

/// OAuth 2.1 public client for the AgentConnect authorization server:
/// RFC 9728 + RFC 8414 discovery, RFC 7591 registration, authorization code
/// with PKCE (RFC 7636), RFC 8707 resource, refresh and (when offered) RFC 7009
/// revocation. Pure protocol: no storage, no UI.

const oauthScopes = 'mcp:read mcp:write';
const clientName = 'AgentConnect for iOS';

// ---- PKCE ----

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String pkceChallenge(String verifier) =>
    base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

String randomUrlSafe([int bytes = 32, Random? rng]) {
  final r = rng ?? Random.secure();
  return base64UrlNoPad(List<int>.generate(bytes, (_) => r.nextInt(256)));
}

// ---- Errors ----

/// The server's OAuth error (`{"error": ...}`), or a protocol failure.
class OAuthError implements Exception {
  OAuthError(this.code, {this.status});
  final String code;
  final int? status;
  bool get invalidClient => code == 'invalid_client';
  bool get invalidGrant => code == 'invalid_grant';
  @override
  String toString() => 'OAuthError($code)';
}

/// The address has no AgentConnect sign-in (no discovery documents).
class NotAnAgentConnectServer implements Exception {}

Map<String, dynamic>? _json(String body) {
  try {
    final m = jsonDecode(body);
    return m is Map<String, dynamic> ? m : null;
  } catch (_) {
    return null;
  }
}

String? _s(dynamic v) => v is String && v.isNotEmpty ? v : null;

OAuthError _errorOf(FetchResult r, String fallback) =>
    OAuthError(_s(_json(r.body)?['error']) ?? fallback, status: r.status);

// ---- Discovery ----

class AuthServer {
  const AuthServer({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.registrationEndpoint,
    this.revocationEndpoint,
    this.resource,
    this.raw = const {},
  });
  final String issuer;
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String registrationEndpoint;
  final String? revocationEndpoint;

  /// `resource` from the protected resource metadata, sent as RFC 8707 `resource`.
  final String? resource;

  /// The raw documents (for API notes / debugging; contain no secrets).
  final Map<String, dynamic> raw;
}

String _trimSlash(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;

/// RFC 8414 §3: the well-known segment goes between the host and the issuer path.
Uri asMetadataUrl(String issuer) {
  final u = Uri.parse(issuer);
  final path = _trimSlash(u.path);
  return u.replace(
    path: '/.well-known/oauth-authorization-server$path',
    query: null,
  );
}

/// PRM locations to try for an API base: the origin root (RFC 9728 for the
/// origin), then path-inserted for the MCP resource under the API path
/// (`/.well-known/oauth-protected-resource/v1/mcp`), which some deployments
/// forward instead.
List<Uri> prmCandidates(String apiBase) {
  final u = Uri.parse(apiBase);
  final origin = Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
  );
  final apiPath = _trimSlash(u.path);
  return [
    origin.replace(path: '/.well-known/oauth-protected-resource'),
    if (apiPath.isNotEmpty)
      origin.replace(path: '/.well-known/oauth-protected-resource$apiPath/mcp'),
  ];
}

/// `resource_metadata` from a `WWW-Authenticate: Bearer ...` challenge.
Uri? resourceMetadataFromChallenge(String? header) {
  if (header == null) return null;
  final m = RegExp(r'resource_metadata="([^"]+)"').firstMatch(header);
  final u = m == null ? null : Uri.tryParse(m.group(1)!);
  return u != null && u.scheme == 'https' ? u : null;
}

Future<Map<String, dynamic>?> _prm(Uri url, Fetch fetch) async {
  final r = await fetch(url);
  if (r.status != 200) return null;
  final m = _json(r.body);
  return m != null && m['authorization_servers'] is List ? m : null;
}

/// Finds the authorization server for an API base:
/// 1. RFC 9728 metadata at the API origin (root, then path-inserted for `/v1/mcp`);
/// 2. otherwise the challenge of the API's MCP endpoint: an unauthenticated
///    `POST {apiBase}/mcp` answers 401 with `WWW-Authenticate: Bearer
///    resource_metadata="..."` (RFC 9728 §5.1). Deployments with a dedicated
///    MCP host serve the metadata only there.
Future<AuthServer> discover(
  String apiBase, {
  Fetch fetch = defaultFetch,
}) async {
  Map<String, dynamic>? prm;
  for (final url in prmCandidates(apiBase)) {
    prm = await _prm(url, fetch);
    if (prm != null) break;
  }
  if (prm == null) {
    final r = await fetch(
      Uri.parse('${_trimSlash(apiBase)}/mcp'),
      json: const {},
    );
    final meta = r.status == 401
        ? resourceMetadataFromChallenge(r.wwwAuthenticate)
        : null;
    if (meta != null) prm = await _prm(meta, fetch);
  }
  if (prm == null) throw NotAnAgentConnectServer();
  final servers = (prm['authorization_servers'] as List)
      .whereType<String>()
      .toList();
  if (servers.isEmpty) throw NotAnAgentConnectServer();
  final issuer = servers.first;
  final r = await fetch(asMetadataUrl(issuer));
  final meta = r.status == 200 ? _json(r.body) : null;
  if (meta == null) throw NotAnAgentConnectServer();
  final authz = _s(meta['authorization_endpoint']);
  final token = _s(meta['token_endpoint']);
  final reg = _s(meta['registration_endpoint']);
  if (authz == null || token == null || reg == null) {
    throw NotAnAgentConnectServer();
  }
  final methods = meta['code_challenge_methods_supported'];
  if (methods is List && !methods.contains('S256')) {
    throw NotAnAgentConnectServer();
  }
  return AuthServer(
    issuer: _s(meta['issuer']) ?? issuer,
    authorizationEndpoint: authz,
    tokenEndpoint: token,
    registrationEndpoint: reg,
    revocationEndpoint: _s(meta['revocation_endpoint']),
    resource: _s(prm['resource']),
    raw: {'protectedResource': prm, 'authorizationServer': meta},
  );
}

// ---- Registration (RFC 7591) ----

class ClientRegistration {
  const ClientRegistration(this.clientId, this.issuedAt);
  final String clientId;
  final DateTime issuedAt;

  /// Registrations expire after 90 days; renew a little early, before the
  /// browser shows the server's bare `invalid_client` error page.
  static const lifetime = Duration(days: 90);
  static const renewBefore = Duration(days: 3);
  bool isStale(DateTime now) =>
      !now.isBefore(issuedAt.add(lifetime - renewBefore));

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'issuedAt': issuedAt.millisecondsSinceEpoch,
  };
  static ClientRegistration? fromJson(dynamic j) {
    if (j is! Map) return null;
    final c = j['clientId'], t = j['issuedAt'];
    if (c is! String || c.isEmpty || t is! int) return null;
    return ClientRegistration(c, DateTime.fromMillisecondsSinceEpoch(t));
  }
}

Future<ClientRegistration> register(
  AuthServer s,
  String redirectUri, {
  Fetch fetch = defaultFetch,
  DateTime Function() now = DateTime.now,
}) async {
  final r = await fetch(
    Uri.parse(s.registrationEndpoint),
    json: {
      'client_name': clientName,
      'redirect_uris': [redirectUri],
      'grant_types': ['authorization_code', 'refresh_token'],
    },
  );
  if (r.status != 200 && r.status != 201) {
    throw _errorOf(r, 'registration_failed');
  }
  final m = _json(r.body);
  final id = _s(m?['client_id']);
  if (id == null) throw OAuthError('registration_failed', status: r.status);
  final at = m?['client_id_issued_at'];
  return ClientRegistration(
    id,
    at is num ? DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000) : now(),
  );
}

// ---- Authorization ----

class AuthRequest {
  const AuthRequest(this.url, this.state, this.verifier, this.redirectUri);
  final Uri url;
  final String state;
  final String verifier;
  final String redirectUri;
}

AuthRequest buildAuthRequest(
  AuthServer s,
  String clientId,
  String redirectUri, {
  String? verifier,
  String? state,
}) {
  final v = verifier ?? randomUrlSafe(48);
  final st = state ?? randomUrlSafe(24);
  final base = Uri.parse(s.authorizationEndpoint);
  final q = <String, String>{
    ...base.queryParameters,
    'response_type': 'code',
    'client_id': clientId,
    'redirect_uri': redirectUri,
    'scope': oauthScopes,
    'state': st,
    'code_challenge': pkceChallenge(v),
    'code_challenge_method': 'S256',
    if (s.resource != null) 'resource': s.resource!,
  };
  return AuthRequest(base.replace(queryParameters: q), st, v, redirectUri);
}

/// Checks the request before the browser opens: the authorization endpoint
/// answers an unknown or expired client with a bare 400 page (it cannot redirect
/// back), so ask it first without following the redirect. Throws an
/// [OAuthError] with `invalid_client` in that case.
Future<void> preflightAuthorize(
  AuthRequest req, {
  Fetch fetch = defaultFetch,
}) async {
  final r = await fetch(req.url);
  if (r.status >= 300 && r.status < 400) return;
  if (r.status == 400 || r.status == 401) throw _errorOf(r, 'invalid_request');
}

/// Validates a callback URL (https or fallback scheme) against [req].
/// Returns the code. Throws [OAuthError] (`access_denied`, `state_mismatch`, ...).
String parseCallback(String callbackUrl, AuthRequest req) {
  final u = Uri.tryParse(callbackUrl);
  if (u == null) throw OAuthError('bad_callback');
  final q = u.queryParameters;
  // A callback for another (stale) attempt is discarded, errors included.
  if (q['state'] != req.state) throw OAuthError('state_mismatch');
  final err = q['error'];
  if (err != null) throw OAuthError(err);
  final code = q['code'];
  if (code == null || code.isEmpty) throw OAuthError('bad_callback');
  return code;
}

// ---- Tokens ----

class TokenSet {
  const TokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scope,
  });
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  /// Granted scopes (the user may un-tick write access on the consent page).
  final String scope;

  bool get canWrite => scope.split(' ').contains('mcp:write');

  bool needsRefresh(
    DateTime now, {
    Duration skew = const Duration(seconds: 60),
  }) => !now.add(skew).isBefore(expiresAt);

  String encode() => jsonEncode({
    'a': accessToken,
    if (refreshToken != null) 'r': refreshToken,
    'e': expiresAt.millisecondsSinceEpoch,
    's': scope,
  });

  static TokenSet? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      final a = m['a'], e = m['e'];
      if (a is! String || a.isEmpty || e is! int) return null;
      final r = m['r'], sc = m['s'];
      return TokenSet(
        accessToken: a,
        refreshToken: r is String && r.isNotEmpty ? r : null,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(e),
        scope: sc is String ? sc : oauthScopes,
      );
    } catch (_) {
      return null;
    }
  }
}

TokenSet parseTokenResponse(
  FetchResult r,
  DateTime now, {
  String? previousRefresh,
  String? previousScope,
}) {
  if (r.status != 200) throw _errorOf(r, 'token_failed');
  final m = _json(r.body);
  final at = _s(m?['access_token']);
  if (m == null || at == null) {
    throw OAuthError('token_failed', status: r.status);
  }
  final type = _s(m['token_type']);
  if (type != null && type.toLowerCase() != 'bearer') {
    throw OAuthError('token_type');
  }
  final ei = m['expires_in'];
  final secs = ei is num ? ei.toInt() : int.tryParse('$ei') ?? 3600;
  return TokenSet(
    accessToken: at,
    refreshToken: _s(m['refresh_token']) ?? previousRefresh,
    expiresAt: now.add(Duration(seconds: secs)),
    scope: _s(m['scope']) ?? previousScope ?? oauthScopes,
  );
}

Future<TokenSet> exchangeCode(
  AuthServer s,
  String clientId,
  AuthRequest req,
  String code, {
  Fetch fetch = defaultFetch,
  DateTime Function() now = DateTime.now,
}) async {
  final r = await fetch(
    Uri.parse(s.tokenEndpoint),
    form: {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': req.redirectUri,
      'client_id': clientId,
      'code_verifier': req.verifier,
      if (s.resource != null) 'resource': s.resource!,
    },
  );
  return parseTokenResponse(r, now());
}

Future<TokenSet> refreshTokens(
  String tokenEndpoint,
  String clientId,
  TokenSet t, {
  String? resource,
  Fetch fetch = defaultFetch,
  DateTime Function() now = DateTime.now,
}) async {
  final r = await fetch(
    Uri.parse(tokenEndpoint),
    form: {
      'grant_type': 'refresh_token',
      'refresh_token': t.refreshToken!,
      'client_id': clientId,
      'resource': ?resource,
    },
  );
  return parseTokenResponse(
    r,
    now(),
    previousRefresh: t.refreshToken,
    previousScope: t.scope,
  );
}

/// RFC 7009. Best effort: errors are ignored by the caller.
Future<void> revoke(
  String endpoint,
  String clientId,
  String token, {
  String hint = 'refresh_token',
  Fetch fetch = defaultFetch,
}) async {
  await fetch(
    Uri.parse(endpoint),
    form: {'token': token, 'token_type_hint': hint, 'client_id': clientId},
  );
}
