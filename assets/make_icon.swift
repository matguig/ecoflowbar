// Générateur de l'icône EcoFlowBar — reprend les codes visuels de l'app :
// anneau héros au dégradé aurora, éclair central, aurora montant du bas.
// Respecte la grille macOS : squircle 824/1024 centrée, marge transparente,
// ombre portée. Usage : swift assets/make_icon.swift
import AppKit
import CoreGraphics

let paletteRGB: [(CGFloat, CGFloat, CGFloat)] = [
    (0.32, 0.54, 1.00),  // bleu (départ en haut de l'anneau)
    (0.72, 0.62, 1.00),  // lavande
    (1.00, 0.45, 0.65),  // rose
    (1.00, 0.32, 0.24),  // rouge
    (1.00, 0.80, 0.30),  // jaune
]

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func auroraColor(at t: CGFloat, alpha: CGFloat = 1) -> CGColor {
    let n = paletteRGB.count
    let x = ((t.truncatingRemainder(dividingBy: 1)) + 1)
        .truncatingRemainder(dividingBy: 1) * CGFloat(n)
    let i = Int(x) % n
    let j = (i + 1) % n
    let f = x - floor(x)
    let c1 = paletteRGB[i], c2 = paletteRGB[j]
    return CGColor(srgbRed: lerp(c1.0, c2.0, f), green: lerp(c1.1, c2.1, f),
                   blue: lerp(c1.2, c2.2, f), alpha: alpha)
}

func makeIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // Squircle Apple : 824 pt centrés, coins ≈ 22,37 %
    let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let corner: CGFloat = 824 * 0.2237
    let squircle = CGPath(roundedRect: squircleRect,
                          cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Ombre portée douce sous la squircle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.17, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Fond : dégradé sombre du panneau
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.15, green: 0.17, blue: 0.25, alpha: 1),
        CGColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100), options: [])

    // Aurora montant du bas (comme l'onboarding) : halos radiaux colorés
    let blobXs: [CGFloat] = [220, 366, 512, 658, 804]
    for (index, x) in blobXs.enumerated() {
        let color = paletteRGB[(index + 2) % paletteRGB.count]
        let blob = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0.55),
            CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        let y: CGFloat = 120 + (index % 2 == 0 ? 0 : 46)
        ctx.drawRadialGradient(blob, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                               endCenter: CGPoint(x: x, y: y), endRadius: 300,
                               options: [])
    }

    // Anneau héros : cercle complet en dégradé aurora (segments interpolés)
    let center = CGPoint(x: 512, y: 540)
    let radius: CGFloat = 252
    let ringWidth: CGFloat = 72
    let segments = 360
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.butt)
    for segment in 0..<segments {
        let t = CGFloat(segment) / CGFloat(segments)
        // Départ en haut, sens horaire
        let a0 = CGFloat.pi / 2 - t * 2 * .pi
        let a1 = a0 - (2 * .pi / CGFloat(segments)) * 1.6  // léger recouvrement
        ctx.setStrokeColor(auroraColor(at: t))
        ctx.addArc(center: center, radius: radius,
                   startAngle: a0, endAngle: a1, clockwise: true)
        ctx.strokePath()
    }

    // Lueur douce derrière l'éclair
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: 210, options: [])

    // Éclair central (points normalisés dans une boîte 260×360 centrée)
    let boltUnit: [CGPoint] = [
        CGPoint(x: 0.62, y: 1.00), CGPoint(x: 0.00, y: 0.42),
        CGPoint(x: 0.40, y: 0.42), CGPoint(x: 0.34, y: 0.00),
        CGPoint(x: 1.00, y: 0.60), CGPoint(x: 0.56, y: 0.60),
    ]
    let boltWidth: CGFloat = 250
    let boltHeight: CGFloat = 350
    let boltOrigin = CGPoint(x: center.x - boltWidth / 2 - 10,
                             y: center.y - boltHeight / 2)
    let bolt = CGMutablePath()
    for (index, p) in boltUnit.enumerated() {
        let point = CGPoint(x: boltOrigin.x + p.x * boltWidth,
                            y: boltOrigin.y + p.y * boltHeight)
        if index == 0 { bolt.move(to: point) } else { bolt.addLine(to: point) }
    }
    bolt.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: CGColor(gray: 0, alpha: 0.55))
    ctx.addPath(bolt)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Léger dégradé sur l'éclair pour la profondeur
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    let boltGradient = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.85, green: 0.89, blue: 1.00, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(boltGradient,
                           start: CGPoint(x: 512, y: boltOrigin.y + boltHeight),
                           end: CGPoint(x: 512, y: boltOrigin.y), options: [])
    ctx.restoreGState()

    ctx.restoreGState()  // fin du clip squircle
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let base = FileManager.default.currentDirectoryPath + "/assets"
let iconset = base + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    writePNG(makeIcon(pixels: pixels), to: "\(iconset)/\(name).png")
}
writePNG(makeIcon(pixels: 512), to: base + "/icon-preview.png")
print("iconset généré dans \(iconset)")
