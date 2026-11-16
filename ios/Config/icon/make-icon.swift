import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
let s = CGFloat(size)

// Sky: light teal at the top to the app's accent teal.
let sky = CGGradient(colorsSpace: space, colors: [color(0.43, 0.80, 0.84), color(0.086, 0.478, 0.541)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.25), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])

// Sun, warm, upper right.
ctx.setFillColor(color(1.0, 0.80, 0.30))
ctx.fillEllipse(in: CGRect(x: s * 0.62, y: s * 0.62, width: s * 0.24, height: s * 0.24))

// Sea: two soft waves across the lower third.
func wave(base: CGFloat, height: CGFloat, shift: CGFloat, fill: CGColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: base))
    let step = s / 4
    var x: CGFloat = -shift
    while x < s + step {
        path.addQuadCurve(to: CGPoint(x: x + step / 2, y: base), control: CGPoint(x: x + step / 4, y: base + height))
        path.addQuadCurve(to: CGPoint(x: x + step, y: base), control: CGPoint(x: x + step * 0.75, y: base - height))
        x += step
    }
    path.addLine(to: CGPoint(x: s, y: 0))
    path.closeSubpath()
    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
}
wave(base: s * 0.30, height: s * 0.035, shift: s * 0.06, fill: color(0.05, 0.36, 0.43))
wave(base: s * 0.215, height: s * 0.03, shift: 0, fill: color(0.03, 0.27, 0.34))

// House: white, with a pitched roof, standing above the water.
let houseW = s * 0.44, bodyH = s * 0.24
let left = (s - houseW) / 2, bottom = s * 0.30
let house = CGMutablePath()
let overhang = s * 0.055
house.move(to: CGPoint(x: left - overhang, y: bottom + bodyH))
house.addLine(to: CGPoint(x: s / 2, y: bottom + bodyH + s * 0.22))
house.addLine(to: CGPoint(x: left + houseW + overhang, y: bottom + bodyH))
house.addLine(to: CGPoint(x: left + houseW, y: bottom + bodyH))
house.addLine(to: CGPoint(x: left + houseW, y: bottom))
house.addLine(to: CGPoint(x: left, y: bottom))
house.addLine(to: CGPoint(x: left, y: bottom + bodyH))
house.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0.15, 0.2, 0.35))
ctx.addPath(house); ctx.setLineJoin(.round); ctx.setFillColor(color(1, 1, 1)); ctx.fillPath()
ctx.restoreGState()

// Door and window in the accent colour.
ctx.setFillColor(color(0.086, 0.478, 0.541))
let door = CGRect(x: s / 2 - s * 0.05, y: bottom, width: s * 0.10, height: s * 0.15)
ctx.addPath(CGPath(roundedRect: door, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)); ctx.fillPath()
ctx.fill(CGRect(x: door.minX, y: bottom, width: door.width, height: s * 0.06))
for x in [left + s * 0.045, left + houseW - s * 0.045 - s * 0.085] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: bottom + s * 0.09, width: s * 0.085, height: s * 0.085), cornerWidth: s * 0.015, cornerHeight: s * 0.015, transform: nil))
    ctx.fillPath()
}
// Front wave over the foot of the house, so it sits in the scene.
wave(base: s * 0.275, height: s * 0.028, shift: s * 0.03, fill: color(0.05, 0.36, 0.43))
wave(base: s * 0.20, height: s * 0.028, shift: s * 0.10, fill: color(0.03, 0.27, 0.34))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
