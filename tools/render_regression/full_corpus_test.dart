/// The comparison of `test/regression/test_234_render_regression_test.dart` on a full corpus of the forum's threads,
/// which never goes into the repository (see README.md next to this file). Not a test of the repository: run it by
/// hand, locally.
///
/// ```sh
/// flutter test tools/render_regression/full_corpus_test.dart \
///   --dart-define=RENDER_CORPUS=<dir> --dart-define=RENDER_OUT=<dir> [--dart-define=RENDER_IMAGES=<images.json>]
/// ```
///
/// RENDER_CORPUS holds `threads/<tid>.json` (the app API's answer for the thread's first page); RENDER_OUT holds
/// `web/<tid>.json` (`node web_snapshot.mjs --corpus <corpus> --full --out <out>`) and gets `compare/<tid>.json` (the
/// differences of each floor: counts and an example of each kind) and `summary.json` (the counts of the whole corpus,
/// the floors with each kind, the floors with the most). RENDER_IMAGES: the size of the images of the posts
/// (`{"<url>": {"w": …, "h": …}}`), 1000 × 700 without it. RENDER_THREADS: only these threads (`tid,tid`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as hp;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

import '../../test/regression/render_regression/compare.dart';
import '../../test/regression/render_regression/dump.dart';
import '../../test/regression/render_regression/harness.dart';

const _corpus = String.fromEnvironment('RENDER_CORPUS');
const _out = String.fromEnvironment('RENDER_OUT');
const _images = String.fromEnvironment('RENDER_IMAGES');
const _threads = String.fromEnvironment('RENDER_THREADS');

/// The floor's `td.t_f` in the table holding it, as the web snapshot reads it.
String? _cellOf(String html, String pid) {
  final doc = hp.parse(html);
  final cell = doc.querySelector('td#postmessage_$pid') ?? doc.querySelector('td.t_f');
  var holder = cell?.parent;
  while (holder != null && holder.localName != 'table') {
    holder = holder.parent;
  }
  return holder == null ? cell?.outerHtml : '<div class="t_fsz">${holder.outerHtml}</div>';
}

void main() {
  if (_corpus.isEmpty || _out.isEmpty) {
    test('full corpus', () {}, skip: 'give RENDER_CORPUS and RENDER_OUT (see the documentation of this file)');
    return;
  }
  final images = _images.isEmpty
      ? const <String, dynamic>{}
      : jsonDecode(File(_images).readAsStringSync()) as Map<String, dynamic>;
  (int, int)? sizeOf(String url) {
    final info = (images[url] ?? images[url.replaceFirst(RegExp('^https?://[^/]+/'), '')]) as Map<String, dynamic>?;
    return info == null ? null : ((info['w'] as num).toInt(), (info['h'] as num).toInt());
  }

  final only = _threads.split(',').where((e) => e.isNotEmpty).toSet();
  final files = Directory('$_corpus/threads').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).where(
    (f) {
      final tid = f.uri.pathSegments.last.replaceAll('.json', '');
      return (only.isEmpty || only.contains(tid)) && File('$_out/web/$tid.json').existsSync();
    },
  ).toList()..sort((a, b) => a.path.compareTo(b.path));
  Directory('$_out/compare').createSync(recursive: true);
  final darkTheme = appTheme(dark: true);
  final darkInk = hexColor(darkTheme.colorScheme.onSurface);
  final darkSurface = hexColor(darkTheme.cardTheme.color ?? darkTheme.colorScheme.surfaceContainerLow);
  final all = <String, Map<String, int>>{};

  late Future<void> Function() unregister;
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  setUp(() async => unregister = await registerFloorServices());
  tearDown(() async => unregister());
  tearDownAll(() {
    final total = <String, int>{};
    final floors = <String, int>{};
    for (final counts in all.values) {
      for (final MapEntry(:key, :value) in counts.entries) {
        total[key] = (total[key] ?? 0) + value;
        floors[key] = (floors[key] ?? 0) + 1;
      }
    }
    final worst = all.entries.toList()
      ..sort((a, b) => b.value.values.fold(0, (s, v) => s + v).compareTo(a.value.values.fold(0, (s, v) => s + v)));
    File('$_out/summary.json').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert({
        'floors': all.length,
        'floors_with_differences': all.values.where((e) => e.isNotEmpty).length,
        'total': total,
        'floors_by_kind': floors,
        'worst': {for (final e in worst.where((e) => e.value.isNotEmpty).take(40)) e.key: e.value},
      }),
    );
  });

  for (final file in files) {
    final tid = file.uri.pathSegments.last.replaceAll('.json', '');
    testWidgets('thread $tid', (tester) async {
      usePhone(tester);
      final web = jsonDecode(File('$_out/web/$tid.json').readAsStringSync()) as Map<String, dynamic>;
      final styles = (web['styles'] as List).cast<Map<String, dynamic>>();
      final paths = (web['paths'] as List).cast<String>();
      final webFloors = {
        for (final f in (web['floors'] as List).cast<Map<String, dynamic>>()) f['pid'] as String: f,
      };
      final page = threadPageFromApi(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>, 1);
      final out = <String, Object?>{};
      for (final post in page.postList) {
        final pid = post.postID;
        final w = webFloors[pid];
        final html = _cellOf(post.data, pid);
        if (w == null || w['missing'] == true || html == null) {
          out[pid] = {'skipped': w == null || w['missing'] == true ? 'not on the web page' : 'no td.t_f'};
          continue;
        }
        final tokens = [
          for (final t in (w['tokens'] as List).cast<Map<String, dynamic>>())
            {
              ...t,
              if (t['st'] is int) 'st': styles[t['st'] as int],
              if (t['tp'] is int) 'tp': paths[t['tp'] as int],
            },
        ];
        final base = w['base'] as Map<String, dynamic>;
        PaintingBinding.instance.imageCache.clear();
        await seedImages(tester, html, sizeOf: sizeOf);
        final (light, error) = await dumpFloor(tester, html, dark: false);
        final diff = compareFloor(tokens, base, light);
        final (dark, _) = await dumpFloor(tester, html, dark: true);
        final r = darkReadability(tokens, dark, defaultInk: darkInk, surface: darkSurface);
        final counts = {
          ...diff.counts,
          if (r.hiddenShown > 0) 'dark.hidden_shown': r.hiddenShown,
          if (r.unreadable > 0) 'dark.unreadable': r.unreadable,
          if (error != null) 'errors': 1,
        };
        all['$tid/$pid'] = counts;
        out[pid] = {
          'counts': counts,
          'examples': {
            ...diff.examples,
            if (r.hiddenShown > 0) 'dark.hidden_shown': r.hiddenExample,
            if (r.unreadable > 0) 'dark.unreadable': r.unreadableExample,
            'errors': ?error,
          },
          'tolerated': diff.tolerated,
        };
      }
      await tester.pumpWidget(const SizedBox.shrink());
      File('$_out/compare/$tid.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }
}
