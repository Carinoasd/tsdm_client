/// A video of a floor on the thread page ([PostVideoPlayer] under [ThreadReadingGestures]):
///
/// * a tap on the video (its box, its controls) is the player's: the page's tap (hiding the bars, a floor's tap to
///   reply) is not told; a tap beside it still is. The controls of media_kit show on the pointer ([Listener]) and
///   race a double tap only, which is what the fake view does.
/// * a speed chosen after the controls hid (the button gone with them) is applied.
/// * the play button of the box stands out of it in the light and in the dark.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/widgets/reading_gestures.dart';
import 'package:tsdm_client/features/video_player/controller/video_backend.dart';
import 'package:tsdm_client/features/video_player/models/post_video.dart';
import 'package:tsdm_client/features/video_player/widgets/post_video_player.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

final class _VideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast(sync: true);

  @override
  bool playing = false;

  @override
  bool get loaded => true;

  @override
  Future<void> open(String source) async {}

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> dispose() async {}

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => const Stream.empty();

  /// As the material controls of media_kit: shown on the pointer down, a double tap to seek in the arena.
  @override
  Widget buildView(
    BuildContext context, {
    required Future<void> Function() onEnterFullscreen,
    required Future<void> Function() onExitFullscreen,
  }) => Listener(
    onPointerDown: (_) {},
    child: GestureDetector(
      onDoubleTap: () {},
      child: const ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(key: ValueKey('video view')),
      ),
    ),
  );
}

final _video = PostVideo(url: Uri.parse('https://video.example.com/v/clip.mp4'));

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('a tap on the video is not the page tap', () {
    late int pageTaps;
    late int floorTaps;

    Future<void> pump(WidgetTester tester) async {
      addTearDown(VideoPlayback.reset);
      VideoPlayback.backendFactory = _VideoBackend.new;
      VideoPlayback.audio = () => null;
      pageTaps = 0;
      floorTaps = 0;
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ThreadReadingGestures(
                onTap: () => pageTaps++,
                child: ListView(
                  children: [
                    // The floor's own tap to reply, outside the video.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => floorTaps++,
                      child: Column(
                        children: [
                          PostVideoPlayer(_video),
                          const SizedBox(key: ValueKey('beside'), height: 200, width: 400),
                        ],
                      ),
                    ),
                    const SizedBox(key: ValueKey('below'), height: 400),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> tapAndSettle(WidgetTester tester, Finder finder, {Offset? at}) async {
      if (at != null) {
        await tester.tapAt(at);
      } else {
        await tester.tap(finder);
      }
      // Past the double tap of the controls.
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pump();
    }

    testWidgets('the controls, their edges, the box before it plays', (tester) async {
      await pump(tester);
      // The play button of the box: it starts the video, the page is not told.
      await tapAndSettle(tester, find.byType(PostVideoPlayer));
      expect(find.byKey(const ValueKey('video view')), findsOneWidget);
      expect((pageTaps, floorTaps), (0, 0));

      // The video playing, its controls: shown, hidden, shown again; never the page.
      await tapAndSettle(tester, find.byKey(const ValueKey('video view')));
      await tapAndSettle(tester, find.byKey(const ValueKey('video view')));
      expect((pageTaps, floorTaps), (0, 0));
      // Its corner (the edge the controls of media_kit leave out).
      final box = tester.getRect(find.byType(PostVideoPlayer));
      await tapAndSettle(tester, find.byType(PostVideoPlayer), at: box.topLeft + const Offset(4, 4));
      expect((pageTaps, floorTaps), (0, 0));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('beside the video the floor and the page are told', (tester) async {
      await pump(tester);
      await tapAndSettle(tester, find.byKey(const ValueKey('beside')));
      expect((pageTaps, floorTaps), (0, 1));
      await tapAndSettle(tester, find.byKey(const ValueKey('below')));
      expect((pageTaps, floorTaps), (1, 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets('a speed chosen after the controls hid is applied', (tester) async {
    final rate = StreamController<double>.broadcast();
    addTearDown(rate.close);
    final chosen = <double>[];
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: ValueListenableBuilder(
                valueListenable: shown,
                builder: (context, value, _) => value
                    ? VideoSpeedButton(rate: rate.stream, initialRate: 1, onChanged: chosen.add)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('1x'));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);

    // The controls hide, the menu stays open.
    shown.value = false;
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(VideoSpeedButton), findsNothing);
    expect(find.text('1.5x'), findsOneWidget);

    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(chosen, [1.5]);
  });

  testWidgets('the play button stands out in the light and in the dark', (tester) async {
    addTearDown(VideoPlayback.reset);
    for (final brightness in Brightness.values) {
      final theme = ThemeData(colorSchemeSeed: Colors.blue, brightness: brightness);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            // Anew, not the theme of the one before animating to this one.
            key: ValueKey(brightness),
            theme: theme,
            home: Scaffold(body: Center(child: PostVideoPlayer(_video))),
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.play_arrow_rounded));
      final circle = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((e) => e.decoration)
          .whereType<BoxDecoration>()
          .singleWhere((e) => e.shape == BoxShape.circle);
      final box = theme.colorScheme.surfaceContainerHighest;
      expect(_contrast(icon.color!, circle.color!), greaterThan(4.5), reason: '$brightness icon');
      expect(_contrast(circle.color!, box), greaterThan(3), reason: '$brightness circle');
    }
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}
