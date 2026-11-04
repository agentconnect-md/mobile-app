import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import 'token_store.dart';

const oidcRedirectScheme = 'com.yulong.agentconnect';
const oidcRedirectUri = '$oidcRedirectScheme://callback';
const oidcScopes = 'openid offline_access profile email';

/// Build-time override for a separately registered native client:
/// `--dart-define=OIDC_CLIENT_ID=...`.
const oidcClientIdOverride = String.fromEnvironment('OIDC_CLIENT_ID');

class FetchResult {
  const FetchResult(this.status, this.body);
  final int status;
  final String body;
}

/// GET (no form) or form-encoded POST (form given). Throws [NetworkException].
typedef Fetch = Future<FetchResult> Function(Uri url,
    {Map<String, String>? form});

/// Default [Fetch] on dart:io. Never logs.
Future<FetchResult> defaultFetch(Uri url, {Map<String, String>? form}) async {
  final http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'AgentConnect/1.0';
  try {
    final req = form == null
        ? await http.getUrl(url)
        : await http.postUrl(url);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (form != null) {
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.add(utf8.encode(Uri(queryParameters: form).query));
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    return FetchResult(res.statusCode, text);
  } on SocketException {
    throw NetworkException();
  } on TimeoutException {
    throw NetworkException();
  } on TlsException {
    throw NetworkException();
  } on HttpException {
    throw NetworkException();
  } finally {
    http.close(force: true);
  }
}

/// Opens the system browser sheet and returns the callback URL.
typedef Authenticator = Future<String> Function(String url);

Future<String> systemAuthenticator(String url) => FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: oidcRedirectScheme,
    );

// ---- PKCE (RFC 7636) ----

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String pkceChallenge(String verifier) =>
    base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

String randomUrlSafe([int bytes = 32, Random? rng]) {
  final r = rng ?? Random.secure();
  return base64UrlNoPad(List<int>.generate(bytes, (_) => r.nextInt(256)));
}

// ---- Config ----

class OidcConfig {
  const OidcConfig({
    required this.apiBase,
    required this.issuer,
    required this.clientId,
    required this.resource,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.endSessionEndpoint,
  });
  final String apiBase;
  final String issuer;

  /// `oidcClientId`: runtime-config `appId`, unless overridden at build time.
  final String clientId;
  final String? resource;
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String? endSessionEndpoint;
}

/// The user may paste the API address with or without `/v1`.
List<String> apiBaseCandidates(String normalized) {
  final u = Uri.parse(normalized);
  if (u.path.endsWith('/v1')) return [normalized];
  return ['$normalized/v1', normalized];
}

String resolveClientId(String appId, {String override = oidcClientIdOverride}) =>
    override.trim().isNotEmpty ? override.trim() : appId;

class OidcCancelled implements Exception {}

/// The sign-in could not be completed (bad config, state mismatch, rejected code).
class OidcFailure implements Exception {
  OidcFailure([this.reason = '']);
  final String reason;
  @override
  String toString() => 'OidcFailure($reason)';
}

class TokenResponse {
  const TokenResponse(this.accessToken, this.refreshToken, this.expiresIn,
      this.idToken);
  final String accessToken;
  final String? refreshToken;
  final Duration expiresIn;
  final String? idToken;

  OidcTokens toTokens(DateTime now, {String? previousRefresh}) => OidcTokens(
        accessToken: accessToken,
        refreshToken: refreshToken ?? previousRefresh,
        expiresAt: now.add(expiresIn),
      );
}

TokenResponse? parseTokenResponse(String body) {
  try {
    final m = jsonDecode(body);
    if (m is! Map) return null;
    final at = m['access_token'];
    if (at is! String || at.isEmpty) return null;
    final rt = m['refresh_token'];
    final ei = m['expires_in'];
    final secs = ei is num ? ei.toInt() : int.tryParse('$ei') ?? 3600;
    final idt = m['id_token'];
    return TokenResponse(at, rt is String && rt.isNotEmpty ? rt : null,
        Duration(seconds: secs), idt is String ? idt : null);
  } catch (_) {
    return null;
  }
}

String? jwtClaim(String jwt, String name) {
  try {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    final m = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final v = m is Map ? m[name] : null;
    return v is String ? v : null;
  } catch (_) {
    return null;
  }
}

class AuthRequest {
  const AuthRequest(this.url, this.state, this.nonce, this.verifier);
  final Uri url;
  final String state;
  final String nonce;
  final String verifier;
}

