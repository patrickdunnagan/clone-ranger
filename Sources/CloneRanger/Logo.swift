import AppKit
import SwiftUI

/// The Clone Ranger mark: two classic-Mac blue folders, slightly overlapping, wearing a Lone Ranger mask.
/// One drawing serves the top bar, the PDF report and the app icon.
enum Logo {
    static let outline = CGColor(srgbRed: 0.04, green: 0.12, blue: 0.24, alpha: 1)
    static let back = CGColor(srgbRed: 0.22, green: 0.47, blue: 0.84, alpha: 1)
    static let front = CGColor(srgbRed: 0.36, green: 0.62, blue: 0.95, alpha: 1)
    static let shine = CGColor(srgbRed: 0.66, green: 0.82, blue: 0.99, alpha: 1)

    /// Draws into `rect` (any aspect; the mark keeps 1.3 : 1 and centers itself).
    static func draw(in ctx: CGContext, rect: CGRect) {
        let aspect: CGFloat = 1.3
        var w = rect.width, h = rect.width / aspect
        if h > rect.height { h = rect.height; w = h * aspect }
        ctx.saveGState()
        // Work top-down in a 130 × 100 box.
        ctx.translateBy(x: rect.midX - w / 2, y: rect.midY + h / 2)
        ctx.scaleBy(x: w / 130, y: -h / 100)

        folder(ctx, x: 52, y: 6, w: 76, h: 62)    // back folder, up and right
        folder(ctx, x: 2, y: 28, w: 76, h: 62)    // front folder, overlapping it slightly
        mask(ctx)
        ctx.restoreGState()
    }

    private static func folder(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let lw = w * 0.045
        let tabH = h * 0.14, tabW = w * 0.42
        // Tab + back panel as one outline.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: y + h))
        p.addLine(to: CGPoint(x: x, y: y + tabH))
        p.addLine(to: CGPoint(x: x + w * 0.05, y: y))
        p.addLine(to: CGPoint(x: x + tabW - w * 0.05, y: y))
        p.addLine(to: CGPoint(x: x + tabW, y: y + tabH))
        p.addLine(to: CGPoint(x: x + w, y: y + tabH))
        p.addLine(to: CGPoint(x: x + w, y: y + h))
        p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(back); ctx.fillPath()

        // Front flap, lighter, with the bright top edge old Mac folders had.
        let flapTop = y + tabH + h * 0.16
        let flap = CGRect(x: x, y: flapTop, width: w, height: y + h - flapTop)
        ctx.setFillColor(front); ctx.fill(flap)
        ctx.setFillColor(shine); ctx.fill(CGRect(x: x + lw, y: flapTop + lw * 0.6, width: w - lw * 2, height: lw * 0.9))

        ctx.setStrokeColor(outline)
        ctx.setLineWidth(lw)
        ctx.setLineJoin(.round)
        ctx.addPath(p); ctx.strokePath()
        ctx.move(to: CGPoint(x: x, y: flapTop)); ctx.addLine(to: CGPoint(x: x + w, y: flapTop)); ctx.strokePath()
    }

    /// Black domino mask across both folders, one eye over each.
    private static func mask(_ ctx: CGContext) {
        let m = CGMutablePath()
        // Outer shape: pointed tips at both ends, a dip over the nose, a notch underneath.
        m.move(to: CGPoint(x: 2, y: 52))
        m.addCurve(to: CGPoint(x: 64, y: 40), control1: CGPoint(x: 14, y: 34), control2: CGPoint(x: 46, y: 32))
        m.addCurve(to: CGPoint(x: 128, y: 36), control1: CGPoint(x: 84, y: 28), control2: CGPoint(x: 114, y: 22))
        m.addCurve(to: CGPoint(x: 72, y: 70), control1: CGPoint(x: 122, y: 60), control2: CGPoint(x: 92, y: 74))
        m.addCurve(to: CGPoint(x: 60, y: 62), control1: CGPoint(x: 68, y: 66), control2: CGPoint(x: 64, y: 62))
        m.addCurve(to: CGPoint(x: 2, y: 52), control1: CGPoint(x: 40, y: 76), control2: CGPoint(x: 10, y: 70))
        m.closeSubpath()
        // Almond eye holes.
        func eye(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, tilt: CGFloat) {
            var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: tilt)
            let e = CGMutablePath()
            e.move(to: CGPoint(x: -rx, y: 0))
            e.addQuadCurve(to: CGPoint(x: rx, y: 0), control: CGPoint(x: 0, y: -ry * 2))
            e.addQuadCurve(to: CGPoint(x: -rx, y: 0), control: CGPoint(x: 0, y: ry * 2))
            e.closeSubpath()
            m.addPath(e, transform: t)
            t = .identity
        }
        eye(36, 52, 13, 6.5, tilt: 0.12)
        eye(94, 44, 13, 6.5, tilt: -0.16)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 4, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(m)
        ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        // A faint edge so it reads on a dark background.
        ctx.addPath(m)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    static func image(width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: width / 1.3)
        return NSImage(size: size, flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: r)
            return true
        }
    }

    /// 1024 × 1024 app icon: dark rounded square like the other apps, the mark in the middle.
    static func iconPNG() -> Data? {
        let s = 1024
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let bg = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(bg); ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(gray: 0.22, alpha: 1), CGColor(gray: 0.12, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        ctx.restoreGState()
        ctx.addPath(bg); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08)); ctx.setLineWidth(4); ctx.strokePath()
        draw(in: ctx, rect: rect.insetBy(dx: 70, dy: 70).offsetBy(dx: 0, dy: -10))
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

/// The mark as a SwiftUI view.
struct LogoMark: View {
    var width: CGFloat = 40
    var body: some View {
        Image(nsImage: Logo.image(width: width * 2))
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: width / 1.3)
    }
}
