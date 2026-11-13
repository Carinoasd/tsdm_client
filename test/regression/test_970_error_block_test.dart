import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/diagnostics/widgets/error_block.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/error_reporting.dart';
import 'package:tsdm_client/utils/redacting_talker.dart';

/// P16: a widget that fails to build shows [ErrorBlock] in a release build, whatever the place and the size it lands
/// in, without a second error; the error and its stack are in the log, not on the screen; a debug build keeps the
/// error screen of Flutter.

final class _BoomError extends Error {
  @override
  String toString() => 'BoomError: the widget under test failed on purpose';
}

class _Boom extends StatelessWidget {
  const _Boom();

  @override
  Widget build(BuildContext context) => throw _BoomError();
}

final _logLines = <String>[];

/// Every error the framework reported while [body] ran, with [installErrorReporting] set up as in a release build.
///
/// The errors are collected here instead of by the test binding: a failing widget is expected, a second error (one of
/// the error block itself, an overflow) must show up as one more entry.
Future<List<FlutterErrorDetails>> _releaseErrors(Future<void> Function() body) async {
  final errors = <FlutterErrorDetails>[];
  final onError = FlutterError.onError;
  final builder = ErrorWidget.builder;
  final platformOnError = PlatformDispatcher.instance.onError;
  FlutterError.onError = errors.add;
  installErrorReporting(debug: false);
  try {
    await body();
  } finally {
    FlutterError.onError = onError;
    ErrorWidget.builder = builder;
    PlatformDispatcher.instance.onError = platformOnError;
  }
  return errors;
}

/// Only the failing widgets' own errors, as many as error blocks on the screen.
void _expectOnlyBooms(List<FlutterErrorDetails> errors, {int? count}) {
  expect(errors, isNotEmpty);
  for (final e in errors) {
    expect(e.exception, isA<_BoomError>(), reason: 'a second error: ${e.exceptionAsString()}');
  }
  final blocks = find.byType(ErrorBlock).evaluate().length;
  expect(blocks, errors.length);
  if (count != null) {
    expect(blocks, count);
  }
}

String get _message => t.diagnostics.errorBlock;

String get _export => t.diagnostics.export;

