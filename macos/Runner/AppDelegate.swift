import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Native plugins are registered in MainFlutterWindow.awakeFromNib (where the
  // FlutterViewController is created), so they're available for both the normal
  // app launch and the integration-test harness.

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
