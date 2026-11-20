import 'package:agentconnect/core/auth/account.dart';
import 'package:agentconnect/core/auth/app_state.dart';
import 'package:agentconnect/core/auth/http_fetch.dart';
import 'package:agentconnect/core/auth/native.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/auth/sign_in_flow.dart';
import 'package:agentconnect/core/auth/token_store.dart';
import 'package:agentconnect/core/console_links.dart';
import 'package:agentconnect/features/developer/developer_menu.dart';
import 'package:agentconnect/features/settings/settings_screen.dart';
import 'package:agentconnect/features/signin/signin_screen.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _test = AppEnv(
  name: 'Test',
  apiBase: 'https://test-api.example.test/v1',
  callbackHost: 'test-app.example.test',
  callbackPath: '/mobile/oauth/callback',
  urlScheme: 'agentconnect-test',
);
const _prod = AppEnv(
  name: 'Production',
  apiBase: 'https://api.example.test/v1',
  callbackHost: 'app.example.test',
  callbackPath: '/mobile/oauth/callback',
  urlScheme: 'agentconnect',
);
const _withMenu = BuildConfig(env: _test, debugMenu: true, alt: _prod);

Account _account(String apiBase) => Account(
      id: 'a1',
      apiBase: apiBase,
      auth: const AuthInfo(issuer: 'https://id.example.test', tokenEndpoint: 'https://id.example.test/token', clientId: 'c'),
      orgId: 'o1',
      orgName: 'Acme',
      userId: 'u1',
      userName: 'Pat',
    );

Future<AppState> _state(BuildConfig build, {SecretStore? secrets, List<AppEnv>? signedInTo}) async {
  final app = AppState(
    secrets: secrets ?? MemoryStore(),
    build: build,
    flow: (env, clients) {
      signedInTo?.add(env);
      return SignInFlow(
        env: env,
        clients: clients,
        fetch: (url, {form, json, headers, bearer, method}) async => throw NetworkException(),
      );
    },
  );
  await app.init();
  return app;
}

