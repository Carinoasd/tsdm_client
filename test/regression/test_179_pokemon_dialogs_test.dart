import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/pokemon/utils/pokemon_dialogs.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// Tests of the pokemon dialog helpers used by every purchase/confirm flow.
///
/// They are wrapped in `RootPage` and closed through go_router; the point here is that opening and closing them leaves
/// no framework exception (the `InheritedElement.debugDeactivated` assertion reported while buying).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<void> open(WidgetTester tester, Future<void> Function(BuildContext) action) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.en));
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(onPressed: () => action(context), child: const Text('open')),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('confirm dialog confirms and closes cleanly', (tester) async {
    bool? result;
    await open(tester, (context) async {
      result = await showPokemonConfirmDialog(
        context: context,
        icon: Icons.delete_outline,
        title: 'release',
        message: 'release it?',
        confirmLabel: 'go',
        dangerous: true,
      );
    });
    expect(find.text('release it?'), findsOneWidget);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirm dialog cancels and closes cleanly', (tester) async {
    bool? result;
    await open(tester, (context) async {
      result = await showPokemonConfirmDialog(
        context: context,
        icon: Icons.delete_outline,
        title: 'release',
        message: 'release it?',
        confirmLabel: 'go',
      );
    });
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('input dialog returns the text and closes cleanly', (tester) async {
    String? result;
    await open(tester, (context) async {
      result = await showPokemonInputDialog(
        context: context,
        icon: Icons.edit,
        title: 'quantity',
        initialValue: '1',
        confirmLabel: 'go',
        hintText: 'quantity',
        keyboardType: TextInputType.number,
      );
    });
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(result, '3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('input dialog cancellation returns null and closes cleanly', (tester) async {
    String? result = 'unset';
    await open(tester, (context) async {
      result = await showPokemonInputDialog(
        context: context,
        icon: Icons.edit,
        title: 'quantity',
        initialValue: '1',
        confirmLabel: 'go',
        hintText: 'quantity',
      );
    });
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });
}
