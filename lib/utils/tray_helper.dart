import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘管理助手（仅 Windows）。
///
/// 负责初始化托盘图标、处理右键菜单点击。本类**不拦截**窗口关闭事件：点击
/// 标题栏 X 时由 Windows 默认行为直接退出应用
/// （`windows/runner/main.cpp` 中已设置 `SetQuitOnClose(true)`）。
///
/// 本类不做平台判断，由调用方（`main.dart`）保证只在 Windows 上初始化；
/// 初始化失败不会抛出，避免影响主程序启动。
class TrayHelper with TrayListener, LoggerMixin {
  TrayHelper._();

  /// 全局单例。
  static final TrayHelper instance = TrayHelper._();

  /// 设置流订阅，用于在登录用户名或语言变化时刷新菜单。
  StreamSubscription<SettingsMap>? _settingsSubscription;

  /// 上次构建菜单时的用户名，用于对比是否需要刷新菜单。
  String _lastUsername = '';

  /// 上次构建菜单时的 locale，用于对比是否需要刷新菜单。
  String _lastLocale = '';

  /// 初始化托盘。
  ///
  /// 应在 `windowManager.ensureInitialized()` 后调用；只在 Windows 上调用。
  Future<void> init() async {
    trayManager.addListener(this);

    final iconPath = await _prepareTrayIcon();
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('tsdm_client');

    await _updateContextMenu();

    // 登录用户名或 locale 变化时自动刷新菜单（登录、登出、切账户、切语言）。
    final settingsRepo = getIt.get<SettingsRepository>();
    _settingsSubscription = settingsRepo.settings.listen((settings) {
      final usernameChanged = settings.loginUsername != _lastUsername;
      final localeChanged = settings.locale != _lastLocale;
      if (usernameChanged || localeChanged) {
        _lastUsername = settings.loginUsername;
        _lastLocale = settings.locale;
        unawaited(_updateContextMenu());
      }
    });
  }

  /// 将打包在 assets 中的图标复制到系统临时目录，返回绝对路径。
  ///
  /// `tray_manager` 在 Windows 上需要绝对路径，且不接受 asset 路径。
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

  /// 当前 slang 翻译表。
  ///
  /// 用 [LocaleSettings.instance] 而不是 `context.t`：托盘菜单可能在 UI 上下文
  /// 之外（或语言切换后立即）构建，`context.t` 会拿不到最新语言，导致回退英文。
  Translations get _t => LocaleSettings.instance.currentTranslations;

  /// 构建并设置右键菜单。
  Future<void> _updateContextMenu() async {
    final settings = getIt.get<SettingsRepository>().currentSettings;
    final username = settings.loginUsername;
    _lastUsername = username;
    _lastLocale = settings.locale;

    final tr = _t;
    final userLabel = tr.tray.user(name: username.isEmpty ? tr.tray.notLoggedIn : username);

    final menu = Menu(
      items: [
        MenuItem(key: 'userInfo', label: userLabel, disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'history', label: tr.tray.history),
        MenuItem(key: 'favorite', label: tr.tray.favorite),
        MenuItem(key: 'manageAccount', label: tr.tray.manageAccount),
        MenuItem.separator(),
        MenuItem(key: 'logout', label: tr.tray.logout),
        MenuItem(key: 'exit', label: tr.tray.exit),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  /// 左键单击托盘图标：还原并聚焦窗口。
  @override
  void onTrayIconMouseDown() {
    unawaited(_bringToFront());
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
    switch (menuItem.key) {
      case 'history':
        await _bringToFront();
        unawaited(router.pushNamed(ScreenPaths.threadVisitHistory));
      case 'favorite':
        await _bringToFront();
        unawaited(router.pushNamed(ScreenPaths.favorite));
      case 'manageAccount':
        await _bringToFront();
        unawaited(router.pushNamed(ScreenPaths.manageAccount));
      case 'logout':
        await _bringToFront();
        await _logout();
      case 'exit':
        await _exitApp();
    }
  }

  /// 从最小化/后台状态还原窗口并聚焦。
  Future<void> _bringToFront() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// 退出当前账号。检查 [AuthenticationRepository.logout] 的结果并给出提示。
  Future<void> _logout() async {
    final either = await getIt.get<AuthenticationRepository>().logout().run();
    either.match(
      (err) {
        debug('tray logout failed: $err');
        _showToast(_t.tray.logoutFailed(err: '$err'));
      },
      (_) {
        debug('tray logout succeeded');
        _showToast(_t.tray.logoutSuccess);
        unawaited(_updateContextMenu());
      },
    );
  }

  /// 强制退出应用进程。
  ///
  /// 用 `io.exit(0)` 而不是 `windowManager.destroy()`：后者在某些 Win32 场景下
  /// 会阻塞 UI 线程，导致窗口"未响应"后再崩溃。
  Future<void> _exitApp() async {
    try {
      await _settingsSubscription?.cancel();
    } on Exception catch (e) {
      debug('cancel settings subscription failed: $e');
    }
    trayManager.removeListener(this);
    io.exit(0);
  }

  /// 通过全局 SnackBar 显示一次性提示。
  void _showToast(String message) {
    final ctx = router.routerDelegate.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      return;
    }
    showSnackBar(context: ctx, message: message);
  }
}
