/// The three languages hold the same texts, and the screens do not gain Chinese written in code.
///
/// * Every key of `zh-CN.i18n.json` is in `en.i18n.json` and `zh-TW.i18n.json`, and nothing more: a text added to one
///   language only shows another language's text, or fails to build.
/// * A text takes the same parameters (`$name`, `${name: Type}`) and links (`@:key`) in every language: one dropped
///   in a translation is a value that never shows.
/// * The string literals of `lib/` holding Chinese are the ones of the allowlist
///   (`test/data/i18n/cjk_literal_allowlist.txt`): the forum's own words the parsers look for, the texts the app sends
///   to the forum, names. A new one fails: a text for the screen goes to the i18n files; one that has to stay in code
///   is added to the allowlist, under the heading saying why. An entry no longer in `lib/` fails too, so the list does
///   not let the same literal back in unseen. `UPDATE_CJK_ALLOWLIST=1` appends the new ones and drops the gone ones.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/cjk_literals.dart';
import 'fixtures/same_members.dart';

const _allowlistPath = 'test/data/i18n/cjk_literal_allowlist.txt';

Map<String, Object?> _load(String locale) =>
    jsonDecode(File('lib/i18n/$locale.i18n.json').readAsStringSync()) as Map<String, Object?>;

/// The texts of [node] by their dotted keys; a key with a modifier (`key(rich)`, `key(plural)`) is one text.
Map<String, Object?> _flatten(Map<String, Object?> node, [String prefix = '']) => {
  for (final MapEntry(:key, :value) in node.entries)
    if (value is Map<String, Object?> && !key.contains('('))
      ..._flatten(value, '$prefix$key.')
    else
      '$prefix$key': value,
};

final _paramRe = RegExp(r'(?<!\\)\$\{?([A-Za-z_][A-Za-z0-9_]*)|@:([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)');

/// The parameters and links of [value], over every form of a text with forms.
Set<String> _params(Object? value) => switch (value) {
  final String s => {
    for (final m in _paramRe.allMatches(s)) m.group(1) != null ? '\$${m.group(1)}' : '@:${m.group(2)}',
  },
  final Map<String, Object?> m => {for (final v in m.values) ..._params(v)},
  final List<Object?> l => {for (final v in l) ..._params(v)},
  _ => const {},
};

void main() {
  final base = _flatten(_load('zh-CN'));
  final others = {
    for (final l in ['zh-TW', 'en']) l: _flatten(_load(l)),
  };

  group('i18n files', () {
    for (final MapEntry(key: locale, value: texts) in others.entries) {
      test('$locale has the keys of zh-CN', () {
        expectSameMembers(texts.keys, base.keys, reason: '$locale against zh-CN');
      });

      test('$locale takes the parameters of zh-CN', () {
        final differ = [
          for (final MapEntry(:key, :value) in base.entries)
            if (texts.containsKey(key) && !_sameSet(_params(texts[key]), _params(value)))
              '$key: zh-CN ${_params(value)}, $locale ${_params(texts[key])}',
        ];
        expect(differ, isEmpty);
      });
    }
  });

  test('lib gains no Chinese string literal and the allowlist holds no gone one', () {
    final found = cjkLiteralsUnder(Directory('lib')).map(cjkLiteralEntry).toList();
    final allowFile = File(_allowlistPath);
    final lines = allowFile.readAsLinesSync();
    final left = <String, int>{};
    for (final l in lines.where((l) => l.isNotEmpty && !l.startsWith('#'))) {
      left.update(l, (n) => n + 1, ifAbsent: () => 1);
    }
    final added = <String>[];
    for (final e in found) {
      final n = left[e] ?? 0;
      if (n > 0) {
        left[e] = n - 1;
      } else {
        added.add(e);
      }
    }
    final gone = [
      for (final MapEntry(:key, :value) in left.entries) ...List.filled(value, key),
    ];
    if ((added.isNotEmpty || gone.isNotEmpty) && Platform.environment['UPDATE_CJK_ALLOWLIST'] == '1') {
      final drop = Map.of(left);
      final kept = <String>[];
      for (final l in lines) {
        final n = drop[l] ?? 0;
        if (n > 0) {
          drop[l] = n - 1;
        } else {
          kept.add(l);
        }
      }
      allowFile.writeAsStringSync('${[...kept, ...added].join('\n')}\n');
      return;
    }
    expect(
      added,
      isEmpty,
      reason:
          'Chinese string literals not in $_allowlistPath. Move a text shown on screen to lib/i18n (all three '
          'languages); add one that has to stay in code to the allowlist under the heading saying why, one line '
          'each:\n${added.join('\n')}',
    );
    expect(gone, isEmpty, reason: 'Allowlist entries no longer in lib/, remove these lines:\n${gone.join('\n')}');
  });
}

bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);
