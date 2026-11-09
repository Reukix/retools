import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.dropFirst().first ?? "Host/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let orange = CGColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1)
context.setFillColor(orange)
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
for (x, y, alpha) in [(256.0, 228.0, 0.3), (218.0, 358.0, 0.6), (180.0, 488.0, 1.0)] {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 25, color: CGColor(gray: 0, alpha: 0.1))
    context.setFillColor(CGColor(gray: 1, alpha: alpha))
    context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 590, height: 246), cornerWidth: 67, cornerHeight: 67, transform: nil))
    context.fillPath()
    context.restoreGState()
}
context.setStrokeColor(orange)
context.setLineWidth(28)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 392, y: 608))
context.addLine(to: CGPoint(x: 579, y: 608))
context.move(to: CGPoint(x: 525, y: 662))
context.addLine(to: CGPoint(x: 579, y: 608))
context.addLine(to: CGPoint(x: 525, y: 554))
context.strokePath()
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
assert(CGImageDestinationFinalize(destination))
