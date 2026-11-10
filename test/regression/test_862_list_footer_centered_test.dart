import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/list_footer.dart';

void main() {
  testWidgets('the end-of-list line is centered in the row', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: Scaffold(
            body: ListFooter(status: ListFooterStatus.noMore, noMoreText: 'THE END'),
          ),
        ),
      ),
    );
    final view = tester.getRect(find.byType(ListFooter));
    final text = tester.getRect(find.text('THE END'));
    expect(text.center.dx, closeTo(view.center.dx, 1));
    // The rules reach both paddings of the row.
    final rules = tester.widgetList<Divider>(find.byType(Divider)).length;
    expect(rules, 2);
  });
}
