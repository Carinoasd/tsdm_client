import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_toast.dart';

void main() {
  testWidgets('a snack bar with an action leaves on its own', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: snackbarKey,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    showSnackBar(
      context: ctx,
      message: 'done',
      action: SnackBarAction(label: 'open', onPressed: () {}),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('done'), findsOneWidget);
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.text('done'), findsNothing);
  });
}
