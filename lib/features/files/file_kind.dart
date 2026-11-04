import 'package:flutter/material.dart';

/// How a workspace file is shown: highlighted code, rendered Markdown, an
/// image, a PDF, or plain text. Decided from the name alone, so a row can
/// pick its icon before anything is read.
enum FilePreview { code, markdown, image, pdf, text, binary }

class FileKind {
  const FileKind._(this.preview, this.icon, {this.language, this.label});
  final FilePreview preview;
  final IconData icon;

  /// highlight.js language id (null: no highlighting).
  final String? language;

  /// "TypeScript", "Markdown", "PNG image" — the header's first meta part.
  final String? label;

  /// Read through the raw download (bytes), not the text slices.
  bool get usesBytes => preview == FilePreview.image || preview == FilePreview.pdf;

  static FileKind of(String path) {
    final name = path.split('/').last.toLowerCase();
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1) : '';
    final byName = _names[name];
    if (byName != null) return _code(byName);
    if (_markdown.contains(ext)) {
      return const FileKind._(FilePreview.markdown, Icons.article_outlined, language: 'markdown', label: 'Markdown');
    }
    if (_images.contains(ext)) {
      return FileKind._(FilePreview.image, Icons.image_outlined, label: '${ext.toUpperCase()} image');
    }
    if (ext == 'pdf') return const FileKind._(FilePreview.pdf, Icons.picture_as_pdf_outlined, label: 'PDF');
    final lang = _ext[ext];
    if (lang != null) return _code(lang);
    if (_archives.contains(ext)) return const FileKind._(FilePreview.binary, Icons.folder_zip_outlined);
    if (_plain.contains(ext)) return const FileKind._(FilePreview.text, Icons.notes_outlined, label: 'Text');
    return const FileKind._(FilePreview.text, Icons.insert_drive_file_outlined);
  }

  static FileKind _code(String lang) => FileKind._(
    FilePreview.code,
    _data.contains(lang) ? Icons.data_object : Icons.code,
    language: lang,
    label: _labels[lang],
  );

  static const _markdown = {'md', 'markdown', 'mdx', 'mdown'};
  static const _images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};
  static const _archives = {'zip', 'gz', 'tgz', 'tar', 'bz2', 'xz', '7z', 'rar', 'jar', 'whl'};
  static const _plain = {'txt', 'log', 'csv', 'tsv', 'lock', 'out'};
  static const _data = {'json', 'yaml', 'ini', 'xml', 'properties', 'protobuf', 'graphql'};

  /// Same mapping as the web console's viewer (`lib/highlight.ts`), plus a few.
  static const _ext = {
    'ts': 'typescript',
    'tsx': 'typescript',
    'mts': 'typescript',
    'cts': 'typescript',
    'js': 'javascript',
    'jsx': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'json': 'json',
    'jsonc': 'json',
    'json5': 'json',
    'py': 'python',
    'pyi': 'python',
    'go': 'go',
    'rs': 'rust',
    'rb': 'ruby',
    'java': 'java',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'c': 'c',
    'h': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'cxx': 'cpp',
    'hpp': 'cpp',
    'm': 'objectivec',
    'mm': 'objectivec',
    'cs': 'csharp',
    'php': 'php',
    'swift': 'swift',
    'dart': 'dart',
    'scala': 'scala',
    'lua': 'lua',
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
    'fish': 'bash',
    'ps1': 'powershell',
    'sql': 'sql',
    'html': 'xml',
    'htm': 'xml',
    'xml': 'xml',
    'svg': 'xml',
    'plist': 'xml',
    'vue': 'xml',
    'css': 'css',
    'scss': 'scss',
    'less': 'less',
    'yaml': 'yaml',
    'yml': 'yaml',
    'toml': 'ini',
    'ini': 'ini',
    'cfg': 'ini',
    'conf': 'ini',
    'env': 'bash',
    'properties': 'properties',
    'gradle': 'gradle',
    'proto': 'protobuf',
    'graphql': 'graphql',
    'gql': 'graphql',
    'dockerfile': 'dockerfile',
    'makefile': 'makefile',
    'mk': 'makefile',
    'cmake': 'cmake',
    'diff': 'diff',
    'patch': 'diff',
    'r': 'r',
    'pl': 'perl',
    'ex': 'elixir',
    'exs': 'elixir',
    'hs': 'haskell',
    'clj': 'clojure',
    'erl': 'erlang',
    'nix': 'nix',
    'nginx': 'nginx',
  };

  static const _names = {
    'dockerfile': 'dockerfile',
    'makefile': 'makefile',
    'gnumakefile': 'makefile',
    'cmakelists.txt': 'cmake',
    '.gitignore': 'bash',
    '.dockerignore': 'bash',
    '.env': 'bash',
    '.bashrc': 'bash',
    '.zshrc': 'bash',
    '.editorconfig': 'ini',
    '.npmrc': 'ini',
    'gemfile': 'ruby',
    'rakefile': 'ruby',
    'podfile': 'ruby',
  };

  static const _labels = {
    'typescript': 'TypeScript',
    'javascript': 'JavaScript',
    'json': 'JSON',
    'python': 'Python',
    'go': 'Go',
    'rust': 'Rust',
    'ruby': 'Ruby',
    'java': 'Java',
    'kotlin': 'Kotlin',
    'c': 'C',
    'cpp': 'C++',
    'objectivec': 'Objective-C',
    'csharp': 'C#',
    'php': 'PHP',
    'swift': 'Swift',
    'dart': 'Dart',
    'scala': 'Scala',
    'lua': 'Lua',
    'bash': 'Shell',
    'powershell': 'PowerShell',
    'sql': 'SQL',
    'xml': 'XML',
    'css': 'CSS',
    'scss': 'SCSS',
    'less': 'Less',
    'yaml': 'YAML',
    'ini': 'INI',
    'properties': 'Properties',
    'gradle': 'Gradle',
    'protobuf': 'Protobuf',
    'graphql': 'GraphQL',
    'dockerfile': 'Dockerfile',
    'makefile': 'Makefile',
    'cmake': 'CMake',
    'diff': 'Diff',
    'r': 'R',
    'perl': 'Perl',
    'elixir': 'Elixir',
    'haskell': 'Haskell',
    'clojure': 'Clojure',
    'erlang': 'Erlang',
    'nix': 'Nix',
    'nginx': 'nginx',
    'markdown': 'Markdown',
  };
}

/// Raw downloads stop here (the server answers 413 above it).
const maxPreviewBytes = 8 * 1024 * 1024;

/// "812 B", "2.1 KB", "1.4 MB".
String formatBytes(num? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '${bytes.toInt()} B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 ? v.toStringAsFixed(1) : v.round()} ${units[i]}';
}

/// Lines as an editor counts them: a trailing newline ends the last line.
List<String> splitLines(String text) {
  if (text.isEmpty) return const [];
  final parts = text.split(RegExp(r'\r?\n'));
  if (parts.length > 1 && parts.last.isEmpty) parts.removeLast();
  return parts;
}

/// A link in a Markdown file, resolved against that file's folder:
/// `../docs/a.md#x` from `src/README.md` → `docs/a.md`. Null when it leaves
/// the workspace or is not a relative path.
String? resolveRelative(String fromFile, String href) {
  if (href.isEmpty || href.startsWith('#') || href.startsWith('/') || Uri.tryParse(href)?.hasScheme == true) {
    return null;
  }
  var target = href.split('#').first.split('?').first;
  if (target.isEmpty) return null;
  target = Uri.decodeComponent(target);
  final parts = fromFile.split('/')..removeLast();
  for (final seg in target.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.isEmpty ? null : parts.join('/');
}
