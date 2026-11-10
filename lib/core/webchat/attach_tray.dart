import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import 'attachments.dart';

enum PendingState { preparing, uploading, ready, failed }

/// Why a picked file can't be sent (shown under its card).
enum PendingError { unreadableImage, tooLarge, uploadsUnavailable, daemonTooOld, network, failed }

/// One file picked for the next message. Its bytes stay in memory until it is
/// sent or removed; nothing is written to disk or logged.
class PendingAttachment {
  PendingAttachment._(this.id, this.name, this.mimeType, this._bytes)
      : size = _bytes!.length,
        isImage = mimeType.startsWith('image/');
  final int id;
  final String name;
  final String mimeType;
  final int size;
  final bool isImage;
  Uint8List? _bytes;
  PendingState state = PendingState.preparing;
  PendingError? error;

  /// The card's thumbnail (the inline image or the file's preview).
  Uint8List? thumb;
  ImageAttachment? inline;
  UploadedFile? uploaded;

  bool get canRetry => state == PendingState.failed && error != PendingError.tooLarge && _bytes != null;
}

/// The composer's picked files: prepares each (shrinks an inline image, or
/// uploads a file with its preview), one upload at a time, and hands the
/// ready ones to the send.
///
/// With [uploads] the message takes up to [messageAttachmentsMax] images and
/// files, all uploaded first. Without, it takes one image, sent inline.
class AttachTray extends ChangeNotifier {
  AttachTray({
    required this.client,
    required this.orgId,
    required this.agentId,
    required this.uploads,
    this.transfer,
  });
  final ApiClient client;
  final String orgId;
  final String agentId;
  final bool uploads;
  final FileTransferConfig? transfer;

  final List<PendingAttachment> items = [];
  int _ids = 0;
  bool _disposed = false;
  Future<void> _queue = Future.value();

  int get max => uploads ? messageAttachmentsMax : 1;
  int get room => max - items.length;
  bool get isEmpty => items.isEmpty;

  /// Nothing preparing, uploading or failed: the message can go.
  bool get ready => items.every((p) => p.state == PendingState.ready);

  /// Adds picked files, up to [room]. Returns how many were left out.
  int add(Iterable<(String name, Uint8List bytes, String? mime)> files) {
    var skipped = 0;
    for (final (name, bytes, mime) in files) {
      final type = sanitizeMime(mime ?? mimeFromName(name));
      if (room <= 0 || (!uploads && !type.startsWith('image/'))) {
        skipped++;
        continue;
      }
      final p = PendingAttachment._(_ids++, sanitizeFileName(name), type, bytes);
      items.add(p);
      _start(p);
    }
    _notify();
    return skipped;
  }

  void remove(PendingAttachment p) {
    items.remove(p);
    p._bytes = null;
    _notify();
  }

  void retry(PendingAttachment p) {
    if (!p.canRetry) return;
    p.state = PendingState.preparing;
    p.error = null;
    _start(p);
    _notify();
  }

  /// The ready attachments for the turn; empties the tray.
  (List<ImageAttachment>, List<UploadedFile>) take() {
    final images = [for (final p in items) ?p.inline];
    final files = [for (final p in items) ?p.uploaded];
    for (final p in items) {
      p._bytes = null;
    }
    items.clear();
    _notify();
    return (images, files);
  }

  void _start(PendingAttachment p) {
    if (uploads) {
      _queue = _queue.then((_) => _upload(p)).catchError((_) {});
    } else {
      _inline(p);
    }
  }

  Future<void> _inline(PendingAttachment p) async {
    final bytes = p._bytes;
    if (bytes == null) return;
    final img = await shrinkImage(bytes, p.name);
    if (!items.contains(p)) return;
    if (img == null) {
      _fail(p, PendingError.unreadableImage);
    } else {
      p.inline = img;
      p.thumb = img.bytes;
      p.state = PendingState.ready;
      // The original isn't needed once shrunk.
      p._bytes = null;
    }
    _notify();
  }

  Future<void> _upload(PendingAttachment p) async {
    final bytes = p._bytes;
    if (bytes == null || !items.contains(p)) return;
    final t = transfer;
    if (t != null && p.size > t.singlePutMax) {
      _fail(p, PendingError.tooLarge);
      p._bytes = null;
      _notify();
      return;
    }
    try {
      ImageAttachment? preview;
      if (p.isImage) {
        try {
          preview = await shrinkImage(bytes, p.name, maxBytes: filePreviewMaxBytes, maxEdge: 512);
        } catch (_) {}
        if (preview != null) p.thumb = preview.bytes;
      }
      if (!items.contains(p)) return;
      p.state = PendingState.uploading;
      _notify();
      final sha = sha256Base64(bytes);
      final grant = await client.reserveUpload(orgId, agentId,
          name: p.name, mimeType: p.mimeType, size: p.size, sha256: sha);
      if (!items.contains(p)) return;
      await client.putUpload(grant, bytes);
      if (!items.contains(p)) return;
      p.uploaded = UploadedFile(
        uploadId: grant.uploadId,
        name: p.name,
        mimeType: p.mimeType,
        size: p.size,
        sha256: sha,
        preview: preview,
      );
      p.state = PendingState.ready;
      p._bytes = null;
    } on ApiException catch (e) {
      _fail(
          p,
          switch (e.code) {
            'WORKSPACE_TOO_LARGE' => PendingError.tooLarge,
            'WORKSPACE_TRANSFER_UNAVAILABLE' => PendingError.uploadsUnavailable,
            'DAEMON_FEATURE_MISSING' => PendingError.daemonTooOld,
            _ => PendingError.failed,
          });
      if (p.error == PendingError.tooLarge) p._bytes = null;
    } on NetworkException {
      _fail(p, PendingError.network);
    } catch (_) {
      _fail(p, PendingError.failed);
    }
    _notify();
  }

  void _fail(PendingAttachment p, PendingError e) {
    p.state = PendingState.failed;
    p.error = e;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final p in items) {
      p._bytes = null;
    }
    items.clear();
    super.dispose();
  }
}
