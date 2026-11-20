import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';
import 'native.dart';
import 'token_store.dart';

/// Account list (no secrets, but kept in the Keychain beside the tokens) and
/// non-secret preferences.
class AccountStore {
  AccountStore(this._secrets);
  final SecretStore _secrets;
  static const _accountsKey = 'accounts.v2';
  static const _legacyKey = 'accounts.v1';
  static const _currentKey = 'currentAccount';
  static const _alertsKey = 'approvalAlerts';
  static const _themeKey = 'themeMode';
  static const _devEnvKey = 'developer.environment';
  static const _devCustomKey = 'developer.customEnvironment';

  Future<List<Account>> load() async {
    // API key accounts of earlier builds are no longer supported: remove the keys.
    if (await _secrets.read(_legacyKey) != null) {
      await _secrets.delete(_legacyKey);
    }
    return Account.decodeList(await _secrets.read(_accountsKey));
  }

  Future<void> save(List<Account> a) =>
      _secrets.write(_accountsKey, Account.encodeList(a));

  Future<String?> currentId() async =>
      (await SharedPreferences.getInstance()).getString(_currentKey);

  Future<void> setCurrentId(String? id) async {
    final p = await SharedPreferences.getInstance();
    id == null
        ? await p.remove(_currentKey)
        : await p.setString(_currentKey, id);
  }

  Future<String?> themeMode() async =>
      (await SharedPreferences.getInstance()).getString(_themeKey);

  Future<void> setThemeMode(String v) async =>
      (await SharedPreferences.getInstance()).setString(_themeKey, v);

  Future<bool> alertsEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_alertsKey) ?? false;

  Future<void> setAlerts(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_alertsKey, v);

  static AppEnv? _env(String? raw) {
    if (raw == null) return null;
    try {
      return AppEnv.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _setEnv(String key, AppEnv? e) async {
    final p = await SharedPreferences.getInstance();
    e == null ? await p.remove(key) : await p.setString(key, jsonEncode(e.toJson()));
  }

  /// Developer menu: the server chosen for the next sign-in (addresses only, no secrets).
  Future<AppEnv?> developerEnv() async => _env((await SharedPreferences.getInstance()).getString(_devEnvKey));

  Future<void> setDeveloperEnv(AppEnv? e) => _setEnv(_devEnvKey, e);

  /// Developer menu: the last custom server typed in.
  Future<AppEnv?> developerCustomEnv() async =>
      _env((await SharedPreferences.getInstance()).getString(_devCustomKey));

  Future<void> setDeveloperCustomEnv(AppEnv? e) => _setEnv(_devCustomKey, e);
}
