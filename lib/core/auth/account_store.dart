import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';

/// API keys are stored only in the iOS Keychain (this device only, after first unlock).
class AccountStore {
  AccountStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );
  final FlutterSecureStorage _storage;
  static const _accountsKey = 'accounts.v1';
  static const _currentKey = 'currentAccount';
  static const _alertsKey = 'approvalAlerts';

  Future<List<Account>> load() async =>
      Account.decodeList(await _storage.read(key: _accountsKey));

  Future<void> save(List<Account> a) =>
      _storage.write(key: _accountsKey, value: Account.encodeList(a));

  Future<String?> currentId() async =>
      (await SharedPreferences.getInstance()).getString(_currentKey);

  Future<void> setCurrentId(String? id) async {
    final p = await SharedPreferences.getInstance();
    if (id == null) {
      await p.remove(_currentKey);
    } else {
      await p.setString(_currentKey, id);
    }
  }

  Future<bool> alertsEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_alertsKey) ?? false;

  Future<void> setAlerts(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_alertsKey, v);
}