Widget _host(AppState app, Widget child) => AppScope(
      state: app,
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) => MaterialApp(
          theme: buildTheme(Brightness.light),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('build configuration', () {
    Map<String, String> native({String menu = 'YES', String altApi = 'api.example.test'}) => {
          'name': 'Test',
          'apiBase': 'https://test-api.example.test/v1',
          'callbackHost': 'test-app.example.test',
          'callbackPath': '/mobile/oauth/callback',
          'urlScheme': 'agentconnect-test',
          'debugMenu': menu,
          'altName': 'Production',
          'altApiHost': altApi,
          'altApiPath': '/v1',
          'altCallbackHost': 'app.example.test',
          'altUrlScheme': 'agentconnect',
        };

    test('a package for testers has the menu and its second server', () {
      final b = Native.buildConfigFrom(native());
      expect(b.debugMenu, isTrue);
      expect(b.env.sameAs(_test), isTrue);
      expect(b.alt!.sameAs(_prod), isTrue);
    });

    test('without the flag there is no menu and no second server', () {
      final b = Native.buildConfigFrom(native(menu: 'NO'));
      expect(b.debugMenu, isFalse);
      expect(b.alt, isNull);
      // A package built before the flag existed answers without it.
      final old = Native.buildConfigFrom({'name': 'Test', 'apiBase': 'https://test-api.example.test/v1'});
      expect(old.debugMenu, isFalse);
      expect(old.alt, isNull);
    });

    test('an unset second server is left out', () {
      expect(Native.buildConfigFrom(native(altApi: '')).alt, isNull);
      expect(Native.buildConfigFrom(native(altApi: r'$(AC_ALT_API_HOST)')).alt, isNull);
    });
  });

  group('choosing the server', () {
    test('sign-in goes to the chosen server, and the choice is kept', () async {
      final used = <AppEnv>[];
      final app = await _state(_withMenu, signedInTo: used);
      expect(app.env.sameAs(_test), isTrue);
      expect(app.environments.map((e) => e.name), ['Test', 'Production']);

      await app.useEnvironment(_prod);
      expect(await app.signIn(), SignInFailure.network);
      expect(used.single.sameAs(_prod), isTrue);

      // The next start of the app still signs in to it.
      expect((await _state(_withMenu)).env.sameAs(_prod), isTrue);
      // Back on the package's own server, nothing is stored.
      await app.useEnvironment(_test);
      expect((await _state(_withMenu)).env.sameAs(_test), isTrue);
    });

    test('a package without the menu ignores a stored choice and cannot change server', () async {
      await (await _state(_withMenu)).useEnvironment(_prod);
      final app = await _state(const BuildConfig(env: _test));
      expect(app.env.sameAs(_test), isTrue);
      expect(app.environments, hasLength(1));
      await app.useEnvironment(_prod);
      expect(app.env.sameAs(_test), isTrue);
    });

    test('a stored choice the package no longer offers falls back to its own server', () async {
      await (await _state(_withMenu)).useEnvironment(_prod);
      final app = await _state(const BuildConfig(env: _test, debugMenu: true));
      expect(app.env.sameAs(_test), isTrue);
    });

    test('a custom server is remembered and chosen', () async {
      const custom = AppEnv(
        name: 'Custom',
        apiBase: 'https://api.staging.example.test/v1',
        callbackHost: 'app.staging.example.test',
        callbackPath: '/mobile/oauth/callback',
        urlScheme: 'agentconnect-staging',
      );
      final app = await _state(_withMenu);
      await app.useCustomEnvironment(custom);
      final again = await _state(_withMenu);
      expect(again.env.sameAs(custom), isTrue);
      expect(again.environments.map((e) => e.name), ['Test', 'Production', 'Custom']);
      // Choosing another keeps the custom one on offer.
      await again.useEnvironment(_test);
      expect((await _state(_withMenu)).customEnv!.sameAs(custom), isTrue);
    });

    test("console links use the account's own server, whichever is chosen", () async {
      final app = await _state(_withMenu);
      app.current = _account(_test.apiBase);
      await app.useEnvironment(_prod);
      expect(consoleUri(app, 'acme', 'sessions/s-1').toString(), 'https://test-app.example.test/acme/sessions/s-1');
      expect(app.currentEnv.sameAs(_test), isTrue);

      app.current = _account(_prod.apiBase);
      expect(consoleUri(app, 'acme', 'sessions/s-1').toString(), 'https://app.example.test/acme/sessions/s-1');
      // A server the app doesn't know has no console to link to.
      app.current = _account('https://api.elsewhere.example.test/v1');
      expect(consoleUri(app, 'acme', 'sessions/s-1'), isNull);
    });
  });

  test('typed console hosts and URL schemes', () {
    expect(normalizeConsoleHost(' https://App.Example.test/ '), 'app.example.test');
    expect(normalizeConsoleHost('app.example.test'), 'app.example.test');
    expect(normalizeConsoleHost('localhost'), isNull);
    expect(normalizeConsoleHost('app.example.test/path'), isNull);
    expect(normalizeConsoleHost('http://app.example.test'), isNull);
    expect(normalizeConsoleHost(''), isNull);
    expect(normalizeUrlScheme('AgentConnect-Test://'), 'agentconnect-test');
    expect(normalizeUrlScheme('1abc'), isNull);
    expect(normalizeUrlScheme('a b'), isNull);
    expect(normalizeUrlScheme(''), isNull);
  });

  group('the menu', () {
    Future<void> phone(WidgetTester tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> open(WidgetTester tester, AppState app) async {
      await tester.pumpWidget(_host(
        app,
        Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showDeveloperMenu(c), child: const Text('open')))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the servers, marks the chosen one, and switches', (tester) async {
      await phone(tester);
      final app = (await tester.runAsync(() => _state(_withMenu)))!;
      await open(tester, app);

      expect(find.text('Developer'), findsOneWidget);
      expect(find.text('Test'), findsOneWidget);
      expect(find.text('test-api.example.test'), findsOneWidget);
      expect(find.text('This package'), findsOneWidget);
      expect(find.text('Production'), findsOneWidget);
      expect(find.text('api.example.test'), findsOneWidget);
      // The chosen server has a check, not just a colour.
      Finder checkIn(String name) =>
          find.descendant(of: find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first, matching: find.byType(Icon));
      expect(checkIn('Test'), findsOneWidget);
      expect(checkIn('Production'), findsNothing);
      // Signed out: the sign-in screen is behind the sheet, so no button to it.
      expect(find.text('Add organization'), findsNothing);

      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(app.env.sameAs(_prod), isTrue);
      expect(checkIn('Production'), findsOneWidget);
      expect(checkIn('Test'), findsNothing);
      // Every row is a full-size touch target.
      for (final row in tester.widgetList<InkWell>(find.byType(InkWell))) {
        expect(tester.getSize(find.byWidget(row)).height, greaterThanOrEqualTo(44));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a custom server is checked before it is used', (tester) async {
      await phone(tester);
      final app = (await tester.runAsync(() => _state(_withMenu)))!;
      await open(tester, app);

      await tester.tap(find.text('Custom server…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this server'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an https address, such as api.example.com.'), findsOneWidget);
      expect(find.text('Enter a host name, such as app.example.com.'), findsOneWidget);
      expect(app.customEnv, isNull);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'api.staging.example.test');
      await tester.enterText(fields.at(1), 'https://app.staging.example.test/');
      await tester.pumpAndSettle();
      expect(find.text('Enter an https address, such as api.example.com.'), findsNothing);
      await tester.tap(find.text('Use this server'));
      await tester.pumpAndSettle();

      final custom = app.customEnv!;
      expect(custom.apiBase, 'https://api.staging.example.test/v1');
      expect(custom.callbackHost, 'app.staging.example.test');
      // The scheme starts as the package's own.
      expect(custom.urlScheme, 'agentconnect-test');
      expect(app.env.sameAs(custom), isTrue);
      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not open in a package without it', (tester) async {
      final app = (await tester.runAsync(() => _state(const BuildConfig(env: _test))))!;
      await open(tester, app);
      expect(find.text('Developer'), findsNothing);
    });

    testWidgets('Settings and the sign-in screen show the server only in packages with the menu', (tester) async {
      await phone(tester);
      final plain = (await tester.runAsync(() => _state(const BuildConfig(env: _test))))!;
      await tester.pumpWidget(_host(plain, const SettingsScreen()));
      expect(find.text('Developer'), findsNothing);
      await tester.pumpWidget(_host(plain, const SignInScreen()));
      expect(find.textContaining('Server:'), findsNothing);

      final app = (await tester.runAsync(() => _state(_withMenu)))!;
      await tester.pumpWidget(_host(app, const SignInScreen()));
      expect(find.text('Server: Test · test-api.example.test'), findsOneWidget);
      await tester.tap(find.text('Server: Test · test-api.example.test'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(find.text('Server: Production · api.example.test'), findsOneWidget);
      Navigator.of(tester.element(find.text('Developer'))).pop();
      await tester.pumpAndSettle();

      await tester.pumpWidget(_host(app, const SettingsScreen()));
      await tester.scrollUntilVisible(find.text('Developer'), 200);
      expect(find.text('Server'), findsOneWidget);
      expect(find.text('Production'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
