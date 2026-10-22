/// Post content keeps showing what the web page shows (the fifth phase of the post display work: the comparison with
/// the web page, floor by floor, kept in the repository so it cannot slip back).
///
/// The first phases were measured with a tool outside the repository on a hundred threads of the forum: the web page
/// read in a browser, the app's floor read from its widget tree, the two compared. The same comparison runs here on a
/// small synthetic corpus (`test/data/render_regression`), without a browser or the network:
///
/// * `floors/c*.html`: floors made from real ones picked for what they hold (blank lines, rules and empty paragraphs,
///   tags of every kind, hidden content, players, spoilers, tables of one row, spanning cells, nested or holding wide
///   images, the styles of authors, links, long paragraphs, and what was still different), their text replaced by
///   random text of the same kind and length, their names, numbers, links and images by made up ones, their style
///   sheets cut to what is compared (`make_corpus.py`); `floors/h*.html`: written by hand
///   (`tools/render_regression/hand`) for what the real ones did not have (jammer text, the folds a post makes
///   itself, hidden text and colors for a dark theme), their text made up the same way;
/// * `web.json`: what the forum's web page shows of each, read in a browser with the forum's style sheets
///   (`tools/render_regression/web_snapshot.mjs`, run locally);
/// * `baseline.json`: the differences each floor still has (what the app does not show as the web page does yet, or
///   on purpose).
///
/// Each floor is shown as the thread page shows it (`render_regression/harness.dart`) and compared
/// (`render_regression/compare.dart`, which says what is compared and what is not, on purpose): in the light theme,
/// content, line breaks, style, tables, blocks, images; in the dark theme, only that text the web page shows reads
/// and text it hides stays hidden. A floor with more differences of a kind than its baseline fails, naming the kind
/// and showing one; one with fewer says so. After a change that shows the floors better, write the baseline again:
///
///   flutter test test/regression/test_234_render_regression_test.dart --dart-define=RENDER_REGRESSION_UPDATE=true
///
/// and see in the diff that only fewer differences are left. `tools/render_regression/README.md` tells how the
/// corpus and the web snapshot are made and how to run the comparison on a full corpus.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

import 'render_regression/compare.dart';
import 'render_regression/dump.dart';
import 'render_regression/harness.dart';

const _dir = 'test/data/render_regression';

/// Write the baseline from this run instead of checking against it.
const _update = bool.fromEnvironment('RENDER_REGRESSION_UPDATE');

/// A directory to write what the app shows of each floor and its differences to (`<id>.json`), to look into them.
const _dumpDir = String.fromEnvironment('RENDER_REGRESSION_DUMP');

/// Floors also shown with long paragraphs cut after sentences (a setting, off by default): the content stays the
/// same, only line breaks are added.
const _splitFeature = 'long_para';

/// The web snapshot of the floors: their tokens (styles and tag paths taken back out of their tables) and base style.
Map<String, (List<Map<String, Object?>>, Map<String, Object?>)> _loadWeb() {
  final json = jsonDecode(File('$_dir/web.json').readAsStringSync()) as Map<String, dynamic>;
  final styles = (json['styles'] as List).cast<Map<String, dynamic>>();
  final paths = (json['paths'] as List).cast<String>();
  return {
    for (final MapEntry(:key, :value) in (json['floors'] as Map<String, dynamic>).entries)
      key: (
        [
          for (final t in ((value as Map<String, dynamic>)['tokens'] as List).cast<Map<String, dynamic>>())
            {
              ...t,
              if (t['st'] is int) 'st': styles[t['st'] as int],
              if (t['tp'] is int) 'tp': paths[t['tp'] as int],
            },
        ],
        value['base'] as Map<String, dynamic>,
      ),
  };
}

