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
        // A nil name is the primary icon.
        let icons: [String: String?] = ["default": nil, "dark": "AppIconDark", "mono": "AppIconMono", "pink": "AppIconPink"]
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
