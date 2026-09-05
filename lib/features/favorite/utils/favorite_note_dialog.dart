import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Ask the optional note of a new favorite.
///
/// Returns the note (may be empty) or null when the user cancelled.
Future<String?> showFavoriteNoteDialog(BuildContext context) async => showDialog<String>(
  context: context,
  builder: (context) => const RootPage(DialogPaths.favoriteNote, _FavoriteNoteDialog()),
);

class _FavoriteNoteDialog extends StatefulWidget {
  const _FavoriteNoteDialog();

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
      title: Text(tr.add),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 200,
        decoration: InputDecoration(hintText: tr.noteHint, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text(context.t.general.cancel)),
        TextButton(onPressed: () => context.pop(_controller.text.trim()), child: Text(context.t.general.ok)),
      ],
    );
  }
}
