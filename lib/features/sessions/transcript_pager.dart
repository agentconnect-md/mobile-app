import '../../core/api/models.dart';
import 'transcript.dart';

/// Reads one page of a session's main timeline: the newest page with no
/// argument, the older page a [cursor] names, or what was added or changed
/// [after] a page's `liveCursor`.
typedef TranscriptFetch = Future<MessagePage> Function({String? cursor, String? after});

/// A session's main transcript as far as it is loaded: the newest page, older
/// pages added on demand until the start of the conversation, and what
/// arrives later merged in by seq. Message content stays in memory only.
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

  /// Where the next forward read starts (`liveCursor`).
  String? _live;

  /// Forward pages read in one refresh at most.
  static const _forwardPagesMax = 20;

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
    _live = page.liveCursor;
    anchorSeq = items.isEmpty ? null : items.first.seq;
  }

  /// Brings in what was added or changed since the last read: forward from
  /// the last page's `liveCursor` where the daemon gives one, else the newest
  /// page again, merged in (see [mergeNewestPage]). Either way the older
  /// pages already loaded stay. Throws what the read does.
  Future<void> refresh() async {
    final after = _live;
    if (after != null && items.isNotEmpty) {
      try {
        return await _readForward(after);
      } catch (_) {
        // The forward read was refused: the newest page still says where things stand.
      }
    }
    final page = await _fetch();
    _live = page.liveCursor;
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

  /// Reads forward from [after] and puts each row in by seq: new rows are
  /// added, rows that changed (a tool call that finished) are replaced.
  Future<void> _readForward(String after) async {
    var cursor = after;
    for (var n = 0; n < _forwardPagesMax; n++) {
      final page = await _fetch(after: cursor);
      // A row below the loaded ones belongs to a page not asked for yet.
      final floor = hasOlder && items.isNotEmpty ? items.first.seq : null;
      final bySeq = {for (final i in items) i.seq: i};
      for (final i in buildTranscript(page.messages, agentIds)) {
        if (floor == null || i.seq >= floor) bySeq[i.seq] = i;
      }
      items = bySeq.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
      if (page.roots) threads = {...threads, ...page.threads};
      final next = page.liveCursor;
      if (next == null) break;
      cursor = next;
      _live = next;
      if (!page.liveMore) break;
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
