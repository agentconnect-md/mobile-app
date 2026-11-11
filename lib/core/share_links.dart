import 'auth/app_state.dart';
import 'auth/native.dart';
import 'console_links.dart';

/// A console session URL: `/<org>/sessions/<id>[?thread=<root>][?fill=<id>][#msg=<seq>]`.
class ConsoleLink {
  const ConsoleLink({required this.slug, required this.sessionId, this.thread, this.fill, this.seq});
  final String slug;
  final String sessionId;
  final String? thread;
  final String? fill;

  /// The message's transcript seq (the same in every view).
  final int? seq;
}

/// Parses a console session link of this build's console; null otherwise.
ConsoleLink? parseConsoleLink(String raw, AppEnv env) {
  final u = Uri.tryParse(raw);
  if (u == null || u.scheme != 'https' || u.host.toLowerCase() != env.callbackHost.toLowerCase()) return null;
  final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length != 3 || segs[1] != 'sessions' || segs[2].isEmpty) return null;
  int? seq;
  final frag = u.fragment;
  if (frag.startsWith('msg=')) seq = int.tryParse(frag.substring(4));
  String? q(String k) {
    final v = u.queryParameters[k];
    return v == null || v.isEmpty ? null : v;
  }

  return ConsoleLink(slug: segs[0], sessionId: segs[2], thread: q('thread'), fill: q('fill'), seq: seq);
}

/// The console link to a session, or to one of its messages by [seq]; a
/// message in a thread names the thread's root too (`?thread=<root>`).
/// Null for an account on a server whose console the app doesn't know.
Uri? sessionLink(AppState app, String slug, String sessionId, {int? seq, String? thread}) => consoleUri(
      app,
      slug,
      'sessions/$sessionId',
      query: thread == null ? null : {'thread': thread},
      fragment: seq == null ? null : 'msg=$seq',
    );
