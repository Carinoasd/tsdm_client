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
/// 负责初始化托盘图标、处理右键菜单点击、拦截窗口关闭（隐藏到托盘）以及处理退出逻辑。
class TrayHelper with TrayListener, WindowListener, LoggerMixin {
  TrayHelper._();

  /// 全局单例。
  static final TrayHelper instance = TrayHelper._();

  /// 保存设置监听的订阅，用于释放。
  StreamSubscription? _settingsSubscription;

  /// 上次构建菜单时的用户名，用于对比是否需要刷新菜单。
  String _lastUsername = '';

  /// 初始化托盘。
  Future<void> init() async {
    trayManager.addListener(this);
    windowManager.addListener(this);

    // 加载托盘图标
    final iconPath = await _prepareTrayIcon();
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('tsdm_client');

    // 构建初始菜单
    await _updateContextMenu();

    // 监听设置变化（特别是登录用户名），以便自动刷新菜单
    final settingsRepo = getIt.get<SettingsRepository>();
    _settingsSubscription = settingsRepo.settings.listen((settings) {
      if (settings.loginUsername != _lastUsername) {
        _lastUsername = settings.loginUsername;
        _updateContextMenu();
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
    // 使用 Emoji 装饰，稍微弥补没有头像的缺憾
    final username = settings.loginUsername.isEmpty ? '未登录' : settings.loginUsername;
    _lastUsername = settings.loginUsername; // 记录当前状态

    final menu = Menu(
      items: [
        MenuItem(key: 'userInfo', label: '👤 用户：$username', disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'history', label: '📖 历史'),
        MenuItem(key: 'favorite', label: '⭐ 收藏'),
        MenuItem(key: 'manageAccount', label: '👥 管理账户'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '🚪 退出'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  /// 左键单击托盘图标：显示并聚焦窗口。
  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  Future<void> _showWindow() async {
    // 先取消跳过任务栏，再显示
    await windowManager.setSkipTaskbar(false);
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

  /// 拦截窗口关闭事件：不退出，而是隐藏到托盘。
  @override
  Future<void> onWindowClose() async {
    debug('window close intercepted, hiding to tray');
    // 为了规避 Windows 原生崩溃，先隐藏窗口，暂时不调用 setSkipTaskbar(true)
    // 或者调换顺序：先设置跳过任务栏，再隐藏
    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
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
      await _updateContextMenu(); // 退出账号后刷新菜单
    } else {
      debug('exit action: exit app');
      _settingsSubscription?.cancel(); // 退出前取消监听
      await windowManager.destroy();
    }
  }
}

/// 退出选择的返回结果。
class ExitChoiceResult {
  ExitChoiceResult({required this.action, required this.remember});
  final String action;
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
