import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/api/workspace.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';
import 'code_view.dart';
import 'file_kind.dart';
import 'workspace_files.dart';

/// One workspace file, read-only and in memory only: highlighted code with line
/// numbers, Markdown rendered (or its source), images and PDFs previewed from
/// the file's raw bytes.
class FileViewScreen extends StatefulWidget {
  const FileViewScreen({
    super.key,
    required this.ws,
    required this.path,
    this.size,
    this.changes = const Changes(),
    this.depth,
  });
  final WorkspaceRef ws;
  final String path;

  /// From the folder listing, when known (skips downloads over the cap).
  final int? size;
  final Changes changes;

  /// Folder screens under this one (see [Breadcrumb.depth]).
  final int? depth;

  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

enum _Problem { missing, folder, binary, tooLarge, oldDaemon, failed }

class _FileViewScreenState extends State<FileViewScreen> {
  late final FileKind _kind = FileKind.of(widget.path);
  FileSlice? _slice;
  List<List<Token>>? _lines;
  Uint8List? _bytes;
  Size? _imageSize;
  int? _pages;
  int? _size;
  _Problem? _problem;
  Object? _error;
  bool _loadingMore = false;
  bool _wrap = true;
  late bool _preview = _kind.preview == FilePreview.markdown;

  String get _name => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    _size = widget.size;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _problem = null;
    });
    try {
      if (_kind.usesBytes) {
        await _loadBytes();
      } else {
        await _loadText();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadText() async {
    final app = AppScope.read(context);
    final f = await withSession(
      (sid) => app.client.file(app.current!.orgId, widget.ws.agentId, widget.path, sessionId: sid),
      widget.ws.sessionId,
    );
    if (!mounted) return;
    _size = f.size ?? _size;
    if (!f.exists || f.isDir || f.binary) {
      setState(() {
        _slice = f;
        _problem = !f.exists ? _Problem.missing : (f.isDir ? _Problem.folder : _Problem.binary);
      });
      return;
    }
    await _show(f);
  }

  Future<void> _show(FileSlice f) async {
    final lines = await highlightLines(f.text, _kind.language);
    if (mounted) {
      setState(() {
        _slice = f;
        _lines = lines;
      });
    }
  }

  Future<void> _loadMore() async {
    final f = _slice;
    if (f == null || f.nextOffset == null || _loadingMore) return;
    final app = AppScope.read(context);
    setState(() => _loadingMore = true);
    try {
      final next = await withSession(
        (sid) =>
            app.client.file(app.current!.orgId, widget.ws.agentId, widget.path, sessionId: sid, offset: f.nextOffset!),
        widget.ws.sessionId,
      );
      await _show(f.append(next));
    } catch (_) {
      // The rows already shown stay; the button stays to try again.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadBytes() async {
    if ((_size ?? 0) > maxPreviewBytes) {
      setState(() => _problem = _Problem.tooLarge);
      return;
    }
    final app = AppScope.read(context);
    final Uint8List bytes;
    try {
      bytes = await withSession(
        (sid) => app.client.fileBytes(app.current!.orgId, widget.ws.agentId, widget.path, sessionId: sid),
        widget.ws.sessionId,
      );
    } on ApiException catch (e) {
      final p = switch (e.status) {
        413 => _Problem.tooLarge,
        409 when e.code == 'DAEMON_FEATURE_MISSING' || (e.message ?? '').contains('upgrade') => _Problem.oldDaemon,
        404 => _Problem.missing,
        _ => null,
      };
      if (p == null) rethrow;
      if (mounted) setState(() => _problem = p);
      return;
    }
    if (!mounted) return;
    _size = bytes.length;
    if (_kind.preview == FilePreview.image) {
      try {
        final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
        final desc = await ui.ImageDescriptor.encoded(buf);
        _imageSize = Size(desc.width.toDouble(), desc.height.toDouble());
        desc.dispose();
        buf.dispose();
      } catch (_) {
        if (mounted) setState(() => _problem = _Problem.failed);
        return;
      }
    }
    if (mounted) setState(() => _bytes = bytes);
  }

  String _meta(AppLocalizations l) {
    final f = _slice;
    final lines = _lines;
    final size = _size == null ? null : formatBytes(_size);
    if (lines != null && f != null) {
      return [
        _kind.label,
        f.truncated ? l.fileFirstLines(lines.length) : l.fileLines(lines.length),
        size,
      ].whereType<String>().join(' · ');
    }
    if (_imageSize != null) {
      return [
        '${_imageSize!.width.toInt()} × ${_imageSize!.height.toInt()}',
        size,
        _kind.label,
      ].whereType<String>().join(' · ');
    }
    if (_pages != null) return [l.pdfPages(_pages!), size].whereType<String>().join(' · ');
    return [_kind.label, size].whereType<String>().join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final textShown = _lines != null && _problem == null;
    final segs = widget.path.split('/');
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: mono(context, size: 16, color: p.ink, weight: FontWeight.w600),
        ),
        actions: [
          if (textShown && !_preview)
            IconButton(
              tooltip: l.wrapLines,
              isSelected: _wrap,
              onPressed: () => setState(() => _wrap = !_wrap),
              icon: Icon(Icons.wrap_text, color: _wrap ? p.brandText : p.secondary),
            ),
          if (textShown)
            IconButton(
              tooltip: l.copyContents,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _slice!.text));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
              },
              icon: Icon(Icons.copy_rounded, size: 20, color: p.secondary),
            ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Breadcrumb(segments: segs, depth: widget.depth, isFile: true),
        ),
      ),
      body: Column(
        children: [
          _header(context, l),
          Expanded(child: _body(context, l)),
        ],
      ),
    );
  }

  /// Kind icon, meta ("TypeScript · 120 lines · 4.2 KB"), change tag, and the
  /// Preview / Code switch for Markdown.
  Widget _header(BuildContext context, AppLocalizations l) {
    final p = context.pal;
    final code = widget.changes.of(widget.path);
    final meta = _meta(l);
    final md = _kind.preview == FilePreview.markdown && _lines != null && _problem == null;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          Icon(_kind.icon, size: 16, color: p.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
          ),
          if (code != null) ...[const SizedBox(width: 8), ChangeTag(code)],
          if (md) ...[
            const SizedBox(width: 10),
            _MiniToggle(
              items: [(true, l.filePreview), (false, l.fileSource)],
              value: _preview,
              onChanged: (v) => setState(() => _preview = v),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l) {
    final p = context.pal;
    if (_error != null) {
      return StateView(
        icon: Icons.cloud_off,
        title: workspaceError(l, _error!),
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    }
    final size = _size == null ? null : formatBytes(_size);
    switch (_problem) {
      case _Problem.missing:
        return StateView(icon: Icons.search_off, title: l.fileMissing);
      case _Problem.folder:
        return StateView(icon: Icons.folder_outlined, title: l.pathIsFolder);
      case _Problem.binary:
        return StateView(icon: _kind.icon, title: l.binaryFile, body: size);
      case _Problem.tooLarge:
        return StateView(icon: _kind.icon, title: l.previewTooLarge(size ?? '> 8 MB'));
      case _Problem.oldDaemon:
        return StateView(icon: _kind.icon, title: l.previewNeedsUpdate);
      case _Problem.failed:
        return StateView(icon: _kind.icon, title: l.previewFailed, actionLabel: l.tryAgain, onAction: _load);
      case null:
    }
    final bytes = _bytes;
    if (bytes != null && _kind.preview == FilePreview.image) return _image(context, l, bytes);
    if (bytes != null && _kind.preview == FilePreview.pdf) return _pdf(context, l, bytes);
    final lines = _lines;
    final f = _slice;
    if (lines == null || f == null) return const Center(child: CircularProgressIndicator());
    if (lines.isEmpty) return StateView(icon: _kind.icon, title: l.fileEmpty);
    final more = f.truncated && f.nextOffset != null ? _moreRow(context, l) : null;
    if (_preview) {
      return SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
          children: [
            MarkdownBody(
              data: f.text,
              styleSheet: _markdownStyle(context),
              onTapLink: (text, href, title) => _openLink(href),
              imageBuilder: (uri, title, alt) => _markdownImage(context, uri, alt),
            ),
            ?more,
          ],
        ),
      );
    }
    return ColoredBox(
      color: p.surface,
      child: CodeLines(lines: lines, wrap: _wrap, footer: more),
    );
  }

  Widget _moreRow(BuildContext context, AppLocalizations l) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(l.fileTruncated, style: TextStyle(fontSize: 13, color: p.secondary)),
          ),
          _loadingMore
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : TextButton(onPressed: _loadMore, child: Text(l.loadMore)),
        ],
      ),
    );
  }

  Widget _image(BuildContext context, AppLocalizations l, Uint8List bytes) {
    final p = context.pal;
    return ColoredBox(
      color: p.sunken,
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 8,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              semanticLabel: _name,
              errorBuilder: (_, _, _) => StateView(icon: _kind.icon, title: l.previewFailed),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pdf(BuildContext context, AppLocalizations l, Uint8List bytes) {
    final p = context.pal;
    return PdfViewer.data(
      bytes,
      sourceName: 'workspace:${widget.ws.agentId}:${widget.ws.sessionId}:${widget.path}',
      params: PdfViewerParams(
        backgroundColor: p.sunken,
        margin: 12,
        pageDropShadow: BoxShadow(color: p.shadow, blurRadius: 6, offset: const Offset(0, 2)),
        onViewerReady: (doc, _) {
          if (mounted) setState(() => _pages = doc.pages.length);
        },
        errorBannerBuilder: (_, _, _, _) => StateView(icon: _kind.icon, title: l.previewFailed),
      ),
    );
  }

  Future<void> _openLink(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'mailto')) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    final target = resolveRelative(widget.path, href);
    if (target == null || !mounted) return;
    push(context, FileViewScreen(ws: widget.ws, path: target, changes: widget.changes));
  }

  Widget _markdownImage(BuildContext context, Uri uri, String? alt) {
    final p = context.pal;
    final fallback = Text(
      alt ?? '',
      style: TextStyle(color: p.tertiary, fontStyle: FontStyle.italic),
    );
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Image.network(uri.toString(), errorBuilder: (_, _, _) => fallback);
    }
    final target = resolveRelative(widget.path, uri.toString());
    if (target == null || FileKind.of(target).preview != FilePreview.image) return fallback;
    return _WorkspaceImage(ws: widget.ws, path: target, fallback: fallback);
  }

  MarkdownStyleSheet _markdownStyle(BuildContext context) {
    final p = context.pal;
    final body = TextStyle(fontSize: 15, height: 1.55, color: p.ink);
    final code = mono(context, size: 13, color: p.ink);
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: body,
      a: TextStyle(color: p.link),
      h1: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.3),
      h2: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3),
      h3: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.35),
      h4: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      h1Padding: const EdgeInsets.only(top: 4, bottom: 4),
      h2Padding: const EdgeInsets.only(top: 12, bottom: 2),
      h3Padding: const EdgeInsets.only(top: 10),
      listBullet: body,
      blockSpacing: 12,
      code: code.copyWith(backgroundColor: p.sunken, fontSize: 13.5),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: p.sunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.hairline),
      ),
      blockquote: TextStyle(fontSize: 15, height: 1.55, color: p.secondary),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.borderStrong, width: 3)),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      tableHead: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      tableBody: TextStyle(fontSize: 14, color: p.ink),
      tableBorder: TableBorder.all(color: p.border),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    );
  }
}

