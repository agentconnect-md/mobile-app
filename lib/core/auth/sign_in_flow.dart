import 'http_fetch.dart';
import 'native.dart';
import 'oauth.dart';
import 'token_store.dart';

/// Result of a completed browser sign-in (organization not yet known).
class SignInGrant {
  const SignInGrant(this.apiBase, this.server, this.clientId, this.tokens);
  final String apiBase;
  final AuthServer server;
  final String clientId;
  final TokenSet tokens;
}

enum SignInError {
  /// Not an AgentConnect API address.
  address,
  network,

  /// The user closed the sheet or chose Deny.
  cancelled,

  /// Anything else (rejected code, bad callback, registration refused...).
  failed,
}

class SignInException implements Exception {
  SignInException(this.error, [this.detail = '']);
  final SignInError error;

  /// OAuth error code, for the API notes; never content.
  final String detail;
  @override
  String toString() => 'SignInException($error, $detail)';
}

/// Discovery → registration (cached per server, renewed when stale or
/// rejected) → system sign-in sheet → code exchange.
class SignInFlow {
  SignInFlow({
    required this.env,
    required this.clients,
    Fetch? fetch,
    Authenticator? authenticator,
    DateTime Function()? now,
  }) : _fetch = fetch ?? defaultFetch,
       _auth = authenticator ?? Native.authenticate,
       _now = now ?? DateTime.now;

  final AppEnv env;
  final ClientStore clients;
  final Fetch _fetch;
  final Authenticator _auth;
  final DateTime Function() _now;

  Future<String> _clientId(AuthServer s, {bool fresh = false}) async {
    final redirect = env.redirectUri;
    if (!fresh) {
      final c = await clients.read(s.issuer, redirect);
      if (c != null && !c.isStale(_now())) return c.clientId;
    }
    final c = await register(s, redirect, fetch: _fetch, now: _now);
    await clients.write(s.issuer, redirect, c);
    return c.clientId;
  }

  Future<SignInGrant> run(String apiBase) async {
    try {
      final server = await discover(apiBase, fetch: _fetch);
      return await _attempt(apiBase, server, retried: false);
    } on NotAnAgentConnectServer {
      throw SignInException(SignInError.address);
    } on NetworkException {
      throw SignInException(SignInError.network);
    } on SignInCancelled {
      throw SignInException(SignInError.cancelled);
    } on SignInSheetFailed {
      throw SignInException(SignInError.failed, 'sheet');
    } on OAuthError catch (e) {
      if (e.code == 'access_denied') {
        throw SignInException(SignInError.cancelled);
      }
      throw SignInException(SignInError.failed, e.code);
    }
  }

  Future<SignInGrant> _attempt(
    String apiBase,
    AuthServer server, {
    required bool retried,
  }) async {
    final clientId = await _clientId(server, fresh: retried);
    final req = buildAuthRequest(server, clientId, env.redirectUri);
    try {
      // Unknown/expired client or an unregistered redirect: re-register first.
      await preflightAuthorize(req, fetch: _fetch);
    } on OAuthError catch (e) {
      if (!retried && (e.invalidClient || e.code == 'invalid_request')) {
        return _attempt(apiBase, server, retried: true);
      }
      rethrow;
    }
    final callback = await _auth(req.url, env);
    final code = parseCallback(callback, req);
    try {
      final tokens = await exchangeCode(
        server,
        clientId,
        req,
        code,
        fetch: _fetch,
        now: _now,
      );
      return SignInGrant(apiBase, server, clientId, tokens);
    } on OAuthError catch (e) {
      if (!retried && e.invalidClient) {
        return _attempt(apiBase, server, retried: true);
      }
      rethrow;
    }
  }
}
