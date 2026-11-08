import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/thread_link_card/models/thread_link_card_info.dart';
import 'package:tsdm_client/features/thread_link_card/repository/thread_link_card_repository.dart';
import 'package:tsdm_client/features/thread_link_card/utils/thread_link.dart';

/// A thread a link in a post's content leads to was loaded and can be drawn as its card ([ThreadLinkCardTrigger]):
/// the html holding the link is munched again, the link then a [ThreadLinkCard].
class ThreadLinkCardLoaded extends Notification {
  /// Constructor.
  const ThreadLinkCardLoaded(this.tid);

  /// The thread loaded.
  final int tid;
}

/// Loads the thread [tid] of a link in a post's content ([threadLinkOf]) once it comes into view, and tells the html
/// around when it can be drawn as a card ([ThreadLinkCardLoaded]). Nothing to see: it is put before the link, which
/// stays as it was until then, and stays so when the account can not read the thread or the request failed.
class ThreadLinkCardTrigger extends StatefulWidget {
  /// Constructor.
  const ThreadLinkCardTrigger(this.tid, {super.key});

  /// The thread linked.
  final int tid;

  @override
  State<ThreadLinkCardTrigger> createState() => _ThreadLinkCardTriggerState();
}

class _ThreadLinkCardTriggerState extends State<ThreadLinkCardTrigger> {
  /// The thread was asked: the trigger no longer watches whether it is in view.
  bool _requested = false;

  ScrollPosition? _position;
  bool _checkScheduled = false;

  ThreadLinkCardRepository get _repository => ThreadLinkCardRepository.instance;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) => _watch());
  }

  @override
  void didUpdateWidget(ThreadLinkCardTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tid != widget.tid) {
      _unwatch();
      _requested = false;
      SchedulerBinding.instance.addPostFrameCallback((_) => _watch());
    }
  }

  @override
  void dispose() {
    _unwatch();
    super.dispose();
  }

  /// Ask the thread now when the link is in view, or once scrolling brings it there.
  void _watch() {
    if (!mounted || _requested) {
      return;
    }
    final scrollable = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (scrollable == null) {
      _request();
      return;
    }
    _position = scrollable.position..addListener(_onScroll);
    _check();
  }

  void _unwatch() {
    _position?.removeListener(_onScroll);
    _position = null;
  }

  /// The position notifies while it is laid out too: the trigger looks where it is after the frame.
  void _onScroll() {
    if (_checkScheduled) {
      return;
    }
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      _check();
    });
  }

  void _check() {
    if (!mounted || _requested || !_inView()) {
      return;
    }
    _unwatch();
    _request();
  }

  bool _inView() {
    final box = context.findRenderObject();
    final view = Scrollable.maybeOf(context, axis: Axis.vertical)?.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return false;
    }
    if (view is! RenderBox || !view.attached || !view.hasSize) {
      return true;
    }
    final top = box.localToGlobal(Offset.zero).dy;
    final viewTop = view.localToGlobal(Offset.zero).dy;
    return top >= viewTop && top <= viewTop + view.size.height;
  }

  void _request() {
    _requested = true;
    final tid = widget.tid;
    _repository.load(tid).then((info) {
      if (!mounted || widget.tid != tid || info == null) {
        return;
      }
      ThreadLinkCardLoaded(tid).dispatch(context);
    }).ignore();
  }

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(child: SizedBox.shrink());
}

/// A link in a post's content to a thread ([threadLinkOf]) drawn as a card of the thread [info]: its title, its
/// author, its forum, its replies and views, when it was started. Tapping it opens the link ([onOpen]) as tapping the
/// link does.
class ThreadLinkCard extends StatelessWidget {
  /// Constructor.
  const ThreadLinkCard({required this.info, required this.onOpen, this.onShowUrl, super.key});

  /// The thread.
  final ThreadLinkCardInfo info;

  /// Open the link.
  final VoidCallback onOpen;

  /// Show what the link is (long press, secondary tap), as for a link.
  final VoidCallback? onShowUrl;

  @override
  Widget build(BuildContext context) => _Card(info: info, onOpen: onOpen, onShowUrl: onShowUrl);
}

class _Card extends StatelessWidget {
  const _Card({required this.info, required this.onOpen, required this.onShowUrl});

  final ThreadLinkCardInfo info;
  final VoidCallback onOpen;
  final VoidCallback? onShowUrl;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final metaStyle = textTheme.bodySmall?.copyWith(color: colorScheme.outline);
    final iconSize = (metaStyle?.fontSize ?? 12) + 2;
    final time = info.publishTime;
    final meta = <(IconData, String)>[
      if (info.author != null) (Icons.person_outline, info.author!),
      if (info.forumName != null) (Icons.folder_outlined, info.forumName!),
      if (info.replyCount != null) (Icons.forum_outlined, '${info.replyCount}'),
      if (info.viewCount != null) (Icons.bar_chart_outlined, '${info.viewCount}'),
      if (time != null) (Icons.access_time, time.elapsedTillNow(context)),
    ];
    final shape = RoundedRectangleBorder(
      side: BorderSide(color: colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(8),
    );
    // A column of rich text, no row: it lays out in any width, also in the cell of a table working out its columns.
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            info.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: colorScheme.primary),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  for (final (i, (icon, text)) in meta.indexed) ...[
                    if (i > 0) const TextSpan(text: '    '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(icon, size: iconSize, color: colorScheme.outline),
                    ),
                    TextSpan(text: ' $text'),
                  ],
                ],
              ),
              style: metaStyle,
            ),
          ],
        ],
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        link: true,
        label: info.title,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('thread-link-card-${info.tid}'),
            customBorder: shape,
            onTap: onOpen,
            onLongPress: onShowUrl,
            onSecondaryTap: onShowUrl,
            child: DecoratedBox(
              decoration: ShapeDecoration(shape: shape, color: colorScheme.surfaceContainerLow),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
