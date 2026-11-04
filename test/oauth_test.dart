import 'dart:async';
import 'dart:convert';

import 'package:agentconnect/core/auth/http_fetch.dart';
import 'package:agentconnect/core/auth/native.dart';
import 'package:agentconnect/core/auth/oauth.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/auth/sign_in_flow.dart';
import 'package:agentconnect/core/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

// Anonymized hosts: the API and the authorization server on different hosts.
const api = 'https://api.example.test/v1';
const asHost = 'https://mcp.example.test';
const env = AppEnv(
  name: 'Test',
  apiBase: api,
  callbackHost: 'console.example.test',
  callbackPath: '/mobile/oauth/callback',
  urlScheme: 'agentconnect-test',
);

class Call {
  Call(this.url, this.form, this.json);
  final Uri url;
  final Map<String, String>? form;
  final Object? json;
}

/// A scripted server. Handlers by "METHOD path"; records every call.
class FakeServer {
  final calls = <Call>[];
  final routes = <String, FetchResult Function(Call)>{};
  int clientSeq = 0;
  final validClients = <String>{};

  Future<FetchResult> fetch(Uri url, {Map<String, String>? form, Object? json}) async {
    final c = Call(url, form, json);
    calls.add(c);
    final method = form != null || json != null ? 'POST' : 'GET';
    final h = routes['$method ${url.origin}${url.path}'];
    if (h == null) return const FetchResult(404, '{}');
    return h(c);
  }

  List<Call> to(String path) => calls.where((c) => c.url.path == path).toList();

  static FetchResult ok(Object body, [int status = 200]) =>
      FetchResult(status, jsonEncode(body));

  FakeServer() {
    routes['GET https://api.example.test/.well-known/oauth-protected-resource'] = (_) => ok({
          'resource': asHost,
          'authorization_servers': [asHost],
          'scopes_supported': ['mcp:read', 'mcp:write'],
        });
    routes['GET $asHost/.well-known/oauth-authorization-server'] = (_) => ok({
          'issuer': asHost,
          'authorization_endpoint': '$asHost/oauth/authorize',
          'token_endpoint': '$asHost/oauth/token',
          'registration_endpoint': '$asHost/oauth/register',
          'code_challenge_methods_supported': ['S256'],
        });
    routes['POST $asHost/oauth/register'] = (c) {
      final id = 'client-${++clientSeq}';
      validClients.add(id);
      return ok({'client_id': id, 'client_id_issued_at': DateTime.now().millisecondsSinceEpoch ~/ 1000}, 201);
    };
    routes['GET $asHost/oauth/authorize'] = (c) {
      if (!validClients.contains(c.url.queryParameters['client_id'])) {
        return ok({'error': 'invalid_client'}, 400);
      }
      return const FetchResult(302, '', location: 'https://console.example.test/oauth/consent');
    };
    routes['POST $asHost/oauth/token'] = (c) {
      final f = c.form!;
      if (f['grant_type'] == 'authorization_code') {
        if (!validClients.contains(f['client_id'])) return ok({'error': 'invalid_client'}, 400);
        return ok({
          'access_token': 'at-1',
          'token_type': 'Bearer',
          'expires_in': 3600,
          'refresh_token': 'rt-1',
          'scope': 'mcp:read mcp:write',
        });
      }
      return ok({'error': 'unsupported_grant_type'}, 400);
    };
  }
}

/// Answers the sign-in sheet like the consent page: code + the request's state.
Authenticator consent({String? overrideState, bool fallbackScheme = false, String? error}) =>
    (Uri url, AppEnv e) async {
      final state = overrideState ?? url.queryParameters['state']!;
      final base = fallbackScheme
          ? '${e.urlScheme}://oauth/callback'
          : '${url.queryParameters['redirect_uri']}';
      final q = error != null ? 'error=$error&state=$state' : 'code=c-1&state=$state';
      return '$base?$q';
    };

