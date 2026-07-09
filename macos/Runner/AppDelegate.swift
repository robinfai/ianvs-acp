import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let deepLinkChannelName = "ianvs_acp/deep_links"
  private var deepLinkChannel: FlutterMethodChannel?
  private var pendingDeepLinks: [String] = []

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // FlutterAppDelegate does not safely implement this optional callback on
    // every engine version; calling super here can raise an Objective-C
    // forwarding exception during launch.
    configureDeepLinkChannel()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      handleDeepLink(url)
    }
  }

  private func configureDeepLinkChannel() {
    guard let controller = NSApplication.shared.windows.compactMap({ window in
      window.contentViewController as? FlutterViewController
    }).first else {
      return
    }

    let channel = FlutterMethodChannel(
      name: deepLinkChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getInitialDeepLinks" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let links = self?.pendingDeepLinks ?? []
      self?.pendingDeepLinks.removeAll()
      result(links)
    }
    deepLinkChannel = channel
  }

  private func handleDeepLink(_ url: URL) {
    guard url.scheme == "ianvs-acp" else {
      return
    }

    let value = url.absoluteString
    if let channel = deepLinkChannel {
      channel.invokeMethod("openDeepLink", arguments: value)
    } else {
      pendingDeepLinks.append(value)
    }
  }
}
