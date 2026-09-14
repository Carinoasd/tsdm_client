import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
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

/// 系统托盘管理助手
///
/// 负责初始化托盘图标、处理右键菜单点击、拦截窗口关闭（隐藏到托盘）以及处理退出逻辑。
class TrayHelper with TrayListener, WindowListener, LoggerMixin {
  TrayHelper._();
  static final TrayHelper instance = TrayHelper._();

  /// 初始化托盘
  Future<void> init() async {
    trayManager.addListener(this);
    windowManager.addListener(this);

    // 加载托盘图标（将 assets 中的 ico 文件复制到临时目录，因为 tray_manager 需要绝对路径）
    final iconPath = await _prepareTrayIcon();

    // 设置托盘图标和提示文本
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('tsdm_client');

    // 构建右键菜单
    await _updateContextMenu();
  }

  /// 将打包在 assets 中的图标复制到系统临时目录，返回绝对路径
  Future<String> _prepareTrayIcon() async {
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}${Platform.pathSeparator}app_icon.ico';
    final file = File(filePath);

    // 如果文件不存在，或者大小不对，就重新写入
    if (!await file.exists() || await file.length() == 0) {
      final bytes = await rootBundle.load('assets/images/app_icon.ico');
      await file.writeAsBytes(bytes.buffer.asUint8List());
    }
    return filePath;
  }

  /// 更新右键菜单（例如：登录用户名变化时需要重新构建）
  Future<void> _updateContextMenu() async {
    final settings = getIt.get<SettingsRepository>().currentSettings;
    final username = settings.loginUsername.isEmpty ? '未登录' : settings.loginUsername;

    // 构建菜单项
    final menu = Menu(
      items: [
        MenuItem(key: 'userInfo', label: '用户：$username', disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'history', label: '历史'),
        MenuItem(key: 'favorite', label: '收藏'),
        MenuItem(key: 'manageAccount', label: '管理账户'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  /// 左键单击托盘图标：显示并聚焦窗口
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setSkipTaskbar(false);
  }

  /// 右键单击托盘图标：弹出菜单
  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  /// 菜单项点击事件
  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'history':
        router.pushNamed(ScreenPaths.threadVisitHistory);
        break;
      case 'favorite':
        router.pushNamed(ScreenPaths.favorite);
        break;
      case 'manageAccount':
        router.pushNamed(ScreenPaths.manageAccount);
        break;
      case 'exit':
        await _handleExit();
        break;
    }
  }

  /// 拦截窗口关闭事件：不退出，而是隐藏到托盘
  @override
  Future<void> onWindowClose() async {
    debug('window close intercepted, hiding to tray');
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  /// 处理退出逻辑
  Future<void> _handleExit() async {
    final settingsRepo = getIt.get<SettingsRepository>();
    final settings = settingsRepo.currentSettings;

    // 如果用户勾选了“记住选择”，直接执行上次的选择
    if (settings.rememberExitChoice) {
      await _executeExit(settings.exitAction);
      return;
    }

    // 获取全局 Context 用于弹窗
    final context = router.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return;
    }

    // 弹出退出选择对话框
    final result = await showDialog<ExitChoiceResult>(
      context: context,
      builder: (context) => const _ExitDialog(),
    );

    if (result != null) {
      // 如果用户勾选了“记住选择”，保存到设置
      if (result.remember) {
        await settingsRepo.setValue<bool>(SettingsKeys.rememberExitChoice, true);
        await settingsRepo.setValue<String>(SettingsKeys.exitAction, result.action);
      }
      await _executeExit(result.action);
    }
  }

  /// 执行退出动作
  Future<void> _executeExit(String action) async {
    if (action == 'logout') {
      // 退出账号：调用 Repository 退出，应用继续运行
      debug('exit action: logout');
      await getIt.get<AuthenticationRepository>().logout().run();
      // 退出后刷新一下菜单里的用户名
      await _updateContextMenu();
    } else {
      // 退出软件：销毁窗口，结束进程
      debug('exit action: exit app');
      await windowManager.destroy();
    }
  }
}

/// 退出选择的返回结果
class ExitChoiceResult {
  final String action;
  final bool remember;
  ExitChoiceResult(this.action, this.remember);
}

/// 退出确认对话框
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
          RadioListTile<String>(
            title: const Text('退出账号'),
            value: 'logout',
            groupValue: _action,
            onChanged: (v) => setState(() => _action = v!),
          ),
          RadioListTile<String>(
            title: const Text('退出软件'),
            value: 'exit',
            groupValue: _action,
            onChanged: (v) => setState(() => _action = v!),
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
          onPressed: () => Navigator.pop(context, ExitChoiceResult(_action, _remember)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
