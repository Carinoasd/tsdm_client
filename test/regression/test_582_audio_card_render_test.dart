/// A floor's audio attachments are cards that play them in the app ([PostAudioCard]): the inline ones and the listed
/// one, an attachment to buy and a file that is not audio left as the forum prints them; the play button of a card
/// plays its attachment, its download button opens the attachment as its link did; a link to a song of NetEase Cloud
/// Music has a mark that plays it ([NeteasePlayMark]); the mini player shows what plays and closes.
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_backend.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/features/audio_player/widgets/audio_mini_player.dart';
import 'package:tsdm_client/features/audio_player/widgets/netease_play.dart';
import 'package:tsdm_client/features/audio_player/widgets/post_audio_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

import 'render_regression/harness.dart' show registerFloorServices;

final class _Backend implements AudioBackend {
  final loaded = <String>[];

  @override
  Stream<bool> get playingStream => const Stream.empty();

  @override
  Stream<AudioBackendState> get stateStream => const Stream.empty();

  @override
  Stream<Duration> get positionStream => Stream.value(const Duration(seconds: 3));

  @override
  Future<Duration?> load(String path, AudioTrack track) async {
    loaded.add(path);
    return const Duration(seconds: 6);
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}
}

final class _Fetcher implements AudioFetcher {
  final fetched = <AudioTrack>[];

  @override
  Future<String> fetch(
    AudioTrack track, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  }) async {
    fetched.add(track);
    return '/cache/${track.id}';
  }
}

final String _floor = File('test/data/audio_attachment_post_x5.html').readAsStringSync();

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _Backend backend;
  late _Fetcher fetcher;

  Future<void> pump(WidgetTester tester, String html) async {
    addTearDown(await registerFloorServices());
    backend = _Backend();
    fetcher = _Fetcher();
    getIt.registerSingleton(AudioPlayerController(backend: backend, fetcher: fetcher));
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(400, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => AudioMiniPlayerHost(child: child!),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PostTypographyScope(typography: const PostTypography(), child: MunchedHtml(html)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  /// Let the requests of the file type icons (offline) end.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('each audio attachment is a card; the others stay as printed', (tester) async {
    await pump(tester, _floor);
    final cards = find.byType(PostAudioCard).evaluate().map((e) => (e.widget as PostAudioCard).attachment).toList();
    expect(cards.map((e) => e.aid), [1610, 1608, 1609]);
    expect(find.text('测试 歌曲.mp3'), findsOneWidget);
    expect(find.textContaining('35.23 KB · 第二首'), findsOneWidget);
    // Not cards: a link each, as before.
    expect(find.textContaining('paid.mp3', findRichText: true), findsOneWidget);
    expect(find.textContaining('pack.zip', findRichText: true), findsOneWidget);
    // The link to a song of NetEase Cloud Music.
    expect(find.byType(NeteasePlayMark), findsOneWidget);
    await finish(tester);
  });

  testWidgets('play plays the card; the mini player shows it and closes', (tester) async {
    await pump(tester, _floor);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.descendant(of: find.byType(PostAudioCard).at(1), matching: find.byType(IconButton)).first);
    await tester.pump();
    await tester.pump();
    expect(fetcher.fetched.map((e) => e.id), ['attach:1608']);
    expect(backend.loaded, ['/cache/attach:1608']);
    final controller = getIt.get<AudioPlayerController>();
    expect(controller.state.status, AudioPlayerStatus.playing);
    // The card shows where it is and the length; the mini player its name.
    expect(find.text('0:03 / 0:06'), findsOneWidget);
    expect(find.text('sine_b.flac'), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(controller.state.queue, isNull);
    expect(find.text('sine_b.flac'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a card in a table cell, in a table wider than the screen', (tester) async {
    const block =
        '<ignore_js_op><img src="static/image/filetype/av.gif" class="vm" /><span id="attach_7">'
        '<a href="forum.php?mod=attachment&amp;aid=7">a.mp3</a> <em class="xg1">(1.00 MB, 下载次数: 0)</em>'
        '</span></ignore_js_op>';
    await pump(
      tester,
      '<table><tr><td>曲目</td><td>$block</td></tr></table>'
      '<table width="1600"><tr><td>1</td><td>2</td><td>3</td><td>$block</td></tr></table>',
    );
    expect(find.byType(PostAudioCard), findsNWidgets(2));
    await finish(tester);
  });

  testWidgets('a link to a song of NetEase Cloud Music plays from its outer url', (tester) async {
    await pump(tester, '<a href="https://music.163.com/#/song?id=186016" target="_blank">晴天</a>');
    await tester.tap(find.byType(NeteasePlayMark));
    await tester.pump();
    await tester.pump();
    expect(fetcher.fetched.single.url, 'https://music.163.com/song/media/outer/url?id=186016.mp3');
    expect(fetcher.fetched.single.title, '晴天');
    unawaited(getIt.get<AudioPlayerController>().dismiss());
    await tester.pump();
  });
}
