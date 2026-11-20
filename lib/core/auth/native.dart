import 'dart:async';

import 'package:flutter/services.dart';

/// A server the app signs in to: the package's own (injected by the xcconfig
/// through Info.plist) or one chosen in the developer menu.
class AppEnv {
  const AppEnv({
    required this.name,
    required this.apiBase,
    required this.callbackHost,
    required this.callbackPath,
    required this.urlScheme,
  });
  final String name;

  /// Default API base of this package (ends in `/v1`).
  final String apiBase;
  final String callbackHost;
  final String callbackPath;

  /// Fallback scheme (`agentconnect-test` / `agentconnect`).
  final String urlScheme;

  /// The one redirect URI the app registers (https; custom schemes are not
  /// registerable on the server).
  String get redirectUri => 'https://$callbackHost$callbackPath';

  static const placeholder = AppEnv(
    name: 'Test',
    apiBase: 'https://api.example.test/v1',
    callbackHost: 'console.example.test',
    callbackPath: '/mobile/oauth/callback',
    urlScheme: 'agentconnect-test',
  );

  /// The API host, for showing which server this is.
  String get apiHost => Uri.tryParse(apiBase)?.host ?? apiBase;

  bool sameAs(AppEnv o) =>
      name == o.name &&
      apiBase == o.apiBase &&
      callbackHost == o.callbackHost &&
      callbackPath == o.callbackPath &&
      urlScheme == o.urlScheme;

  Map<String, String> toJson() => {
    'name': name,
    'apiBase': apiBase,
    'callbackHost': callbackHost,
    'callbackPath': callbackPath,
    'urlScheme': urlScheme,
  };

  /// Null unless every field is a non-empty string.
  static AppEnv? fromJson(Object? j) {
    if (j is! Map) return null;
    String? v(String k) {
      final s = j[k];
      return s is String && s.trim().isNotEmpty ? s.trim() : null;
    }

    final name = v('name'), apiBase = v('apiBase'), host = v('callbackHost');
    final path = v('callbackPath'), scheme = v('urlScheme');
    if (name == null || apiBase == null || host == null || path == null || scheme == null) return null;
    return AppEnv(name: name, apiBase: apiBase, callbackHost: host, callbackPath: path, urlScheme: scheme);
  }
}

/// What the package was built with: its own server and, in packages for
/// testers (xcconfig `AC_DEBUG_MENU`), the developer menu and a second server
/// it offers.
class BuildConfig {
  const BuildConfig({required this.env, this.debugMenu = false, this.alt});
  final AppEnv env;

  /// The package has the developer menu: the server of the next sign-in can be chosen.
  final bool debugMenu;

  /// The second server the developer menu offers, when the package names one.
  final AppEnv? alt;
}

class SignInCancelled implements Exception {}

/// The system sign-in sheet could not be shown or failed.
class SignInSheetFailed implements Exception {}

/// Opens the sign-in sheet; returns the callback URL (https, or the custom-scheme
/// fallback). Throws [SignInCancelled] / [SignInSheetFailed].
typedef Authenticator = Future<String> Function(Uri url, AppEnv env);

/// Bridge to `NativeBridge` in AppDelegate.swift.
class Native {
  Native._();
  static const _ch = MethodChannel('agentconnect/native');
  static final _links = StreamController<String>.broadcast();
  static final _shakes = StreamController<void>.broadcast();
  static bool _wired = false;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        _links.add(call.arguments as String);
      }
      if (call.method == 'shake') _shakes.add(null);
      // 'staleCallback': a fallback callback with no sign-in waiting; ignored.
      return null;
    });
  }

  /// Other app links (not sign-in callbacks), for deep links.
  static Stream<String> get links {
    _wire();
    return _links.stream;
  }

  /// The phone was shaken, in a package with the developer menu.
  static Stream<void> get shakes {
    _wire();
    return _shakes.stream;
  }

  static Future<BuildConfig> build() async {
    _wire();
    try {
      return buildConfigFrom(await _ch.invokeMapMethod<String, String>('env'));
    } on MissingPluginException {
      return const BuildConfig(env: AppEnv.placeholder);
    }
  }

  /// Reads the native `env` answer. An unset xcconfig variable arrives empty
  /// or as its own `$(NAME)`.
  static BuildConfig buildConfigFrom(Map<String, String>? m) {
    String v(String k, String d) {
      final s = m?[k]?.trim() ?? '';
      return s.isEmpty || s.contains(r'$(') ? d : s;
    }

    const p = AppEnv.placeholder;
    final env = AppEnv(
      name: v('name', p.name),
      apiBase: v('apiBase', p.apiBase),
      callbackHost: v('callbackHost', p.callbackHost),
      callbackPath: v('callbackPath', p.callbackPath),
      urlScheme: v('urlScheme', p.urlScheme),
    );
    final debugMenu = v('debugMenu', 'NO').toUpperCase() == 'YES';
    AppEnv? alt;
    final altApi = v('altApiHost', ''), altHost = v('altCallbackHost', '');
    if (debugMenu && altApi.isNotEmpty && altHost.isNotEmpty) {
      alt = AppEnv(
        name: v('altName', altApi),
        apiBase: 'https://$altApi${v('altApiPath', '/v1')}',
        callbackHost: altHost,
        callbackPath: env.callbackPath,
        urlScheme: v('altUrlScheme', env.urlScheme),
      );
    }
    return BuildConfig(env: env, debugMenu: debugMenu, alt: alt);
  }

  /// The console link the app was launched with (once), else null.
  static Future<String?> initialLink() async {
    _wire();
    try {
      return await _ch.invokeMethod<String>('initialLink');
    } catch (_) {
      return null;
    }
  }

  /// Debug builds: the tab to start on (launch argument), else null.
  static Future<int?> debugTab() async {
    try {
      return int.tryParse(await _ch.invokeMethod<String>('debugTab') ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Debug builds: open the Nth recent conversation on start (launch argument).
  static Future<int?> debugOpen() async {
    try {
      return int.tryParse(await _ch.invokeMethod<String>('debugOpen') ?? '');
    } catch (_) {
      return null;
    }
  }

  /// ASWebAuthenticationSession with `.https(host:path:)`; not ephemeral.
  static Future<String> authenticate(Uri url, AppEnv env) async {
    _wire();
    try {
      final r = await _ch.invokeMethod<String>('authenticate', {
        'url': url.toString(),
        'host': env.callbackHost,
        'path': env.callbackPath,
        'scheme': env.urlScheme,
      });
      if (r == null) throw SignInSheetFailed();
      return r;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') throw SignInCancelled();
      throw SignInSheetFailed();
    } on MissingPluginException {
      throw SignInSheetFailed();
    }
  }
}
