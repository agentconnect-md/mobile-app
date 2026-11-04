import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/clojure.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/elixir.dart';
import 'package:re_highlight/languages/erlang.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/haskell.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/nix.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../ui/theme.dart';

/// One run of text inside a line and the highlight.js scope it belongs to
/// (`keyword`, `title.function_`, …; null for plain text).
typedef Token = (String text, String? scope);

/// Larger files are shown as plain text: highlighting stays well under a frame
/// budget per screenful, and the server sends 64 KiB slices anyway.
const _maxHighlightChars = 400 * 1024;

/// Splits [code] into lines of scoped tokens. Runs the highlighter on a
/// background isolate; an unknown language or a failure gives plain lines.
Future<List<List<Token>>> highlightLines(String code, String? language) async {
  if (language == null || code.length > _maxHighlightChars) return _plain(code);
  try {
    return await Isolate.run(() => tokenize(code, language));
  } catch (_) {
    return _plain(code);
  }
}

List<List<Token>> _plain(String code) => [
  for (final l in _lines(code)) [(l, null)],
];

List<String> _lines(String code) {
  final parts = code.split('\n');
  if (parts.length > 1 && parts.last.isEmpty) parts.removeLast();
  return [for (final p in parts) p.endsWith('\r') ? p.substring(0, p.length - 1) : p];
}

/// Synchronous tokenizer (exposed for tests).
List<List<Token>> tokenize(String code, String language) {
  final hl = Highlight()..registerLanguages(_languages);
  if (hl.getLanguage(language) == null) return _plain(code);
  final r = _LineRenderer();
  hl.highlight(code: code, language: language).render(r);
  final lines = r.lines;
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

final Map<String, Mode> _languages = {
  'bash': langBash,
  'c': langC,
  'clojure': langClojure,
  'cmake': langCmake,
  'cpp': langCpp,
  'csharp': langCsharp,
  'css': langCss,
  'dart': langDart,
  'diff': langDiff,
  'dockerfile': langDockerfile,
  'elixir': langElixir,
  'erlang': langErlang,
  'go': langGo,
  'gradle': langGradle,
  'graphql': langGraphql,
  'haskell': langHaskell,
  'ini': langIni,
  'java': langJava,
  'javascript': langJavascript,
  'json': langJson,
  'kotlin': langKotlin,
  'less': langLess,
  'lua': langLua,
  'makefile': langMakefile,
  'markdown': langMarkdown,
  'nginx': langNginx,
  'nix': langNix,
  'objectivec': langObjectivec,
  'perl': langPerl,
  'php': langPhp,
  'powershell': langPowershell,
  'properties': langProperties,
  'protobuf': langProtobuf,
  'python': langPython,
  'r': langR,
  'ruby': langRuby,
  'rust': langRust,
  'scala': langScala,
  'scss': langScss,
  'sql': langSql,
  'swift': langSwift,
  'typescript': langTypescript,
  'xml': langXml,
  'yaml': langYaml,
};

/// Walks the token tree and cuts it at newlines, keeping the innermost scope.
class _LineRenderer implements HighlightRenderer {
  final lines = <List<Token>>[[]];
  final _scopes = <String?>[];

  @override
  void addText(String text) {
    final scope = _scopes.lastWhere((s) => s != null, orElse: () => null);
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) lines.add([]);
      var t = parts[i];
      if (t.endsWith('\r')) t = t.substring(0, t.length - 1);
      if (t.isNotEmpty) lines.last.add((t, scope));
    }
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) {
    if (_scopes.isNotEmpty) _scopes.removeLast();
  }
}

/// Token colors: the web console's highlight.js theme (`globals.css`, `.hljs-*`),
/// mapped onto the same tokens in light and plum dark.
class CodeTheme {
  CodeTheme._(this._styles, this.base);
  final Map<String, TextStyle> _styles;
  final TextStyle base;

