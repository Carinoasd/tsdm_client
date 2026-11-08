import Flutter
import UIKit
#if canImport(WidgetKit)
  import WidgetKit
#endif

/// The app's side of the home screen widget (`TsdmWidget`, a WidgetKit extension), the iOS counterpart of Android's
/// `HomeWidgetChannel` and `ShortcutsHandler`.
///
/// * `kzs.th000.tsdm_client/homeWidget`, method `update`: Dart tells the whole state (`uid`, null when no account is
///   in use, `notice`, `personalMessage`, `checkedInDay`); it is stored in the App Group ([HomeWidgetState]) and the
///   widget's timelines reloaded. A null count keeps the one stored while the account is the same; for another account
///   it is [HomeWidgetState.unknownCount], a dash, until counted. The day is stored as Dart tells it.
/// * `kzs.th000.tsdm_client/shortcuts`: a tap on the widget opens a `tsdm://shortcut/<id>` link. Dart asks for the
///   link the app was opened with (`getInitialShortcut`, once) and is told the ones opened while it runs
///   (`onShortcut`); Dart parses the link (`AppShortcut.fromIdOrLink`).
///
/// Links come with the scene events (the app uses the UIScene lifecycle), or with the application ones when it does
/// not; every `tsdm://` link is taken here so that none reaches the router.
final class HomeWidgetBridge: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  static let homeWidgetChannel = "kzs.th000.tsdm_client/homeWidget"
  static let updateMethod = "update"

  static let shortcutsChannel = "kzs.th000.tsdm_client/shortcuts"
  static let getInitialShortcutMethod = "getInitialShortcut"
  static let onShortcutMethod = "onShortcut"

  static let linkScheme = "tsdm"

  private var shortcuts: FlutterMethodChannel?

  /// The link opened before Dart asked for it (a cold start from the widget). Only the last one is kept on purpose: a
  /// cold start opens one link, and of several taps before Dart runs the last is the wish.
  private var pendingLink: String?

  /// Dart asked for the initial link: its handler for the links opened later is set.
  private var dartListens = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = HomeWidgetBridge()
    let widget = FlutterMethodChannel(name: homeWidgetChannel, binaryMessenger: registrar.messenger())
    widget.setMethodCallHandler { call, result in
      instance.handleWidget(call, result: result)
    }
    let shortcuts = FlutterMethodChannel(name: shortcutsChannel, binaryMessenger: registrar.messenger())
    shortcuts.setMethodCallHandler { call, result in
      instance.handleShortcuts(call, result: result)
    }
    instance.shortcuts = shortcuts
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  // MARK: - Widget state

  private func handleWidget(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == HomeWidgetBridge.updateMethod else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let uid = (args["uid"] as? NSNumber).map { $0.intValue }.flatMap { $0 > 0 ? $0 : nil }
    let checkedInDay = (args["checkedInDay"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let current = HomeWidgetState.read()
    var kept = current
    if uid == nil {
      kept = .empty
    } else if uid != current.uid {
      kept.notice = HomeWidgetState.unknownCount
      kept.personalMessage = HomeWidgetState.unknownCount
    }
    let notice = (args["notice"] as? NSNumber)?.intValue ?? kept.notice
    let personalMessage = (args["personalMessage"] as? NSNumber)?.intValue ?? kept.personalMessage
    let next = HomeWidgetState(
      uid: uid,
      notice: max(notice, HomeWidgetState.unknownCount),
      personalMessage: max(personalMessage, HomeWidgetState.unknownCount),
      checkedInDay: uid != nil ? checkedInDay : nil
    )
    if next != current {
      next.write()
      HomeWidgetBridge.reloadWidget()
    }
    result(true)
  }

  private static func reloadWidget() {
    #if canImport(WidgetKit)
      if #available(iOS 14.0, *) {
        WidgetCenter.shared.reloadTimelines(ofKind: HomeWidgetState.widgetKind)
      }
    #endif
  }

  // MARK: - Shortcut links

  private func handleShortcuts(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == HomeWidgetBridge.getInitialShortcutMethod else {
      result(FlutterMethodNotImplemented)
      return
    }
    dartListens = true
    let link = pendingLink
    pendingLink = nil
    result(link)
  }

  /// Take [url] when it is a `tsdm://` link: hand it to Dart, or keep it until Dart asks.
  private func open(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == HomeWidgetBridge.linkScheme else { return false }
    let link = url.absoluteString
    if dartListens, let shortcuts = shortcuts {
      shortcuts.invokeMethod(HomeWidgetBridge.onShortcutMethod, arguments: link)
    } else {
      pendingLink = link
    }
    return true
  }

  private func open(_ contexts: Set<UIOpenURLContext>) -> Bool {
    var handled = false
    for context in contexts where open(context.url) {
      handled = true
    }
    return handled
  }

  // MARK: - Scene events

  // The selectors are spelled out: the protocol methods are optional, so a Swift name that missed them would only warn
  // and never be called; with the selector a mismatch does not compile.

  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts else { return false }
    return open(contexts)
  }

  @objc(scene:openURLContexts:)
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return open(URLContexts)
  }

  // MARK: - Application events (without the UIScene lifecycle)

  @objc(application:openURL:options:)
  func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return open(url)
  }
}
