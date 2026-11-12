import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // flutter_local_notifications: the app delegate forwards the notification callbacks (shown in the foreground, a
    // tap) to the plugin. Only the delegate is set: nothing is asked or posted until the user turns the notifications
    // on in the settings.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HomeWidgetBridge") {
      HomeWidgetBridge.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppIconChannel") {
      AppDelegate.registerAppIconChannel(with: registrar.messenger())
    }
  }

  /// `kzs.th000.tsdm_client/appIcon`, method `setAppIcon`: the alternate icons are the app icon sets AppIconDark,
  /// AppIconMono and AppIconPink of the asset catalog (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES); "default" is
  /// the primary icon.
  private static func registerAppIconChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "kzs.th000.tsdm_client/appIcon", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "setAppIcon", let args = call.arguments as? [String: Any],
        let name = args["name"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      // A nil name is the primary icon.
      let icons: [String: String?] = ["default": nil, "dark": "AppIconDark", "mono": "AppIconMono", "pink": "AppIconPink"]
      guard let iconName = icons[name] else {
        result(FlutterError(code: "unknown_icon", message: "No such app icon: \(name)", details: nil))
        return
      }
      let application = UIApplication.shared
      guard application.supportsAlternateIcons else {
        result(false)
        return
      }
      if application.alternateIconName == iconName {
        result(true)
        return
      }
      application.setAlternateIconName(iconName) { error in
        // The completion handler is not promised to run on the main queue, the result must be.
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "set_icon_failed", message: error.localizedDescription, details: nil))
          } else {
            result(true)
          }
        }
      }
    }
  }
}
