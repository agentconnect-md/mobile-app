import 'models.dart';

/// A task an agent started from a conversation (`assistant/subsessions`).
class AgentTask {
  const AgentTask({
    required this.title,
    required this.state,
    this.sessionId,
    this.startedAt,
    this.summary,
    this.summaryAt,
    this.replies = 0,
    this.threaded = false,
    this.openedForMessageId,
    this.canStop = false,
    this.visible = true,
  });

  /// False when the caller can see the task exists but not its conversation.
  final bool visible;
  final String? sessionId;
  final String title;

  /// open / done / failed.
  final String state;
  final DateTime? startedAt;
  final String? summary;
  final DateTime? summaryAt;
  final int replies;
  final bool threaded;

  /// The message that started it: the card is shown under that message.
  final String? openedForMessageId;
  final bool canStop;

  bool get running => state == 'open';

  factory AgentTask.fromJson(dynamic j) {
    final m = asMap(j);
    final r = m['replies'];
    return AgentTask(
      sessionId: asStr(m['sessionId']),
      title: asStr(m['title']) ?? '',
      state: asStr(m['state']) ?? 'open',
      startedAt: asDate(m['startedAt']),
      summary: asStr(m['summary']),
      summaryAt: asDate(m['summaryUpdatedAt']),
      replies: r is num ? r.toInt() : 0,
      threaded: m['threaded'] == true,
      openedForMessageId: asStr(m['openedForMessageId']),
      canStop: m['canStop'] == true,
      visible: m['visible'] != false,
    );
  }
}

class FileEntry {
  const FileEntry(this.name, this.type, {this.size, this.mtime});
  final String name;

  /// dir / file / symlink / other.
  final String type;
  final num? size;
  final DateTime? mtime;
  bool get isDir => type == 'dir';
  factory FileEntry.fromJson(dynamic j) {
    final m = asMap(j);
    final s = m['size'];
    return FileEntry(asStr(m['name']) ?? '', asStr(m['type']) ?? 'other',
        size: s is num ? s : null, mtime: asDate(m['mtime']));
  }
}

class DirPage {
  const DirPage(this.path, this.exists, this.entries, this.nextCursor);
  final String path;
  final bool exists;
  final List<FileEntry> entries;
  final String? nextCursor;
  factory DirPage.fromJson(dynamic j) {
    final m = asMap(j);
    final list = asList(m['entries']).map(FileEntry.fromJson).toList()
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return DirPage(asStr(m['path']) ?? '', m['exists'] != false, list, asStr(m['nextCursor']));
  }
}

class FileSlice {
  const FileSlice(this.text, this.binary, this.truncated, this.exists);
  final String text;
  final bool binary;
  final bool truncated;
  final bool exists;
  factory FileSlice.fromJson(dynamic j) {
    final m = asMap(j);
    return FileSlice(
      asStr(m['content']) ?? asStr(m['data']) ?? '',
      asStr(m['encoding']) == 'none',
      m['truncated'] == true,
      m['exists'] != false,
    );
  }
}

class GitFile {
  const GitFile(this.path, this.index, this.workingDir, {this.additions, this.deletions});
  final String path;
  final String index;
  final String workingDir;
  final int? additions;
  final int? deletions;

  /// One letter like `git status --short`: M, A, D, R, ?.
  String get code {
    final c = index.trim().isNotEmpty && index != ' ' ? index : workingDir;
    if (c == '?') return 'A';
    return c.isEmpty ? 'M' : c.substring(0, 1).toUpperCase();
  }

  factory GitFile.fromJson(dynamic j) {
    final m = asMap(j);
    int? n(dynamic v) => v is num ? v.toInt() : null;
    return GitFile(asStr(m['path']) ?? '', asStr(m['index']) ?? '', asStr(m['workingDir']) ?? '',
        additions: n(m['additions']), deletions: n(m['deletions']));
  }
}

class GitStatus {
  const GitStatus({
    required this.isRepo,
    required this.clean,
    this.branch,
    this.tracking,
    this.dir,
    this.files = const [],
  });
  final bool isRepo;
  final bool clean;
  final String? branch;
  final String? tracking;
  final String? dir;
  final List<GitFile> files;

  /// "origin/main" → "main".
  String? get base {
    final t = tracking;
    if (t == null || t.isEmpty) return null;
    final i = t.indexOf('/');
    return i >= 0 ? t.substring(i + 1) : t;
  }

  factory GitStatus.fromJson(dynamic j) {
    final m = asMap(j);
    return GitStatus(
      isRepo: m['isRepo'] == true,
      clean: m['clean'] == true,
      branch: asStr(m['branch']),
      tracking: asStr(m['tracking']),
      dir: asStr(m['agentDir']),
      files: asList(m['files']).map(GitFile.fromJson).where((f) => f.path.isNotEmpty).toList(),
    );
  }
}

class CommitResult {
  const CommitResult(this.ok, {this.sha, this.reason});
  final bool ok;
  final String? sha;
  final String? reason;
  factory CommitResult.fromJson(dynamic j) {
    final m = asMap(j);
    final r = m['reason'];
    return CommitResult(m['ok'] == true, sha: asStr(m['sha']), reason: r is String ? r : asStr(asMap(r)['code']));
  }
}
