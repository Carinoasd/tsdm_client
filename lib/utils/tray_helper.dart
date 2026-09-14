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

  /// Exercises native events against a real test navigator without terminating the test process.
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

  /// Whether the native icon and menu are ready to receive updates.
  bool _started = false;

  bool _registered = false;
  bool _iconCreated = false;
  Future<void>? _initialization;

  /// 初始化托盘。
  ///
  /// 应在 `windowManager.ensureInitialized()` 后调用；只在 Windows 上调用。
  Future<void> init() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    trayManager.addListener(this);
    _registered = true;
    try {
      final iconPath = await _prepareTrayIcon();
      await trayManager.setIcon(iconPath);
      _iconCreated = true;
      await trayManager.setToolTip('tsdm_client');
      await _updateContextMenu();

      _started = true;
      final settingsRepo = getIt.get<SettingsRepository>();
      _settingsSubscription = settingsRepo.settings.listen((settings) {
        if (settings.loginUsername != _lastUsername || settings.locale != _lastLocale) {
          unawaited(_refreshContextMenu());
        }
      });
      // Asset loading may throw FlutterError as well as platform exceptions.
    } on Object {
      await dispose();
      rethrow;
    }
  }

  /// 由 `App.build` 调用，把当前 UI 的翻译表同步给托盘。
  ///
  /// Uses the UI's translation instance after a locale change, including device locale changes.
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
  /// 优先使用 [updateTranslations] 注入的那份；还没注入时（初始化极早期）退回
  /// 当前 locale 的翻译，不影响主流程。
  Translations get _t => _translations ?? LocaleSettings.currentLocale.translations;

  /// 将打包在 assets 中的图标复制到系统临时目录，返回绝对路径。
  ///
  /// `tray_manager` 在 Windows 上需要绝对路径，且不接受 asset 路径。
  Future<String> _prepareTrayIcon() async {
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}${io.Platform.pathSeparator}tsdm_tray.ico';
    final file = io.File(filePath);
    // Refresh on each launch so an app upgrade cannot keep displaying an old cached icon.
    final bytes = await rootBundle.load('assets/images/app_icon.ico');
    await file.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    return filePath;
  }

  Future<void> _refreshContextMenu() async {
    if (!_started) {
      return;
    }
    try {
      await _updateContextMenu();
      // An optional native menu update must not become an unhandled asynchronous error.
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
  /// Windows requires the native menu owner to be foreground for clicks outside to dismiss it.
  /// The plugin's default skips SetForegroundWindow; this option activates its top-level owner.
  @override
  void onTrayIconRightMouseDown() {
    // Supported by tray_manager 0.5.x; needed until the Windows backend handles this unconditionally.
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
    if (_popupObserver.hasPopupRoute) {
      // Show the existing dialog instead of bypassing it, including while logging out.
      await _bringToFront();
      return;
    }
    if (menuItem.key == 'exit') {
      await _exitApp();
      return;
    }
    await _bringToFront();
    // A dialog or shutdown may have started while the native window calls were pending.
    if (!_started || _popupObserver.hasPopupRoute) {
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

  /// Remove the tray, then let the shared shutdown flow close storage before terminating.
  Future<void> _exitApp() async {
    await dispose();
    await _shutdown();
  }

  /// Release subscriptions and remove the native icon, including after partial initialization.
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
    // Do not call native cleanup when preparing the asset failed before setIcon.
    if (_iconCreated) {
      _iconCreated = false;
      try {
        await trayManager.destroy();
        // Preserve the initialization failure if cleanup also fails.
      } on Object catch (e, st) {
        talker.handle(e, st, 'tray cleanup failed');
      }
    }
  }
}
