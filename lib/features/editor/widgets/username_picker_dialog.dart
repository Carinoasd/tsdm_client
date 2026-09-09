import 'package:flutter/material.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';

/// Let the user pick a user to mention and return the username, null when dismissed.
///
/// The `BBCodeUsernamePicker` injected into the editor package (toolbar `@` button and tapping an existing mention
/// chip); it opens the mention picker sheet, see [showMentionPicker].
Future<String?> showUsernamePickerDialog(BuildContext context, {String? username}) async =>
    showMentionPicker(context, username: username);
