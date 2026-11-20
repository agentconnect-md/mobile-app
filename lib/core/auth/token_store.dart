import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'oauth.dart';

/// Secrets and the client registrations. Keychain only
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, readable by a
/// background refresh). Never logged, never in preferences.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeychainStore implements SecretStore {
  KeychainStore({FlutterSecureStorage? storage})
    : _s =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
            // macOS: the login keychain. The data protection keychain needs a
            // keychain-access-groups entitlement, which a Mac app only gets
            // with a provisioning profile (a Developer ID package has none).
            mOptions: MacOsOptions(useDataProtectionKeyChain: false),
          );
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryStore implements SecretStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Tokens of one account.
class TokenStore {
  TokenStore(this._s);
  final SecretStore _s;
  String _k(String accountId) => 'oauth.tokens.v1.$accountId';
  Future<TokenSet?> read(String id) async =>
      TokenSet.decode(await _s.read(_k(id)));
  Future<void> write(String id, TokenSet t) => _s.write(_k(id), t.encode());
  Future<void> delete(String id) => _s.delete(_k(id));
}

/// `client_id` per authorization server + redirect URI.
class ClientStore {
  ClientStore(this._s);
  final SecretStore _s;
  String _k(String issuer, String redirectUri) =>
      'oauth.client.v1.${base64Url.encode(utf8.encode('$issuer|$redirectUri'))}';
  Future<ClientRegistration?> read(String issuer, String redirectUri) async {
    final s = await _s.read(_k(issuer, redirectUri));
    if (s == null) return null;
    try {
      return ClientRegistration.fromJson(jsonDecode(s));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String issuer, String redirectUri, ClientRegistration c) =>
      _s.write(_k(issuer, redirectUri), jsonEncode(c.toJson()));
  Future<void> delete(String issuer, String redirectUri) =>
      _s.delete(_k(issuer, redirectUri));
}
