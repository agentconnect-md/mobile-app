import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode, Brightness;
import 'package:flutter/widgets.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../../ui/platform.dart';
import '../approvals_controller.dart';
import '../desktop/presence.dart';
import '../last_read_store.dart';
import '../org_data.dart';
import '../streaming/live_updates.dart';
import 'account.dart';
import 'account_store.dart';
import 'biometrics.dart';
import 'native.dart';
import 'oauth.dart';
import 'oauth_session.dart';
import 'sign_in_flow.dart';
import 'token_store.dart';

enum SignInFailure {
  network,
  cancelled,
  other,

  /// Signed in, but the organization chosen in the browser couldn't be found.
  noOrg,
}

/// Root application state: accounts, the active API client and live updates.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    SecretStore? secrets,
    AccountStore? store,
    Biometrics? biometrics,
    AppEnv? env,
    BuildConfig? build,
    SignInFlow Function(AppEnv env, ClientStore clients)? flow,
  }) : secrets = secrets ?? KeychainStore(),
       biometrics = biometrics ?? Biometrics(),
       _buildOverride = build ?? (env == null ? null : BuildConfig(env: env)),
       _flowFactory = flow {
    this.store = store ?? AccountStore(this.secrets);
    tokens = TokenStore(this.secrets);
    clients = ClientStore(this.secrets);
  }

  final SecretStore secrets;
  late final AccountStore store;
  late final TokenStore tokens;
  late final ClientStore clients;
  final Biometrics biometrics;
  final BuildConfig? _buildOverride;
  final SignInFlow Function(AppEnv env, ClientStore clients)? _flowFactory;
  final Map<String, OAuthSession> _sessions = {};

  /// The server the next sign-in uses: the package's own, unless the
  /// developer menu chose another.
  AppEnv env = AppEnv.placeholder;

  /// The package's own server (xcconfig).
  AppEnv buildEnv = AppEnv.placeholder;

  /// The package has the developer menu (packages for testers only).
  bool debugMenu = false;
  AppEnv? _altEnv;

  /// Developer menu: the custom server last typed in.
  AppEnv? customEnv;
  bool ready = false;
  List<Account> accounts = [];
  Account? current;

  /// The current account's sign-in ended (revoked in the web console, or the
  /// refresh token expired). Shows the "You were signed out" screen.
  bool signInEnded = false;
  bool alerts = false;

  ApiClient? _client;
  LiveUpdates? _live;

  /// Per-organization state, recreated when the current account changes.
  OrgData? orgData;
  ApprovalsController? approvals;
  PreviewCache? previews;

  /// macOS: the menu bar item and notifications. Null elsewhere.
  DesktopPresence? desktop;

  /// Light / dark / system, chosen with the header toggle.
  ThemeMode themeMode = ThemeMode.system;

  ApiClient get client => _client!;
  LiveUpdates? get live => _live;
  bool get signedIn => current != null;

  /// False when the current sign-in was granted without write access.
  bool get canWrite => _sessions[current?.id]?.canWrite ?? true;

  /// Developer menu: the servers on offer, the package's own first.
  List<AppEnv> get environments => [buildEnv, ?_altEnv, ?customEnv];

  /// The server [a] is signed in to, when it is one the app knows: its console
  /// host is what links are built from and matched against.
  AppEnv? envOf(Account a) {
    for (final e in environments) {
      if (normalizeApiBase(e.apiBase) == a.apiBase) return e;
    }
    return null;
  }

  /// The current organization's server when known, else the one the next sign-in uses.
  AppEnv get currentEnv {
    final a = current;
    return (a == null ? null : envOf(a)) ?? env;
  }

  /// Developer menu: sign in to [e] from now on. Organizations already signed
  /// in keep their own server.
  Future<void> useEnvironment(AppEnv e) async {
    if (!debugMenu || env.sameAs(e)) return;
    env = e;
    notifyListeners();
    await store.setDeveloperEnv(e.sameAs(buildEnv) ? null : e);
  }

  /// Developer menu: keep [e] as the custom server and sign in to it from now on.
  Future<void> useCustomEnvironment(AppEnv e) async {
    if (!debugMenu) return;
    customEnv = e;
    env = e;
    notifyListeners();
    await store.setDeveloperCustomEnv(e);
    await store.setDeveloperEnv(e);
  }

  Future<void> _initEnv() async {
    final build = _buildOverride ?? await Native.build();
    buildEnv = build.env;
    env = build.env;
    debugMenu = build.debugMenu;
    _altEnv = build.alt;
    if (!debugMenu) return;
    try {
      customEnv = await store.developerCustomEnv();
      final chosen = await store.developerEnv();
      // Only a server still on offer: the package's list may have changed.
      if (chosen != null) {
        env = environments.firstWhere((e) => e.sameAs(chosen), orElse: () => buildEnv);
      }
    } catch (_) {}
  }

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    await _initEnv();
    if (isMacOS) desktop = DesktopPresence(alertsOn: () => alerts)..attach(null, null);
    try {
      alerts = await store.alertsEnabled();
      themeMode = ThemeMode.values.asNameMap()[await store.themeMode()] ?? ThemeMode.system;
      accounts = await store.load();
      final id = await store.currentId();
      for (final a in accounts) {
        final t = await tokens.read(a.id);
        if (t != null) {
          _sessions[a.id] = _session(a.id, a.auth, t, persisted: true);
        }
      }
      if (accounts.isNotEmpty) {
        current = accounts.firstWhere(
          (a) => a.id == id,
          orElse: () => accounts.first,
        );
        _activate();
      }
    } catch (_) {
      accounts = [];
      current = null;
    }
    ready = true;
    notifyListeners();
  }

  OAuthSession _session(
    String id,
    AuthInfo info,
    TokenSet t, {
    bool persisted = false,
  }) {
    final s = OAuthSession(
      accountId: id,
      info: info,
      tokens: t,
      store: tokens,
      persisted: persisted,
    );
    s.onEnded = () {
      if (current?.id == id) _onUnauthorized();
    };
    return s;
  }

  void _disposeOrg() {
    orgData?.dispose();
    approvals?.dispose();
    previews?.dispose();
    orgData = null;
    approvals = null;
    previews = null;
  }

  void _activate() {
    _disposeOrg();
    _live?.dispose();
    _client?.close();
    _live = null;
    final a = current!;
    signInEnded = false;
    final session = _sessions[a.id];
    if (session == null || session.ended) {
      // Tokens are gone from the Keychain: needs a new sign-in.
      signInEnded = true;
      _client = null;
      desktop?.attach(null, null);
      return;
    }
    _client = ApiClient(a.apiBase, session, onUnauthorized: _onUnauthorized);
    _live = LiveUpdates(_client!, a.orgId)..start();
    orgData = OrgData(_client!, a.orgId, _live)..refresh();
    approvals = ApprovalsController(_client!, a.orgId, _live)..refresh();
    previews = PreviewCache(_client!, a.orgId);
    desktop?.attach(orgData, approvals, orgName: a.orgName);
  }

  /// The header toggle: flips between light and dark (starting from the
  /// system appearance) and remembers the choice.
  Future<void> toggleTheme(Brightness current) async {
    themeMode = current == Brightness.dark ? ThemeMode.light : ThemeMode.dark;
    await store.setThemeMode(themeMode.name);
    notifyListeners();
  }

  void _onUnauthorized() {
    if (signInEnded) return;
    signInEnded = true;
    _live?.stop();
    desktop?.attach(null, null);
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The Mac app keeps watching while its window is hidden or closed: the
    // menu bar item and notifications live on this stream.
    if (isMacOS) return;
    if (_live == null || signInEnded) return;
    if (state == AppLifecycleState.resumed) {
      _live!.start();
    } else if (state == AppLifecycleState.paused) {
      _live!.stop();
    }
  }

  /// Runs the browser sign-in against [env] (this build's server, unless the
  /// developer menu chose another), finds the organization the user chose, and
  /// stores the account. Null on success.
  Future<SignInFailure?> signIn() async {
    final base = normalizeApiBase(env.apiBase);
    if (base == null) return SignInFailure.other;
    final flow =
        _flowFactory?.call(env, clients) ??
        SignInFlow(env: env, clients: clients);
    final SignInGrant grant;
    try {
      grant = await flow.run(base);
    } on SignInException catch (e) {
      return switch (e.error) {
        SignInError.address => SignInFailure.other,
        SignInError.network => SignInFailure.network,
        SignInError.cancelled => SignInFailure.cancelled,
        SignInError.failed => SignInFailure.other,
      };
    }
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final info = AuthInfo(
      issuer: grant.server.issuer,
      tokenEndpoint: grant.server.tokenEndpoint,
      clientId: grant.clientId,
      revocationEndpoint: grant.server.revocationEndpoint,
      resource: grant.server.resource,
    );
    final session = _session(id, info, grant.tokens);
    final c = ApiClient(base, session);
    try {
      final me = await c.me();
      final org = await _boundOrg(c);
      if (org == null) {
        await session.signOut();
        return SignInFailure.noOrg;
      }
      await _store(base, id, info, session, me, org);
      return null;
    } on NetworkException {
      return SignInFailure.network;
    } catch (_) {
      return SignInFailure.other;
    } finally {
      c.close();
    }
  }

  /// A sign-in is bound to the one organization chosen on the consent page, but
  /// neither the token response nor `/me` names it (see API_NOTES). `/orgs` lists
  /// every membership; the bound org is the one whose subtree answers 200.
  Future<Org?> _boundOrg(ApiClient c) async {
    final orgs = await c.orgs();
    for (final o in orgs) {
      if (o.id.isEmpty) continue;
      final status = await c.probeOrg(o.id);
      if (status == 200) return o;
    }
    return null;
  }

  Future<void> _store(
    String base,
    String id,
    AuthInfo info,
    OAuthSession session,
    Me me,
    Org org,
  ) async {
    // Same server + org: replace (a fresh sign-in for that org).
    for (final a in accounts.where((a) => a.sameOrg(base, org.id))) {
      _sessions.remove(a.id);
      await tokens.delete(a.id);
    }
    accounts = accounts.where((a) => !a.sameOrg(base, org.id)).toList();
    final acc = Account(
      id: id,
      apiBase: base,
      auth: info,
      orgId: org.id,
      orgName: org.name,
      userId: me.userId,
      userName: me.name,
    );
    await session.persist();
    _sessions[id] = session;
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

  /// Sign out of one organization: revoke when offered, delete local credentials.
  Future<void> signOut(Account a) async {
    final s = _sessions.remove(a.id);
    if (s != null) {
      await s.signOut();
    } else {
      await tokens.delete(a.id);
    }
    accounts = accounts.where((x) => x.id != a.id).toList();
    await store.save(accounts);
    if (current?.id == a.id) {
      _disposeOrg();
      _live?.dispose();
      _client?.close();
      _live = null;
      _client = null;
      signInEnded = false;
      if (accounts.isEmpty) {
        current = null;
        desktop?.attach(null, null);
        await store.setCurrentId(null);
        await LastReadStore.instance.clear();
      } else {
        await select(accounts.first);
        return;
      }
    }
    notifyListeners();
  }

  /// "Sign in again" after the sign-in ended; replaces the account if the same
  /// organization is chosen again.
  Future<SignInFailure?> signInAgain() => signIn();

  /// Leave the ended account and go back to the sign-in page.
  Future<void> dropEnded() async {
    final a = current;
    if (a != null) await signOut(a);
  }

  Future<void> setAlerts(bool v) async {
    alerts = v;
    await store.setAlerts(v);
    notifyListeners();
  }

  /// macOS: turns notifications on, asking the system for permission the
  /// first time. False when the system doesn't allow them (the person said
  /// no, now or earlier); the setting then stays off.
  Future<bool> turnOnAlerts() async {
    if (!await Native.requestNotifications()) return false;
    await setAlerts(true);
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeOrg();
    desktop?.dispose();
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
