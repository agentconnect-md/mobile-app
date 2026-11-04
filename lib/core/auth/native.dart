import 'dart:async';

import 'package:flutter/services.dart';

/// Build environment, injected by the xcconfig through Info.plist.
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
  static bool _wired = false;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        _links.add(call.arguments as String);
      }
      // 'staleCallback': a fallback callback with no sign-in waiting; ignored.
      return null;
    });
  }

  /// Other app links (not sign-in callbacks), for deep links.
  static Stream<String> get links {
    _wire();
    return _links.stream;
  }

  static Future<AppEnv> env() async {
    _wire();
    try {
      final m = await _ch.invokeMapMethod<String, String>('env');
      String v(String k, String d) {
        final s = m?[k]?.trim() ?? '';
        return s.isEmpty || s.contains(r'$(') ? d : s;
      }

      const p = AppEnv.placeholder;
      return AppEnv(
        name: v('name', p.name),
        apiBase: v('apiBase', p.apiBase),
        callbackHost: v('callbackHost', p.callbackHost),
        callbackPath: v('callbackPath', p.callbackPath),
        urlScheme: v('urlScheme', p.urlScheme),
      );
    } on MissingPluginException {
      return AppEnv.placeholder;
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
