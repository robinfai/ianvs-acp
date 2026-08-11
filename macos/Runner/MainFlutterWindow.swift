import Cocoa
import FlutterMacOS

final class AccessibleTextFieldProxyFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "com.ianvs.acp/accessible-text-field"

  private let messenger: FlutterBinaryMessenger
  private let accessibilityCoordinator: AccessibleTextFieldAccessibilityCoordinator

  init(
    messenger: FlutterBinaryMessenger,
    accessibilityContainer: NSView?
  ) {
    self.messenger = messenger
    accessibilityCoordinator = AccessibleTextFieldAccessibilityCoordinator(
      container: accessibilityContainer
    )
    super.init()
  }

  func create(
    withViewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> NSView {
    return AccessibleTextFieldProxyView(
      viewId: viewId,
      arguments: args as? [String: Any] ?? [:],
      messenger: messenger,
      accessibilityCoordinator: accessibilityCoordinator
    )
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

final class AccessibleTextFieldAccessibilityCoordinator {
  private weak var container: NSView?
  private let views = NSHashTable<AccessibleTextFieldProxyView>.weakObjects()
  private var semanticRoots: [Any] = []

  init(container: NSView?) {
    self.container = container
  }

  func register(_ view: AccessibleTextFieldProxyView) {
    views.add(view)
    refresh()
  }

  func unregister(_ view: AccessibleTextFieldProxyView) {
    views.remove(view)
    refresh()
  }

  func refresh() {
    guard let container else { return }
    let currentChildren = container.accessibilityChildren() ?? []
    let proxyViews = views.allObjects
    let currentRoots = currentChildren.filter {
      !($0 is AccessibleTextFieldProxyView)
    }
    if !currentRoots.isEmpty {
      semanticRoots = currentRoots
    }
    guard !semanticRoots.isEmpty else { return }

    let attachedViews = proxyViews.filter { $0.window != nil }
    for view in attachedViews {
      view.setAccessibilityParent(container)
    }
    container.setAccessibilityChildren(semanticRoots + attachedViews)
  }
}

final class AccessibleTextFieldProxyView: NSView {
  private let channel: FlutterMethodChannel?
  private weak var accessibilityCoordinator: AccessibleTextFieldAccessibilityCoordinator?
  private var isApplyingState = false

  init(
    viewId: Int64,
    arguments: [String: Any],
    messenger: FlutterBinaryMessenger,
    accessibilityCoordinator: AccessibleTextFieldAccessibilityCoordinator
  ) {
    let channel = FlutterMethodChannel(
      name: "com.ianvs.acp/accessible-text-field/\(viewId)",
      binaryMessenger: messenger
    )
    self.channel = channel
    self.accessibilityCoordinator = accessibilityCoordinator
    super.init(frame: .zero)
    configure(viewId: viewId)
    apply(arguments)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      guard call.method == "update",
            let arguments = call.arguments as? [String: Any]
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.apply(arguments)
      result(nil)
    }
  }

  init(viewId: Int64, arguments: [String: Any]) {
    channel = nil
    accessibilityCoordinator = nil
    super.init(frame: .zero)
    configure(viewId: viewId)
    apply(arguments)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    accessibilityCoordinator?.unregister(self)
    channel?.setMethodCallHandler(nil)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      accessibilityCoordinator?.unregister(self)
    } else {
      accessibilityCoordinator?.register(self)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    return nil
  }

  override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
    super.setAccessibilityFocused(accessibilityFocused)
    if accessibilityFocused && !isApplyingState {
      channel?.invokeMethod("focus", arguments: nil)
    }
  }

  override func setAccessibilityValue(_ accessibilityValue: Any?) {
    super.setAccessibilityValue(accessibilityValue)
    if !isApplyingState, let value = accessibilityValue as? String {
      channel?.invokeMethod("setText", arguments: value)
    }
  }

  private func configure(viewId: Int64) {
    setAccessibilityElement(true)
    setAccessibilityRole(.textField)
    setAccessibilityIdentifier("ianvs-acp.accessible-text-field.\(viewId)")
  }

  private func apply(_ arguments: [String: Any]) {
    isApplyingState = true
    defer { isApplyingState = false }

    let label = arguments["label"] as? String ?? ""
    let description = arguments["description"] as? String ?? ""
    setAccessibilityLabel(label)
    setAccessibilityTitle(label)
    setAccessibilityHelp(description)
    setAccessibilityValue(arguments["value"] as? String ?? "")
    setAccessibilityEnabled(arguments["enabled"] as? Bool ?? true)
    setAccessibilityFocused(arguments["focused"] as? Bool ?? false)
  }
}

