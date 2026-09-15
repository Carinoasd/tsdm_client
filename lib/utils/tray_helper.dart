import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/shutdown.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘管理助手（仅 Windows）。
///
/// 负责初始化托盘图标、处理右键菜单点击。本类**不拦截**窗口关闭事件：点击
/// 标题栏 X 时由 Windows 默认行为直接退出应用
/// （`windows/runner/main.cpp` 中已设置 `SetQuitOnClose(true)`）。
///
/// 托盘菜单的翻译由 [updateTranslations] 从 `App.build` 注入，保证语言切换
/// 后菜单文字跟着变。
class TrayHelper with TrayListener, LoggerMixin {
  TrayHelper._(this._router, this._popupObserver, this._shutdown);

  /// 测试用工厂：注入假的 router / observer / shutdown，让测试能在不结束
  /// 进程的情况下驱动托盘事件。
  @visibleForTesting
  TrayHelper.forTesting({
    required GoRouter appRouter,
    required PopupRouteObserver popupObserver,
    required Future<void> Function() shutdown,
  }) : this._(appRouter, popupObserver, shutdown);

  /// 全局单例。
  static final TrayHelper instance = TrayHelper._(router, popupRouteObserver, exitApp);

  final GoRouter _router;
  final PopupRouteObserver _popupObserver;
  final Future<void> Function() _shutdown;

  /// 设置流订阅，用于在登录用户名或语言变化时刷新菜单。
  StreamSubscription<SettingsMap>? _settingsSubscription;

  /// 上次构建菜单时的用户名，用于对比是否需要刷新菜单。
  String _lastUsername = '';

  /// 上次构建菜单时的 locale，用于对比是否需要刷新菜单。
  String _lastLocale = '';

  /// 最近一次由 [updateTranslations] 注入的翻译表。
  Translations? _translations;

  /// 是否已完成初始化（图标 + 菜单已就绪）。
  bool _started = false;

  /// 是否已注册 [TrayListener]。
  bool _registered = false;

  /// 是否已创建原生图标（`trayManager.setIcon` 成功）。
  bool _iconCreated = false;

  /// 初始化 Future，用于幂等和并发调用。
  Future<void>? _initialization;