AuthRequest buildAuthRequest(OidcConfig c,
    {String? verifier, String? state, String? nonce}) {
  final v = verifier ?? randomUrlSafe(48);
  final s = state ?? randomUrlSafe(24);
  final n = nonce ?? randomUrlSafe(24);
  final base = Uri.parse(c.authorizationEndpoint);
  final q = <String, String>{
    ...base.queryParameters,
    'client_id': c.clientId,
    'response_type': 'code',
    'redirect_uri': oidcRedirectUri,
    'scope': oidcScopes,
    'state': s,
    'nonce': n,
    'code_challenge': pkceChallenge(v),
    'code_challenge_method': 'S256',
    if (c.resource != null) 'resource': c.resource!,
    'prompt': 'consent',
  };
  return AuthRequest(base.replace(queryParameters: q), s, n, v);
}

/// Returns the authorization code, or throws [OidcCancelled]/[OidcFailure].
String parseCallback(String callbackUrl, AuthRequest req, {String? issuer}) {
  final u = Uri.tryParse(callbackUrl);
  if (u == null) throw OidcFailure('callback');
  final q = u.queryParameters;
  final err = q['error'];
  if (err != null) {
    if (err == 'access_denied') throw OidcCancelled();
    throw OidcFailure('error:$err');
  }
  if (q['state'] != req.state) throw OidcFailure('state');
  final iss = q['iss'];
  if (iss != null && issuer != null && iss != issuer) throw OidcFailure('iss');
  final code = q['code'];
  if (code == null || code.isEmpty) throw OidcFailure('code');
  return code;
}

class OidcClient {
  OidcClient({Fetch? fetch, Authenticator? authenticator, DateTime Function()? now})
      : _fetch = fetch ?? defaultFetch,
        _auth = authenticator ?? systemAuthenticator,
        _now = now ?? DateTime.now;
  final Fetch _fetch;
  final Authenticator _auth;
  final DateTime Function() _now;

  Map<String, dynamic>? _json(FetchResult r) {
    if (r.status != 200) return null;
    try {
      final m = jsonDecode(r.body);
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  /// Reads `GET {apiBase}/runtime-config` then the issuer's discovery document.
  /// Returns null when the address has no runtime-config (try the next candidate).
  Future<OidcConfig?> discover(String apiBase,
      {String clientIdOverride = oidcClientIdOverride}) async {
    final rc = _json(await _fetch(Uri.parse('$apiBase/runtime-config')));
    if (rc == null) return null;
    final auth = asMap(asMap(rc['config'])['auth']);
    final issuer = asStr(auth['issuer']);
    final appId = asStr(auth['appId']);
    if (issuer == null || appId == null) throw OidcFailure('runtime-config');
    final disc = _json(await _fetch(Uri.parse(
        '${issuer.endsWith('/') ? issuer.substring(0, issuer.length - 1) : issuer}/.well-known/openid-configuration')));
    if (disc == null) throw OidcFailure('discovery');
    final authz = asStr(disc['authorization_endpoint']);
    final token = asStr(disc['token_endpoint']);
    if (authz == null || token == null) throw OidcFailure('discovery');
    return OidcConfig(
      apiBase: apiBase,
      issuer: issuer,
      clientId: resolveClientId(appId, override: clientIdOverride),
      resource: asStr(auth['apiResource']),
      authorizationEndpoint: authz,
      tokenEndpoint: token,
      endSessionEndpoint: asStr(disc['end_session_endpoint']),
    );
  }

  /// Opens the browser sheet and exchanges the code.
  Future<OidcTokens> signIn(OidcConfig c) async {
    final req = buildAuthRequest(c);
    final String callback;
    try {
      callback = await _auth(req.url.toString());
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') throw OidcCancelled();
      throw OidcFailure('browser');
    }
    final code = parseCallback(callback, req, issuer: c.issuer);
    final res = await _fetch(Uri.parse(c.tokenEndpoint), form: {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': oidcRedirectUri,
      'client_id': c.clientId,
      'code_verifier': req.verifier,
      if (c.resource != null) 'resource': c.resource!,
    });
    final tr = res.status == 200 ? parseTokenResponse(res.body) : null;
    if (tr == null) throw OidcFailure('token');
    final idt = tr.idToken;
    if (idt != null) {
      final n = jwtClaim(idt, 'nonce');
      if (n != null && n != req.nonce) throw OidcFailure('nonce');
    }
    return tr.toTokens(_now());
  }
}
