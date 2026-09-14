import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';

void main() {
  late GlobalKey<NavigatorState> navigatorKey;
  late PopupRouteObserver observer;

  setUp(() {
    navigatorKey = GlobalKey<NavigatorState>();
    observer = PopupRouteObserver();
  });

  Future<void> mountNavigator(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [observer],
      home: const Scaffold(body: Text('home')),
    ),
  );

  MaterialPageRoute<void> page(String name) => MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(name)));

  DialogRoute<void> dialog(String name) => DialogRoute<void>(
    context: navigatorKey.currentContext!,
    builder: (_) => AlertDialog(title: Text(name)),
  );

  testWidgets('ordinary pages never block external navigation', (tester) async {
    await mountNavigator(tester);
    expect(observer.hasPopupRoute, isFalse);

    unawaited(navigatorKey.currentState!.push(page('second page')));
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);
    expect(observer.hasPopupRoute, isFalse);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(observer.hasPopupRoute, isFalse);
  });

  testWidgets('a non-dismissible waiting dialog blocks until it is closed', (tester) async {
    await mountNavigator(tester);
    unawaited(
      showDialog<void>(
        context: navigatorKey.currentContext!,
        barrierDismissible: false,
        builder: (_) => const PopScope(canPop: false, child: AlertDialog(title: Text('logging out'))),
      ),
    );
    expect(observer.hasPopupRoute, isTrue, reason: 'the barrier must be known before the next frame');
    await tester.pumpAndSettle();

    await navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('logging out'), findsOneWidget);
    expect(observer.hasPopupRoute, isTrue);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('logging out'), findsNothing);
    expect(observer.hasPopupRoute, isFalse);
  });

  testWidgets('closing a nested dialog keeps the underlying modal barrier active', (tester) async {
    await mountNavigator(tester);
    unawaited(navigatorKey.currentState!.push(dialog('account actions')));
    await tester.pumpAndSettle();
    unawaited(navigatorKey.currentState!.push(dialog('confirmation')));
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('confirmation'), findsNothing);
    expect(find.text('account actions'), findsOneWidget);
    expect(observer.hasPopupRoute, isTrue);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(observer.hasPopupRoute, isFalse);
  });

  testWidgets('removing a covered dialog clears its barrier without popping the page', (tester) async {
    await mountNavigator(tester);
    final popup = dialog('covered dialog');
    unawaited(navigatorKey.currentState!.push(popup));
    await tester.pumpAndSettle();
    unawaited(navigatorKey.currentState!.push(page('covering page')));
    await tester.pumpAndSettle();
    expect(observer.hasPopupRoute, isTrue);

    navigatorKey.currentState!.removeRoute(popup);
    await tester.pumpAndSettle();
    expect(find.text('covering page'), findsOneWidget);
    expect(observer.hasPopupRoute, isFalse);
  });

  testWidgets('replacing routes adds and removes modal barriers while preserving the top page', (tester) async {
    await mountNavigator(tester);
    final ordinary = page('underlying page');
    unawaited(navigatorKey.currentState!.push(ordinary));
    await tester.pumpAndSettle();
    unawaited(navigatorKey.currentState!.push(page('top page')));
    await tester.pumpAndSettle();

    final firstDialog = dialog('first dialog');
    navigatorKey.currentState!.replace(oldRoute: ordinary, newRoute: firstDialog);
    await tester.pumpAndSettle();
    expect(observer.hasPopupRoute, isTrue);

    final secondDialog = dialog('replacement dialog');
    navigatorKey.currentState!.replace(oldRoute: firstDialog, newRoute: secondDialog);
    await tester.pumpAndSettle();
    expect(observer.hasPopupRoute, isTrue);

    navigatorKey.currentState!.replace(oldRoute: secondDialog, newRoute: page('replacement page'));
    await tester.pumpAndSettle();
    expect(find.text('top page'), findsOneWidget);
    expect(observer.hasPopupRoute, isFalse);
  });
}
