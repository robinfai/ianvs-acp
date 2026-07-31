import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var promptImageClipboardChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 760, height: 560)
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
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
