import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The button that plays [track] (or pauses it, or tries it again) with the state of the player for it: a ring
/// filling up while it is fetched.
class AudioPlayButton extends StatelessWidget {
  /// Constructor.
  const AudioPlayButton({required this.track, required this.onPressed, this.size = 40, super.key});

  /// What it plays.
  final AudioTrack track;

  /// Pressed.
  final VoidCallback onPressed;

  /// Its size.
  final double size;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.audioPlayer;
    return BlocBuilder<AudioPlayerController, AudioPlayerState>(
      bloc: AudioPlayerController.instance,
      buildWhen: (prev, curr) => prev.isCurrent(track) || curr.isCurrent(track),
      builder: (context, state) {
        final status = state.isCurrent(track) ? state.status : AudioPlayerStatus.idle;
        final colorScheme = Theme.of(context).colorScheme;
        final (IconData icon, String label) = switch (status) {
          AudioPlayerStatus.playing => (Icons.pause, tr.pause),
          AudioPlayerStatus.failed => (Icons.refresh, tr.play),
          _ => (Icons.play_arrow, tr.play),
        };
        final iconSize = size * 0.6;
        final child = status == AudioPlayerStatus.loading
            ? SizedBox.square(
                dimension: iconSize,
                child: CircularProgressIndicator(value: state.progress, strokeWidth: 2.5),
              )
            : Icon(icon, size: iconSize, color: status == AudioPlayerStatus.failed ? colorScheme.error : null);
        return Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: SizedBox.square(
            dimension: size,
            child: IconButton.filledTonal(
              padding: EdgeInsets.zero,
              onPressed: onPressed,
              icon: child,
            ),
          ),
        );
      },
    );
  }
}

/// Why [failure] stopped a track, in a few words.
String audioFailureText(BuildContext context, AudioFetchFailure? failure) => switch (failure) {
  AudioFetchFailure.network => context.t.audioPlayer.loadFailed,
  AudioFetchFailure.notAudio || null => context.t.audioPlayer.cannotPlay,
};

/// `m:ss`, `h:mm:ss` from an hour.
String formatAudioDuration(Duration d) {
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (d.inHours > 0) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours}:$minutes:$seconds';
  }
  return '${d.inMinutes}:$seconds';
}

/// Where the current track is (a bar to drag) and its length.
class AudioSeekBar extends StatefulWidget {
  /// Constructor.
  const AudioSeekBar({required this.duration, super.key});

  /// The length of the current track.
  final Duration duration;

  @override
  State<AudioSeekBar> createState() => _AudioSeekBarState();
}

class _AudioSeekBarState extends State<AudioSeekBar> {
  /// Where the bar is dragged to, while it is.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final controller = AudioPlayerController.instance;
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.outline,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final max = widget.duration.inMilliseconds.toDouble();
    return StreamBuilder<Duration>(
      stream: controller.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final value = (_dragging ?? position.inMilliseconds.toDouble()).clamp(0.0, max > 0 ? max : 0.0);
        return Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: value,
                  max: max > 0 ? max : 1,
                  onChanged: max > 0 ? (v) => setState(() => _dragging = v) : null,
                  onChangeEnd: max > 0
                      ? (v) async {
                          setState(() => _dragging = null);
                          await controller.seek(Duration(milliseconds: v.round()));
                        }
                      : null,
                ),
              ),
            ),
            Text(
              '${formatAudioDuration(Duration(milliseconds: value.round()))} / ${formatAudioDuration(widget.duration)}',
              style: textStyle,
            ),
          ],
        );
      },
    );
  }
}
