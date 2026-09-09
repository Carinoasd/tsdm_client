import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Issue #4: the "auto check-in finished" snack bar wrapped onto two rows on phones because the close icon pushed the
/// action over Flutter's 25% overflow threshold. The bar is now shown without the icon and with a raised threshold,
/// exactly as `lib/app.dart` does; this pins the single-row layout on a 320x640 screen at the app's maximum text scale.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Widget host() => MaterialApp(
    scaffoldMessengerKey: snackbarKey,
    builder: (context, child) => MediaQuery(
      // The app clamps its text scaler to at most 1.5; use the worst case.
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)),
      child: child!,
    ),
    home: const Scaffold(body: SizedBox.expand()),
  );

  Future<void> show(WidgetTester tester, {required bool showCloseIcon, double? actionOverflowThreshold}) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    final context = tester.element(find.byType(Scaffold));
    showSnackBar(
      context: context,
      message: '自动签到已完成',
      clearPrevious: true,
      showCloseIcon: showCloseIcon,
      actionOverflowThreshold: actionOverflowThreshold,
      action: SnackBarAction(label: '查看详情', onPressed: () {}),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the finished bar keeps message and action on one row and has no close icon', (tester) async {
    await show(tester, showCloseIcon: false, actionOverflowThreshold: 0.6);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    final message = tester.getRect(find.text('自动签到已完成'));
    final action = tester.getRect(find.text('查看详情'));
    expect(message.height, lessThan(message.width), reason: 'the message must not wrap');
    expect(
      (message.center.dy - action.center.dy).abs(),
      lessThan(4),
      reason: 'action must sit on the same row as the message',
    );
    expect(action.left, greaterThan(message.right), reason: 'the action is to the right of the message');
  });

  testWidgets('the old layout (close icon, default threshold) is the two-row one this guards against', (tester) async {
    await show(tester, showCloseIcon: true);
    expect(find.byIcon(Icons.close), findsOneWidget);
    final message = tester.getRect(find.text('自动签到已完成'));
    final action = tester.getRect(find.text('查看详情'));
    expect(action.center.dy, greaterThan(message.bottom), reason: 'the action used to be pushed below the message');
  });
}