void main() {
  test('PKCE S256 matches the RFC 7636 example', () {
    expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('metadata URLs: PRM at the API origin, AS metadata path-inserted', () {
    expect(prmCandidates(api).map((u) => u.toString()), [
      'https://api.example.test/.well-known/oauth-protected-resource',
      'https://api.example.test/.well-known/oauth-protected-resource/v1/mcp',
    ]);
    expect(asMetadataUrl('https://as.example.test').toString(),
        'https://as.example.test/.well-known/oauth-authorization-server');
    expect(asMetadataUrl('https://as.example.test/tenant/').toString(),
        'https://as.example.test/.well-known/oauth-authorization-server/tenant');
  });

  test('discovery follows the PRM to an AS on another host', () async {
    final s = FakeServer();
    final d = await discover(api, fetch: s.fetch);
    expect(d.issuer, asHost);
    expect(d.registrationEndpoint, '$asHost/oauth/register');
    expect(d.resource, asHost);
    expect(d.revocationEndpoint, isNull);
  });

  test('discovery falls back to the path-inserted PRM', () async {
    final s = FakeServer();
    final root = s.routes.remove('GET https://api.example.test/.well-known/oauth-protected-resource')!;
    s.routes['GET https://api.example.test/.well-known/oauth-protected-resource/v1/mcp'] = root;
    expect((await discover(api, fetch: s.fetch)).issuer, asHost);
  });

  test('discovery via the MCP endpoint challenge when the API host has no metadata', () async {
    final s = FakeServer();
    final prm = s.routes.remove('GET https://api.example.test/.well-known/oauth-protected-resource')!;
    s.routes['GET $asHost/.well-known/oauth-protected-resource'] = prm;
    s.routes['POST https://api.example.test/v1/mcp'] = (_) => const FetchResult(401, '',
        wwwAuthenticate:
            'Bearer resource_metadata="$asHost/.well-known/oauth-protected-resource", scope="mcp:read mcp:write"');
    final d = await discover(api, fetch: s.fetch);
    expect(d.issuer, asHost);
    expect(d.resource, asHost);
  });

  test('no discovery documents: not an AgentConnect server', () async {
    final s = FakeServer()..routes.clear();
    expect(() => discover(api, fetch: s.fetch), throwsA(isA<NotAnAgentConnectServer>()));
  });

  group('sign-in flow', () {
    late FakeServer s;
    late ClientStore clients;
    setUp(() {
      s = FakeServer();
      clients = ClientStore(MemoryStore());
    });

    SignInFlow flow(Authenticator a, {DateTime Function()? now}) => SignInFlow(
        env: env, clients: clients, fetch: s.fetch, authenticator: a, now: now);

    test('registers once, sends PKCE + resource + scopes, exchanges the code', () async {
      final g = await flow(consent()).run(api);
      expect(g.tokens.accessToken, 'at-1');
      expect(g.tokens.canWrite, isTrue);
      final reg = s.to('/oauth/register').single.json as Map;
      expect(reg['client_name'], 'AgentConnect for iOS');
      expect(reg['redirect_uris'], ['https://console.example.test/mobile/oauth/callback']);
      expect(reg['grant_types'], ['authorization_code', 'refresh_token']);
      final q = s.to('/oauth/authorize').single.url.queryParameters;
      expect(q['scope'], 'mcp:read mcp:write');
      expect(q['code_challenge_method'], 'S256');
      expect(q['resource'], asHost);
      expect(q['redirect_uri'], 'https://console.example.test/mobile/oauth/callback');
      final tok = s.to('/oauth/token').single.form!;
      expect(tok['code'], 'c-1');
      expect(pkceChallenge(tok['code_verifier']!), q['code_challenge']);
      expect(tok['resource'], asHost);

      // Second sign-in on the same server reuses the cached client_id.
      await flow(consent()).run(api);
      expect(s.to('/oauth/register'), hasLength(1));
    });

    test('custom-scheme fallback callback is accepted the same way', () async {
      final g = await flow(consent(fallbackScheme: true)).run(api);
      expect(g.tokens.accessToken, 'at-1');
    });

    test('a callback with another state is discarded', () async {
      await expectLater(flow(consent(overrideState: 'forged')).run(api),
          throwsA(isA<SignInException>().having((e) => e.error, 'error', SignInError.failed)));
      expect(s.to('/oauth/token'), isEmpty);
    });

    test('Deny on the consent page reads as cancelled', () async {
      await expectLater(flow(consent(error: 'access_denied')).run(api),
          throwsA(isA<SignInException>().having((e) => e.error, 'error', SignInError.cancelled)));
    });

    test('expired client (invalid_client) re-registers silently and retries once', () async {
      await clients.write(asHost, env.redirectUri, ClientRegistration('gone', DateTime.now()));
      final g = await flow(consent()).run(api);
      expect(g.clientId, 'client-1');
      expect(s.to('/oauth/register'), hasLength(1));
      expect((await clients.read(asHost, env.redirectUri))!.clientId, 'client-1');
    });

    test('a registration close to 90 days old is renewed before the browser opens', () async {
      final old = DateTime(2026, 1, 1);
      s.validClients.add('old');
      await clients.write(asHost, env.redirectUri, ClientRegistration('old', old));
      final g = await flow(consent(), now: () => old.add(const Duration(days: 88))).run(api);
      expect(g.clientId, 'client-1');
    });

    test('invalid_client at the token step re-registers and signs in again once', () async {
      var n = 0;
      s.routes['POST $asHost/oauth/token'] = (c) {
        if (++n == 1) return FakeServer.ok({'error': 'invalid_client'}, 400);
        return FakeServer.ok({'access_token': 'at-2', 'expires_in': 3600, 'refresh_token': 'rt'});
      };
      final g = await flow(consent()).run(api);
      expect(g.tokens.accessToken, 'at-2');
      expect(s.to('/oauth/register'), hasLength(2));
    });

    test('read-only consent is reflected in canWrite', () async {
      s.routes['POST $asHost/oauth/token'] = (c) => FakeServer.ok(
          {'access_token': 'a', 'expires_in': 3600, 'refresh_token': 'r', 'scope': 'mcp:read'});
      expect((await flow(consent()).run(api)).tokens.canWrite, isFalse);
    });
  });

  group('session', () {
    late FakeServer s;
    late TokenStore store;
    var now = DateTime(2026, 11, 4, 12);
    const info = AuthInfo(issuer: asHost, tokenEndpoint: '$asHost/oauth/token', clientId: 'cid');
    setUp(() {
      s = FakeServer();
      store = TokenStore(MemoryStore());
      now = DateTime(2026, 11, 4, 12);
    });
    OAuthSession session({DateTime? expires, String? revocation}) => OAuthSession(
          accountId: 'acc',
          info: revocation == null
              ? info
              : AuthInfo(
                  issuer: asHost,
                  tokenEndpoint: info.tokenEndpoint,
                  clientId: 'cid',
                  revocationEndpoint: revocation),
          tokens: TokenSet(
              accessToken: 'old',
              refreshToken: 'rt-0',
              expiresAt: expires ?? now.add(const Duration(minutes: 30)),
              scope: 'mcp:read mcp:write'),
          store: store,
          fetch: s.fetch,
          now: () => now,
          persisted: true,
        );

    test('refreshes 60 s before expiry; rotation is persisted', () async {
      var n = 0;
      s.routes['POST $asHost/oauth/token'] = (c) {
        expect(c.form!['grant_type'], 'refresh_token');
        expect(c.form!['client_id'], 'cid');
        n++;
        return FakeServer.ok({'access_token': 'new-$n', 'expires_in': 3600, 'refresh_token': 'rt-$n'});
      };
      final x = session(expires: now.add(const Duration(seconds: 30)));
      expect(await x.accessToken(), 'new-1');
      expect((await store.read('acc'))!.refreshToken, 'rt-1');
      expect(await x.accessToken(), 'new-1');
      expect(n, 1);
    });

    test('concurrent 401s refresh only once', () async {
      final gate = Completer<void>();
      var n = 0;
      s.routes['POST $asHost/oauth/token'] = (c) {
        n++;
        return FakeServer.ok({'access_token': 'new', 'expires_in': 3600, 'refresh_token': 'rt-1'});
      };
      final x = session();
      // Wrap fetch so all three callers are waiting before the refresh answers.
      final y = OAuthSession(
        accountId: 'acc',
        info: info,
        tokens: x.tokens,
        store: store,
        now: () => now,
        fetch: (u, {form, json}) async {
          await gate.future;
          return s.fetch(u, form: form, json: json);
        },
      );
      final f = Future.wait([y.refreshAfter401('old'), y.refreshAfter401('old'), y.refreshAfter401('old')]);
      gate.complete();
      expect(await f, [true, true, true]);
      expect(n, 1);
      expect(await y.accessToken(), 'new');
    });

    test('revoked grant (invalid_grant) ends the sign-in once', () async {
      s.routes['POST $asHost/oauth/token'] =
          (c) => FakeServer.ok({'error': 'invalid_grant', 'error_description': 'grant revoked'}, 400);
      var ended = 0;
      final x = session(expires: now)..onEnded = () => ended++;
      await expectLater(x.accessToken(), throwsA(isA<SignInEnded>()));
      expect(await x.refreshAfter401('old'), isFalse);
      expect(x.ended, isTrue);
      expect(ended, 1);
    });

    test('server 5xx during refresh is a network problem, not a sign-out', () async {
      s.routes['POST $asHost/oauth/token'] = (c) => const FetchResult(503, '');
      final x = session(expires: now.add(const Duration(seconds: 30)));
      // Still valid for 30 s: the old token is used.
      expect(await x.accessToken(), 'old');
      expect(x.ended, isFalse);
    });

    test('sign-out revokes only when the server offers revocation', () async {
      s.routes['POST $asHost/oauth/revoke'] = (c) => const FetchResult(200, '');
      await session().signOut();
      expect(s.to('/oauth/revoke'), isEmpty);
      expect(await store.read('acc'), isNull);

      await store.write('acc', session().tokens);
      await session(revocation: '$asHost/oauth/revoke').signOut();
      final r = s.to('/oauth/revoke').single.form!;
      expect(r['token'], 'rt-0');
      expect(r['token_type_hint'], 'refresh_token');
      expect(await store.read('acc'), isNull);
    });
  });
}
