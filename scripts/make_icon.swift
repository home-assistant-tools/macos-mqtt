import Foundation
import CoreGraphics
import ImageIO

// Draws a simple "broadcast" app icon (blue→cyan squircle + radio waves).
func draw(_ px: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(px)
    let radius = w * 0.2237
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: w),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.clip()

    let locs: [CGFloat] = [0, 1]
    let colors = [CGColor(red: 0.10, green: 0.43, blue: 0.82, alpha: 1),
                  CGColor(red: 0.00, green: 0.70, blue: 0.78, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locs)!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: w), end: CGPoint(x: w, y: 0), options: [])

    let cx = w / 2, cy = w * 0.34
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineWidth(w * 0.055)
    for r in [w * 0.16, w * 0.27, w * 0.38] {
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                   startAngle: .pi * 0.18, endAngle: .pi * 0.82, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let dot = w * 0.045
    ctx.fillEllipse(in: CGRect(x: cx - dot, y: cy - dot, width: dot * 2, height: dot * 2))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    _ = CGImageDestinationFinalize(dest)
}

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs { writePNG(draw(px), "\(iconset)/\(name).png") }
print("wrote \(iconset)")
