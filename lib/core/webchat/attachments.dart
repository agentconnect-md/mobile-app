import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../api/models.dart';

/// At most this many images and files per message (`MESSAGE_ATTACHMENTS_MAX`).
const messageAttachmentsMax = 10;

/// Decoded bytes of every inline image plus every file preview of one
/// message (`WEBCHAT_IMAGE_MAX_BYTES`, the relay's budget).
const webchatImageMaxBytes = 160 * 1024;

/// One file's preview: the budget shared by the most files a message holds.
const filePreviewMaxBytes = webchatImageMaxBytes ~/ messageAttachmentsMax;

/// The relay forwards uploaded files with previews (`ready.features`).
const uploadPreviewsFeature = 'webchat-upload-previews-v1';

/// A daemon that fetches uploaded files (`capabilities.features`).
const fileTransferFeature = 'file-transfer-v2';

const inlineImageTypes = {'image/png', 'image/jpeg', 'image/webp'};

/// `WebchatImageAttachment`: an image carried in the message itself.
class ImageAttachment {
  const ImageAttachment({required this.name, required this.mimeType, required this.data});
  final String name;
  final String mimeType;

  /// Base64, no `data:` prefix.
  final String data;

  Uint8List? get bytes {
    try {
      return base64Decode(data);
    } catch (_) {
      return null;
    }
  }

  int get byteLength => (data.length * 3) ~/ 4 - (data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0);

  Map<String, Object?> toJson() => {'name': name, 'mimeType': mimeType, 'data': data};

  static ImageAttachment? fromJson(dynamic j) {
    final m = asMap(j);
    final name = asStr(m['name']);
    final mime = asStr(m['mimeType']);
    final data = asStr(m['data']);
    if (name == null || mime == null || data == null || !mime.startsWith('image/')) return null;
    return ImageAttachment(name: name, mimeType: mime, data: data);
  }

  static List<ImageAttachment> listFrom(dynamic j) =>
      asList(j).map(ImageAttachment.fromJson).whereType<ImageAttachment>().toList();
}

/// `WebchatFileAttachment`: a file uploaded to the transfer store before the
/// turn, named on the turn by its upload id.
class UploadedFile {
  const UploadedFile({
    required this.uploadId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.sha256,
    this.preview,
  });
  final String uploadId;
  final String name;
  final String mimeType;
  final int size;

  /// Base64 SHA-256 of the whole file.
  final String sha256;
  final ImageAttachment? preview;

  Map<String, Object?> toJson() => {
        'uploadId': uploadId,
        'name': name,
        'mimeType': mimeType,
        'size': size,
        'sha256': sha256,
        if (preview != null) 'preview': preview!.toJson(),
      };
}

/// A file named in a message's `[attached: …]` marker (no bytes to fetch).
class MarkedFile {
  const MarkedFile(this.name, this.mimeType);
  final String name;
  final String mimeType;
  @override
  bool operator ==(Object other) => other is MarkedFile && other.name == name && other.mimeType == mimeType;
  @override
  int get hashCode => Object.hash(name, mimeType);
}

/// The marker a turn with files ends with: `[attached: a.pdf (application/pdf), …]`.
String filesMarker(Iterable<MarkedFile> files) =>
    '[attached: ${files.map((f) => '${f.name} (${f.mimeType})').join(', ')}]';

final _markerRe = RegExp(r'(?:^|\n)\[attached: ([^\n]+)\]$');
final _entryRe = RegExp(r'(.+?) \(([A-Za-z0-9][\w.+-]*/[A-Za-z0-9][\w.+-]*)\)(?:, |$)');

/// Splits the `[attached: …]` marker off the end of [text]. Names may hold
/// brackets (`[Tag][Show].S01.torrent`). When any entry doesn't parse, the
/// text is left whole and no files are returned (as the console does).
(String, List<MarkedFile>) splitFilesMarker(String text) {
  final m = _markerRe.firstMatch(text);
  if (m == null) return (text, const []);
  final list = m.group(1)!;
  final files = <MarkedFile>[];
  var at = 0;
  while (at < list.length) {
    final e = _entryRe.matchAsPrefix(list, at);
    if (e == null || e.end == at) return (text, const []);
    files.add(MarkedFile(e.group(1)!, e.group(2)!));
    at = e.end;
  }
  if (files.isEmpty) return (text, const []);
  return (text.substring(0, m.start).trimRight(), files);
}

