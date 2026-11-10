/// A video of a floor the app plays itself ([PostVideo], [PostVideoPlayer]): a `<video>`, a `[media]` of a video
/// file or an HLS playlist and a video attachment; the players of sites (bilibili, YouTube) stay cards opening the
/// browser. Nothing loads before the player is tapped; its picture is held back as the pictures of the floor are; an
/// attachment is fetched (with the account's cookie) and played from the file, a stream from its address; one thing
/// plays at a time, a video or the sound player; the page closed stops it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_backend.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/features/image/widgets/post_image.dart';
import 'package:tsdm_client/features/video_player/controller/video_backend.dart';
import 'package:tsdm_client/features/video_player/controller/video_fetcher.dart';
import 'package:tsdm_client/features/video_player/models/post_video.dart';
import 'package:tsdm_client/features/video_player/widgets/post_video_player.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/utils/html/media_card.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

import 'render_regression/harness.dart' show registerFloorServices;

/// A floor of the test forum: an inline video attachment, `[media]` of an mp4, a webm, an m3u8 (the forum leaves
/// that one a link) and a video of bilibili, a video attachment listed below.
final String _floor = File('test/data/video_post_x5.html').readAsStringSync();

final class _VideoBackend implements VideoBackend {
  _VideoBackend(this.log);

  final List<String> log;
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);

  @override
  bool playing = false;

  @override
  bool loaded = false;

  String? opened;
  bool disposed = false;

  @override
  Future<void> open(String source) async {
    opened = source;
    log.add('open $source');
  }

  @override
  Future<void> play() async {
    playing = true;
    log.add('play $opened');
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    log.add('pause $opened');
    _playing.add(false);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    log.add('dispose $opened');
  }

  void fail(String message) => _errors.add(message);

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Widget buildView(
    BuildContext context, {
    required Future<void> Function() onEnterFullscreen,
    required Future<void> Function() onExitFullscreen,
  }) => const SizedBox.expand(key: ValueKey('video view'));
}

final class _VideoFetcher implements VideoFetcher {
  final fetched = <PostVideo>[];
  VideoFetchFailure? failure;

  @override
  Future<String> fetch(
    PostVideo video, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  }) async {
    fetched.add(video);
    onProgress?.call(0.5);
    if (failure case final failure?) {
      throw VideoFetchException(failure);
    }
    return '/cache/${video.aid}.mp4';
  }
}

final class _AudioBackend implements AudioBackend {
  @override
  Stream<bool> get playingStream => const Stream.empty();

  @override
  Stream<AudioBackendState> get stateStream => const Stream.empty();

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Future<Duration?> load(String path, AudioTrack track) async => const Duration(seconds: 6);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}
}

final class _AudioFetcher implements AudioFetcher {
  /// Holds the fetch until completed, when set.
  Completer<void>? gate;

  @override
  Future<String> fetch(
    AudioTrack track, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  }) async {
    await gate?.future;
    return '/cache/${track.id}';
  }
}