class MainFlutterWindow: NSWindow {
  static let chromeToolbarIdentifier = NSToolbar.Identifier(
    "com.ianvs.acp.window-chrome"
  )

  private var promptImageClipboardChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 760, height: 560)
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let accessibilityRegistrar = flutterViewController.registrar(
      forPlugin: "AccessibleTextFieldProxy"
    )
    accessibilityRegistrar.register(
      AccessibleTextFieldProxyFactory(
        messenger: accessibilityRegistrar.messenger,
        accessibilityContainer: accessibilityRegistrar.view
      ),
      withId: AccessibleTextFieldProxyFactory.viewType
    )
    let clipboardChannel = FlutterMethodChannel(
      name: "com.ianvs.acp/prompt_image_clipboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    clipboardChannel.setMethodCallHandler { call, result in
      guard call.method == "readImage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        result(try Self.readPromptImage())
      } catch {
        result(
          FlutterError(
            code: "clipboard_image_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
    promptImageClipboardChannel = clipboardChannel

    super.awakeFromNib()
    configureWindowChrome()
  }

  func configureWindowChrome() {
    title = ""
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    styleMask.insert(.fullSizeContentView)

    let chromeToolbar = NSToolbar(
      identifier: Self.chromeToolbarIdentifier
    )
    chromeToolbar.displayMode = .iconOnly
    chromeToolbar.sizeMode = .regular
    chromeToolbar.showsBaselineSeparator = false
    chromeToolbar.allowsUserCustomization = false
    chromeToolbar.autosavesConfiguration = false
    toolbar = chromeToolbar
    toolbarStyle = .unified

    backgroundColor = NSColor(
      calibratedRed: 247.0 / 255.0,
      green: 247.0 / 255.0,
      blue: 247.0 / 255.0,
      alpha: 1
    )
  }

  private static func readPromptImage() throws -> [String: Any]? {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] {
      for url in urls where url.isFileURL {
        guard let image = NSImage(contentsOf: url) else { continue }
        let extensionName = url.pathExtension.lowercased()
        if let mimeType = imageMimeType(forExtension: extensionName),
           let data = try? Data(contentsOf: url)
        {
          return try clipboardPayload(
            data: data,
            mimeType: mimeType,
            name: url.lastPathComponent
          )
        }
        if let data = pngData(from: image) {
          return try clipboardPayload(
            data: data,
            mimeType: "image/png",
            name: "\(url.deletingPathExtension().lastPathComponent).png"
          )
        }
      }
    }

    if let data = pasteboard.data(forType: .png) {
      return try clipboardPayload(
        data: data,
        mimeType: "image/png",
        name: "Pasted Image.png"
      )
    }
    if let data = pasteboard.data(forType: .tiff),
       let image = NSImage(data: data),
       let png = pngData(from: image)
    {
      return try clipboardPayload(
        data: png,
        mimeType: "image/png",
        name: "Pasted Image.png"
      )
    }
    return nil
  }

  private static func clipboardPayload(
    data: Data,
    mimeType: String,
    name: String
  ) throws -> [String: Any] {
    let maximumImageBytes = 4 * 1024 * 1024
    guard !data.isEmpty, data.count <= maximumImageBytes else {
      throw NSError(
        domain: "com.ianvs.acp.prompt-image-clipboard",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Clipboard images must be 4 MB or smaller."
        ]
      )
    }
    return [
      "bytes": FlutterStandardTypedData(bytes: data),
      "mimeType": mimeType,
      "name": name,
    ]
  }

  private static func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }

  private static func imageMimeType(forExtension value: String) -> String? {
    switch value {
    case "png":
      return "image/png"
    case "jpg", "jpeg":
      return "image/jpeg"
    case "gif":
      return "image/gif"
    case "webp":
      return "image/webp"
    case "bmp":
      return "image/bmp"
    default:
      return nil
    }
  }
}
