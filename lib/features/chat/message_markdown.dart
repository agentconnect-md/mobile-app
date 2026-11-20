import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../ui/icons.dart';
import '../../ui/theme.dart';

/// Longer messages skip the Markdown parser and show as plain text (the web
/// console's cap: parsing is superlinear on very large strings).
const maxMarkdownChars = 100000;

/// The only link targets that open; any other link shows as its label.
final _webHref = RegExp(r'^(?:https?:|mailto:)', caseSensitive: false);

/// A chat message rendered as GitHub-flavored Markdown, like the web console's
/// transcript: single newlines break lines, links open in the external
/// browser, code is plain monospace. The text is selectable. A message that is
/// too long, or that the parser cannot handle, shows as plain text.
class MessageMarkdown extends StatefulWidget {
  const MessageMarkdown(this.text, {super.key, this.onOpenLink});
  final String text;

  /// Opens an http, https or mailto link. Defaults to the external browser.
  final ValueChanged<Uri>? onOpenLink;

  @override
  State<MessageMarkdown> createState() => _MessageMarkdownState();
}

class _MessageMarkdownState extends State<MessageMarkdown> implements MarkdownBuilderDelegate {
  /// The rendered blocks, or null when the message shows as plain text.
  List<Widget>? _blocks;
  final List<GestureRecognizer> _recognizers = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _render();
  }

  @override
  void didUpdateWidget(MessageMarkdown old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text) _render();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  void _render() {
    _disposeRecognizers();
    _blocks = null;
    final text = widget.text;
    if (text.length > maxMarkdownChars) return;
    try {
      final doc = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false);
      final nodes = _clean(doc.parseLines(const LineSplitter().convert(text)), root: true);
      final blocks = MarkdownBuilder(
        delegate: this,
        selectable: false,
        styleSheet: _style(context),
        imageDirectory: null,
        imageBuilder: _image,
        checkboxBuilder: _checkbox,
        bulletBuilder: null,
        builders: const {},
        paddingBuilders: const {},
        listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
        fitContent: true,
        softLineBreak: true,
      ).build(nodes);
      if (blocks.isNotEmpty) _blocks = blocks;
    } catch (_) {
      // A reply still streaming in, or Markdown the parser chokes on, must not
      // break the transcript: the text shows as written. Nothing is logged,
      // since message content stays out of logs.
      _disposeRecognizers();
      _blocks = null;
    }
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final r = TapGestureRecognizer()..onTap = () => _open(href);
    _recognizers.add(r);
    return r;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
        text: code.replaceAll(RegExp(r'\n$'), ''),
        style: mono(context, size: 12.5, color: context.pal.ink).copyWith(height: 1.55),
      );

  Future<void> _open(String? href) async {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri == null || !const {'http', 'https', 'mailto'}.contains(uri.scheme)) return;
    final open = widget.onOpenLink;
    if (open != null) {
      open(uri);
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No app can open it (a mailto link without a mail app).
    }
  }

  Widget _image(Uri uri, String? title, String? alt) {
    final fallback = Text(
      alt ?? '',
      style: TextStyle(fontSize: 15, color: context.pal.tertiary, fontStyle: FontStyle.italic),
    );
    if (uri.scheme != 'http' && uri.scheme != 'https') return fallback;
    return Image.network(uri.toString(), errorBuilder: (_, _, _) => fallback);
  }

  Widget _checkbox(bool checked) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Icon(
          checked ? AppIcons.checkBox : AppIcons.checkBoxOutlineBlank,
          size: 16,
          color: context.pal.tertiary,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks;
    if (blocks == null) return SelectableText(widget.text, style: _body(context));
    return SelectionArea(
      child: blocks.length == 1
          ? blocks.single
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: blocks,
            ),
    );
  }
}

/// Prepares the parsed message for the builder: a link that is not http, https
/// or mailto becomes its label, and text directly under the root (a raw HTML
/// block, which the builder would drop) becomes a paragraph, so HTML an agent
/// wrote stays readable as text.
List<md.Node> _clean(List<md.Node> nodes, {bool root = false}) {
  final out = <md.Node>[];
  for (final n in nodes) {
    if (n is! md.Element) {
      out.add(root ? md.Element('p', [n]) : n);
      continue;
    }
    final children = n.children;
    final kids = children == null ? null : _clean(children);
    if (n.tag == 'a' && !_webHref.hasMatch(n.attributes['href'] ?? '')) {
      out.addAll(kids ?? const []);
      continue;
    }
    out.add(kids == null
        ? n
        : (md.Element(n.tag, kids)
          ..attributes.addAll(n.attributes)
          ..generatedId = n.generatedId
          ..footnoteLabel = n.footnoteLabel));
  }
  return out;
}

/// The bubble's text style, complete (family included): table cells are drawn
/// with exactly the style they are given, not merged into the ambient one.
TextStyle _body(BuildContext context) =>
    DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: 15, color: context.pal.ink, height: 1.4));

/// Compact chat typography (the web console's `.mdtxt`), unlike the roomier
/// document style of the Markdown file preview.
MarkdownStyleSheet _style(BuildContext context) {
  final p = context.pal;
  final body = _body(context);
  final heading = body.copyWith(fontWeight: FontWeight.w600);
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: body,
    a: TextStyle(color: p.link),
    strong: const TextStyle(fontWeight: FontWeight.w600),
    em: const TextStyle(fontStyle: FontStyle.italic),
    del: TextStyle(decoration: TextDecoration.lineThrough, color: p.secondary),
    h1: heading.copyWith(fontSize: 16.5),
    h2: heading.copyWith(fontSize: 16.5),
    h3: heading,
    h4: heading,
    h5: heading,
    h6: heading,
    blockSpacing: 8,
    listIndent: 20,
    listBullet: body.copyWith(color: p.tertiary),
    code: mono(context, size: 13.5, color: p.ink).copyWith(backgroundColor: p.sunken),
    codeblockPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
    codeblockDecoration: BoxDecoration(
      color: p.sunken,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: p.hairline),
    ),
    blockquote: body.copyWith(color: p.secondary),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 1, 0, 1),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: p.borderStrong, width: 3)),
    ),
    // Rules and table lines sit on the tinted bubble, where the hairline color disappears in dark.
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: p.borderStrong)),
    ),
    tableHead: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
    tableBody: body.copyWith(fontSize: 14),
    tableHeadAlign: TextAlign.left,
    tableBorder: TableBorder.all(color: p.borderStrong),
    tableColumnWidth: const _HugColumnWidth(),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    tableHeadCellsDecoration: BoxDecoration(color: p.sunken),
    tableVerticalAlignment: TableCellVerticalAlignment.top,
  );
}

/// Table columns as wide as their content, up to [_max]: longer cells wrap, and
/// a table wider than the bubble scrolls sideways (the builder puts a table
/// with intrinsic column widths in a horizontal scroll view).
class _HugColumnWidth extends IntrinsicColumnWidth {
  const _HugColumnWidth();
  static const _max = 260.0;

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      math.min(super.minIntrinsicWidth(cells, containerWidth), _max);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      math.min(super.maxIntrinsicWidth(cells, containerWidth), _max);
}
