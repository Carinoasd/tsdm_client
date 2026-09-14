import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘管理助手。
///
/// 负责初始化托盘图标、处理右键菜单点击，以及处理退出逻辑。
///
/// 注意：本类**不拦截**窗口关闭事件。点击标题栏 X 时由 Windows 默认行为直接
/// 退出应用（`windows/runner/main.cpp` 中已设置 `SetQuitOnClose(true)`）。
class TrayHelper with TrayListener, LoggerMixin {
  TrayHelper._();

  /// 全局单例。
  static final TrayHelper instance = TrayHelper._();

  /// 设置流订阅，用于在用户名变化时刷新菜单。
  StreamSubscription<SettingsMap>? _settingsSubscription;

  /// 上次构建菜单时的用户名，用于对比是否需要刷新菜单。
  String _lastUsername = '';

  /// 初始化托盘。
  Future<void> init() async {
    trayManager.addListener(this);

    // 加载托盘图标。
    final iconPath = await _prepareTrayIcon();
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('tsdm_client');

    // 构建初始菜单。
    await _updateContextMenu();

    // 监听设置变化（特别是登录用户名），以便自动刷新菜单。
    final settingsRepo = getIt.get<SettingsRepository>();
    _settingsSubscription = settingsRepo.settings.listen((settings) {
      if (settings.loginUsername != _lastUsername) {
        _lastUsername = settings.loginUsername;
        unawaited(_updateContextMenu());
      }
    });
  }

  /// 将打包在 assets 中的图标复制到系统临时目录，返回绝对路径。
  Future<String> _prepareTrayIcon() async {
    final dir = await getTemporaryDirectory();
    final separator = io.Platform.pathSeparator;
    final filePath = '${dir.path}$separator/app_icon.ico';
    final file = io.File(filePath);

    if (!file.existsSync() || file.lengthSync() == 0) {
      final bytes = await rootBundle.load('assets/images/app_icon.ico');
      await file.writeAsBytes(bytes.buffer.asUint8List());
    }
    return filePath;
  }

  /// 更新右键菜单。
  Future<void> _updateContextMenu() async {
    final settings = getIt.get<SettingsRepository>().currentSettings;
    final username = settings.loginUsername.isEmpty ? '未登录' : settings.loginUsername;
    _lastUsername = settings.loginUsername;

    // 图标选用视觉宽度相近的 emoji，Win32 原生菜单能更整齐地对齐：
    // 👤（用户）/ 📖（历史）/ 📁（收藏）/ 👥（管理账户）/ ➡️（退出）
    final menu = Menu(
      items: [
        MenuItem(key: 'userInfo', label: '👤 用户：$username', disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'history', label: '📖 历史'),
        MenuItem(key: 'favorite', label: '📁 收藏'),
        MenuItem(key: 'manageAccount', label: '👥 管理账户'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '➡️ 退出'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  /// 左键单击托盘图标：显示并聚焦窗口。
  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  /// 显示并聚焦窗口。
  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// 右键单击托盘图标：弹出菜单。
  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  /// 菜单项点击事件。
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    unawaited(_handleMenuItemClick(menuItem));
  }

  /// 处理单个菜单项的点击。
  Future<void> _handleMenuItemClick(MenuItem menuItem) async {
    final key = menuItem.key;
    if (key == 'history') {
      unawaited(router.pushNamed(ScreenPaths.threadVisitHistory));
    } else if (key == 'favorite') {
      unawaited(router.pushNamed(ScreenPaths.favorite));
    } else if (key == 'manageAccount') {
      unawaited(router.pushNamed(ScreenPaths.manageAccount));
    } else if (key == 'exit') {
      await _handleExit();
    }
  }

  /// 处理退出逻辑。
  Future<void> _handleExit() async {
    final settingsRepo = getIt.get<SettingsRepository>();

    final remember = await settingsRepo.getValue<bool>(SettingsKeys.rememberExitChoice);
    final savedAction = await settingsRepo.getValue<String>(SettingsKeys.exitAction);
    if (remember) {
      await _executeExit(savedAction);
      return;
    }

    final context = router.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return;
    }

    final result = await showDialog<ExitChoiceResult>(
      context: context,
      builder: (context) => const _ExitDialog(),
    );

    if (result != null) {
      if (result.remember) {
        await settingsRepo.setValue<bool>(SettingsKeys.rememberExitChoice, true);
        await settingsRepo.setValue<String>(SettingsKeys.exitAction, result.action);
      }
      await _executeExit(result.action);
    }
  }

  /// 执行退出动作。
  Future<void> _executeExit(String action) async {
    if (action == 'logout') {
      debug('exit action: logout');
      await getIt.get<AuthenticationRepository>().logout().run();
      await _updateContextMenu();
    } else {
      debug('exit action: exit app');
      await _cleanupAndExit();
    }
  }

  /// 清理监听并强制结束进程。
  ///
  /// 使用 `io.exit(0)` 而不是 `windowManager.destroy()`：后者在某些 Win32 场景下
  /// 会阻塞 UI 线程，导致窗口"未响应"后再崩溃。
  Future<void> _cleanupAndExit() async {
    try {
      await _settingsSubscription?.cancel();
    } on Exception catch (e) {
      debug('cancel settings subscription failed: $e');
    }
    trayManager.removeListener(this);
    io.exit(0);
  }
}

/// 退出选择的返回结果。
///
/// 表示用户在退出弹窗中做出的选择。
class ExitChoiceResult {
  /// 构造函数。
  ///
  /// [action] 为退出动作（'logout' 或 'exit'），[remember] 表示是否记住本次选择。
  ExitChoiceResult({required this.action, required this.remember});

  /// 退出动作：'logout' 退出账号，'exit' 退出软件。
  final String action;

  /// 是否记住本次选择，下次点击退出直接执行。
  final bool remember;
}

/// 退出确认对话框。
class _ExitDialog extends StatefulWidget {
  const _ExitDialog();

  @override
  State<_ExitDialog> createState() => _ExitDialogState();
}

class _ExitDialogState extends State<_ExitDialog> {
  String _action = 'exit';
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('退出'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioGroup<String>(
            groupValue: _action,
            onChanged: (v) => setState(() => _action = v!),
            child: const Column(
              children: [
                RadioListTile<String>(
                  title: Text('退出账号'),
                  value: 'logout',
                ),
                RadioListTile<String>(
                  title: Text('退出软件'),
                  value: 'exit',
                ),
              ],
            ),
          ),
          CheckboxListTile(
            title: const Text('记住我的选择'),
            value: _remember,
            onChanged: (v) => setState(() => _remember = v!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ExitChoiceResult(action: _action, remember: _remember)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
