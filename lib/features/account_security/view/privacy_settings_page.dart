import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/account_security/cubit/account_security_cubit.dart';
import 'package:tsdm_client/features/account_security/models/account_security.dart';
import 'package:tsdm_client/features/account_security/repository/account_security_repository.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The privacy settings of the account in use: every tab of the forum's privacy page (but the ignore filter, which the
/// blocking pages handle), saved at once.
class PrivacySettingsPage extends StatelessWidget {
  /// Constructor.
  const PrivacySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.repo<AuthenticationRepository>().effectiveCurrentUid;
    final tr = context.t.privacySettingsPage;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.title)),
        body: AppStateView(icon: Icons.login_outlined, message: context.t.general.needLogin),
      );
    }
    return BlocProvider(
      create: (_) {
        final cubit = PrivacySettingsCubit(repository: AccountSecurityRepository(), uid: uid);
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocConsumer<PrivacySettingsCubit, PrivacySettingsState>(
        listenWhen: (prev, curr) => prev.resultSeq != curr.resultSeq,
        listener: (context, state) =>
            showSnackBar(context: context, message: state.lastSaveOk ? tr.saved : tr.saveFailed),
        builder: (context, state) {
          final cubit = context.read<PrivacySettingsCubit>();
          final canSave = state.changed.isNotEmpty;
          return Scaffold(
            appBar: AppBar(
              title: Text(tr.title),
              actions: [
                if (state.saving)
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: sizedCircularProgressIndicator)
                else
                  IconButton(
                    key: const ValueKey('privacy-save'),
                    icon: const Icon(Icons.check),
                    tooltip: tr.save,
                    onPressed: canSave ? cubit.save : null,
                  ),
              ],
            ),
            body: SafeArea(bottom: false, child: _body(context, state)),
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, PrivacySettingsState state) {
    final cubit = context.read<PrivacySettingsCubit>();
    switch (state.status) {
      case AccountPageStatus.loading when state.edited.isEmpty:
        return const CenteredCircularIndicator();
      case AccountPageStatus.failed when state.edited.isEmpty:
        return AppStateView(
          icon: Icons.error_outline,
          error: true,
          message: context.t.general.failedToLoad,
          action: FilledButton.tonal(onPressed: cubit.load, child: Text(context.t.general.retry)),
        );
      case AccountPageStatus.loading || AccountPageStatus.failed || AccountPageStatus.ready:
        break;
    }
    final sections = state.edited.where((e) => e.section != null).toList();
    if (sections.isEmpty) {
      return AppStateView(icon: Icons.privacy_tip_outlined, message: context.t.general.noData);
    }
    return AppCenteredList(
      maxWidth: appFormMaxWidth,
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 12, bottom: 24).add(context.safePadding()),
        children: [
          for (final (i, e) in sections.indexed) ...[
            if (i > 0) const SizedBox(height: appSurfaceGap),
            AppTileGroup(
              title: e.tab.title,
              children: [
                for (final item in e.section!.items) _item(context, e.tab.op, item, enabled: !state.saving),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _item(BuildContext context, String op, PrivacyItem item, {required bool enabled}) {
    final cubit = context.read<PrivacySettingsCubit>();
    switch (item) {
      case PrivacyToggle():
        return SwitchListTile(
          title: Text(item.label),
          value: item.checked,
          onChanged: enabled ? (v) => cubit.change(op, item.withChecked(checked: v)) : null,
        );
      case PrivacyChoice():
        return ListTile(
          title: Text(item.label),
          enabled: enabled,
          trailing: Text(
            item.valueLabel,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.secondary),
          ),
          onTap: () async {
            final value = await showDialog<String>(
              context: context,
              builder: (dialogContext) => SimpleDialog(
                title: Text(item.label),
                children: [
                  RadioGroup<String>(
                    groupValue: item.value,
                    onChanged: (v) => Navigator.of(dialogContext).pop(v),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (value, text) in item.options) RadioListTile(value: value, title: Text(text)),
                      ],
                    ),
                  ),
                ],
              ),
            );
            if (value != null && value != item.value) {
              cubit.change(op, item.withValue(value));
            }
          },
        );
    }
  }
}
