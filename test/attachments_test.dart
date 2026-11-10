import 'dart:convert';
import 'dart:typed_data';

import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/webchat/attachments.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('files marker', () {
    test('splits the marker off the end', () {
      final (text, files) = splitFilesMarker('see these\n[attached: a.pdf (application/pdf), b c.txt (text/plain)]');
      expect(text, 'see these');
      expect(files, [const MarkedFile('a.pdf', 'application/pdf'), const MarkedFile('b c.txt', 'text/plain')]);
    });

    test('a marker alone', () {
      final (text, files) = splitFilesMarker('[attached: x.zip (application/zip)]');
      expect(text, '');
      expect(files.single.name, 'x.zip');
    });

    test('file names with brackets', () {
      final (text, files) =
          splitFilesMarker('hi\n[attached: [Tag][Some.Show].S01.torrent (application/x-bittorrent)]');
      expect(text, 'hi');
      expect(files.single.name, '[Tag][Some.Show].S01.torrent');
      expect(files.single.mimeType, 'application/x-bittorrent');
    });

    test('names with parentheses and commas', () {
      final (_, files) = splitFilesMarker('[attached: a (1), final.pdf (application/pdf), b.png (image/png)]');
      expect(files.map((f) => f.name), ['a (1), final.pdf', 'b.png']);
    });

    test('an entry that does not parse leaves the text whole', () {
      const t = 'x\n[attached: no type here]';
      final (text, files) = splitFilesMarker(t);
      expect(text, t);
      expect(files, isEmpty);
    });

    test('a marker not at the end is text', () {
      const t = '[attached: a.pdf (application/pdf)]\nmore';
      expect(splitFilesMarker(t).$2, isEmpty);
    });

    test('round trip', () {
      const files = [MarkedFile('[a].txt', 'text/plain'), MarkedFile('b.pdf', 'application/pdf')];
      expect(splitFilesMarker('t\n${filesMarker(files)}').$2, files);
    });
  });

  test('names and types the transfer store accepts', () {
    expect(sanitizeFileName('a/b\\c\u0001.txt'), 'a_b_c_.txt');
    expect(sanitizeFileName('  '), 'file');
    expect(sanitizeMime('image/png'), 'image/png');
    expect(sanitizeMime(''), 'application/octet-stream');
    expect(sanitizeMime(null), 'application/octet-stream');
    expect(mimeFromName('Report.PDF'), 'application/pdf');
    expect(mimeFromName('noext'), 'application/octet-stream');
  });

  test('base64 sha256', () {
    expect(sha256Base64(Uint8List.fromList(utf8.encode('abc'))), 'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=');
  });

  test('shrinks an image under the budget', () async {
    final big = img.Image(width: 2400, height: 1800);
    for (final px in big) {
      px
        ..r = (px.x * 7 + px.y * 13) % 256
        ..g = (px.x * 3) % 256
        ..b = (px.y * 5) % 256;
    }
    final png = Uint8List.fromList(img.encodePng(big));
    final a = await shrinkImage(png, 'photo.png', maxBytes: filePreviewMaxBytes, maxEdge: 512);
    expect(a, isNotNull);
    expect(a!.mimeType, 'image/jpeg');
    expect(a.name, 'photo.jpg');
    expect(a.bytes!.length, lessThanOrEqualTo(filePreviewMaxBytes));
    final back = img.decodeJpg(a.bytes!)!;
    expect(back.width, lessThanOrEqualTo(512));
    expect(await shrinkImage(Uint8List.fromList([1, 2, 3]), 'x.png'), isNull);
  });

  test('uploaded file and image wire shapes', () {
    const prev = ImageAttachment(name: 'a.jpg', mimeType: 'image/jpeg', data: 'AAAA');
    final f = const UploadedFile(
            uploadId: 'u', name: 'a.png', mimeType: 'image/png', size: 3, sha256: 's', preview: prev)
        .toJson();
    expect(f, {
      'uploadId': 'u',
      'name': 'a.png',
      'mimeType': 'image/png',
      'size': 3,
      'sha256': 's',
      'preview': {'name': 'a.jpg', 'mimeType': 'image/jpeg', 'data': 'AAAA'},
    });
  });

  test('attach policy from continuationAttachments', () {
    expect(AttachPolicy.fromWire('images'), AttachPolicy.images);
    expect(AttachPolicy.fromWire('images_and_files'), AttachPolicy.imagesAndFiles);
    expect(AttachPolicy.fromWire(null), AttachPolicy.none);
  });

  test('file transfer config and upload grant', () {
    expect(FileTransferConfig.fromJson(null), isNull);
    final c = FileTransferConfig.fromJson({'maxBytes': 100, 'partBytes': 40})!;
    expect(c.singlePutMax, 40);
    expect(FileTransferConfig.fromJson({'maxBytes': 100})!.singlePutMax, 100);
    final g = UploadGrant.fromJson({
      'uploadId': 'u',
      'expiresAt': '2026-01-01T00:00:00Z',
      'url': 'https://store.example.test/x',
      'headers': {'x-amz-checksum-sha256': 'h', 'content-length': '3'},
    });
    expect(g.headers['x-amz-checksum-sha256'], 'h');
    expect(() => UploadGrant.fromJson({'uploadId': 'u', 'multipart': {}}), throwsFormatException);
  });

  test('frames: ready features and post images', () {
    final r = decodeFrame('{"type":"ready","conversationId":"c","features":["webchat-upload-previews-v1"]}')
        as ReadyFrame;
    expect(r.features, contains(uploadPreviewsFeature));
    final p = decodeFrame(jsonEncode({
      'type': 'post',
      'post': {
        'postId': 'p',
        'text': 'here',
        'author': {'kind': 'agent', 'agentId': 'a'},
        'attachments': [
          {'name': 'a.png', 'mimeType': 'image/png', 'data': 'AAAA'}
        ],
        'image': {
          'attachment': {'name': 'chart.webp', 'mimeType': 'image/webp', 'data': 'BBBB'},
          'original': {'kind': 'inline'},
          'revision': 0
        },
      }
    })) as PostFrame;
    expect(p.images.map((i) => i.name), ['a.png', 'chart.webp']);
  });

  test('transcript rows carry images and the files marker', () {
    final items = buildTranscript([
      ApiMessage.fromJson({
        'seq': 1,
        'sender': 'me',
        'kind': 'text',
        'text': 'look\n[attached: r.pdf (application/pdf)]',
        'attachments': [
          {'name': 'a.png', 'mimeType': 'image/png', 'data': 'AAAA'}
        ],
      }),
      ApiMessage.fromJson({
        'seq': 2,
        'sender': 'agent',
        'kind': 'text',
        'text': 'made this',
        'sharedImage': {
          'attachment': {'name': 'c.png', 'mimeType': 'image/png', 'data': 'CCCC'},
          'original': {'kind': 'inline'},
          'revision': 0
        },
      }),
    ], {'agent'});
    expect(items[0].text, 'look');
    expect(items[0].files.single.name, 'r.pdf');
    expect(items[0].images.single.name, 'a.png');
    expect(items[1].images.single.name, 'c.png');
  });

  test('daemon features', () {
    final m = Machine.fromJson({
      'daemonId': 'd',
      'capabilities': {
        'features': ['file-transfer-v2', 'webchat-upload-previews-v1']
      }
    });
    expect(m.features, containsAll([fileTransferFeature, uploadPreviewsFeature]));
  });
}