/// A file name the transfer store accepts: no control characters or slashes.
String sanitizeFileName(String name) {
  var s = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f/\\]'), '_').trim();
  if (s.isEmpty) s = 'file';
  if (s.length > 255) {
    final dot = s.lastIndexOf('.');
    final ext = dot > 0 && s.length - dot <= 16 ? s.substring(dot) : '';
    s = s.substring(0, 255 - ext.length) + ext;
  }
  return s;
}

final _mimeRe = RegExp(r'^[A-Za-z0-9][\w.+-]*/[A-Za-z0-9][\w.+-]*$');

/// A MIME type the transfer store accepts, else `application/octet-stream`.
String sanitizeMime(String? mime) =>
    mime != null && mime.length <= 255 && _mimeRe.hasMatch(mime) ? mime : 'application/octet-stream';

const _mimeByExt = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'xml': 'application/xml',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  'html': 'text/html',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
};

/// MIME type from a file name (pickers rarely give one).
String mimeFromName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  return _mimeByExt[ext] ?? 'application/octet-stream';
}

/// Base64 SHA-256, as the transfer store checks it.
String sha256Base64(Uint8List bytes) => base64Encode(sha256.convert(bytes).bytes);

class _ShrinkArgs {
  const _ShrinkArgs(this.bytes, this.maxBytes, this.maxEdge);
  final Uint8List bytes;
  final int maxBytes;
  final int maxEdge;
}

Uint8List? _shrink(_ShrinkArgs a) {
  final src = img.decodeImage(a.bytes);
  if (src == null) return null;
  var image = img.bakeOrientation(src);
  var edge = image.width > image.height ? image.width : image.height;
  if (edge > a.maxEdge) {
    image = image.width >= image.height
        ? img.copyResize(image, width: a.maxEdge, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: a.maxEdge, interpolation: img.Interpolation.average);
    edge = a.maxEdge;
  }
  // Quality first, then size, as the console steps down (10 tries at most).
  var quality = 86;
  for (var i = 0; i < 10; i++) {
    final out = img.encodeJpg(image, quality: quality);
    if (out.length <= a.maxBytes) return out;
    if (quality > 50) {
      quality = (quality - 12).clamp(50, 86);
    } else {
      edge = (edge * 0.75).round();
      if (edge < 32) return null;
      image = image.width >= image.height
          ? img.copyResize(image, width: edge, interpolation: img.Interpolation.average)
          : img.copyResize(image, height: edge, interpolation: img.Interpolation.average);
    }
  }
  return null;
}

/// Re-encodes an image as a JPEG of at most [maxBytes] (long edge at most
/// [maxEdge]), off the UI isolate. Null when it can't be decoded or shrunk.
Future<ImageAttachment?> shrinkImage(Uint8List bytes, String name,
    {int maxBytes = webchatImageMaxBytes, int maxEdge = 1600}) async {
  final out = await compute(_shrink, _ShrinkArgs(bytes, maxBytes, maxEdge));
  if (out == null) return null;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return ImageAttachment(name: sanitizeFileName('$stem.jpg'), mimeType: 'image/jpeg', data: base64Encode(out));
}

/// Files a session continuation takes (`continuationAttachments`).
enum AttachPolicy {
  /// Nothing: no attach button.
  none,

  /// Images only (a continued Slack thread and other mirrored sessions).
  images,

  /// Images and files (web chats, tasks, hook sessions).
  imagesAndFiles;

  static AttachPolicy fromWire(dynamic v) => switch (v) {
        'images' => AttachPolicy.images,
        'images_and_files' => AttachPolicy.imagesAndFiles,
        _ => AttachPolicy.none,
      };
}
