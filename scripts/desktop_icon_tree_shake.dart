// Copyright (C) 2026 Carinoasd. MIT License.
//
// Make release builds for Windows and Linux tree shake icon fonts, and check that they did.
//
// Flutter's desktop build backend (`packages/flutter_tools/bin/tool_backend.dart`, run by the generated CMake files)
// passes `-dTreeShakeIcons="$treeShakeIcons"` through `Process.start`. No shell strips those quotes, so the
// define arrives as `"true"`, the icon tree shaker compares it with `true` and skips every icon font. Android, iOS
// and macOS go through other backends and are not affected. Fixed upstream in flutter/flutter#184249, first
// shipped in Flutter 3.47.0; this script can be dropped once CI_FLUTTER_VERSION is at least that.
//
// Usage:
//   dart scripts/desktop_icon_tree_shake.dart patch
//     Remove the quotes in the Flutter SDK on PATH. Fails when the line looks like neither the broken nor the
//     fixed form, so a Flutter update cannot silently turn this into a no-op.
//   dart scripts/desktop_icon_tree_shake.dart check <bundle directory>
//     Fail when a Material icon font in the built bundle is missing or still full size.
import 'dart:convert';
import 'dart:io';

const _broken = r"""'-dTreeShakeIcons="$treeShakeIcons"',""";
const _fixed = r"""'-dTreeShakeIcons=$treeShakeIcons',""";

/// Fonts that shrink to a few dozen KB when tree shaken (full copies are 1.6 MB to 15 MB).
///
/// The other bundled icon fonts are listed for reference only: even on Android, where tree shaking works, the
/// Font Awesome regular face keeps its full 85 KB and the MDI font stays near 1 MB.
const int _maxShakenBytes = 512 * 1024;
const _mustShrink = <String>[
  'MaterialIcons-Regular.otf',
  'MaterialSymbolsOutlined.ttf',
  'MaterialSymbolsRounded.ttf',
  'MaterialSymbolsSharp.ttf',
];
const _reportOnly = <String>[
  'materialdesignicons-webfont.ttf',
  'Font-Awesome-7-Brands-Regular-400.otf',
  'Font-Awesome-7-Free-Regular-400.otf',
  'Font-Awesome-7-Free-Solid-900.otf',
];

Future<void> main(List<String> args) async {
  switch (args) {
    case ['patch']:
      await _patch();
    case ['check', final String bundle]:
      _check(bundle);
    default:
      stderr.writeln('usage: dart scripts/desktop_icon_tree_shake.dart patch | check <bundle directory>');
      exitCode = 2;
      return;
  }
}

Future<void> _patch() async {
  final flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final result = await Process.run(flutter, ['--version', '--machine'], runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    stderr.writeln('flutter --version --machine failed: ${result.stderr}');
    exitCode = 1;
    return;
  }
  final stdoutText = result.stdout as String;
  final info = jsonDecode(stdoutText.substring(stdoutText.indexOf('{'))) as Map<String, dynamic>;
  final root = info['flutterRoot'] as String;
  final version = info['frameworkVersion'] as String;
  final file = File([root, 'packages', 'flutter_tools', 'bin', 'tool_backend.dart'].join(Platform.pathSeparator));
  final source = file.readAsStringSync();
  final broken = _broken.allMatches(source).length;
  final fixed = _fixed.allMatches(source).length;
  if (broken == 1 && fixed == 0) {
    file.writeAsStringSync(source.replaceFirst(_broken, _fixed));
    stdout.writeln('Flutter $version: unquoted TreeShakeIcons define in ${file.path}');
  } else if (broken == 0 && fixed == 1) {
    stdout.writeln('Flutter $version: TreeShakeIcons define is already unquoted in ${file.path}');
  } else {
    stderr.writeln(
      'Flutter $version: expected exactly one TreeShakeIcons define in ${file.path} '
      '(found $broken quoted, $fixed unquoted); update scripts/desktop_icon_tree_shake.dart',
    );
    exitCode = 1;
    return;
  }
}

void _check(String bundle) {
  final dir = Directory(bundle);
  if (!dir.existsSync()) {
    stderr.writeln('$bundle does not exist');
    exitCode = 1;
    return;
  }
  final fonts = {
    for (final f in dir.listSync(recursive: true).whereType<File>())
      if (_mustShrink.contains(f.uri.pathSegments.last) || _reportOnly.contains(f.uri.pathSegments.last))
        f.uri.pathSegments.last: f,
  };
  var failed = false;
  for (final name in _mustShrink) {
    final font = fonts[name];
    if (font == null) {
      stderr.writeln('MISSING $name');
      failed = true;
      continue;
    }
    final size = font.lengthSync();
    final ok = size <= _maxShakenBytes;
    failed |= !ok;
    stdout.writeln('${ok ? 'ok  ' : 'FULL'} ${size.toString().padLeft(9)}  ${font.path}');
  }
  for (final name in _reportOnly) {
    final font = fonts[name];
    if (font != null) {
      stdout.writeln('     ${font.lengthSync().toString().padLeft(9)}  ${font.path}');
    }
  }
  if (failed) {
    stderr.writeln('icon fonts were not tree shaken');
    exitCode = 1;
    return;
  }
}
