import 'dart:async';

import 'package:flutter/widgets.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../streaming/live_updates.dart';
import 'account.dart';
import 'account_store.dart';
import 'biometrics.dart';

enum SignInFailure { key, address, network, other }

class SignInResult {
  const SignInResult.ok(this.me, this.orgs, this.client) : failure = null;
  const SignInResult.fail(this.failure)
      : me = null,
        orgs = const [],
        client = null;
  final Me? me;
  final List<Org> orgs;
  final ApiClient? client;
  final SignInFailure? failure;
}

/// Root application state: accounts, the active API client and live updates.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({AccountStore? store, Biometrics? biometrics})
      : store = store ?? AccountStore(),
        biometrics = biometrics ?? Biometrics();

  final AccountStore store;
  final Biometrics biometrics;

  bool ready = false;
  List<Account> accounts = [];
  Account? current;
  bool keyExpired = false;
  bool alerts = false;
  ApiClient? _client;
  LiveUpdates? _live;

  ApiClient get client => _client!;
  LiveUpdates? get live => _live;
  bool get signedIn => current != null;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      accounts = await store.load();
      final id = await store.currentId();
      alerts = await store.alertsEnabled();
      if (accounts.isNotEmpty) {
        current = accounts.firstWhere((a) => a.id == id,
            orElse: () => accounts.first);
        _activate();
      }
    } catch (_) {
      accounts = [];
      current = null;
    }
    ready = true;
    notifyListeners();
  }

  void _activate() {
    _live?.dispose();
    _client?.close();
    final a = current!;
    keyExpired = false;
    _client = ApiClient(a.apiBase, a.key, onUnauthorized: _onUnauthorized);
    _live = LiveUpdates(_client!, a.orgId)..start();
  }

  void _onUnauthorized() {
    if (keyExpired) return;
    keyExpired = true;
    _live?.stop();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_live == null || keyExpired) return;
    if (state == AppLifecycleState.resumed) {
      _live!.start();
    } else if (state == AppLifecycleState.paused) {
      _live!.stop();
    }
  }

  /// Validates a key and lists orgs. Does not store anything.
  Future<SignInResult> validate(String rawBase, String rawKey) async {
    final base = normalizeApiBase(rawBase);
    final key = rawKey.trim();
    if (base == null) return const SignInResult.fail(SignInFailure.address);
    if (key.isEmpty) return const SignInResult.fail(SignInFailure.key);
    final c = ApiClient(base, key);
    try {
      final me = await c.me();
      final orgs = await c.orgs();
      if (orgs.isEmpty) {
        c.close();
        return const SignInResult.fail(SignInFailure.key);
      }
      return SignInResult.ok(me, orgs, c);
    } on ApiException catch (e) {
      c.close();
      return SignInResult.fail(e.status == 401 || e.status == 403
          ? SignInFailure.key
          : e.status == 404
              ? SignInFailure.address
              : SignInFailure.other);
    } on BadResponseException {
      c.close();
      return const SignInResult.fail(SignInFailure.address);
    } on NetworkException {
      c.close();
      return const SignInResult.fail(SignInFailure.network);
    } catch (_) {
      c.close();
      return const SignInResult.fail(SignInFailure.other);
    }
  }

  Future<void> addAccount(SignInResult r, String rawBase, String rawKey,
      Org org) async {
    final base = normalizeApiBase(rawBase)!;
    final key = rawKey.trim();
    r.client?.close();
    // Replace a stored account with the same key on the same address and org.
    accounts = accounts
        .where((a) =>
            !(a.apiBase == base && a.orgId == org.id && a.userId == r.me!.userId))
        .toList();
    final acc = Account(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      apiBase: base,
      key: key,
      orgId: org.id,
      orgName: org.name,
      userId: r.me!.userId,
      userName: r.me!.name,
    );
    accounts = [...accounts, acc];
    await store.save(accounts);
    await select(acc);
  }

  Future<void> select(Account a) async {
    current = a;
    await store.setCurrentId(a.id);
    _activate();
    notifyListeners();
  }

  Future<void> remove(Account a) async {
    accounts = accounts.where((x) => x.id != a.id).toList();
    await store.save(accounts);
    if (current?.id == a.id) {
      _live?.dispose();
      _client?.close();
      _live = null;
      _client = null;
      if (accounts.isEmpty) {
        current = null;
        await store.setCurrentId(null);
        keyExpired = false;
      } else {
        await select(accounts.first);
        return;
      }
    }
    notifyListeners();
  }

  /// Expired key: remove it and go to sign-in.
  Future<void> dropExpired() async {
    final a = current;
    if (a != null) await remove(a);
    keyExpired = false;
    notifyListeners();
  }

  Future<void> setAlerts(bool v) async {
    alerts = v;
    await store.setAlerts(v);
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _live?.dispose();
    _client?.close();
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);
  static AppState of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext c) =>
      c.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