const _song = AudioTrack(
  id: 'attach:1',
  title: 'song.mp3',
  url: 'https://forum.test/a',
  source: AudioTrackSource.attachment,
);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('which videos the app plays', () {
    PostVideo? ofUrl(String url, {bool videoElement = false}) =>
        PostVideo.ofUrl(Uri.parse(url), videoElement: videoElement);
    PostVideo? ofHtml(String html) {
      final element = parseHtmlDocument('<body>$html</body>').body!.children.single;
      return PostVideo.ofMedia(PostMedia.of(element));
    }

    test('the address of a video file or an HLS playlist is streamed', () {
      for (final url in [
        'https://video.example.com/v/clip.mp4',
        'https://video.example.com/v/clip.WEBM',
        'https://video.example.com/v/clip.mov?t=1',
        'https://video.example.com/v/clip.mkv',
        'https://video.example.com/live/index.m3u8',
        // The forum's own static file: served without a cookie.
        'https://www.tsdm39.com/data/attachment/forum/202311/15/clip.mp4',
      ]) {
        final video = ofUrl(url);
        expect(video, isNotNull, reason: url);
        expect(video!.isAttachment, isFalse, reason: url);
        expect(video.url.toString(), url);
      }
      expect(ofUrl('https://video.example.com/v/clip.mp4')!.title, 'clip.mp4');
    });

    test('anything else is not', () {
      for (final url in [
        'https://video.example.com/v/song.mp3',
        'https://video.example.com/v/page.html',
        'https://video.example.com/v/',
        'ftp://video.example.com/v/clip.mp4',
        // An attachment-looking address of another site is no attachment: no cookie goes there, and it is no file.
        'https://forum.test/forum.php?mod=attachment&aid=MXwy',
      ]) {
        expect(ofUrl(url), isNull, reason: url);
      }
    });

    test('an attachment of the forum is fetched, at the canonical address', () {
      for (final url in [
        'https://www.tsdm39.com/forum.php?mod=attachment&aid=OTAwMDR8ZjFmMmYzZjR8MTcwMDAwMDAwMHwzMXwx',
        'http://tsdm39.com/forum.php?mod=attachment&aid=OTAwMDR8ZjFmMmYzZjR8MTcwMDAwMDAwMHwzMXwx',
      ]) {
        final video = ofUrl(url, videoElement: true)!;
        expect(video.aid, 90004);
        expect(video.url.toString(), startsWith('https://www.tsdm39.com/forum.php?mod=attachment&aid='));
      }
    });

    test('a <video> plays whatever it points at, with its poster', () {
      final video = ofHtml(
        '<video src="https://video.example.com/stream?id=1" poster="//img.example.com/p.jpg"></video>',
      );
      expect(video!.url.toString(), 'https://video.example.com/stream?id=1');
      expect(video.poster.toString(), 'https://img.example.com/p.jpg');
      expect(
        ofHtml(
          '<video controls><source src="/data/attachment/forum/a.webm" type="video/webm"></video>',
        )!.url.toString(),
        'https://www.tsdm39.com/data/attachment/forum/a.webm',
      );
    });

    test('the players of sites stay cards opening the browser', () {
      for (final html in [
        '<iframe src="https://player.bilibili.com/player.html?bvid=BV1xx411c7mD"></iframe>',
        '<iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>',
        '<embed src="https://example.com/player.swf" />',
        '<audio src="https://video.example.com/a.mp4"></audio>',
      ]) {
        expect(ofHtml(html), isNull, reason: html);
      }
      // A flash player of a video file, a frame of one: the file is played.
      expect(
        ofHtml(
          '<embed src="https://example.com/player.swf" flashvars="file=https://video.example.com/v/a.mp4" />',
        )!.url.toString(),
        'https://video.example.com/v/a.mp4',
      );
      expect(
        ofHtml('<iframe src="https://video.example.com/v/a.webm"></iframe>')!.url.toString(),
        'https://video.example.com/v/a.webm',
      );
      // A site's player is not taken for a file even when its path looks like one.
      expect(ofHtml('<video src="https://www.bilibili.com/x/clip.mp4"></video>'), isNull);
      expect(
        PostVideo.ofMedia(
          PostMedia.ofScript('detectPlayer("mp4_a", "mp4", "https://video.example.com/v/clip.mp4", "640", "360");')!,
        )!.url.toString(),
        'https://video.example.com/v/clip.mp4',
      );
    });

    test('the video attachments of a floor; an audio attachment is none', () {
      final doc = parseHtmlDocument(_floor);
      final videos = doc.querySelectorAll('ignore_js_op').map(PostVideo.attachmentOf).nonNulls.toList();
      expect(videos.map((e) => (e.aid, e.title, e.sizeText)), [
        (90004, 'clip.mp4', '23.95 KB'),
        (90005, 'listed.mp4', '23.95 KB'),
      ]);
      expect(
        videos.every((e) => e.url.toString().startsWith('https://www.tsdm39.com/forum.php?mod=attachment')),
        isTrue,
      );
      final audio = parseHtmlDocument(File('test/data/audio_attachment_post_x5.html').readAsStringSync());
      expect(audio.querySelectorAll('ignore_js_op').map(PostVideo.attachmentOf).nonNulls, isEmpty);
    });

    test('a file that is a video, a page that is not', () {
      expect(looksLikeVideo(File('test/data/attachment_head.jpg').readAsBytesSync()), isFalse);
      expect(looksLikeVideo(Uint8List.fromList([0, 0, 0, 0x1c, ...'ftypisom'.codeUnits])), isTrue);
      expect(looksLikeVideo(Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, 0x9F])), isTrue);
      expect(looksLikeVideo(Uint8List.fromList('<!DOCTYPE html>'.codeUnits)), isFalse);
    });
  });

  group('the player in the floor', () {
    late List<String> log;
    late List<_VideoBackend> backends;
    late _VideoFetcher fetcher;
    late _AudioFetcher audioFetcher;

    Future<void> pump(WidgetTester tester, Widget child) async {
      addTearDown(await registerFloorServices());
      addTearDown(VideoPlayback.reset);
      log = [];
      backends = [];
      fetcher = _VideoFetcher();
      VideoPlayback.backendFactory = () {
        final backend = _VideoBackend(log);
        backends.add(backend);
        return backend;
      };
      VideoPlayback.fetcher = fetcher;
      audioFetcher = _AudioFetcher();
      getIt.registerSingleton(AudioPlayerController(backend: _AudioBackend(), fetcher: audioFetcher));
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(400, 2400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PostTypographyScope(typography: const PostTypography(), child: child),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    List<PostVideo> players() =>
        find.byType(PostVideoPlayer).evaluate().map((e) => (e.widget as PostVideoPlayer).video).toList();

    testWidgets('each video of the floor is a player; nothing loads before a tap', (tester) async {
      await pump(tester, MunchedHtml(_floor));
      expect(players().map((e) => e.aid ?? e.url.toString()), [
        90004,
        'https://video.example.com/v/clip.mp4',
        'https://video.example.com/v/clip.webm',
        90005,
      ]);
      // The m3u8 the forum left a link stays one.
      expect(find.textContaining('index.m3u8', findRichText: true), findsOneWidget);
      expect(backends, isEmpty);
      expect(fetcher.fetched, isEmpty);
      // The file name and size of an attachment.
      expect(find.text('clip.mp4 · 23.95 KB'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a player in a table cell lays out', (tester) async {
      await pump(
        tester,
        const MunchedHtml(
          '<table><tr><td>预告</td><td><video src="https://video.example.com/v/a.mp4"></video></td></tr></table>',
        ),
      );
      expect(find.byType(PostVideoPlayer), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an attachment is fetched and played from the file; a stream from its address', (tester) async {
      await pump(tester, MunchedHtml(_floor));
      await tester.tap(find.byType(PostVideoPlayer).first);
      await tester.pump();
      await tester.pump();
      expect(fetcher.fetched.single.aid, 90004);
      expect(log, ['open /cache/90004.mp4', 'play /cache/90004.mp4']);
      expect(find.byKey(const ValueKey('video view')), findsOneWidget);

      // Another one: the first pauses, one plays at a time.
      await tester.tap(find.byType(PostVideoPlayer).at(1));
      await tester.pump();
      await tester.pump();
      expect(fetcher.fetched, hasLength(1));
      expect(log.skip(2), [
        'pause /cache/90004.mp4',
        'open https://video.example.com/v/clip.mp4',
        'play https://video.example.com/v/clip.mp4',
      ]);

      // The page closed: both stop.
      await finish(tester);
      expect(backends.every((e) => e.disposed), isTrue);
    });

    testWidgets('an attachment that is not given shows it cannot play, to try again or open', (tester) async {
      await pump(tester, MunchedHtml(_floor));
      fetcher.failure = VideoFetchFailure.notVideo;
      await tester.tap(find.byType(PostVideoPlayer).first);
      await tester.pump();
      await tester.pump();
      expect(find.text('无法播放'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('打开'), findsOneWidget);
      expect(backends, isEmpty);

      fetcher.failure = null;
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump();
      expect(log, ['open /cache/90004.mp4', 'play /cache/90004.mp4']);
      await finish(tester);
    });

    testWidgets('a stream that cannot be opened shows it cannot play, also after play was asked for', (tester) async {
      await pump(tester, PostVideoPlayer(PostVideo(url: _stream)));
      await tester.tap(find.byType(PostVideoPlayer));
      await tester.pump();
      // Asked to play at once; libmpv tells later that it cannot open it.
      expect(backends.single.playing, isTrue);
      backends.single.fail('loading failed');
      await tester.pump();
      expect(find.text('无法播放'), findsOneWidget);
      expect(backends.single.disposed, isTrue);
      await finish(tester);
    });

    testWidgets('an error once the video is open leaves the player as it is, paused or not', (tester) async {
      await pump(tester, PostVideoPlayer(PostVideo(url: _stream)));
      await tester.tap(find.byType(PostVideoPlayer));
      await tester.pump();
      backends.single.loaded = true;
      await backends.single.pause();
      backends.single.fail('segment failed');
      await tester.pump();
      expect(find.text('无法播放'), findsNothing);
      expect(find.byKey(const ValueKey('video view')), findsOneWidget);
      expect(backends.single.disposed, isFalse);
      await finish(tester);
    });

    testWidgets('a video pauses the sound player; a song started pauses the video', (tester) async {
      await pump(tester, MunchedHtml(_floor));
      final audio = getIt.get<AudioPlayerController>();
      await audio.playTrack(_song);
      expect(audio.state.status, AudioPlayerStatus.playing);

      await tester.tap(find.byType(PostVideoPlayer).at(1));
      await tester.pump();
      await tester.pump();
      expect(audio.state.status, AudioPlayerStatus.paused);
      expect(backends.single.playing, isTrue);

      await audio.toggle();
      await tester.pump();
      expect(audio.state.status, AudioPlayerStatus.playing);
      expect(backends.single.playing, isFalse);

      // Played again from its own controls: the song pauses again.
      await backends.single.play();
      await tester.pump();
      expect(audio.state.status, AudioPlayerStatus.paused);
      await finish(tester);
    });

    testWidgets('a song loading when a video starts is stopped', (tester) async {
      await pump(tester, MunchedHtml(_floor));
      final audio = getIt.get<AudioPlayerController>();
      final gate = audioFetcher.gate = Completer<void>();
      final loading = audio.playTrack(_song);
      expect(audio.state.status, AudioPlayerStatus.loading);
      await tester.tap(find.byType(PostVideoPlayer).at(1));
      await tester.pump();
      gate.complete();
      await loading;
      await tester.pump();
      expect(audio.state.queue, isNull);
      expect(backends.single.playing, isTrue);
      await finish(tester);
    });

    testWidgets('another page over it pauses it; the app in the background too', (tester) async {
      await pump(tester, MunchedHtml(_floor));
      await tester.tap(find.byType(PostVideoPlayer).at(1));
      await tester.pump();
      await tester.pump();
      expect(backends.single.playing, isTrue);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())));
      await tester.pumpAndSettle();
      expect(backends.single.playing, isFalse);
      navigator.pop();
      await tester.pumpAndSettle();

      await backends.single.play();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(backends.single.playing, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(backends.single.playing, isFalse);
      await finish(tester);
    });

    Widget withPoster(DataSaverMode dataSaver) => PostImageScope(
      images: FloorImages(),
      autoLoad: PostImageAutoLoad.always,
      dataSaver: dataSaver,
      child: const MunchedHtml(
        '<video src="https://video.example.com/v/a.mp4" poster="https://img.example.com/p.jpg"></video>',
      ),
    );

    testWidgets('its picture loads as the pictures of the floor', (tester) async {
      await pump(tester, withPoster(DataSaverMode.off));
      expect(find.byType(CachedImage), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the data saver holds its picture back; a tap still plays', (tester) async {
      await pump(tester, withPoster(DataSaverMode.always));
      expect(find.byType(CachedImage), findsNothing);
      expect(find.byType(PostVideoPlayer), findsOneWidget);
      await tester.tap(find.byType(PostVideoPlayer));
      await tester.pump();
      await tester.pump();
      expect(log, ['open https://video.example.com/v/a.mp4', 'play https://video.example.com/v/a.mp4']);
      await finish(tester);
    });
  });
}

final Uri _stream = Uri.parse('https://video.example.com/v/clip.mp4');
