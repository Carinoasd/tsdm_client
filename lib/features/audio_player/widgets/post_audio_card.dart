import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/audio_player/utils/audio_attachment.dart';
import 'package:tsdm_client/features/audio_player/widgets/audio_controls.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/platform.dart';

/// An audio attachment of a floor ([PostAudioAttachment]) the app plays itself: its name, a button to play it, where
/// it is and its length while it is the one played, a button to download it as before.
///
/// Played in a thread, the audio attachments of the floors after it play after it.
class PostAudioCard extends StatelessWidget {
  /// Constructor.
  const PostAudioCard(this.attachment, {required this.onDownload, super.key});

  /// The attachment.
  final PostAudioAttachment attachment;

  /// Download it as a link to it does.
  final VoidCallback onDownload;

  Future<void> _play(BuildContext context) async {
    final thread = context.readOrNull<ThreadBloc>()?.state;
    final apple = isIOS || isMacOS;
    final track = attachment.toTrack(tid: thread?.tid, threadTitle: thread?.title);
    final all = thread == null
        ? null
        : audioTracksOfPosts(thread.postList, tid: thread.tid, threadTitle: thread.title, apple: apple);
    await AudioPlayerController.instance.playTrack(track, queue: all);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.audioPlayer;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final track = attachment.toTrack();
    final info = [?attachment.sizeText, ?attachment.description].join(' · ');
    final shape = RoundedRectangleBorder(
      side: BorderSide(color: colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
          child: Row(
            children: [
              AudioPlayButton(track: track, onPressed: () async => _play(context)),
              const SizedBox(width: 12),
              Expanded(
                child: BlocBuilder<AudioPlayerController, AudioPlayerState>(
                  bloc: AudioPlayerController.instance,
                  buildWhen: (prev, curr) => prev.isCurrent(track) || curr.isCurrent(track),
                  builder: (context, state) {
                    final current = state.isCurrent(track);
                    final duration = state.duration;
                    final Widget second;
                    if (current && state.status == AudioPlayerStatus.failed) {
                      second = Text(
                        audioFailureText(context, state.failure),
                        style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
                      );
                    } else if (current && duration != null && state.status != AudioPlayerStatus.loading) {
                      second = AudioSeekBar(duration: duration);
                    } else if (info.isNotEmpty) {
                      second = Text(info, style: textTheme.bodySmall?.copyWith(color: colorScheme.outline));
                    } else {
                      second = const SizedBox.shrink();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          attachment.filename,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(color: current ? colorScheme.primary : null),
                        ),
                        second,
                      ],
                    );
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.download_outlined),
                tooltip: tr.download,
                onPressed: onDownload,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
