import 'package:flutter/material.dart';
import 'package:tsdm_client/features/thread/v1/tts/thread_tts_controller.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The speeds offered, [ttsMinRate] to [ttsMaxRate].
const ttsRateSteps = <double>[0.8, 0.9, 1, 1.1, 1.25, 1.5];

/// Controls of the reader at the bottom of the thread page: previous floor, pause, next floor, speed, close.
class ThreadTtsBar extends StatelessWidget {
  /// Constructor.
  const ThreadTtsBar({required this.controller, this.safeBottom = false, super.key});

  /// The reader the bar controls.
  final ThreadTtsController controller;

  /// Whether the bar keeps off the bottom inset of the system itself (nothing below it does).
  final bool safeBottom;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadTts;
    final colorScheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.active) {
          return const SizedBox.shrink();
        }
        final status = controller.status;
        return ColoredBox(
          color: colorScheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            bottom: safeBottom,
            child: AppContentWidth(
              maxWidth: appReadingMaxWidth,
              child: Row(
                key: const ValueKey('thread-tts-bar'),
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    key: const ValueKey('thread-tts-previous'),
                    tooltip: tr.previous,
                    icon: const Icon(Icons.skip_previous_outlined),
                    onPressed: controller.previous,
                  ),
                  if (status == TtsStatus.waitingPage)
                    const SizedBox.square(
                      dimension: 48,
                      child: Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    )
                  else
                    IconButton.filled(
                      key: const ValueKey('thread-tts-toggle'),
                      tooltip: status == TtsStatus.paused ? tr.resume : tr.pause,
                      icon: Icon(status == TtsStatus.paused ? Icons.play_arrow : Icons.pause),
                      onPressed: status == TtsStatus.paused ? controller.resume : controller.pause,
                    ),
                  IconButton(
                    key: const ValueKey('thread-tts-next'),
                    tooltip: tr.next,
                    icon: const Icon(Icons.skip_next_outlined),
                    onPressed: controller.next,
                  ),
                  PopupMenuButton<double>(
                    key: const ValueKey('thread-tts-rate'),
                    tooltip: tr.rate,
                    initialValue: controller.rate,
                    onSelected: controller.setRate,
                    itemBuilder: (context) => [
                      for (final step in ttsRateSteps) PopupMenuItem(value: step, child: Text('${step}x')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      child: Text('${controller.rate}x', style: Theme.of(context).textTheme.labelLarge),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('thread-tts-close'),
                    tooltip: tr.close,
                    icon: const Icon(Icons.close),
                    onPressed: controller.stop,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