/// An image a Markdown file links by relative path, read from the workspace.
class _WorkspaceImage extends StatefulWidget {
  const _WorkspaceImage({required this.ws, required this.path, required this.fallback});
  final WorkspaceRef ws;
  final String path;
  final Widget fallback;
  @override
  State<_WorkspaceImage> createState() => _WorkspaceImageState();
}

class _WorkspaceImageState extends State<_WorkspaceImage> {
  Future<Uint8List>? _bytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bytes != null) return;
    final app = AppScope.read(context);
    _bytes = withSession(
      (sid) => app.client.fileBytes(app.current!.orgId, widget.ws.agentId, widget.path, sessionId: sid),
      widget.ws.sessionId,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snap) {
      if (snap.hasError) return widget.fallback;
      final b = snap.data;
      if (b == null) {
        return const SizedBox(
          height: 48,
          child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        );
      }
      return Image.memory(b, errorBuilder: (_, _, _) => widget.fallback);
    },
  );
}

/// Two-option switch sized for a header row (Preview / Code).
class _MiniToggle<T> extends StatelessWidget {
  const _MiniToggle({required this.items, required this.value, required this.onChanged});
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.sunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label) in items)
            Semantics(
              selected: v == value,
              button: true,
              child: GestureDetector(
                onTap: () => onChanged(v),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 28, minWidth: 56),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: v == value ? p.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: v == value
                        ? [BoxShadow(color: p.shadow, blurRadius: 2, offset: const Offset(0, 1))]
                        : null,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: v == value ? FontWeight.w600 : FontWeight.w500,
                      color: v == value ? p.ink : p.secondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
