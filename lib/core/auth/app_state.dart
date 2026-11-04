import 'dart:async';

import 'package:flutter/widgets.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../streaming/live_updates.dart';
import 'account.dart';
import 'account_store.dart';
import 'biometrics.dart';
import 'oidc_client.dart';
import 'oidc_session.dart';
import 'token_store.dart';

enum SignInFailure {
  key,
  address,
  network,
  other,
  cancelled,

  /// Browser sign-in worked but the API refused the access token.
  rejected,
}

class SignInResult {
  const SignInResult.ok(this.me, this.orgs, this.client,
      {this.session, this.apiBase, this.info})
      : failure = null;
  const SignInResult.fail(this.failure)
      : me = null,
        orgs = const [],
        client = null,
        session = null,
        apiBase = null,
        info = null;
  final OidcSession? session;
  final String? apiBase;
  final OidcInfo? info;
  final Me? me;
  final List<Org> orgs;
  final ApiClient? client;
  final SignInFailure? failure;
}

/// Root application state: accounts, the active API client and live updates.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(
      {AccountStore? store,
      Biometrics? biometrics,
      TokenStore? tokens,
      OidcClient? oidc})
      : store = store ?? AccountStore(),
        biometrics = biometrics ?? Biometrics(),
        tokens = tokens ?? SecureTokenStore(),
        oidc = oidc ?? OidcClient();

  final TokenStore tokens;
  final OidcClient oidc;
  final Map<String, OidcSession> _sessions = {};

  /// Address of the last account that needed a new sign-in (prefills the field).
  String? lastBase;
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
      for (final a in accounts.where((a) => a.isBrowser)) {
        final t = await tokens.read(a.id);
        if (t != null) {
          _sessions[a.id] = OidcSession(
              accountId: a.id,
              info: a.oidc!,
              tokens: t,
              store: tokens,
              persisted: true);
        }
      }
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
    final session = _sessions[a.id];
    _client = ApiClient(a.apiBase, a.key,
        onUnauthorized: _onUnauthorized, session: session);
    if (a.isBrowser && session == null) {
      // Tokens are gone from the Keychain: needs a new sign-in.
      keyExpired = true;
      return;
    }
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

  /// Browser sign-in: finds the sign-in service from `{apiBase}/runtime-config`,
  /// opens the system browser sheet, then checks the access token with /me and /orgs.
  Future<SignInResult> validateBrowser(String rawBase) async {
    final norm = normalizeApiBase(rawBase);
    if (norm == null) return const SignInResult.fail(SignInFailure.address);
    try {
      OidcConfig? cfg;
      for (final b in apiBaseCandidates(norm)) {
        cfg = await oidc.discover(b);
        if (cfg != null) break;
      }
      if (cfg == null) return const SignInResult.fail(SignInFailure.address);
      final t = await oidc.signIn(cfg);
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      final info = OidcInfo.fromConfig(cfg);
      final session = OidcSession(
          accountId: id, info: info, tokens: t, store: tokens);
      final c = ApiClient(cfg.apiBase, '', session: session);
      try {
        final me = await c.me();
        final orgs = await c.orgs();
        if (orgs.isEmpty) {
          c.close();
          return const SignInResult.fail(SignInFailure.rejected);
        }
        return SignInResult.ok(me, orgs, c,
            session: session, apiBase: cfg.apiBase, info: info);
      } on ApiException catch (e) {
        c.close();
        return SignInResult.fail(e.status == 401 || e.status == 403
            ? SignInFailure.rejected
            : SignInFailure.other);
      } on BadResponseException {
        c.close();
        return const SignInResult.fail(SignInFailure.other);
      } on NetworkException {
        c.close();
        return const SignInResult.fail(SignInFailure.network);
      }
    } on OidcCancelled {
      return const SignInResult.fail(SignInFailure.cancelled);
    } on NetworkException {
      return const SignInResult.fail(SignInFailure.network);
    } catch (_) {
      return const SignInResult.fail(SignInFailure.other);
    }
  }

  Future<void> addAccount(SignInResult r, String rawBase, String rawKey,
      Org org) async {
    final session = r.session;
    final base = session != null ? r.apiBase! : normalizeApiBase(rawBase)!;
    final key = session != null ? '' : rawKey.trim();
    r.client?.close();
    // Replace a stored account with the same key on the same address and org.
    final replaced = accounts.where((a) =>
        a.apiBase == base && a.orgId == org.id && a.userId == r.me!.userId);
    for (final a in replaced) {
      _sessions.remove(a.id);
      await tokens.delete(a.id);
    }
    accounts = accounts
        .where((a) =>
            !(a.apiBase == base && a.orgId == org.id && a.userId == r.me!.userId))
        .toList();
    final acc = Account(
      id: session?.accountId ?? '${DateTime.now().microsecondsSinceEpoch}',
      apiBase: base,
      key: key,
      oidc: r.info,
      orgId: org.id,
      orgName: org.name,
      userId: r.me!.userId,
      userName: r.me!.name,
    );
    if (session != null) {
      await session.persist();
      _sessions[acc.id] = session;
    }
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
    _sessions.remove(a.id);
    await tokens.delete(a.id);
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
    if (a != null) {
      lastBase = a.isBrowser ? a.apiBase : null;
      await remove(a);
    }
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
