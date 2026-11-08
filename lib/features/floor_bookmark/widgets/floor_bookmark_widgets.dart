import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The excerpt a bookmark keeps of the floor's plain [text]: its first [floorBookmarkExcerptLength] characters, the
/// white space folded.
String floorBookmarkExcerpt(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim().characters.take(floorBookmarkExcerptLength).toString();

/// What the bookmark dialog asked for.
sealed class FloorBookmarkEdit {
  const FloorBookmarkEdit();
}

/// Keep the bookmark with [note].
final class FloorBookmarkSave extends FloorBookmarkEdit {
  /// Constructor.
  const FloorBookmarkSave(this.note);

  /// The note, empty for none.
  final String note;
}

/// Remove the bookmark.
final class FloorBookmarkRemove extends FloorBookmarkEdit {
  /// Constructor.
  const FloorBookmarkRemove();
}

/// Ask the note of a bookmark of a floor: a new one, or [current] (then it can be removed too). Null when cancelled.
Future<FloorBookmarkEdit?> showFloorBookmarkDialog(BuildContext context, {FloorBookmark? current}) =>
    showDialog<FloorBookmarkEdit>(
      context: context,
      builder: (context) => RootPage(DialogPaths.floorBookmark, _FloorBookmarkDialog(current: current)),
    );

class _FloorBookmarkDialog extends StatefulWidget {
  const _FloorBookmarkDialog({this.current});

  final FloorBookmark? current;

  @override
  State<_FloorBookmarkDialog> createState() => _FloorBookmarkDialogState();
}

class _FloorBookmarkDialogState extends State<_FloorBookmarkDialog> {
  late final _controller = TextEditingController(text: widget.current?.note ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(FloorBookmarkSave(_controller.text.trim()));

  @override
  Widget build(BuildContext context) {
    final tr = context.t.floorBookmark;
    return AlertDialog(
      icon: Icon(widget.current == null ? Icons.turned_in_not_outlined : Icons.turned_in_outlined),
      title: Text(widget.current == null ? tr.add : tr.edit),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320),
        child: TextField(
          key: const ValueKey('floor-bookmark-note'),
          controller: _controller,
          autofocus: true,
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
            LengthLimitingTextInputFormatter(floorBookmarkNoteMaxLength),
          ],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            labelText: tr.note,
            prefixIcon: const Icon(Icons.sticky_note_2_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
          ),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            key: const ValueKey('floor-bookmark-remove'),
            onPressed: () => Navigator.of(context).pop(const FloorBookmarkRemove()),
            child: Text(tr.remove, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(key: const ValueKey('floor-bookmark-save'), onPressed: _save, child: Text(context.t.general.ok)),
      ],
    );
  }
}

/// A bookmark as a row: the floor, the note, the excerpt.
class FloorBookmarkTile extends StatelessWidget {
  /// Constructor.
  const FloorBookmarkTile(this.bookmark, {this.onTap, this.onLongPress, super.key});

  /// The bookmark.
  final FloorBookmark bookmark;

  /// Tap callback.
  final VoidCallback? onTap;

  /// Long press callback.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final note = bookmark.note;
    final excerpt = bookmark.excerpt;
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: SizedBox(
        width: 48,
        child: Text(
          bookmark.floor == null ? '#' : '#${bookmark.floor}',
          style: textTheme.titleSmall?.copyWith(
            color: colorScheme.primary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      title: Text(note.isNotEmpty ? note : excerpt, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: note.isNotEmpty && excerpt.isNotEmpty
          ? Text(
              excerpt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
            )
          : null,
    );
  }
}

/// List [bookmarks] (of one thread) in a bottom sheet; the one tapped, null when closed.
Future<FloorBookmark?> showThreadBookmarksSheet(BuildContext context, List<FloorBookmark> bookmarks) =>
    showCustomBottomSheet<FloorBookmark>(
      context: context,
      title: context.t.floorBookmark.title,
      childrenBuilder: (context) => [
        for (final bookmark in bookmarks)
          FloorBookmarkTile(
            bookmark,
            key: ValueKey('thread-bookmark-${bookmark.key}'),
            onTap: () => Navigator.of(context).pop(bookmark),
          ),
      ],
    );