  /// 将打包在 assets 中的图标复制到系统临时目录，返回绝对路径。
  ///
  /// `tray_manager` 和 Windows Toast 都需要绝对路径，且不接受 asset 路径。
  /// 同一个文件被两者复用：托盘图标和通知图标显示的是同一张图。
  ///
  /// **每次调用都重新写入**：应用升级后图标内容变化，旧缓存不能被复用。
  static Future<String> prepareAppIcon() async {
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}${io.Platform.pathSeparator}tsdm_tray.ico';
    final file = io.File(filePath);
    final bytes = await rootBundle.load('assets/images/app_icon.ico');
    await file.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    return filePath;
  }

  /// 初始化托盘。
  ///
  /// 应在 `windowManager.ensureInitialized()` 后调用；只在 Windows 上调用。
  /// 幂等且并发安全：多个调用者共享同一个 [_initialization] Future。
  Future<void> init() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    trayManager.addListener(this);
    _registered = true;

    try {
      final iconPath = await prepareAppIcon();
      await trayManager.setIcon(iconPath);
      _iconCreated = true;
      await trayManager.setToolTip('tsdm_client');
      await _updateContextMenu();
      _started = true;

      // 登录用户名或 locale 变化时自动刷新菜单（登录、登出、切账户、切语言）。
      final settingsRepo = getIt.get<SettingsRepository>();
      _settingsSubscription = settingsRepo.settings.listen((settings) {
        if (settings.loginUsername != _lastUsername || settings.locale != _lastLocale) {
          unawaited(_refreshContextMenu());
        }
      });
    } on Object {
      // Asset 加载可能抛 FlutterError，也可能抛平台异常。清理后重新抛出，
      // 让调用方（`main.dart`）决定是否要吞掉。
      await dispose();
      rethrow;
    }
  }

  /// 由 `App.build` 调用，把当前 UI 的翻译表同步给托盘。
  ///
  /// 用 UI 的翻译实例而不是 `LocaleSettings.instance`：后者在部分 slang
  /// 版本里始终返回 baseLocale 的翻译，导致菜单语言不跟随。
  void updateTranslations(Translations translations) {
    if (identical(_translations, translations)) {
      return;
    }
    _translations = translations;
    if (_started) {
      unawaited(_refreshContextMenu());
    }
  }

  /// 当前 slang 翻译表。
  ///
  /// 优先使用 [updateTranslations] 注入的那份；还没注入时（初始化极早期）
  /// 退回当前 locale 的翻译，不影响主流程。
  Translations get _t => _translations ?? LocaleSettings.currentLocale.translations;

  /// 刷新菜单，吞掉所有异常。
  ///
  /// 菜单更新是"尽力而为"：失败不能变成未处理的异步错误。
  Future<void> _refreshContextMenu() async {
    if (!_started) {
      return;
    }
    try {
      await _updateContextMenu();
    } on Object catch (e, st) {
      talker.handle(e, st, 'tray menu update failed');
    }
  }

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
  ///
  /// Windows 要求原生菜单的 owner 是前台窗口，点击菜单外部才会收起。插件
  /// 默认跳过 `SetForegroundWindow`；`bringAppToFront: true` 会激活它的
  /// 顶层 owner。
  @override
  void onTrayIconRightMouseDown() {
    // Supported by tray_manager 0.5.x; needed until the Windows backend handles this
    // unconditionally.
    // ignore: deprecated_member_use
    unawaited(trayManager.popUpContextMenu(bringAppToFront: true));
  }

  /// 菜单项点击事件。
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    unawaited(_handleMenuItemClick(menuItem));
  }

  Future<void> _handleMenuItemClick(MenuItem menuItem) async {
    if (!_started) {
      return;
    }

    final destination = switch (menuItem.key) {
      'history' => ScreenPaths.threadVisitHistory,
      'favorite' => ScreenPaths.favorite,
      'manageAccount' => ScreenPaths.manageAccount,
      _ => null,
    };
    if (destination == null && menuItem.key != 'exit') {
      return;
    }

    // 有弹窗（对话框 / 底部弹层 / 退出确认）时只把窗口带到前台，不导航：
    // 否则会绕过弹窗的 barrier。
    if (_popupObserver.hasPopupRoute) {
      await _bringToFront();
      return;
    }

    if (menuItem.key == 'exit') {
      await _exitApp();
      return;
    }

    await _bringToFront();

    // 还原窗口期间可能弹出了对话框，或托盘已被释放。
    if (!_started || _popupObserver.hasPopupRoute) {
      return;
    }
    // Selecting the page that is already on top only brings the window forward; pushing it again would stack the
    // same page every time the menu is used.
    if (_router.routerDelegate.currentConfiguration.last.matchedLocation == destination) {
      return;
    }
    unawaited(_router.pushNamed(destination!));
  }

  /// 从最小化/后台状态还原窗口并聚焦。
  Future<void> _bringToFront() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// 移除托盘，然后交给共享的 shutdown 流程关闭存储并结束进程。
  Future<void> _exitApp() async {
    await dispose();
    await _shutdown();
  }

  /// 释放资源：取消订阅、移除 listener、销毁原生图标。
  ///
  /// 可在初始化失败后调用，也支持之后重新 [init]。
  Future<void> dispose() async {
    _started = false;
    _initialization = null;
    _translations = null;

    try {
      await _settingsSubscription?.cancel();
    } on Exception catch (e) {
      debug('cancel settings subscription failed: $e');
    } finally {
      _settingsSubscription = null;
    }

    if (_registered) {
      _registered = false;
      trayManager.removeListener(this);
    }

    // 准备 asset 失败时可能还没调用过 setIcon，此时不能调 destroy。
    if (_iconCreated) {
      _iconCreated = false;
      try {
        await trayManager.destroy();
      } on Object catch (e, st) {
        // 保留初始化失败的原异常，清理失败只记日志。
        talker.handle(e, st, 'tray cleanup failed');
      }
    }
  }
}
