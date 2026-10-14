// Draws the app icon and writes every size the asset catalog needs.
//
//   swift Scripts/make-icon.swift Macinroid/Resources/Assets.xcassets/AppIcon.appiconset
//
// The artwork: a phone in front of a green tile, with a pair of arrows on its
// screen for files going both ways.

import AppKit

guard CommandLine.arguments.count > 1 else {
    print("usage: make-icon.swift <path to AppIcon.appiconset>")
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}

/// Renders the icon on a square canvas of `pixels` points per side.
func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // everything below is laid out on the 1024-point grid Apple's templates use
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // the tile
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, alpha: 0.28))
    context.addPath(tilePath)
    context.setFillColor(color(0x0B7A4B))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0x54E39A), color(0x1FB978), color(0x0A7F52)]),
        start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: []
    )
    // a soft glow in the upper left, as if lit from above
    context.drawRadialGradient(
        gradient([color(0xFFFFFF, alpha: 0.30), color(0xFFFFFF, alpha: 0)]),
        startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
        endCenter: CGPoint(x: 330, y: 820), endRadius: 560, options: []
    )
    context.restoreGState()

    // the phone
    let phone = CGRect(x: 342, y: 212, width: 340, height: 600)
    let phonePath = CGPath(roundedRect: phone, cornerWidth: 62, cornerHeight: 62, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x003D24, alpha: 0.45))
    context.addPath(phonePath)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(phonePath)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0xFFFFFF), color(0xE3F1EA)]),
        start: CGPoint(x: phone.midX, y: phone.maxY), end: CGPoint(x: phone.midX, y: phone.minY), options: []
    )
    context.restoreGState()

    // its screen
    let screen = phone.insetBy(dx: 24, dy: 24)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 40, cornerHeight: 40, transform: nil)
    context.saveGState()
    context.addPath(screenPath)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0x10314A), color(0x0B1F33)]),
        start: CGPoint(x: screen.midX, y: screen.maxY), end: CGPoint(x: screen.midX, y: screen.minY), options: []
    )
    context.restoreGState()

    // the arrows: up on the left, down on the right
    func arrow(x: CGFloat, pointingUp: Bool, color stroke: CGColor) {
        let top: CGFloat = 640, bottom: CGFloat = 384, head: CGFloat = 62
        let tip = pointingUp ? top : bottom
        let tail = pointingUp ? bottom : top
        let direction: CGFloat = pointingUp ? -1 : 1

        context.setStrokeColor(stroke)
        context.setLineWidth(44)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: x, y: tail))
        context.addLine(to: CGPoint(x: x, y: tip))
        context.move(to: CGPoint(x: x - head, y: tip + direction * head))
        context.addLine(to: CGPoint(x: x, y: tip))
        context.addLine(to: CGPoint(x: x + head, y: tip + direction * head))
        context.strokePath()
    }
    arrow(x: 452, pointingUp: true, color: color(0x5BEBA3))
    arrow(x: 572, pointingUp: false, color: color(0xFFFFFF))

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let bitmap = NSBitmapImageRep(cgImage: image)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

struct Entry {
    var points: Int
    var scale: Int
    var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

let entries = [16, 32, 128, 256, 512].flatMap { [Entry(points: $0, scale: 1), Entry(points: $0, scale: 2)] }
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for entry in entries {
    write(render(pixels: entry.points * entry.scale), to: output.appendingPathComponent(entry.filename))
}

let images = entries.map { entry in
    """
        {
          "filename" : "\(entry.filename)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.points)x\(entry.points)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(entries.count) images to \(output.path)")
