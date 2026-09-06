import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// Frame drops reported on the first release round: every rebuild of a page re-parsed and re-munched the html of
/// every card kept alive, and post images were decoded at their full size. [MunchedHtml] keeps the munched spans until
/// the html or what they were built from changes; [decodeWidthFor] bounds image decoding to the displayed size.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Widget? contentOf(WidgetTester tester) {
    Widget? child;
    tester.element(find.byType(MunchedHtml)).visitChildElements((e) => child = e.widget);
    return child;
  }

  Widget host({required String html, ThemeData? theme, double textScale = 1}) => TranslationProvider(
    child: MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: _Rebuilder(child: MunchedHtml(html))),
      ),
    ),
  );

  testWidgets('a parent rebuild keeps the munched spans', (tester) async {
    await tester.pumpWidget(host(html: '<div>hello <b>world</b></div>'));
    final before = contentOf(tester);
    expect(find.textContaining('hello', findRichText: true), findsOneWidget);

    await tester.tap(find.text('rebuild'));
    await tester.pump();
    expect(identical(contentOf(tester), before), isTrue, reason: 'same html, same spans');
  });

  testWidgets('new html, a new theme or a new text scale rebuild the spans', (tester) async {
    await tester.pumpWidget(host(html: '<div>one</div>'));
    final first = contentOf(tester);

    await tester.pumpWidget(host(html: '<div>two</div>'));
    final second = contentOf(tester);
    expect(identical(second, first), isFalse);
    expect(find.textContaining('two', findRichText: true), findsOneWidget);
    expect(find.textContaining('one', findRichText: true), findsNothing);

    // MaterialApp animates a theme change; the spans are rebuilt as the theme moves, so let it finish.
    await tester.pumpWidget(host(html: '<div>two</div>', theme: ThemeData.dark()));
    await tester.pumpAndSettle();
    final third = contentOf(tester);
    expect(identical(third, second), isFalse, reason: 'theme colours are baked into the spans');

    await tester.pumpWidget(host(html: '<div>two</div>', theme: ThemeData.dark(), textScale: 1.5));
    await tester.pumpAndSettle();
    expect(identical(contentOf(tester), third), isFalse, reason: 'text scale changes the layout');
  });

  test('decodeWidthFor bounds decoding to the smallest of the requested and displayed widths', () {
    expect(decodeWidthFor(width: null, maxWidth: null, displayWidth: 360, devicePixelRatio: 3), 1080);
    expect(decodeWidthFor(width: 120, maxWidth: null, displayWidth: 360, devicePixelRatio: 3), 360);
    expect(decodeWidthFor(width: null, maxWidth: 200, displayWidth: 360, devicePixelRatio: 2.5), 500);
    expect(decodeWidthFor(width: 5000, maxWidth: double.infinity, displayWidth: 360, devicePixelRatio: 3), 1080);
    expect(decodeWidthFor(width: 0, maxWidth: -1, displayWidth: double.infinity, devicePixelRatio: 3), isNull);
  });
}

/// A parent that rebuilds its child on demand without changing it.
class _Rebuilder extends StatefulWidget {
  const _Rebuilder({required this.child});

  final Widget child;

  @override
  State<_Rebuilder> createState() => _RebuilderState();
}

class _RebuilderState extends State<_Rebuilder> {
  var _n = 0;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(onPressed: () => setState(() => _n++), child: const Text('rebuild')),
      Text('$_n'),
      widget.child,
    ],
  );
}
