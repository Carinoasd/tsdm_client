import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/thread_link_card/models/thread_link_card_info.dart';
import 'package:tsdm_client/features/thread_link_card/repository/thread_link_card_repository.dart';
import 'package:tsdm_client/features/thread_link_card/utils/thread_link.dart';

/// A link in a post's content to a thread ([threadLinkOf]), drawn as a card of the thread: its title, its author, its
/// forum, its replies and views, when it was started.
///
/// The thread is asked once the card comes into view ([ThreadLinkCardRepository]); until it is answered, and when the
/// account can not read it or the request failed, the link is shown as it was ([fallback]). Tapping the card opens
/// the link ([onOpen]) as tapping the link does.
class ThreadLinkCard extends StatefulWidget {
  /// Constructor.
  const ThreadLinkCard({required this.link, required this.fallback, required this.onOpen, this.onShowUrl, super.key});

  /// The link.
  final ThreadLink link;

  /// The link as it was munched.
  final Widget fallback;

  /// Open the link.
  final VoidCallback onOpen;

  /// Show what the link is (long press, secondary tap), as for a link.
  final VoidCallback? onShowUrl;

  @override
  State<ThreadLinkCard> createState() => _ThreadLinkCardState();
}

class _ThreadLinkCardState extends State<ThreadLinkCard> {
  ThreadLinkCardInfo? _info;

  /// The thread was asked (or answered before): the card no longer watches whether it is in view.
  bool _requested = false;

  ScrollPosition? _position;
  bool _checkScheduled = false;

  ThreadLinkCardRepository get _repository => ThreadLinkCardRepository.instance;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(ThreadLinkCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.tid != widget.link.tid) {
      _unwatch();
      _info = null;
      _requested = false;
      _start();
    }
  }

  @override
  void dispose() {
    _unwatch();
    super.dispose();
  }

  void _start() {
    final tid = widget.link.tid;
    if (_repository.isCached(tid)) {
      _info = _repository.cached(tid);
      _requested = true;
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) => _watch());
  }

  /// Ask the thread now when the card is in view, or once scrolling brings it there.
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

  /// The position notifies while it is laid out too: the card looks where it is after the frame.
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
    return top < viewTop + view.size.height && top + box.size.height > viewTop;
  }

  void _request() {
    _requested = true;
    final tid = widget.link.tid;
    _repository.load(tid).then((info) {
      if (!mounted || widget.link.tid != tid || info == null) {
        return;
      }
      setState(() => _info = info);
    }).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) {
      return widget.fallback;
    }
    return _Card(info: info, onOpen: widget.onOpen, onShowUrl: widget.onShowUrl);
  }
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
