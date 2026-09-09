import 'package:flutter/material.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Ask the optional note of a new favorite.
///
/// [title] defaults to the thread wording ("收藏"); the forum page passes "收藏本版".
/// Returns the note (may be empty) or null when the user cancelled.
Future<String?> showFavoriteNoteDialog(BuildContext context, {String? title}) async => showDialog<String>(
  context: context,
  builder: (context) => RootPage(DialogPaths.favoriteNote, _FavoriteNoteDialog(title: title)),
);

class _FavoriteNoteDialog extends StatefulWidget {
  const _FavoriteNoteDialog({this.title});

  final String? title;

  @override
  State<_FavoriteNoteDialog> createState() => _FavoriteNoteDialogState();
}

class _FavoriteNoteDialogState extends State<_FavoriteNoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.favorite;
    return AlertDialog(
      title: Text(widget.title ?? tr.add),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 200,
        decoration: InputDecoration(hintText: tr.noteHint, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(context.t.general.ok),
        ),
      ],
    );
  }
}
