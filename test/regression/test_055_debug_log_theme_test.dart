import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/view/debug_log_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// Issue #15: the debug log page follows the app theme instead of the package's fixed dark palette, so under the light
/// theme the page, its app bar and the nested monitor page are light and the status bar icons stay readable.
void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  final light = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
  final dark = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
  );

  Widget host(ThemeData theme) => TranslationProvider(
    child: MaterialApp(theme: theme, home: const DebugLogPage()),
  );

  /// The scaffold [TalkerScreen] builds, the one whose background is the page ground.
  Scaffold screenScaffold(WidgetTester tester) =>
      tester.widget<Scaffold>(find.descendant(of: find.byType(TalkerScreen), matching: find.byType(Scaffold)).first);

  group('buildTalkerScreenTheme', () {
    test('takes the ground and text colors from the scheme', () {
      for (final theme in [light, dark]) {
        final t = buildTalkerScreenTheme(theme);
        expect(t.backgroundColor, theme.colorScheme.surface);
        expect(t.textColor, theme.colorScheme.onSurface);
        expect(t.cardColor, theme.colorScheme.surfaceContainerHigh);
        expect(ThemeData.estimateBrightnessForColor(t.backgroundColor), theme.brightness);
      }
    });

    test('darkens the grey log levels under the light theme only', () {
      const packageDefault = TalkerScreenTheme();
      final l = buildTalkerScreenTheme(light);
      expect(l.logColors[TalkerKey.debug], isNot(packageDefault.logColors[TalkerKey.debug]));
      expect(l.logColors[TalkerKey.verbose], isNot(packageDefault.logColors[TalkerKey.verbose]));
      expect(l.logColors[TalkerKey.error], packageDefault.logColors[TalkerKey.error]);
      final d = buildTalkerScreenTheme(dark);
      expect(d.logColors, packageDefault.logColors);
    });
  });

  group('debug log page', () {
    testWidgets('is light under the light theme', (tester) async {
      await tester.pumpWidget(host(light));
      await tester.pump();

      final screen = tester.widget<TalkerScreen>(find.byType(TalkerScreen));
      expect(screen.theme.backgroundColor, light.colorScheme.surface);
      expect(screen.theme.textColor, light.colorScheme.onSurface);
      expect(screenScaffold(tester).backgroundColor, light.colorScheme.surface);
      expect(ThemeData.estimateBrightnessForColor(screenScaffold(tester).backgroundColor!), Brightness.light);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is dark under the dark theme', (tester) async {
      await tester.pumpWidget(host(dark));
      await tester.pump();

      final screen = tester.widget<TalkerScreen>(find.byType(TalkerScreen));
      expect(screen.theme.backgroundColor, dark.colorScheme.surface);
      expect(ThemeData.estimateBrightnessForColor(screenScaffold(tester).backgroundColor!), Brightness.dark);
      expect(tester.takeException(), isNull);
    });
  });
}
