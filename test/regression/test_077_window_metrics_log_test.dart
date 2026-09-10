import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/utils/window_events.dart';

/// GitHub #28: the log lines of the window size diagnostics.
void main() {
  test('an Android window event becomes one line with the sizes of every layer', () {
    expect(
      formatWindowEvent('flutterViewLayout', {
        'width': 1080,
        'height': 2280,
        'visibility': 0,
        'decorWidth': 1080,
        'decorHeight': 2340,
        'displayWidth': 1080,
        'displayHeight': 2340,
        'multiWindow': false,
      }),
      'window event: flutterViewLayout flutter view 1080x2280 visibility=0 multiWindow=false window 1080x2340 '
      'display 1080x2340',
    );
    expect(
      formatWindowEvent('multiWindowModeChanged', {
        'screenWidthDp': 360,
        'screenHeightDp': 400,
        'orientation': 1,
        'densityDpi': 420,
        'multiWindow': true,
        'decorWidth': 1080,
        'decorHeight': 1200,
        'displayWidth': 1080,
        'displayHeight': 2340,
      }),
      'window event: multiWindowModeChanged screen 360x400dp orientation=1 density=420 multiWindow=true '
      'window 1080x1200 display 1080x2340',
    );
    expect(formatWindowEvent('surfaceDestroyed', null), 'window event: surfaceDestroyed window ? display ?');
  });

  testWidgets('the view metrics line carries physical, logical, keyboard and padding sizes', (tester) async {
    tester.view
      ..physicalSize = const Size(1080, 2340)
      ..devicePixelRatio = 3
      ..viewInsets = const FakeViewPadding(bottom: 600)
      ..padding = const FakeViewPadding(top: 90, bottom: 45);
    addTearDown(tester.view.reset);
    expect(
      describeViewMetrics(tester.view),
      'view metrics: physical 1080x2340 dpr=3.0 logical 360.0x780.0 keyboard=200.0 padding(t/b)=30.0/15.0',
    );
  });

  testWidgets('the gate logs size, pixel ratio and padding changes and keyboard show/hide, not every inset step', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1080, 2340)
      ..devicePixelRatio = 3
      ..viewInsets = FakeViewPadding.zero
      ..padding = FakeViewPadding.zero;
    addTearDown(tester.view.reset);
    final gate = ViewMetricsLogGate();
    expect(gate.accept(tester.view), isTrue, reason: 'first metrics');
    expect(gate.accept(tester.view), isFalse, reason: 'nothing changed');

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    expect(gate.accept(tester.view), isTrue, reason: 'keyboard shown');
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    expect(gate.accept(tester.view), isFalse, reason: 'keyboard animation step');
    tester.view.viewInsets = FakeViewPadding.zero;
    expect(gate.accept(tester.view), isTrue, reason: 'keyboard hidden');

    tester.view.physicalSize = const Size(2340, 1080);
    expect(gate.accept(tester.view), isTrue, reason: 'rotated');
    tester.view.padding = const FakeViewPadding(top: 90);
    expect(gate.accept(tester.view), isTrue, reason: 'status bar');
    tester.view.devicePixelRatio = 2;
    expect(gate.accept(tester.view), isTrue, reason: 'density');
    expect(gate.accept(tester.view), isFalse);
  });
}
