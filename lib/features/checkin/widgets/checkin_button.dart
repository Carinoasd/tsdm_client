import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Widget provides ability to checkin.
class CheckinButton extends StatelessWidget {
  /// Constructor.
  const CheckinButton({this.enableSnackBar = false, this.useIcon = false, this.label, super.key});

  /// Enable snack bar feedback after checkin action.
  ///
  /// This flag is added because after refactor, [CheckinButton] becomes a pure
  /// bloc consumer, multiple snackbar may shown if nested pages are here..
  /// Only a workaround.
  final bool enableSnackBar;

  /// Use icon widget instead of button.
  ///
  /// Enabling this field will make the widget not pressable.
  final bool useIcon;

  /// Show a filled button with this label instead of an icon button, e.g. on the homepage greeting card.
  final String? label;

  /// The check-in result told last.
  ///
  /// Every button gets the same state from the app's [CheckinBloc], and several can be built at once (the homepage and
  /// the "me" tab stay alive in the home shell): only the first one to tell a result does, the result showed twice.
  static CheckinState? _told;

  /// The filled button used when [label] is set.
  Widget _buildLabeled(BuildContext context, {required Widget icon, required VoidCallback? onPressed}) =>
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        icon: icon,
        label: Text(label!),
        onPressed: onPressed,
      );

  Future<void> _showCheckinFailedSnackBar(BuildContext context, CheckinResult result) async {
    if (!context.mounted) {
      return;
    }
    return showSnackBar(context: context, message: CheckinResult.message(context, result));
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.profilePage.checkin;
    return BlocListener<CheckinBloc, CheckinState>(
      listener: (context, state) async {
        if (identical(state, _told)) {
          return;
        }
        if (state is CheckinStateSuccess) {
          _told = state;
          return showSnackBar(
            context: context,
            message: tr.success(msg: state.message),
          );
        }
        if (state is CheckinStateFailed && enableSnackBar) {
          _told = state;
          await _showCheckinFailedSnackBar(context, state.result);
        }
      },
      child: BlocBuilder<CheckinBloc, CheckinState>(
        buildWhen: (prev, curr) => prev != curr,
        builder: (context, state) {
          final tooltip = context.t.homepage.welcome.checkin;

          if (state is CheckinStateLoading) {
            if (useIcon) {
              return sizedCircularProgressIndicator;
            }
            if (label != null) {
              return _buildLabeled(context, icon: sizedCircularProgressIndicator, onPressed: null);
            }
            return IconButton(icon: sizedCircularProgressIndicator, tooltip: tooltip, onPressed: null);
          }

          if (useIcon) {
            return const Icon(Icons.domain_verification_outlined);
          }

          // Checked in today: recorded by this app (this run, an earlier run or the auto check-in). A check-in made
          // on the website is not known until the next tap, which then answers "already checked in" and records it.
          final checked =
              state is CheckinStateChecked ||
              state is CheckinStateSuccess ||
              (state is CheckinStateFailed && state.result is CheckinResultAlreadyChecked);
          if (checked) {
            final checkedTr = context.t.homepage.welcome;
            if (label != null) {
              return Tooltip(
                message: checkedTr.checkedInHint,
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  icon: const Icon(Icons.task_alt_outlined),
                  label: Text(checkedTr.checkedIn),
                  onPressed: null,
                ),
              );
            }
            return IconButton(icon: const Icon(Icons.task_alt_outlined), tooltip: checkedTr.checkedIn, onPressed: null);
          }

          if (state is CheckinStateNeedLogin) {
            if (label != null) {
              return _buildLabeled(context, icon: const Icon(Icons.domain_verification_outlined), onPressed: null);
            }
            return IconButton(icon: const Icon(Icons.domain_verification_outlined), tooltip: tooltip, onPressed: null);
          }

          if (label != null) {
            return _buildLabeled(
              context,
              icon: const Icon(Icons.domain_verification_outlined),
              onPressed: () => context.read<CheckinBloc>().add(const CheckinRequested()),
            );
          }

          return IconButton(
            icon: const Icon(Icons.domain_verification_outlined),
            tooltip: tooltip,
            onPressed: () {
              context.read<CheckinBloc>().add(const CheckinRequested());
            },
          );
        },
      ),
    );
  }
}
