import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart' show defaultEnterNativeFullscreen, defaultExitNativeFullscreen;
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/image/widgets/post_image.dart';
import 'package:tsdm_client/features/video_player/controller/video_backend.dart';
import 'package:tsdm_client/features/video_player/controller/video_fetcher.dart';
import 'package:tsdm_client/features/video_player/models/post_video.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:url_launcher/url_launcher.dart';

/// The one video playing in the app, and the sound player kept silent while it plays: one thing plays at a time.
abstract final class VideoPlayback {
  /// What makes the backend of a player (tests give a fake one).
  @visibleForTesting
  static VideoBackend Function() backendFactory = MediaKitVideoBackend.new;

  /// What fetches the attachments (tests give a fake one).
  @visibleForTesting
  static VideoFetcher fetcher = NetVideoFetcher();

  /// The app's sound player, null when there is none to keep silent.
  ///
  /// The one of the app ([AudioPlayerController.instance]): made when not made yet (its player is made when it first
  /// plays), so that a song started while a video plays is heard of.
  @visibleForTesting
  static AudioPlayerController? Function() audio = () => AudioPlayerController.instance;

  static _PostVideoPlayerState? _current;

  /// Put the defaults back (tests).
  @visibleForTesting
  static void reset() {
    backendFactory = MediaKitVideoBackend.new;
    fetcher = NetVideoFetcher();
    audio = () => AudioPlayerController.instance;
    _current = null;
  }

  /// [player] plays: the video that played before pauses, the sound player pauses (one that loads stops).
  static Future<void> _claim(_PostVideoPlayerState player) async {
    final previous = _current;
    _current = player;
    if (previous != null && !identical(previous, player)) {
      await previous._pause();
    }
    await pauseAudio();
  }

  static void _release(_PostVideoPlayerState player) {
    if (identical(_current, player)) {
      _current = null;
    }
  }

  /// Keep the sound player silent: pause what it plays, stop what it loads (it would play when loaded).
  static Future<void> pauseAudio() async {
    final audio = VideoPlayback.audio();
    if (audio == null) {
      return;
    }
    switch (audio.state.status) {
      case AudioPlayerStatus.playing:
        await audio.toggle();
      case AudioPlayerStatus.loading:
        await audio.dismiss();
      case AudioPlayerStatus.idle ||
          AudioPlayerStatus.paused ||
          AudioPlayerStatus.completed ||
          AudioPlayerStatus.failed:
        break;
    }
  }
}

enum _Status { idle, loading, ready, failed }

/// A video of a floor the app plays itself ([PostVideo]), where it is in the floor.
///
/// Before it is tapped it is a box of the video's shape with its picture (`<video poster>`, held back as the pictures
/// of the floor are, [DataSaver]) and a play button: nothing of the video is loaded. Tapped, an attachment is fetched
/// (its progress shown) and played from the file, a stream is played from its address.
///
/// One plays at a time ([VideoPlayback]): starting one pauses the one playing and the sound player, a song started
/// pauses the video. It pauses when the page is left for another page (not for its own fullscreen page) and when the
/// app goes to the background, and stops when the page closes (or the floor is scrolled far enough away to be let go).
class PostVideoPlayer extends StatefulWidget {
  /// Constructor.
  const PostVideoPlayer(this.video, {this.onOpen, super.key});

  /// The video.
  final PostVideo video;

  /// Opens the video outside the app when it cannot be played (the download of an attachment); null opens its
  /// address in the browser.
  final VoidCallback? onOpen;

  /// Widest it goes.
  static const maxWidth = 560.0;

  @override
  State<PostVideoPlayer> createState() => _PostVideoPlayerState();
}

class _PostVideoPlayerState extends State<PostVideoPlayer> with WidgetsBindingObserver {
  _Status _status = _Status.idle;
  double? _progress;
  VideoFetchFailure? _failure;

  VideoBackend? _backend;
  CancelToken? _cancelToken;
  final _subscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<AudioPlayerState>? _audioSubscription;

  /// Bumped at each start and at dispose: what a former start finishes later is dropped.
  int _generation = 0;

  bool _fullscreen = false;
  bool _foreground = true;
  bool _onstage = true;

