import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/webchat/attachments.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../files/file_kind.dart';

const attachmentCardSize = 104.0;

/// A message's attachments as same-size cards: image thumbnails (tap for the
/// full-screen viewer) and file cards (name and type; the app can't fetch an
/// uploaded file back, as the console can't either).
class AttachmentCards extends StatelessWidget {
  const AttachmentCards({super.key, required this.images, required this.files, this.alignEnd = false});
  final List<ImageAttachment> images;
  final List<MarkedFile> files;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty && files.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < images.length; i++)
            ImageCard(
              bytes: images[i].bytes,
              label: images[i].name,
              onTap: () => openImageViewer(context, images, i),
            ),
          for (final f in files) FileCard(name: f.name, mimeType: f.mimeType),
        ],
      ),
    );
  }
}

class ImageCard extends StatelessWidget {
  const ImageCard({super.key, required this.bytes, required this.label, this.onTap, this.overlay});
  final Uint8List? bytes;
  final String label;
  final VoidCallback? onTap;
  final Widget? overlay;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final b = bytes;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      image: true,
      label: label,
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: attachmentCardSize,
          height: attachmentCardSize,
          decoration: BoxDecoration(
            color: p.sunken,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(fit: StackFit.expand, children: [
            if (b != null)
              Image.memory(b,
                  fit: BoxFit.cover,
                  cacheWidth: (attachmentCardSize * dpr).round(),
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: p.tertiary))
            else
              Icon(Icons.image_outlined, color: p.tertiary),
            ?overlay,
          ]),
        ),
      ),
    );
  }
}

class FileCard extends StatelessWidget {
  const FileCard({super.key, required this.name, required this.mimeType, this.sizeText, this.overlay});
  final String name;
  final String mimeType;
  final String? sizeText;
  final Widget? overlay;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final kind = FileKind.of(name);
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 8 ? name.substring(dot + 1).toUpperCase() : '';
    return Semantics(
      label: name,
      child: Container(
        width: attachmentCardSize,
        height: attachmentCardSize,
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(kind.icon, size: 22, color: p.secondary),
              const Spacer(),
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.ink, height: 1.2)),
              const SizedBox(height: 2),
              Text(
                [if (ext.isNotEmpty) ext else mimeType.split('/').last, ?sizeText].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(context, size: 10),
              ),
            ]),
          ),
          ?overlay,
        ]),
      ),
    );
  }
}

/// Full-screen, zoomable images; swipe between a message's images.
Future<void> openImageViewer(BuildContext context, List<ImageAttachment> images, int index) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ImageViewer(images: images, index: index),
    ));

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.images, required this.index});
  final List<ImageAttachment> images;
  final int index;
  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final _pages = PageController(initialPage: widget.index);
  late int _at = widget.index;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final imgs = widget.images;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(imgs[_at].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
        leading: IconButton(
          tooltip: l.close,
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: imgs.length,
        onPageChanged: (i) => setState(() => _at = i),
        itemBuilder: (_, i) {
          final b = imgs[i].bytes;
          return InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: b == null
                  ? const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48)
                  : Image.memory(b,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48)),
            ),
          );
        },
      ),
    );
  }
}

/// Bytes of a picked file waiting to be sent: shown in the composer's tray.
String fileSizeText(int size) => formatBytes(size);
