import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/image/widgets/post_image.dart';

void main() {
  testWidgets('a small picture keeps its own width under a tight parent', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: NoUpscale(
              maxWidth: 20,
              child: ColoredBox(key: Key('pic'), color: Colors.red, child: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('pic'))).width, 20);
  });

  testWidgets('without a known width the picture takes what the parent gives, up to its own size', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(width: 300, child: NoUpscale(child: SizedBox(width: 500, height: 10))),
        ),
      ),
    );
    expect(tester.getSize(find.byType(NoUpscale)).width, 300);
  });
}