  /// Whether it may play now: in the foreground, on the page shown (or fullscreen).
  bool get _mayPlay => _foreground && (_onstage || _fullscreen);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Another page over this one hides it, its own fullscreen page too (told apart by [_fullscreen]); a menu or a
    // dialog over it does not.
    _onstage = TickerMode.valuesOf(context).enabled;
    if (!_mayPlay) {
      unawaited(_pause());
    }
  }

  @override
  void didUpdateWidget(PostVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video != widget.video) {
      unawaited(_stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (!_foreground) {
      // Not played on in the background.
      unawaited(_pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stop(rebuild: false));
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    await _release();
    _cancelToken?.cancel();
    final cancelToken = _cancelToken = CancelToken();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = _Status.loading;
      _progress = null;
      _failure = null;
    });
    // Silent at once, not when the video is loaded.
    await VideoPlayback._claim(this);
    if (generation != _generation || !mounted) {
      return;
    }
    try {
      final String source;
      if (widget.video.isAttachment) {
        source = await VideoPlayback.fetcher.fetch(
          widget.video,
          cancelToken: cancelToken,
          onProgress: (progress) {
            if (generation == _generation && mounted && _status == _Status.loading) {
              setState(() => _progress = progress);
            }
          },
        );
      } else {
        source = widget.video.url.toString();
      }
      if (generation != _generation || !mounted) {
        return;
      }
      final backend = _backend = VideoPlayback.backendFactory();
      _subscriptions
        ..add(backend.playingStream.listen(_onPlaying))
        ..add(backend.errorStream.listen(_onError));
      await backend.open(source);
      if (generation != _generation || !mounted) {
        return;
      }
      setState(() => _status = _Status.ready);
      if (_mayPlay) {
        await VideoPlayback._claim(this);
        await backend.play();
      }
    } on VideoFetchException catch (e) {
      _fail(generation, e.failure);
    } on DioException {
      // Cancelled for a former start (another one, or let go): dropped. Anything else is this one failing.
      _fail(generation, VideoFetchFailure.network);
    } on Object catch (e, st) {
      talker.handle(e, st, 'failed to play video ${widget.video}');
      _fail(generation, null);
    }
  }

  void _fail(int generation, VideoFetchFailure? failure) {
    if (generation != _generation || !mounted) {
      return;
    }
    unawaited(_release());
    setState(() {
      _status = _Status.failed;
      _failure = failure;
    });
  }

  void _onPlaying(bool playing) {
    if (!playing) {
      return;
    }
    if (!_mayPlay) {
      unawaited(_pause());
      return;
    }
    // Played from its own controls.
    unawaited(VideoPlayback._claim(this));
    _followAudio();
  }

  void _onError(String message) {
    talker.warning('video player: $message');
    // Before it played: what is there to play cannot be played. A hiccup while it plays is left to the player.
    if (_status == _Status.ready && !(_backend?.playing ?? false)) {
      _fail(_generation, null);
    }
  }

  /// A song started while this plays pauses this.
  void _followAudio() {
    if (_audioSubscription != null) {
      return;
    }
    final audio = VideoPlayback.audio();
    _audioSubscription = audio?.stream.listen((state) {
      if (state.status == AudioPlayerStatus.playing || state.status == AudioPlayerStatus.loading) {
        unawaited(_pause());
      }
    });
  }

  Future<void> _pause() async {
    final backend = _backend;
    if (backend != null && backend.playing) {
      await backend.pause();
    }
  }

  /// Free the player, keep the box as it is.
  Future<void> _release() async {
    VideoPlayback._release(this);
    // Taken at once: a start right after makes its own.
    final backend = _backend;
    _backend = null;
    // Not waited for: the player is freed at once.
    unawaited(_audioSubscription?.cancel());
    _audioSubscription = null;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    try {
      await backend?.dispose();
    } on Object catch (e, st) {
      talker.handle(e, st, 'failed to free the video player');
    }
  }

  /// Back to the box before it was tapped.
  Future<void> _stop({bool rebuild = true}) async {
    _generation++;
    _cancelToken?.cancel();
    _cancelToken = null;
    if (rebuild && mounted) {
      setState(() {
        _status = _Status.idle;
        _failure = null;
      });
    }
    await _release();
  }

  Future<void> _open() async {
    if (widget.onOpen case final onOpen?) {
      onOpen();
      return;
    }
    await launchUrl(widget.video.url, mode: LaunchMode.externalApplication);
  }

  /// Whether the picture before it plays loads: as the pictures of the floor do.
  bool _posterLoads(BuildContext context) {
    final scope = PostImageScope.maybeOf(context);
    if (DataSaver.holdsBack(context, scope?.dataSaver ?? DataSaverMode.off) ?? true) {
      return false;
    }
    return switch (scope?.autoLoad ?? PostImageAutoLoad.always) {
      PostImageAutoLoad.always => true,
      PostImageAutoLoad.wifiOnly => NetworkUsage.unmetered.value ?? false,
      PostImageAutoLoad.never => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = switch (_status) {
      _Status.ready when _backend != null => _backend!.buildView(
        context,
        onEnterFullscreen: () async {
          _fullscreen = true;
          await defaultEnterNativeFullscreen();
        },
        onExitFullscreen: () async {
          _fullscreen = false;
          await defaultExitNativeFullscreen();
        },
      ),
      _Status.loading => _buildLoading(context),
      _Status.failed => _buildFailed(context),
      _ => _buildIdle(context),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: PostVideoPlayer.maxWidth),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(color: colorScheme.surfaceContainerHighest, child: content),
        ),
      ),
    );
  }

  /// The caption over the bottom of the box: the file name and size.
  Widget? _caption(BuildContext context) {
    final text = [?widget.video.title, ?widget.video.sizeText].join(' · ');
    if (text.isEmpty) {
      return null;
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black54],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildIdle(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final poster = widget.video.poster;
    final caption = _caption(context);
    return Semantics(
      button: true,
      label: [context.t.videoPlayer.play, ?widget.video.title].join(' '),
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: _start,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (poster != null && _posterLoads(context))
                CachedImage(
                  poster.toString(),
                  fit: BoxFit.cover,
                  enableAnimation: false,
                  placeholderBuilder: (_, _) => const SizedBox.shrink(),
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.play_arrow_rounded, size: 40, color: colorScheme.surface),
                  ),
                ),
              ),
              ?caption,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    final caption = _caption(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(child: CircularProgressIndicator(value: _progress)),
        ?caption,
      ],
    );
  }

  Widget _buildFailed(BuildContext context) {
    final tr = context.t.videoPlayer;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final text = _failure == VideoFetchFailure.network ? tr.loadFailed : tr.cannotPlay;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: textTheme.bodyMedium?.copyWith(color: colorScheme.error)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              TextButton.icon(onPressed: _start, icon: const Icon(Icons.refresh), label: Text(tr.retry)),
              TextButton.icon(onPressed: _open, icon: const Icon(Icons.open_in_new), label: Text(tr.open)),
            ],
          ),
        ],
      ),
    );
  }
}
