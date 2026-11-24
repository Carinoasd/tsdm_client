import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Dialog for proxy settings.
///
/// Set proxy address including host name and port.
class ProxySettingsDialog extends StatefulWidget {
  /// Constructor.
  const ProxySettingsDialog({this.host, this.port, super.key});

  /// Initial  host value, if any.
  final String? host;

  /// Initial port value if any.
  final String? port;

  @override
  State<ProxySettingsDialog> createState() => _ProxySettingsDialogState();
}

/// Status of testing proxy target connection.
enum _TestConnStatus {
  /// Waiting for a new test.
  waiting,

  /// Testing.
  testing,

  /// Connected to proxy target.
  connected,

  /// Disconnected to proxy target.
  disconnected,
}

class _ProxySettingsDialogState extends State<ProxySettingsDialog> {
  late TextEditingController hostController;
  late TextEditingController portController;

  final formKey = GlobalKey<FormState>();

  _TestConnStatus connStatus = _TestConnStatus.waiting;

  Future<void> testConnection() async {
    // Do not run test if proxy settings is illegal.
    if (!formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      connStatus = _TestConnStatus.testing;
    });
    try {
      final _ = await Dio().getUri<dynamic>(
        Uri.http(
          '${hostController.text.trim()}'
          ':${portController.text.trim()}',
        ),
        options: Options(sendTimeout: const Duration(seconds: 3)),
      );
      // The dialog may have been closed while waiting.
      if (!mounted) return;
      setState(() {
        connStatus = _TestConnStatus.connected;
      });
    } on DioException catch (e, _) {
      if (!mounted) return;
      setState(() {
        connStatus = _TestConnStatus.connected;
      });
      setState(() {
        if (e.response == null) {
          // No response, maybe proxy is not running.
          connStatus = _TestConnStatus.disconnected;
        } else {
          // Proxy returns reply, no matter what status code is, proxy
          // is running.
          connStatus = _TestConnStatus.connected;
        }
      });
      return;
    }
  }

  @override
  void initState() {
    super.initState();
    hostController = TextEditingController(text: widget.host);
    portController = TextEditingController(text: widget.port);
  }

  @override
  void dispose() {
    hostController.dispose();
    portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.advancedSection.proxySettings;
    final colorScheme = Theme.of(context).colorScheme;
    final (IconData statusIcon, Color statusColor) = switch (connStatus) {
      _TestConnStatus.waiting => (Icons.help_outline, colorScheme.onSurfaceVariant),
      _TestConnStatus.testing => (Icons.hourglass_top_outlined, colorScheme.onSurfaceVariant),
      _TestConnStatus.connected => (Icons.check_circle_outline, colorScheme.primary),
      _TestConnStatus.disconnected => (Icons.error_outline, colorScheme.error),
    };
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.network_locked_outlined, title: tr.title),
      content: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sizedBoxW4H4,
            TextFormField(
              controller: hostController,
              autofocus: true,
              decoration: appFieldDecoration(label: tr.host).copyWith(prefixIcon: Icon(MdiIcons.ipNetworkOutline)),
              validator: (v) {
                if (v == null || v.trim().isEmpty || v.contains(':')) {
                  return tr.invalidHostOrIp;
                }
                return null;
              },
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: appFieldDecoration(label: tr.port, icon: Icons.network_ping_outlined),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return tr.invalidPort;
                }
                final p = int.tryParse(v);
                if (p == null || !(0 < p && p < 65535)) {
                  return tr.invalidPort;
                }
                return null;
              },
            ),
            sizedBoxW12H12,
            // Connection test: the status and its button in one block.
            AppInsetBlock(
              outlined: true,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (connStatus == _TestConnStatus.testing)
                    const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(statusIcon, size: 20, color: statusColor),
                  OutlinedButton.icon(
                    label: Text(switch (connStatus) {
                      _TestConnStatus.waiting => tr.testConnection.waiting,
                      _TestConnStatus.testing => tr.testConnection.testing,
                      _TestConnStatus.connected => tr.testConnection.connected,
                      _TestConnStatus.disconnected => tr.testConnection.disconnected,
                    }),
                    icon: const Icon(Icons.refresh_outlined),
                    onPressed: connStatus == _TestConnStatus.testing ? null : () async => testConnection(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.restart_alt_outlined),
          onPressed: () {
            // Clear proxy settings.
            context.read<SettingsBloc>().add(const SettingsValueChanged(SettingsKeys.netClientProxy, ''));
            showSnackBar(context: context, message: context.t.general.affectAfterRestart);
            context.pop();
          },
          label: Text(context.t.general.reset),
        ),
        TextButton(onPressed: () => context.pop(), child: Text(context.t.general.cancel)),
        FilledButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) {
              return;
            }
            context.read<SettingsBloc>().add(
              SettingsValueChanged(
                SettingsKeys.netClientProxy,
                '${hostController.text.trim()}:'
                '${portController.text.trim()}',
              ),
            );
            showSnackBar(context: context, message: context.t.general.affectAfterRestart);
            context.pop();
          },
          child: Text(context.t.general.ok),
        ),
      ],
    );
  }
}
