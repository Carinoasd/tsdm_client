import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Builds from the part of the settings [select] picks, and again only when that part changes.
///
/// [select] returns a record of the fields the rows read: records compare by value, so a switch of another group
/// leaves this one as it is. Never the whole [SettingsMap]: it is a new object on every change.
class SettingsSelect<T> extends StatelessWidget {
  /// Constructor.
  const SettingsSelect({required this.select, required this.builder, super.key});

  /// The fields read by [builder], as a record.
  final T Function(SettingsMap settings) select;

  /// Builds the rows from what [select] picked.
  final Widget Function(BuildContext context, T selected) builder;

  @override
  Widget build(BuildContext context) => BlocSelector<SettingsBloc, SettingsState, T>(
    selector: (state) => select(state.settingsMap),
    builder: builder,
  );
}

/// Value of a row shown at its end, in the secondary color, never wider than a third of the row.
Widget settingsTrailingValue(BuildContext context, String value) => ConstrainedBox(
  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width / 3),
  child: Text(
    value,
    textAlign: TextAlign.end,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.secondary),
  ),
);

/// The body of a settings sub page: [groups] in one centered column of the width of a form.
class SettingsSubPageBody extends StatelessWidget {
  /// Constructor.
  const SettingsSubPageBody({required this.groups, super.key});

  /// The groups of rows, top to bottom.
  final List<Widget> groups;

  @override
  Widget build(BuildContext context) => SafeArea(
    left: false,
    top: false,
    child: LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: appCenteredPadding(constraints.maxWidth, maxWidth: appFormMaxWidth).copyWith(top: 12, bottom: 24),
        children: [
          for (var i = 0; i < groups.length; i++) ...[if (i > 0) const SizedBox(height: appSurfaceGap), groups[i]],
        ],
      ),
    ),
  );
}
