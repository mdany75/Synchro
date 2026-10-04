// Dessine l'icône de l'app (1024 px) : swift scripts/make-icon.swift sortie.png
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Fond : carré arrondi aux proportions des icônes macOS.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
let colors = [CGColor(red: 0.16, green: 0.62, blue: 0.98, alpha: 1), CGColor(red: 0.07, green: 0.30, blue: 0.78, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Deux flèches circulaires blanches.
let center = CGPoint(x: 512, y: 512)
let radius = 215.0, stroke = 78.0
ctx.setStrokeColor(.white)
ctx.setFillColor(.white)
ctx.setLineWidth(stroke)
ctx.setLineCap(.round)

func arrow(from startDeg: Double, to endDeg: Double) {
    let a0 = startDeg * .pi / 180, a1 = endDeg * .pi / 180
    ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()
    let end = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
    let tangent = CGPoint(x: sin(a1), y: -cos(a1))
    let radial = CGPoint(x: cos(a1), y: sin(a1))
    let half = 105.0, length = 150.0
    ctx.move(to: CGPoint(x: end.x + radial.x * half, y: end.y + radial.y * half))
    ctx.addLine(to: CGPoint(x: end.x - radial.x * half, y: end.y - radial.y * half))
    ctx.addLine(to: CGPoint(x: end.x + tangent.x * length, y: end.y + tangent.y * length))
    ctx.closePath()
    ctx.fillPath()
}
arrow(from: 165, to: 40)
arrow(from: 345, to: 220)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
