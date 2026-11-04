import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// OIDC tokens of one account. Never logged, never in preferences.
class OidcTokens {
  const OidcTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  /// True when the access token expires within [skew] (or already has).
  bool needsRefresh(DateTime now,
          {Duration skew = const Duration(seconds: 60)}) =>
      !now.add(skew).isBefore(expiresAt);

  String encode() => jsonEncode({
        'a': accessToken,
        if (refreshToken != null) 'r': refreshToken,
        'e': expiresAt.millisecondsSinceEpoch,
      });

  static OidcTokens? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      final a = m['a'];
      final e = m['e'];
      if (a is! String || a.isEmpty || e is! int) return null;
      final r = m['r'];
      return OidcTokens(
        accessToken: a,
        refreshToken: r is String && r.isNotEmpty ? r : null,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(e),
      );
    } catch (_) {
      return null;
    }
  }
}

abstract class TokenStore {
  Future<OidcTokens?> read(String accountId);
  Future<void> write(String accountId, OidcTokens tokens);
  Future<void> delete(String accountId);
}

/// Keychain storage with the same accessibility as the API keys.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );
  final FlutterSecureStorage _storage;
  String _k(String id) => 'oidc.v1.$id';

  @override
  Future<OidcTokens?> read(String id) async =>
      OidcTokens.decode(await _storage.read(key: _k(id)));
  @override
  Future<void> write(String id, OidcTokens t) =>
      _storage.write(key: _k(id), value: t.encode());
  @override
  Future<void> delete(String id) => _storage.delete(key: _k(id));
}

class MemoryTokenStore implements TokenStore {
  final Map<String, OidcTokens> data = {};
  @override
  Future<OidcTokens?> read(String id) async => data[id];
  @override
  Future<void> write(String id, OidcTokens t) async => data[id] = t;
  @override
  Future<void> delete(String id) async => data.remove(id);
}
