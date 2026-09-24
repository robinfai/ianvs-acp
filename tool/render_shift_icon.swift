import AppKit
import CoreGraphics
import Foundation

let iconDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func color(_ hex: UInt32) -> CGColor {
  CGColor(
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    components: [
      CGFloat((hex >> 16) & 0xff) / 255,
      CGFloat((hex >> 8) & 0xff) / 255,
      CGFloat(hex & 0xff) / 255,
      1,
    ]
  )!
}

for size in sizes {
  let pixels = size * size * 4
  var data = Data(count: pixels)
  let success = data.withUnsafeMutableBytes { bytes -> Bool in
    guard let context = CGContext(
      data: bytes.baseAddress,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }

    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let background = CGPath(
      roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928),
      cornerWidth: 208,
      cornerHeight: 208,
      transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()
    let backgroundGradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [color(0x263452), color(0x10192E)] as CFArray,
      locations: [0, 1]
    )!
    context.drawLinearGradient(
      backgroundGradient,
      start: CGPoint(x: 48, y: 48),
      end: CGPoint(x: 976, y: 976),
      options: []
    )
    context.restoreGState()

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 512, y: 205))
    for point in [
      CGPoint(x: 782, y: 490), CGPoint(x: 647, y: 490),
      CGPoint(x: 647, y: 725), CGPoint(x: 377, y: 725),
      CGPoint(x: 377, y: 490), CGPoint(x: 242, y: 490),
    ] { arrow.addLine(to: point) }
    arrow.closeSubpath()
    context.saveGState()
    context.addPath(arrow)
    context.clip()
    let arrowGradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [color(0xffffff), color(0xe7f1fa)] as CFArray,
      locations: [0, 1]
    )!
    context.drawLinearGradient(
      arrowGradient,
      start: CGPoint(x: 242, y: 205),
      end: CGPoint(x: 782, y: 725),
      options: []
    )
    context.restoreGState()

    context.setFillColor(color(0x62d9cb))
    context.fill(CGRect(x: 377, y: 490, width: 135, height: 235))
    context.setStrokeColor(color(0x62d9cb))
    context.setLineWidth(42)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 323, y: 795))
    context.addLine(to: CGPoint(x: 701, y: 795))
    context.strokePath()

    guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        iconDirectory.appendingPathComponent("app_icon_\(size).png") as CFURL,
        "public.png" as CFString,
        1,
        nil
      ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }
  guard success else { fatalError("Could not render \(size)px icon") }
}
