import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/workspace.dart';
import 'package:agentconnect/features/files/code_view.dart';
import 'package:agentconnect/features/files/file_kind.dart';
import 'package:agentconnect/features/files/workspace_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file kinds pick the preview from the name', () {
    expect(FileKind.of('src/app.ts').preview, FilePreview.code);
    expect(FileKind.of('src/app.ts').language, 'typescript');
    expect(FileKind.of('lib/main.dart').language, 'dart');
    expect(FileKind.of('Dockerfile').language, 'dockerfile');
    expect(FileKind.of('README.md').preview, FilePreview.markdown);
    expect(FileKind.of('shot.PNG').preview, FilePreview.image);
    expect(FileKind.of('docs/spec.pdf').preview, FilePreview.pdf);
    expect(FileKind.of('docs/spec.pdf').usesBytes, isTrue);
    expect(FileKind.of('build.log').preview, FilePreview.text);
    expect(FileKind.of('LICENSE').preview, FilePreview.text);
    expect(FileKind.of('LICENSE').language, isNull);
    expect(FileKind.of('dist.zip').preview, FilePreview.binary);
  });

  test('sizes read like the console', () {
    expect(formatBytes(812), '812 B');
    expect(formatBytes(2150), '2.1 KB');
    expect(formatBytes(1536 * 1024), '1.5 MB');
    expect(formatBytes(null), '');
  });

  test('markdown links resolve inside the workspace only', () {
    expect(resolveRelative('docs/guide/README.md', 'intro.md'), 'docs/guide/intro.md');
    expect(resolveRelative('docs/guide/README.md', '../api.md#auth'), 'docs/api.md');
    expect(resolveRelative('README.md', './img/a%20b.png'), 'img/a b.png');
    expect(resolveRelative('README.md', '../outside.md'), isNull);
    expect(resolveRelative('README.md', 'https://example.test/x'), isNull);
    expect(resolveRelative('README.md', '#section'), isNull);
  });

  test('breadcrumb pops back only to screens on the stack', () {
    // Files tab → src → src/lib (depth 2).
    const folder = Breadcrumb(segments: ['src', 'lib'], depth: 2);
    expect(folder.popsTo(0), 2);
    expect(folder.popsTo(1), 1);
    expect(folder.popsTo(2), isNull);
    // A file opened from the Files tab directly (no folder screens).
    const rootFile = Breadcrumb(segments: ['README.md'], depth: 0, isFile: true);
    expect(rootFile.popsTo(0), 1);
    // src/lib/a.ts opened from the src/lib screen (depth 2).
    const file = Breadcrumb(segments: ['src', 'lib', 'a.ts'], depth: 2, isFile: true);
    expect(file.popsTo(0), 3);
    expect(file.popsTo(1), 2);
    expect(file.popsTo(2), 1);
    // A file opened from the Git tab: only the root is behind it.
    const fromGit = Breadcrumb(segments: ['src', 'lib', 'a.ts'], depth: 0, isFile: true);
    expect(fromGit.popsTo(0), 1);
    expect(fromGit.popsTo(1), isNull);
    // Unknown stack (a Markdown link): nothing to pop to.
    expect(const Breadcrumb(segments: ['a.md'], depth: null, isFile: true).popsTo(0), isNull);
  });

  test('tokenizer splits highlighted code into lines', () {
    final lines = tokenize('const a = 1;\n// note\nreturn "x";\n', 'typescript');
    expect(lines, hasLength(3));
    expect(lines[0].map((t) => t.$1).join(), 'const a = 1;');
    expect(lines[0].first, ('const', 'keyword'));
    expect(lines[1].single, ('// note', 'comment'));
    expect(lines[2].any((t) => t.$2 == 'string'), isTrue);
  });

  test('a multi-line token is cut at each newline', () {
    final lines = tokenize('/* a\nb */\nx', 'javascript');
    expect(lines, hasLength(3));
    expect(lines[0].single, ('/* a', 'comment'));
    expect(lines[1].single, ('b */', 'comment'));
  });

  test('unknown language gives plain lines', () {
    expect(tokenize('a\r\nb', 'no-such-lang'), [
      [('a', null)],
      [('b', null)],
    ]);
  });

  test('file slices page and changes tag paths', () {
    final first = FileSlice.fromJson({
      'exists': true,
      'type': 'file',
      'encoding': 'utf8',
      'content': 'a\n',
      'size': 4,
      'truncated': true,
      'nextOffset': 2,
    });
    expect(first.nextOffset, 2);
    final all = first.append(FileSlice.fromJson({'exists': true, 'content': 'b\n', 'truncated': false}));
    expect(all.text, 'a\nb\n');
    expect(all.truncated, isFalse);
    expect(all.nextOffset, isNull);
    expect(FileSlice.fromJson({'exists': true, 'type': 'dir'}).isDir, isTrue);

    final changes = Changes.of(GitStatus.fromJson({
      'isRepo': true,
      'files': [
        {'path': 'src/a.ts', 'index': ' ', 'workingDir': 'M'},
        {'path': 'new.md', 'index': '?', 'workingDir': '?'},
      ],
    }));
    expect(changes.of('src/a.ts'), 'M');
    expect(changes.of('new.md'), 'A');
    expect(changes.inside('src'), isTrue);
    expect(changes.inside('sr'), isFalse);
  });

  test('a missing file stays missing in its session; an unreadable session falls back', () async {
    final asked = <String?>[];
    Future<String> read(String? sid, ApiException error) async {
      asked.add(sid);
      if (sid != null) throw error;
      return 'checkout';
    }

    await expectLater(
      withSession((sid) => read(sid, ApiException(404, 'WORKSPACE_FILE_NOT_FOUND')), 's1'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'WORKSPACE_FILE_NOT_FOUND')),
    );
    expect(asked, ['s1']);

    asked.clear();
    expect(await withSession((sid) => read(sid, ApiException(404, null, 'session not found')), 's1'), 'checkout');
    expect(asked, ['s1', null]);

    asked.clear();
    expect(await withSession((sid) => read(sid, ApiException(404, 'WORKSPACE_NOT_FOUND')), 's1'), 'checkout');
    expect(asked, ['s1', null]);
  });
}