void main() {
  final files = Directory('$_dir/floors').listSync().whereType<File>().where((f) => f.path.endsWith('.html')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final web = _loadWeb();
  final baselineFile = File('$_dir/baseline.json');
  final baseline = baselineFile.existsSync()
      ? (jsonDecode(baselineFile.readAsStringSync()) as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as Map<String, dynamic>).cast<String, int>()),
        )
      : <String, Map<String, int>>{};
  final split = {
    for (final f in (jsonDecode(File('$_dir/manifest.json').readAsStringSync()) as List).cast<Map<String, dynamic>>())
      if ((f['features'] as List).contains(_splitFeature)) f['id'] as String,
    'h08-paragraphs',
  };
  final darkTheme = appTheme(dark: true);
  final darkInk = hexColor(darkTheme.colorScheme.onSurface);
  final darkSurface = hexColor(darkTheme.cardTheme.color ?? darkTheme.colorScheme.surfaceContainerLow);

  final results = <String, Map<String, int>>{};
  final tolerated = <String, int>{};
  final improved = <String>[];
  final watch = Stopwatch();

  late Future<void> Function() unregister;
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
    watch.start();
  });
  setUp(() async => unregister = await registerFloorServices());
  tearDown(() async => unregister());
  tearDownAll(() {
    watch.stop();
    final total = <String, int>{};
    for (final counts in results.values) {
      for (final MapEntry(:key, :value) in counts.entries) {
        total[key] = (total[key] ?? 0) + value;
      }
    }
    // Printed for the record: how long the floors took, what is left, what got better.
    // ignore: avoid_print
    print(
      'render regression: ${results.length} floors in ${watch.elapsed.inMilliseconds} ms; '
      'differences left ${jsonEncode(total)}; tolerated ${jsonEncode(tolerated)}'
      '${improved.isEmpty ? '' : '\nfewer differences than the baseline (write it again):\n${improved.join('\n')}'}',
    );
    if (_update) {
      // The floors not run (a test picked by name) keep their baseline; a floor taken out of the corpus goes.
      final merged = {...baseline, ...results};
      final sorted = {
        for (final id in merged.keys.toList()..sort())
          if (merged[id]!.isNotEmpty && web.containsKey(id))
            id: Map.fromEntries(merged[id]!.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      };
      baselineFile.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(sorted)}\n');
    }
  });

  for (final file in files) {
    final id = file.uri.pathSegments.last.replaceAll('.html', '');
    testWidgets('floor $id', (tester) async {
      usePhone(tester);
      final html = file.readAsStringSync();
      final (webTokens, base) = web[id] ?? (throw StateError('$id is not in web.json: run web_snapshot.mjs'));
      await seedImages(tester, html);

      final counts = <String, int>{};
      final examples = <String, String>{};

      // The light theme, as the web page: everything compared.
      final (light, lightError) = await dumpFloor(tester, html, dark: false);
      final diff = compareFloor(webTokens, base, light);
      counts.addAll(diff.counts);
      examples.addAll(diff.examples);
      for (final MapEntry(:key, :value) in diff.tolerated.entries) {
        tolerated[key] = (tolerated[key] ?? 0) + value;
      }
      if (lightError != null) {
        counts['errors'] = 1;
        examples['errors'] = lightError;
      }

      // The dark theme: the readability rules only.
      final (dark, darkError) = await dumpFloor(tester, html, dark: true);
      final r = darkReadability(webTokens, dark, defaultInk: darkInk, surface: darkSurface);
      if (r.hiddenShown > 0) {
        counts['dark.hidden_shown'] = r.hiddenShown;
        examples['dark.hidden_shown'] = r.hiddenExample;
      }
      if (r.unreadable > 0) {
        counts['dark.unreadable'] = r.unreadable;
        examples['dark.unreadable'] = r.unreadableExample;
      }
      if (darkError != null) {
        counts['errors'] = 1;
        examples['errors'] = darkError;
      }

      // Long paragraphs cut after sentences: nothing lost or added.
      if (split.contains(id)) {
        final (cut, _) = await dumpFloor(tester, html, dark: false, splitLongParagraphs: true);
        final d = compareFloor(webTokens, base, cut);
        for (final key in ['content.lost', 'content.extra']) {
          if (d.counts[key] case final n?) {
            counts['split.$key'] = n;
            examples['split.$key'] = d.examples[key]!;
          }
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      results[id] = counts;
      if (_dumpDir.isNotEmpty) {
        Directory(_dumpDir).createSync(recursive: true);
        File('$_dumpDir/$id.json').writeAsStringSync(
          const JsonEncoder.withIndent(
            ' ',
          ).convert({'counts': counts, 'examples': examples, 'light': light, 'dark': dark}),
        );
      }

      if (_update) {
        return;
      }
      final allowed = baseline[id] ?? const <String, int>{};
      final worse = [
        for (final MapEntry(:key, :value) in counts.entries)
          if (value > (allowed[key] ?? 0)) '$id $key: $value, baseline ${allowed[key] ?? 0}; e.g. ${examples[key]}',
      ];
      for (final MapEntry(:key, :value) in allowed.entries) {
        if ((counts[key] ?? 0) < value) {
          improved.add('$id $key: ${counts[key] ?? 0}, baseline $value');
        }
      }
      expect(worse, isEmpty, reason: 'more differences from the web page than the baseline');
    });
  }
}
