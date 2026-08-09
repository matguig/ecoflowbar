// Variantes du logo EcoFlowBar — aperçus 512 px (v2 à v6)
import AppKit
import CoreGraphics

let paletteRGB: [(CGFloat, CGFloat, CGFloat)] = [
    (0.32, 0.54, 1.00), (0.72, 0.62, 1.00), (1.00, 0.45, 0.65),
    (1.00, 0.32, 0.24), (1.00, 0.80, 0.30),
]

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func auroraColor(at t: CGFloat, alpha: CGFloat = 1) -> CGColor {
    let n = paletteRGB.count
    let x = ((t.truncatingRemainder(dividingBy: 1)) + 1)
        .truncatingRemainder(dividingBy: 1) * CGFloat(n)
    let i = Int(x) % n, j = (i + 1) % n
    let f = x - floor(x)
    let c1 = paletteRGB[i], c2 = paletteRGB[j]
    return CGColor(srgbRed: lerp(c1.0, c2.0, f), green: lerp(c1.1, c2.1, f),
                   blue: lerp(c1.2, c2.2, f), alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func boltPath(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    let unit: [CGPoint] = [
        CGPoint(x: 0.62, y: 1.00), CGPoint(x: 0.00, y: 0.42),
        CGPoint(x: 0.40, y: 0.42), CGPoint(x: 0.34, y: 0.00),
        CGPoint(x: 1.00, y: 0.60), CGPoint(x: 0.56, y: 0.60),
    ]
    let origin = CGPoint(x: center.x - width / 2 - 10, y: center.y - height / 2)
    let path = CGMutablePath()
    for (i, p) in unit.enumerated() {
        let pt = CGPoint(x: origin.x + p.x * width, y: origin.y + p.y * height)
        i == 0 ? path.move(to: pt) : path.addLine(to: pt)
    }
    path.closeSubpath()
    return path
}

func auroraBlobs(_ ctx: CGContext, baseY: CGFloat, radius: CGFloat, alpha: CGFloat) {
    for (i, x) in [CGFloat(220), 366, 512, 658, 804].enumerated() {
        let c = paletteRGB[(i + 2) % paletteRGB.count]
        let g = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha),
            CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        let y = baseY + (i % 2 == 0 ? 0 : 46)
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                               endCenter: CGPoint(x: x, y: y), endRadius: radius, options: [])
    }
}

func gradientRing(_ ctx: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat,
                  from startDeg: CGFloat, sweep sweepDeg: CGFloat, roundCaps: Bool) {
    let segments = 300
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    for s in 0..<segments {
        let t = CGFloat(s) / CGFloat(segments)
        let a0 = (startDeg - t * sweepDeg) * .pi / 180
        let a1 = a0 - (sweepDeg / CGFloat(segments)) * 1.6 * .pi / 180
        ctx.setStrokeColor(auroraColor(at: t))
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.strokePath()
    }
    if roundCaps {
        for (t, deg) in [(CGFloat(0), startDeg), (1, startDeg - sweepDeg)] {
            let a = deg * .pi / 180
            let p = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            ctx.setFillColor(auroraColor(at: t))
            ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2,
                                       width: width, height: width))
        }
    }
}

func render(variant: Int, pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let corner: CGFloat = 824 * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner,
                          transform: nil)
    let light = variant == 4
    let baseFill = light
        ? CGColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: 1)
        : CGColor(srgbRed: 0.10, green: 0.11, blue: 0.17, alpha: 1)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(baseFill)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    if light {
        let bg = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.99, green: 0.985, blue: 0.97, alpha: 1),
            CGColor(srgbRed: 0.93, green: 0.92, blue: 0.90, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 100), options: [])
    } else {
        let bg = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.15, green: 0.17, blue: 0.25, alpha: 1),
            CGColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 100), options: [])
    }

    let center = CGPoint(x: 512, y: 540)

    switch variant {
    case 2:  // Jauge ouverte : arc 300° à bouts ronds, éclair blanc
        auroraBlobs(ctx, baseY: 120, radius: 300, alpha: 0.5)
        gradientRing(ctx, center: center, radius: 252, width: 76,
                     from: 240, sweep: 300, roundCaps: true)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 40, color: CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(boltPath(center: center, width: 240, height: 336))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

    case 3:  // Inversé : anneau blanc discret, éclair rempli du dégradé aurora
        auroraBlobs(ctx, baseY: 120, radius: 280, alpha: 0.35)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.setLineWidth(64)
        ctx.strokeEllipse(in: CGRect(x: center.x - 250, y: center.y - 250,
                                     width: 500, height: 500))
        let bolt = boltPath(center: center, width: 280, height: 400)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 46,
                      color: CGColor(srgbRed: 0.8, green: 0.4, blue: 0.9, alpha: 0.5))
        ctx.addPath(bolt)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(bolt)
        ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [
            auroraColor(at: 0.0), auroraColor(at: 0.25), auroraColor(at: 0.5),
            auroraColor(at: 0.75), auroraColor(at: 0.95),
        ] as CFArray, locations: [0, 0.25, 0.5, 0.75, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 380, y: 740),
                               end: CGPoint(x: 640, y: 340), options: [])
        ctx.restoreGState()

    case 4:  // Clair façon Dia : fond crème, anneau aurora, éclair anthracite
        auroraBlobs(ctx, baseY: 110, radius: 320, alpha: 0.45)
        gradientRing(ctx, center: center, radius: 252, width: 72,
                     from: 90, sweep: 360, roundCaps: false)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: CGColor(gray: 0, alpha: 0.25))
        ctx.addPath(boltPath(center: center, width: 240, height: 336))
        ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.14, blue: 0.19, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

    case 5:  // Aurora totale : pas d'anneau, aurora massive, grand éclair blanc
        auroraBlobs(ctx, baseY: 260, radius: 520, alpha: 0.75)
        auroraBlobs(ctx, baseY: 80, radius: 380, alpha: 0.6)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60, color: CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(boltPath(center: CGPoint(x: 512, y: 520), width: 330, height: 480))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

    case 6:  // Orbe de l'intro : disque aurora lumineux, éclair sombre
        auroraBlobs(ctx, baseY: 120, radius: 280, alpha: 0.3)
        for s in 0..<360 {
            let t = CGFloat(s) / 360
            let a0 = (90 - t * 360) * CGFloat.pi / 180
            let a1 = a0 - 1.7 * .pi / 180
            ctx.setFillColor(auroraColor(at: t))
            let wedge = CGMutablePath()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: 270, startAngle: a0, endAngle: a1,
                         clockwise: true)
            wedge.closeSubpath()
            ctx.addPath(wedge)
            ctx.fillPath()
        }
        let core = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(core, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: 230, options: [])
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 24, color: CGColor(gray: 1, alpha: 0.4))
        ctx.addPath(boltPath(center: center, width: 230, height: 320))
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

    default:
        break
    }

    ctx.restoreGState()
    return ctx.makeImage()!
}

for variant in 2...6 {
    let image = render(variant: variant, pixels: 512)
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "assets/icon-v\(variant).png"))
    print("v\(variant) OK")
}
