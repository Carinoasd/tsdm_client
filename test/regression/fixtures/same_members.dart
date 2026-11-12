import 'package:flutter_test/flutter_test.dart';

/// Expects [actual] to hold the same distinct members as [expected], in any order.
///
/// `expect(a.toSet(), b.toSet())` prints both sets whole when they differ and names only the first member missing:
/// with a few hundred long members the log is cut before it shows what changed. Only the difference is compared, so
/// a failure prints what is missing and what is extra, and nothing else.
void expectSameMembers(Iterable<Object?> actual, Iterable<Object?> expected, {String? reason}) {
  final have = actual.toSet();
  final want = expected.toSet();
  expect(
    {'missing': want.difference(have), 'extra': have.difference(want)},
    {'missing': isEmpty, 'extra': isEmpty},
    reason: reason,
  );
}