  factory CodeTheme.of(BuildContext context, {double size = 12.5}) {
    final p = context.pal;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final keyword = TextStyle(color: dark ? const Color(0xFFE479AC) : const Color(0xFFA82165));
    final string = TextStyle(color: p.online);
    final number = const TextStyle(color: Color(0xFFE8624C));
    final title = TextStyle(color: dark ? const Color(0xFF6A97F5) : const Color(0xFF2F6FED));
    final type = TextStyle(color: dark ? const Color(0xFFB794E6) : const Color(0xFF7D46C0));
    final attr = const TextStyle(color: Color(0xFFE0A30F));
    final tag = TextStyle(color: dark ? const Color(0xFFF4B8D3) : const Color(0xFF8A1A53));
    return CodeTheme._({
      'comment': const TextStyle(color: Color(0xFF9AA4B1), fontStyle: FontStyle.italic),
      'quote': const TextStyle(color: Color(0xFF9AA4B1), fontStyle: FontStyle.italic),
      'keyword': keyword,
      'selector-tag': keyword,
      'literal': keyword,
      'doctag': keyword,
      'name': keyword,
      'string': string,
      'regexp': string,
      'addition': string,
      'number': number,
      'symbol': number,
      'bullet': number,
      'link': number,
      'title': title,
      'section': title,
      'type': type,
      'built_in': type,
      'title.class_': type,
      'title.class_.inherited__': type,
      'attr': attr,
      'attribute': attr,
      'variable': attr,
      'template-variable': attr,
      'selector-attr': attr,
      'selector-pseudo': attr,
      'selector-class': tag,
      'selector-id': tag,
      'tag': tag,
      'meta': TextStyle(color: p.secondary),
      'params': TextStyle(color: p.secondary),
      'deletion': TextStyle(color: dark ? const Color(0xFFDC4B4B) : const Color(0xFFC43A3A)),
      'emphasis': const TextStyle(fontStyle: FontStyle.italic),
      'strong': const TextStyle(fontWeight: FontWeight.w600),
    }, mono(context, size: size, color: p.ink).copyWith(height: 1.7));
  }

  /// `title.function_` → `title.function_`, else `title`; `meta keyword` → `keyword`.
  TextStyle? style(String? scope) {
    if (scope == null) return null;
    final s = _styles[scope];
    if (s != null) return s;
    final words = scope.split(' ');
    if (words.length > 1) return style(words.last);
    final dot = scope.indexOf('.');
    return dot > 0 ? _styles[scope.substring(0, dot)] : null;
  }

  TextSpan span(List<Token> line) => TextSpan(
    children: [for (final (text, scope) in line) TextSpan(text: text, style: style(scope))],
  );
}

/// Numbered, highlighted lines. Wrapped by default (the gutter keeps the number
/// beside a wrapped line's first row); [wrap] false scrolls sideways instead.
class CodeLines extends StatelessWidget {
  const CodeLines({super.key, required this.lines, this.wrap = true, this.footer});
  final List<List<Token>> lines;
  final bool wrap;

  /// Under the last line (the "load more" row).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final theme = CodeTheme.of(context);
    final digits = '${lines.length}'.length;
    final gutterStyle = mono(context, size: 12.5, color: p.idle).copyWith(height: 1.7);
    final gutterW = 22.0 + digits * 7.6;
    Widget gutter(int i) => Container(
      width: gutterW,
      padding: const EdgeInsets.only(right: 10),
      alignment: Alignment.topRight,
      child: Text('${i + 1}', style: gutterStyle),
    );
    final count = lines.length + (footer != null ? 1 : 0);
    if (wrap) {
      return SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          itemCount: count,
          itemBuilder: (_, i) {
            if (i == lines.length) return footer!;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionContainer.disabled(child: gutter(i)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, right: 14),
                    child: Text.rich(theme.span(lines[i]), style: theme.base),
                  ),
                ),
              ],
            );
          },
        ),
      );
    }
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectionContainer.disabled(child: Column(children: [for (var i = 0; i < lines.length; i++) gutter(i)])),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 10, right: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in lines) Text.rich(theme.span(line), style: theme.base, softWrap: false),
                    ],
                  ),
                ),
              ),
            ],
          ),
          ?footer,
        ],
      ),
    );
  }
}
