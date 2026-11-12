import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  // "Keep in menu bar when closed" hides the window instead of closing it: an ordered-out window is not a closed one,
  // so the app keeps running. A click on the Dock icon or another launch of the app then brings it back. Without that
  // setting the window is never hidden and nothing here applies.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = mainFlutterWindow, !window.isVisible, !window.isMiniaturized {
      window.makeKeyAndOrderFront(nil)
    }
    return true
  }
}