void main() {
  setUpAll(() => talker = buildRedactingTalker(console: (_) {}, writeLine: _logLines.add));
  setUp(_logLines.clear);

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('a page: the message and the export button, not the error', (tester) async {
    final errors = await _releaseErrors(() => tester.pumpWidget(app(const _Boom())));
    _expectOnlyBooms(errors, count: 1);
    expect(find.text(_message).hitTestable(), findsOneWidget);
    expect(find.text(_export).hitTestable(), findsOneWidget);
    expect(find.textContaining('BoomError'), findsNothing);
    expect(find.byType(ErrorWidget), findsNothing);
  });

  testWidgets('no ancestor at all: no theme, no directionality, no translations, no material', (tester) async {
    final errors = await _releaseErrors(() => tester.pumpWidget(const _Boom()));
    _expectOnlyBooms(errors, count: 1);
    expect(find.text(_message).hitTestable(), findsOneWidget);
  });

  testWidgets('tiny: only the color', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(const Center(child: SizedBox(width: 8, height: 8, child: _Boom()))),
    );
    _expectOnlyBooms(errors, count: 1);
    expect(tester.getSize(find.byType(ErrorBlock)), const Size(8, 8));
    expect(find.byIcon(Icons.error_outline).hitTestable(), findsNothing);
    expect(find.text(_message).hitTestable(), findsNothing);
  });

  testWidgets('small: the icon alone', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(app(const Center(child: SizedBox(width: 40, height: 40, child: _Boom())))),
    );
    _expectOnlyBooms(errors, count: 1);
    expect(find.byIcon(Icons.error_outline).hitTestable(), findsOneWidget);
    expect(find.text(_message).hitTestable(), findsNothing);
  });

  testWidgets('a short row: the icon alone', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(app(const Center(child: SizedBox(width: 360, height: 32, child: _Boom())))),
    );
    _expectOnlyBooms(errors, count: 1);
    expect(find.byIcon(Icons.error_outline).hitTestable(), findsOneWidget);
    expect(find.text(_message).hitTestable(), findsNothing);
  });

  testWidgets('unbounded both ways: a fixed size', (tester) async {
    final errors = await _releaseErrors(() => tester.pumpWidget(app(const UnconstrainedBox(child: _Boom()))));
    _expectOnlyBooms(errors, count: 1);
    expect(tester.getSize(find.byType(ErrorBlock)), const Size(240, 120));
    expect(find.text(_message).hitTestable(), findsOneWidget);
  });

  testWidgets('a vertical list row: the list width, a fixed height', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(app(ListView(children: const [Text('above'), _Boom(), Text('below')]))),
    );
    _expectOnlyBooms(errors, count: 1);
    expect(tester.getSize(find.byType(ErrorBlock)), const Size(800, 120));
    expect(find.text('below'), findsOneWidget);
  });

  testWidgets('a horizontal list: unbounded width', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(
        app(
          SizedBox(
            height: 50,
            child: ListView(scrollDirection: Axis.horizontal, children: const [_Boom()]),
          ),
        ),
      ),
    );
    _expectOnlyBooms(errors, count: 1);
    expect(tester.getSize(find.byType(ErrorBlock)), const Size(240, 50));
  });

  testWidgets('intrinsic layouts ask its size without an error', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(
        app(
          Column(
            children: [
              const IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(child: _Boom()),
                    Text('side'),
                  ],
                ),
              ),
              const IntrinsicWidth(child: _Boom()),
              Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                children: const [
                  TableRow(children: [_Boom(), Text('cell')]),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    _expectOnlyBooms(errors, count: 3);
  });

  testWidgets('many at once: each one alone, no error of their own', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(
        app(
          SingleChildScrollView(
            child: Wrap(
              children: List.generate(200, (_) => const SizedBox(width: 30, height: 30, child: _Boom())),
            ),
          ),
        ),
      ),
    );
    _expectOnlyBooms(errors, count: 200);
    expect(find.text(_message), findsNWidgets(200));
    expect(find.text(_message).hitTestable(), findsNothing);
    // Nothing pops up over the page (a snack bar, a dialog) because of them.
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('a dark theme above it', (tester) async {
    final errors = await _releaseErrors(
      () => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(body: _Boom()),
        ),
      ),
    );
    _expectOnlyBooms(errors, count: 1);
    expect(find.text(_message).hitTestable(), findsOneWidget);
  });

  testWidgets('the error, where it happened and its stack are in the log', (tester) async {
    await _releaseErrors(() => tester.pumpWidget(app(const _Boom())));
    final log = _logLines.join();
    expect(log, contains('BoomError: the widget under test failed on purpose'));
    expect(log, contains('FlutterError in widgets library'));
    expect(log, contains('_Boom'));
    expect(log, contains('test_970_error_block_test.dart'));
  });

  testWidgets('an error outside the zone of main is logged and handled', (tester) async {
    await _releaseErrors(() async {
      final handled = PlatformDispatcher.instance.onError!(StateError('platform callback failed'), StackTrace.current);
      expect(handled, isTrue);
    });
    expect(_logLines.join(), contains('platform callback failed'));
  });

  testWidgets('a debug build keeps the error screen of Flutter', (tester) async {
    final onError = FlutterError.onError;
    final builder = ErrorWidget.builder;
    final platformOnError = PlatformDispatcher.instance.onError;
    try {
      installErrorReporting(debug: true);
      expect(identical(ErrorWidget.builder, builder), isTrue);
    } finally {
      FlutterError.onError = onError;
      ErrorWidget.builder = builder;
      PlatformDispatcher.instance.onError = platformOnError;
    }
    await tester.pumpWidget(app(const _Boom()));
    expect(tester.takeException(), isA<_BoomError>());
    expect(find.byType(ErrorWidget), findsOneWidget);
    expect(find.byType(ErrorBlock), findsNothing);
  });
}
