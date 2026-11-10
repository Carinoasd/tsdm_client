import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// What plays a video of a floor and shows it. Tests give a fake one.
abstract interface class VideoBackend {
  /// Load [source] (a local file or an address to stream), paused.
  Future<void> open(String source);

  /// Play.
  Future<void> play();

  /// Pause.
  Future<void> pause();

  /// Stop and free it; not used after.
  Future<void> dispose();

  /// Whether it plays now (asked to: it says so before the video is open).
  bool get playing;

  /// Whether the video is open: its length or its picture size is known.
  bool get loaded;

  /// Whether it plays, each time that changes.
  Stream<bool> get playingStream;

  /// What went wrong while playing (the stream cannot be opened, the file cannot be read).
  Stream<String> get errorStream;

  /// The video with its controls: play and pause, where it is, volume, speed, fullscreen. [onEnterFullscreen] and
  /// [onExitFullscreen] are told when it goes fullscreen (a page of its own) and back.
  Widget buildView(
    BuildContext context, {
    required Future<void> Function() onEnterFullscreen,
    required Future<void> Function() onExitFullscreen,
  });
}

/// Set up libmpv once, the first time a video is played: nothing is loaded for it before (on Windows and Linux the
/// sound player did it already at start, the second call does nothing).
void ensureVideoPlayerInitialized() => MediaKit.ensureInitialized();

/// [VideoBackend] of media_kit: libmpv plays, [Video] shows it with the material controls (the desktop ones on the
/// desktop platforms).
final class MediaKitVideoBackend implements VideoBackend {
  /// Constructor. Throws when libmpv cannot be loaded.
  MediaKitVideoBackend() {
    ensureVideoPlayerInitialized();
    _player = Player();
    _controller = VideoController(_player);
  }

  late final Player _player;
  late final VideoController _controller;

  @override
  Future<void> open(String source) => _player.open(Media(source), play: false);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  /// Freed: a speed chosen from a menu still open is dropped.
  bool _disposed = false;

  Future<void> _setRate(double rate) async {
    if (!_disposed) {
      await _player.setRate(rate);
    }
  }

  @override
  Future<void> dispose() {
    _disposed = true;
    return _player.dispose();
  }

  @override
  bool get playing => _player.state.playing;

  @override
  bool get loaded => _player.state.duration > Duration.zero || _player.state.width != null;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  Widget buildView(
    BuildContext context, {
    required Future<void> Function() onEnterFullscreen,
    required Future<void> Function() onExitFullscreen,
  }) {
    final speed = VideoSpeedButton(rate: _player.stream.rate, initialRate: _player.state.rate, onChanged: _setRate);
    final mobile = MaterialVideoControlsThemeData(
      // In a page that scrolls the gestures stay off (their default): a drag scrolls it.
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        _MuteButton(player: _player),
        speed,
        const MaterialFullscreenButton(),
      ],
    );
    final desktop = MaterialDesktopVideoControlsThemeData(
      // In a page that scrolls: the wheel scrolls it.
      modifyVolumeOnScroll: false,
      bottomButtonBar: [
        const MaterialDesktopPlayOrPauseButton(),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        speed,
        const MaterialDesktopFullscreenButton(),
      ],
    );
    return MaterialVideoControlsTheme(
      normal: mobile,
      fullscreen: mobile,
      child: MaterialDesktopVideoControlsTheme(
        normal: desktop,
        fullscreen: desktop,
        child: Video(
          controller: _controller,
          onEnterFullscreen: onEnterFullscreen,
          onExitFullscreen: onExitFullscreen,
        ),
      ),
    );
  }
}

/// The speeds to choose from.
const videoSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// `1.25x`, `2x`.
String videoSpeedLabel(double speed) {
  final text = speed == speed.roundToDouble() ? speed.toStringAsFixed(0) : speed.toString();
  return '${text}x';
}

/// Chooses the speed of a video: [rate] is the speed now (from [initialRate]), [onChanged] is told the one chosen.
///
/// The choice is applied when the button is gone already: the controls hide a few seconds after the last touch,
/// a menu open or not, and take the button with them.
@visibleForTesting
class VideoSpeedButton extends StatelessWidget {
  /// Constructor.
  const VideoSpeedButton({required this.rate, required this.initialRate, required this.onChanged, super.key});

  /// The speed, each time it changes.
  final Stream<double> rate;

  /// The speed before [rate] tells one.
  final double initialRate;

  /// The speed chosen.
  final ValueChanged<double> onChanged;

  Future<void> _choose(BuildContext context, double current) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final value = await showMenu<double>(
      context: context,
      position: position,
      initialValue: current,
      items: [for (final speed in videoSpeeds) PopupMenuItem(value: speed, child: Text(videoSpeedLabel(speed)))],
    );
    // Not [PopupMenuButton]: it drops what is chosen once it is unmounted.
    if (value != null) {
      onChanged(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: rate,
      initialData: initialRate,
      builder: (context, snapshot) {
        final current = snapshot.data ?? 1.0;
        return Tooltip(
          message: context.t.videoPlayer.speed,
          child: InkWell(
            onTap: () async => _choose(context, current),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Text(
                videoSpeedLabel(current),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Turns the sound of [player] off and back on, on the phones (the desktop controls have their volume bar).
class _MuteButton extends StatefulWidget {
  const _MuteButton({required this.player});

  final Player player;

  @override
  State<_MuteButton> createState() => _MuteButtonState();
}

class _MuteButtonState extends State<_MuteButton> {
  /// The volume before it was turned off.
  double _restore = 100;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.videoPlayer;
    return StreamBuilder<double>(
      stream: widget.player.stream.volume,
      initialData: widget.player.state.volume,
      builder: (context, snapshot) {
        final volume = snapshot.data ?? 100;
        final muted = volume <= 0;
        return IconButton(
          tooltip: muted ? tr.unmute : tr.mute,
          color: Colors.white,
          icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
          onPressed: () async {
            if (muted) {
              await widget.player.setVolume(_restore);
            } else {
              _restore = volume;
              await widget.player.setVolume(0);
            }
          },
        );
      },
    );
  }
}
