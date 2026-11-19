import '../../core/api/models.dart';
import 'transcript.dart';

/// Reads one page of a session's main timeline: the newest page without a
/// [cursor], else the older page that cursor names.
typedef TranscriptFetch = Future<MessagePage> Function({String? cursor});

/// A session's main transcript as far as it is loaded: the newest page, older
/// pages added on demand until the start of the conversation, and refreshes
/// merged in by seq. Message content stays in memory only.
class TranscriptPager {
  TranscriptPager(this._fetch, this.agentIds);
  final TranscriptFetch _fetch;

  /// The sender ids that count as agents.
  final Set<String> agentIds;

  /// Loaded rows, oldest first, one per seq.
  List<TranscriptItem> items = [];

  /// Thread footers by root id (`view=roots`).
  Map<String, ThreadSummary> threads = {};

  /// The pages came from `view=roots`.
  bool roots = false;

  /// The lowest seq of the page the conversation opened on: rows below it
  /// came from older pages.
  int? anchorSeq;

  String? _older;
  bool _loadingOlder = false;

  /// Messages older than the loaded ones exist.
  bool get hasOlder => _older != null;

  /// Rows from pages older than the one the conversation opened on.
  List<TranscriptItem> get earlier {
    final a = anchorSeq;
    return a == null ? const [] : items.where((i) => i.seq < a).toList();
  }

  /// Rows of the page the conversation opened on, and everything newer.
  List<TranscriptItem> get recent {
    final a = anchorSeq;
    return a == null ? items : items.where((i) => i.seq >= a).toList();
  }

  /// Reads the newest page, dropping what was loaded. Throws what the read does.
  Future<void> loadNewest() async {
    final page = await _fetch();
    items = buildTranscript(page.messages, agentIds);
    threads = page.threads;
    roots = page.roots;
    _older = page.nextCursor;
    anchorSeq = items.isEmpty ? null : items.first.seq;
  }

  /// Reads the newest page again and merges it in; older pages already
  /// loaded stay (see [mergeNewestPage]). Throws what the read does.
  Future<void> refresh() async {
    final page = await _fetch();
    final merged =
        mergeNewestPage(items, buildTranscript(page.messages, agentIds), freshHasOlder: page.nextCursor != null);
    items = merged.items;
    roots = page.roots;
    if (merged.keptOlder) {
      threads = {...threads, ...page.threads};
    } else {
      threads = page.threads;
      _older = page.nextCursor;
    }
  }

  /// Adds the next older page. False when there is none, one is already
  /// loading, or the read failed (the cursor stays, so it can be retried).
  Future<bool> loadOlder() async {
    final cursor = _older;
    if (cursor == null || _loadingOlder) return false;
    _loadingOlder = true;
    try {
      final page = await _fetch(cursor: cursor);
      final have = items.map((e) => e.seq).toSet();
      final older = buildTranscript(page.messages, agentIds).where((o) => !have.contains(o.seq)).toList();
      items = [...older, ...items]..sort((a, b) => a.seq.compareTo(b.seq));
      // Footers of the older page's threads; the newer pages' stay fresher.
      if (page.roots) threads = {...page.threads, ...threads};
      // A cursor that names itself would never end.
      _older = page.nextCursor == cursor ? null : page.nextCursor;
      return true;
    } catch (_) {
      return false;
    } finally {
      _loadingOlder = false;
    }
  }

  /// Pages back until the message [seq] is loaded (a link names it), the
  /// start is reached, or a page fails.
  Future<void> loadBackTo(int seq) async {
    while (hasOlder && !items.any((i) => i.seq <= seq)) {
      if (!await loadOlder()) break;
    }
  }
}
