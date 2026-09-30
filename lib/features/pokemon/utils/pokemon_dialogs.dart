import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Ask the user to confirm a pokemon action, using the app's standard dialog format.
///
/// Wrapped in [RootPage] like every other dialog in the app, so the location stack and the teardown order stay
/// consistent. Returns true only when the user confirms; the buttons keep the pokemon wording.
Future<bool> showPokemonConfirmDialog({
  required BuildContext context,
  required IconData icon,
  required String title,
  required String message,
  required String confirmLabel,
  bool dangerous = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => RootPage(
      DialogPaths.pokemonConfirm,
      CustomAlertDialog.sync(
        title: AppDialogTitle(icon: icon, title: title, error: dangerous),
        content: SelectableText(message),
        actions: [
          TextButton(onPressed: () => context.pop(false), child: Text(context.t.general.cancel)),
          FilledButton(
            style: dangerous ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
            onPressed: () => context.pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}

/// Show a text-input dialog (rename / buy quantity) in the app's standard dialog format; null when cancelled.
Future<String?> showPokemonInputDialog({
  required BuildContext context,
  required IconData icon,
  required String title,
  required String initialValue,
  required String confirmLabel,
  String? hintText,
  int? maxLength,
  TextInputType? keyboardType,
}) => showDialog<String>(
  context: context,
  builder: (context) => RootPage(
    DialogPaths.pokemonInput,
    _PokemonInputDialog(
      icon: icon,
      title: title,
      initialValue: initialValue,
      confirmLabel: confirmLabel,
      hintText: hintText,
      maxLength: maxLength,
      keyboardType: keyboardType,
    ),
  ),
);

/// Body of [showPokemonInputDialog]; owns its [TextEditingController] so it lives exactly as long as the dialog.
class _PokemonInputDialog extends StatefulWidget {
  const _PokemonInputDialog({
    required this.icon,
    required this.title,
    required this.initialValue,
    required this.confirmLabel,
    this.hintText,
    this.maxLength,
    this.keyboardType,
  });

  /// Icon shown in the dialog title.
  final IconData icon;

  /// Dialog title.
  final String title;

  /// Initial text of the field.
  final String initialValue;

  /// Label of the confirm button.
  final String confirmLabel;

  /// Field hint and label text.
  final String? hintText;

  /// Maximum input length, when the value is limited.
  final int? maxLength;

  /// Keyboard type for the field.
  final TextInputType? keyboardType;

  @override
  State<_PokemonInputDialog> createState() => _PokemonInputDialogState();
}

class _PokemonInputDialogState extends State<_PokemonInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomAlertDialog.sync(
    title: AppDialogTitle(icon: widget.icon, title: widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: widget.maxLength,
      keyboardType: widget.keyboardType,
      decoration: InputDecoration(hintText: widget.hintText, labelText: widget.hintText),
    ),
    actions: [
      TextButton(onPressed: () => context.pop(), child: Text(context.t.general.cancel)),
      FilledButton(onPressed: () => context.pop(_controller.text.trim()), child: Text(widget.confirmLabel)),
    ],
  );
}
