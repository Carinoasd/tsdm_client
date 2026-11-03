import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/editor/utils/quick_phrases.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';

const _manage = -1;

/// Show the quick phrases to insert into [controller] at its cursor.
///
/// Without any phrase the page that arranges them opens at once. [focusNode] gets the focus back after an insert.
Future<void> showQuickPhrases(BuildContext context, BBCodeEditorController controller, {FocusNode? focusNode}) async {
  final phrases = decodeQuickPhrases(context.read<SettingsBloc>().state.settingsMap.editorQuickPhrases);
  final router = GoRouter.of(context);
  if (phrases.isEmpty) {
    await router.pushNamed(ScreenPaths.quickPhrases);
    return;
  }

  final picked = await showCustomBottomSheet<int>(
    context: context,
    title: context.t.bbcodeEditor.quickPhrases.title,
    topBar: BottomSheetTopBar(
      height: 48,
      alignment: Alignment.centerRight,
      child: Padding(
        padding: edgeInsetsL16R16,
        child: IconButton(
          key: const ValueKey('quick-phrases-manage'),
          icon: const Icon(Icons.edit_note_outlined),
          tooltip: context.t.bbcodeEditor.quickPhrases.manage,
          onPressed: () => Navigator.of(context).pop(_manage),
        ),
      ),
    ),
    childrenBuilder: (sheetContext) => [
      for (var i = 0; i < phrases.length; i++)
        ListTile(
          key: ValueKey('quick-phrase-item-$i'),
          title: Text(phrases[i], maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.of(sheetContext).pop(i),
        ),
    ],
  );

  if (picked == null) {
    return;
  }
  if (picked == _manage) {
    await router.pushNamed(ScreenPaths.quickPhrases);
    return;
  }
  controller.insertTextAtCursor(phrases[picked]);
  focusNode?.requestFocus();
}
