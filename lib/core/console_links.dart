import 'api/models.dart';
import 'auth/app_state.dart';

/// Links into the web console. The console serves the app's sign-in callback,
/// so its origin is the callback host of the account's server. An account on
/// a server the app no longer knows has no known console: null.
Uri? consoleUri(AppState app, String slug, String path, {Map<String, String>? query, String? fragment}) {
  final a = app.current;
  final env = a == null ? null : app.envOf(a);
  if (env == null) return null;
  final segs = [slug, ...path.split('/').where((s) => s.isNotEmpty)];
  return Uri(
    scheme: 'https',
    host: env.callbackHost,
    pathSegments: segs,
    queryParameters: query == null || query.isEmpty ? null : query,
    fragment: fragment,
  );
}

/// The current org's console slug (`/{slug}/…`), or `-` when the server
/// doesn't name one; the console then falls back to the signed-in org.
Future<String> currentOrgSlug(AppState app) async {
  final id = app.current?.orgId;
  try {
    for (final Org o in await app.client.orgs()) {
      if (o.id == id && (o.slug?.isNotEmpty ?? false)) return o.slug!;
    }
  } catch (_) {}
  return '-';
}
