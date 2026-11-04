import 'dart:async';

import 'oidc_client.dart';
import 'token_store.dart';

/// Where to refresh a browser account's tokens. Not secret; stored with the account.
class OidcInfo {
  const OidcInfo({
    required this.issuer,
    required this.clientId,
    required this.tokenEndpoint,
    this.resource,
    this.endSessionEndpoint,
  });
  final String issuer;
  final String clientId;
  final String tokenEndpoint;
  final String? resource;
  final String? endSessionEndpoint;

  factory OidcInfo.fromConfig(OidcConfig c) => OidcInfo(
        issuer: c.issuer,
        clientId: c.clientId,
        tokenEndpoint: c.tokenEndpoint,
        resource: c.resource,
        endSessionEndpoint: c.endSessionEndpoint,
      );

  Map<String, dynamic> toJson() => {
        'issuer': issuer,
        'clientId': clientId,
        'tokenEndpoint': tokenEndpoint,
        if (resource != null) 'resource': resource,
        if (endSessionEndpoint != null) 'endSession': endSessionEndpoint,
      };

  static OidcInfo? fromJson(dynamic j) {
    if (j is! Map) return null;
    final i = j['issuer'], c = j['clientId'], t = j['tokenEndpoint'];
    if (i is! String || c is! String || t is! String) return null;
    final r = j['resource'], e = j['endSession'];
    return OidcInfo(
      issuer: i,
      clientId: c,
      tokenEndpoint: t,
      resource: r is String ? r : null,
      endSessionEndpoint: e is String ? e : null,
    );
  }
}

class RefreshNetworkError implements Exception {}

/// Holds the tokens of one browser account: hands out a fresh access token
/// (refreshing shortly before expiry) and refreshes after a 401.
// ignore_for_file: prefer_initializing_formals
class OidcSession {
  OidcSession({
    required this.accountId,
    required this.info,
    required OidcTokens tokens,
    required this.store,
    Fetch? fetch,
    DateTime Function()? now,
    this.skew = const Duration(seconds: 60),
    bool persisted = false,
  })  : _tokens = tokens,
        _persisted = persisted,
        _fetch = fetch ?? defaultFetch,
        _now = now ?? DateTime.now;

  final String accountId;
  final OidcInfo info;
  final TokenStore store;
  final Duration skew;
  final Fetch _fetch;
  final DateTime Function() _now;
  OidcTokens _tokens;
  bool _persisted;
  Future<bool>? _inflight;

  /// Set once the refresh token is rejected: the account needs a new sign-in.
  bool expired = false;

  Future<void> persist() async {
    _persisted = true;
    await store.write(accountId, _tokens);
  }

  /// A valid access token, refreshed first when it is about to expire.
  Future<String> accessToken() async {
    if (_tokens.needsRefresh(_now(), skew: skew)) {
      try {
        await _refresh();
      } on RefreshNetworkError {
        // Use the old token while it is still valid; otherwise let the call fail.
        if (!_tokens.needsRefresh(_now(), skew: Duration.zero)) {
          return _tokens.accessToken;
        }
        rethrow;
      }
    }
    return _tokens.accessToken;
  }

  /// Call after a 401 for [rejected]. True when a different, fresh token is
  /// available for one retry.
  Future<bool> refreshAfter401(String rejected) async {
    if (expired) return false;
    if (_tokens.accessToken != rejected) return true;
    try {
      return await _refresh();
    } on RefreshNetworkError {
      return false;
    }
  }

  Future<bool> _refresh() {
    return _inflight ??= _doRefresh().whenComplete(() => _inflight = null);
  }

  Future<bool> _doRefresh() async {
    final rt = _tokens.refreshToken;
    if (rt == null) {
      expired = true;
      return false;
    }
    final FetchResult res;
    try {
      res = await _fetch(Uri.parse(info.tokenEndpoint), form: {
        'grant_type': 'refresh_token',
        'refresh_token': rt,
        'client_id': info.clientId,
        if (info.resource != null) 'resource': info.resource!,
      });
    } catch (_) {
      throw RefreshNetworkError();
    }
    if (res.status >= 500) throw RefreshNetworkError();
    final tr = res.status == 200 ? parseTokenResponse(res.body) : null;
    if (tr == null) {
      expired = true;
      return false;
    }
    _tokens = tr.toTokens(_now(), previousRefresh: rt);
    if (_persisted) await store.write(accountId, _tokens);
    return true;
  }

  Future<void> clear() async {
    _persisted = false;
    await store.delete(accountId);
  }
}
