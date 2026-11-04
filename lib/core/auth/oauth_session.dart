// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'http_fetch.dart';
import 'oauth.dart';
import 'token_store.dart';

/// What the rest of the app sees of authentication: a bearer token, and one
/// retry after a 401. Nothing outside `core/auth` touches tokens directly.
abstract class TokenProvider {
  /// A valid access token (refreshed first when it is about to expire).
  /// Throws [NetworkException] when a needed refresh can't reach the server,
  /// [SignInEnded] when the sign-in is no longer valid.
  Future<String> accessToken();

  /// After a 401 for [rejected]: true when a different token is ready for one retry.
  Future<bool> refreshAfter401(String rejected);

  /// False when the user granted read-only access on the consent page.
  bool get canWrite;
}

/// The refresh token was rejected (revoked in the web console, unused for 30
/// days, or superseded): the account needs a new sign-in.
class SignInEnded implements Exception {}

/// Where to refresh an account's tokens. Not secret; stored with the account.
class AuthInfo {
  const AuthInfo({
    required this.issuer,
    required this.tokenEndpoint,
    required this.clientId,
    this.revocationEndpoint,
    this.resource,
  });
  final String issuer;
  final String tokenEndpoint;
  final String clientId;
  final String? revocationEndpoint;
  final String? resource;

  Map<String, dynamic> toJson() => {
    'issuer': issuer,
    'tokenEndpoint': tokenEndpoint,
    'clientId': clientId,
    if (revocationEndpoint != null) 'revocation': revocationEndpoint,
    if (resource != null) 'resource': resource,
  };

  static AuthInfo? fromJson(dynamic j) {
    if (j is! Map) return null;
    final i = j['issuer'], t = j['tokenEndpoint'], c = j['clientId'];
    if (i is! String || t is! String || c is! String) return null;
    final r = j['revocation'], res = j['resource'];
    return AuthInfo(
      issuer: i,
      tokenEndpoint: t,
      clientId: c,
      revocationEndpoint: r is String ? r : null,
      resource: res is String ? res : null,
    );
  }
}

/// Tokens of one account. Refreshes 60 s before expiry and once after a 401;
/// concurrent callers share one refresh (the server rejects a second use of a
/// rotated refresh token racing the first). Rotated tokens are written to the
/// Keychain before they are handed out.
class OAuthSession implements TokenProvider {
  OAuthSession({
    required this.accountId,
    required this.info,
    required TokenSet tokens,
    required this.store,
    Fetch? fetch,
    DateTime Function()? now,
    this.skew = const Duration(seconds: 60),
    bool persisted = false,
  }) : _tokens = tokens,
       _persisted = persisted,
       _fetch = fetch ?? defaultFetch,
       _now = now ?? DateTime.now;

  final String accountId;
  final AuthInfo info;
  final TokenStore store;
  final Duration skew;
  final Fetch _fetch;
  final DateTime Function() _now;
  TokenSet _tokens;
  bool _persisted;
  Future<void>? _inflight;

  /// Set once the refresh token is rejected.
  bool ended = false;

  /// Called once when [ended] becomes true.
  void Function()? onEnded;

  TokenSet get tokens => _tokens;

  @override
  bool get canWrite => _tokens.canWrite;

  Future<void> persist() async {
    _persisted = true;
    await store.write(accountId, _tokens);
  }

  @override
  Future<String> accessToken() async {
    if (ended) throw SignInEnded();
    if (_tokens.needsRefresh(_now(), skew: skew)) {
      try {
        await _refresh();
      } on NetworkException {
        // Keep using the old token while it is still valid.
        if (!_tokens.needsRefresh(_now(), skew: Duration.zero)) {
          return _tokens.accessToken;
        }
        rethrow;
      }
    }
    return _tokens.accessToken;
  }

  @override
  Future<bool> refreshAfter401(String rejected) async {
    if (ended) return false;
    if (_tokens.accessToken != rejected) return true;
    try {
      await _refresh();
      return true;
    } on NetworkException {
      return false;
    } on SignInEnded {
      return false;
    }
  }

  Future<void> _refresh() =>
      _inflight ??= _doRefresh().whenComplete(() => _inflight = null);

  void _end() {
    if (ended) return;
    ended = true;
    onEnded?.call();
  }

  Future<void> _doRefresh() async {
    if (_tokens.refreshToken == null) {
      _end();
      throw SignInEnded();
    }
    final TokenSet next;
    try {
      next = await refreshTokens(
        info.tokenEndpoint,
        info.clientId,
        _tokens,
        resource: info.resource,
        fetch: _fetch,
        now: _now,
      );
    } on OAuthError catch (e) {
      if ((e.status ?? 400) >= 500) throw NetworkException();
      // invalid_grant (revoked / expired / superseded) or invalid_client: a
      // re-registered client can't use this grant, so sign in again.
      _end();
      throw SignInEnded();
    }
    _tokens = next;
    if (_persisted) await store.write(accountId, _tokens);
  }

  /// Sign-out: revoke when the server offers it (best effort), then forget.
  Future<void> signOut() async {
    final rev = info.revocationEndpoint;
    final rt = _tokens.refreshToken;
    if (rev != null && rt != null) {
      try {
        await revoke(rev, info.clientId, rt, fetch: _fetch);
      } catch (_) {}
    }
    ended = true;
    _persisted = false;
    await store.delete(accountId);
  }
}
