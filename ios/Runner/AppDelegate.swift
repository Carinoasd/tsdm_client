import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      // The alternate icons are the app icon sets AppIconDark, AppIconMono and AppIconPink of the asset catalog
      // (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES); "default" is the primary icon.
      let channel = FlutterMethodChannel(
        name: "kzs.th000.tsdm_client/appIcon", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        guard call.method == "setAppIcon", let args = call.arguments as? [String: Any],
          let name = args["name"] as? String
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        let icons = ["default": nil, "dark": "AppIconDark", "mono": "AppIconMono", "pink": "AppIconPink"]
        guard let iconName = icons[name] else {
          result(FlutterError(code: "unknown_icon", message: "No such app icon: \(name)", details: nil))
          return
        }
        guard application.supportsAlternateIcons else {
          result(false)
          return
        }
        if application.alternateIconName == iconName {
          result(true)
          return
        }
        application.setAlternateIconName(iconName) { error in
          if let error = error {
            result(FlutterError(code: "set_icon_failed", message: error.localizedDescription, details: nil))
          } else {
            result(true)
          }
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
