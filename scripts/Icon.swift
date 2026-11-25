import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: Int) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255,
            blue: CGFloat(hex & 255)/255, alpha: 1)
}

func drawKoala(_ c: CGContext) {
    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: Int) {
        c.setFillColor(color(fill))
        c.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
    }
    func line(_ start: CGPoint, _ end: CGPoint, _ bend: CGPoint, _ ink: Int, _ width: CGFloat) {
        c.setStrokeColor(color(ink)); c.setLineWidth(width); c.setLineCap(.round)
        c.move(to: start); c.addQuadCurve(to: end, control: bend); c.strokePath()
    }
    func leaf(_ x: CGFloat, _ y: CGFloat, _ angle: CGFloat) {
        c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: angle)
        c.setFillColor(color(0x83cbb0)); c.move(to: .zero)
        c.addQuadCurve(to: CGPoint(x: 16,y: 0), control: CGPoint(x: 6,y: 9))
        c.addQuadCurve(to: .zero, control: CGPoint(x: 11,y: -5)); c.fillPath()
        line(.zero, CGPoint(x: 11,y: 1), CGPoint(x: 6,y: 2), 0x478672, 0.8)
        c.restoreGState()
    }
    let ink = 0x343c49
    for x: CGFloat in [9, 63] {
        oval(x, 47, 28, 31, 0x788a99)
        oval(x+1, 49, 26, 29, 0xbbc7ce)
        oval(x+5, 53, 18, 21, 0xe6b4a8)
        oval(x+8, 56, 12, 15, 0xf2d5c2)
    }
    oval(26, 15, 48, 41, 0x879aa8)
    oval(32, 17, 36, 31, 0xe1e3dc)
    oval(19, 31, 62, 48, 0x8899a5)
    oval(19, 33, 62, 46, 0xc5d0d4)
    oval(28, 35, 44, 23, 0xdce2df)
    leaf(56,76,0.78); leaf(57,76,0.16)
    for x: CGFloat in [32, 61] {
        oval(x, 53, 6.5, 7.8, ink)
        oval(x+1.1, 57, 2.3, 2.4, 0xffffff)
    }
    oval(25, 46, 9, 3.8, 0xe8b6ae); oval(66, 46, 9, 3.8, 0xe8b6ae)
    oval(44, 47, 12, 16, ink); oval(46, 57, 4.8, 3.3, 0x677482)
    line(CGPoint(x:44,y:44),CGPoint(x:56,y:44),CGPoint(x:50,y:38),ink,1.7)
    c.setFillColor(color(0x319583))
    c.addPath(CGPath(roundedRect: CGRect(x:34,y:18,width:32,height:17), cornerWidth:7, cornerHeight:7, transform:nil)); c.fillPath()
    c.move(to: CGPoint(x:41,y:21)); c.addLine(to: CGPoint(x:40,y:14)); c.addLine(to: CGPoint(x:50,y:21)); c.fillPath()
    line(CGPoint(x:49,y:31),CGPoint(x:49,y:26),CGPoint(x:49,y:28),0xfff4db,2.3)
    line(CGPoint(x:49,y:26),CGPoint(x:54,y:24),CGPoint(x:52,y:25),0xfff4db,2.3)
    oval(27, 22, 12, 9, 0xc6d1d4); oval(61, 22, 12, 9, 0xc6d1d4)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rgb = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pixels) / 100, y: CGFloat(pixels) / 100)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 5, y: 5, width: 90, height: 90), cornerWidth: 21, cornerHeight: 21, transform: nil))
        ctx.clip()
        let gradient = CGGradient(colorsSpace: rgb, colors: [
            CGColor(red: 0.30, green: 0.70, blue: 0.57, alpha: 1),
            CGColor(red: 0.04, green: 0.38, blue: 0.37, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 18,y: 95), end: CGPoint(x: 85,y: 5), options: [])
        drawKoala(ctx)
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let out = CGImageDestinationCreateWithURL(destination.appendingPathComponent(filename) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
    }
}


let mascot = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
mascot.scaleBy(x: 5.12, y: 5.12)
drawKoala(mascot)
let png = URL(fileURLWithPath: CommandLine.arguments[2])
let output = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(output, mascot.makeImage()!, nil)
guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
