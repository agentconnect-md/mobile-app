import 'dart:convert';
import 'dart:io';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/auth/account.dart';
import 'package:agentconnect/core/auth/oidc_client.dart';
import 'package:agentconnect/core/auth/oidc_session.dart';
import 'package:agentconnect/core/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

const info = OidcInfo(
    issuer: 'https://auth.example.test/oidc',
    clientId: 'cid',
    tokenEndpoint: 'https://auth.example.test/oidc/token',
    resource: 'https://api.example.test/cp');

const cfg = OidcConfig(
  apiBase: 'https://api.example.test/v1',
  issuer: 'https://auth.example.test/oidc',
  clientId: 'cid',
  resource: 'https://api.example.test/cp',
  authorizationEndpoint: 'https://auth.example.test/oidc/auth',
  tokenEndpoint: 'https://auth.example.test/oidc/token',
);

String tokenJson(String at, {String? rt, int exp = 3600}) => jsonEncode({
      'access_token': at,
      'refresh_token': ?rt,
      'expires_in': exp,
      'token_type': 'Bearer'
    });

void main() {
  test('PKCE challenge matches RFC 7636 appendix B', () {
    expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('random verifier is 43+ url-safe chars and unique', () {
    final a = randomUrlSafe(48), b = randomUrlSafe(48);
    expect(a.length, greaterThanOrEqualTo(43));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
    expect(a, isNot(b));
  });

  test('authorization URL', () {
    final r = buildAuthRequest(cfg, verifier: 'v' * 43, state: 'S', nonce: 'N');
    final q = r.url.queryParameters;
    expect(r.url.origin, 'https://auth.example.test');
    expect(r.url.path, '/oidc/auth');
    expect(q['client_id'], 'cid');
    expect(q['response_type'], 'code');
    expect(q['redirect_uri'], 'com.yulong.agentconnect://callback');
    expect(q['scope'], 'openid offline_access profile email');
    expect(q['resource'], 'https://api.example.test/cp');
    expect(q['code_challenge_method'], 'S256');
    expect(q['code_challenge'], pkceChallenge('v' * 43));
    expect(q['state'], 'S');
    expect(q['nonce'], 'N');
  });

  test('callback: state verified, errors mapped', () {
    final r = buildAuthRequest(cfg, state: 'S');
    expect(parseCallback('com.yulong.agentconnect://callback?code=abc&state=S', r),
        'abc');
    expect(() => parseCallback('com.yulong.agentconnect://callback?code=abc&state=X', r),
        throwsA(isA<OidcFailure>()));
    expect(() => parseCallback('com.yulong.agentconnect://callback?error=access_denied&state=S', r),
        throwsA(isA<OidcCancelled>()));
    expect(() => parseCallback('com.yulong.agentconnect://callback?error=server_error', r),
        throwsA(isA<OidcFailure>()));
    expect(() => parseCallback('com.yulong.agentconnect://callback?state=S', r),
        throwsA(isA<OidcFailure>()));
  });

  test('token response parsing', () {
    final t = parseTokenResponse(tokenJson('a', rt: 'r', exp: 120))!;
    expect(t.accessToken, 'a');
    expect(t.refreshToken, 'r');
    expect(t.expiresIn, const Duration(seconds: 120));
    expect(parseTokenResponse('{"error":"x"}'), isNull);
    expect(parseTokenResponse('nope'), isNull);
    final keep = parseTokenResponse(tokenJson('b'))!
        .toTokens(DateTime(2026), previousRefresh: 'old');
    expect(keep.refreshToken, 'old');
  });

  test('client id: runtime appId unless build override', () {
    expect(resolveClientId('app', override: ''), 'app');
    expect(resolveClientId('app', override: ' native '), 'native');
  });

  test('api base candidates accept with or without /v1', () {
    expect(apiBaseCandidates('https://api.example.test/v1'),
        ['https://api.example.test/v1']);
    expect(apiBaseCandidates('https://api.example.test'),
        ['https://api.example.test/v1', 'https://api.example.test']);
    expect(normalizeApiBase('api.example.test/v1/'), 'https://api.example.test/v1');
  });

  test('discover: runtime-config then discovery; sign-in exchanges the code',
      () async {
    final calls = <String>[];
    final c = OidcClient(
      fetch: (u, {form}) async {
        calls.add(u.toString());
        if (u.path.endsWith('/runtime-config')) {
          return FetchResult(
              200,
              jsonEncode({
                'config': {
                  'auth': {
                    'issuer': 'https://auth.example.test/oidc',
                    'appId': 'app1',
                    'apiResource': 'https://api.example.test/cp'
                  }
                }
              }));
        }
        if (u.path.endsWith('openid-configuration')) {
          return FetchResult(
              200,
              jsonEncode({
                'authorization_endpoint': 'https://auth.example.test/oidc/auth',
                'token_endpoint': 'https://auth.example.test/oidc/token',
                'end_session_endpoint': 'https://auth.example.test/oidc/end'
              }));
        }
        return FetchResult(200, tokenJson('at', rt: 'rt'));
      },
      authenticator: (url) async {
        final st = Uri.parse(url).queryParameters['state'];
        return 'com.yulong.agentconnect://callback?code=C&state=$st';
      },
      now: () => DateTime(2026),
    );
    final conf = (await c.discover('https://api.example.test/v1',
        clientIdOverride: ''))!;
    expect(calls.first, 'https://api.example.test/v1/runtime-config');
    expect(calls[1],
        'https://auth.example.test/oidc/.well-known/openid-configuration');
    expect(conf.clientId, 'app1');
    expect(conf.endSessionEndpoint, isNotNull);
    final t = await c.signIn(conf);
    expect(t.accessToken, 'at');
    expect(t.expiresAt, DateTime(2026).add(const Duration(hours: 1)));
  });

  test('discover returns null when no runtime-config', () async {
    final c = OidcClient(fetch: (u, {form}) async => const FetchResult(404, ''));
    expect(await c.discover('https://x.example.test'), isNull);
  });

  test('token store encoding and refresh timing', () {
    final t = OidcTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime(2026, 1, 1, 12));
    final d = OidcTokens.decode(t.encode())!;
    expect(d.accessToken, 'a');
    expect(d.refreshToken, 'r');
    expect(d.expiresAt, t.expiresAt);
    expect(OidcTokens.decode('garbage'), isNull);
    expect(t.needsRefresh(DateTime(2026, 1, 1, 11, 58)), isFalse);
    expect(t.needsRefresh(DateTime(2026, 1, 1, 11, 59, 30)), isTrue);
  });

  group('session', () {
    OidcSession make(List<FetchResult> replies, {DateTime Function()? now,
        DateTime? expires, MemoryTokenStore? store, List<Map<String, String>?>? forms}) {
      var i = 0;
      return OidcSession(
        accountId: 'acc',
        info: info,
        store: store ?? MemoryTokenStore(),
        persisted: true,
        now: now ?? () => DateTime(2026),
        tokens: OidcTokens(
            accessToken: 'old',
            refreshToken: 'rt',
            expiresAt: expires ?? DateTime(2026).add(const Duration(hours: 1))),
        fetch: (u, {form}) async {
          forms?.add(form);
          return replies[i++];
        },
      );
    }

    test('fresh token is used without refreshing', () async {
      final s = make([]);
      expect(await s.accessToken(), 'old');
    });

    test('refreshes shortly before expiry and persists', () async {
      final store = MemoryTokenStore();
      final forms = <Map<String, String>?>[];
      final s = make([FetchResult(200, tokenJson('new', rt: 'rt2'))],
          expires: DateTime(2026).add(const Duration(seconds: 30)),
          store: store,
          forms: forms);
      expect(await s.accessToken(), 'new');
      expect(forms.single!['grant_type'], 'refresh_token');
      expect(forms.single!['refresh_token'], 'rt');
      expect(forms.single!.containsKey('client_secret'), isFalse);
      expect((await store.read('acc'))!.refreshToken, 'rt2');
    });

    test('rejected refresh marks expired; network error does not', () async {
      final s = make([const FetchResult(400, '{"error":"invalid_grant"}')]);
      expect(await s.refreshAfter401('old'), isFalse);
      expect(s.expired, isTrue);
      final n = make([const FetchResult(503, '')]);
      expect(await n.refreshAfter401('old'), isFalse);
      expect(n.expired, isFalse);
    });

    test('concurrent 401s share one refresh', () async {
      final forms = <Map<String, String>?>[];
      final s = make([FetchResult(200, tokenJson('new'))], forms: forms);
      final r = await Future.wait([s.refreshAfter401('old'), s.refreshAfter401('old')]);
      expect(r, [true, true]);
      expect(forms.length, 1);
    });
  });

  group('ApiClient with a local server', () {
    late HttpServer server;
    final seen = <String>[];
    var meStatus = <int>[];
    setUp(() async {
      seen.clear();
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        seen.add(req.headers.value('authorization') ?? '');
        final st = meStatus.isEmpty ? 200 : meStatus.removeAt(0);
        req.response.statusCode = st;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"userId":"u","email":"e","name":"n"}');
        req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    OidcSession session(List<FetchResult> replies, List<String> forms) {
      var i = 0;
      return OidcSession(
          accountId: 'a',
          info: info,
          store: MemoryTokenStore(),
          tokens: OidcTokens(
              accessToken: 'old',
              refreshToken: 'rt',
              expiresAt: DateTime.now().add(const Duration(hours: 1))),
          fetch: (u, {form}) async {
            forms.add(form!['grant_type']!);
            return replies[i++];
          });
    }

    test('401 refreshes and retries once with the new Bearer token', () async {
      meStatus = [401, 200];
      final forms = <String>[];
      var unauthorized = 0;
      final c = ApiClient('http://127.0.0.1:${server.port}/v1', '',
          onUnauthorized: () => unauthorized++,
          session: session([FetchResult(200, tokenJson('new', rt: 'r2'))], forms));
      final me = await c.me();
      expect(me.userId, 'u');
      expect(seen, ['Bearer old', 'Bearer new']);
      expect(forms, ['refresh_token']);
      expect(unauthorized, 0);
      c.close();
    });

    test('second 401 after retry marks unauthorized; no loop', () async {
      meStatus = [401, 401];
      var unauthorized = 0;
      final c = ApiClient('http://127.0.0.1:${server.port}/v1', '',
          onUnauthorized: () => unauthorized++,
          session: session([FetchResult(200, tokenJson('new'))], []));
      await expectLater(c.me(), throwsA(isA<ApiException>()));
      expect(seen.length, 2);
      expect(unauthorized, 1);
      c.close();
    });

    test('failed refresh -> unauthorized (expired state)', () async {
      meStatus = [401];
      var unauthorized = 0;
      final c = ApiClient('http://127.0.0.1:${server.port}/v1', '',
          onUnauthorized: () => unauthorized++,
          session: session([const FetchResult(400, '{"error":"invalid_grant"}')], []));
      await expectLater(c.me(), throwsA(isA<ApiException>()));
      expect(unauthorized, 1);
      expect(seen.length, 1);
      c.close();
    });

    test('API key accounts send the key and never refresh', () async {
      meStatus = [401];
      var unauthorized = 0;
      final c = ApiClient('http://127.0.0.1:${server.port}/v1', 'KEY',
          onUnauthorized: () => unauthorized++);
      await expectLater(c.me(), throwsA(isA<ApiException>()));
      expect(seen, ['Bearer KEY']);
      expect(unauthorized, 1);
      c.close();
    });
  });

  test('Account round trip: key and browser credentials', () {
    final a = Account(
        id: '1', apiBase: 'https://a.test/v1', key: '', oidc: info,
        orgId: 'o', orgName: 'O', userId: 'u', userName: 'N');
    final k = Account(
        id: '2', apiBase: 'https://a.test/v1', key: 'KEY',
        orgId: 'o', orgName: 'O', userId: 'u', userName: 'N');
    final l = Account.decodeList(Account.encodeList([a, k]));
    expect(l.length, 2);
    expect(l[0].isBrowser, isTrue);
    expect(l[0].oidc!.clientId, 'cid');
    expect(l[1].isBrowser, isFalse);
    expect(l[1].key, 'KEY');
  });
}
