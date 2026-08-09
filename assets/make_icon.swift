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

    // Aurora montant du bas (comme l'onboarding), discrète
    let blobXs: [CGFloat] = [220, 366, 512, 658, 804]
    for (index, x) in blobXs.enumerated() {
        let color = paletteRGB[(index + 2) % paletteRGB.count]
        let blob = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0.35),
            CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        let y: CGFloat = 120 + (index % 2 == 0 ? 0 : 46)
        ctx.drawRadialGradient(blob, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                               endCenter: CGPoint(x: x, y: y), endRadius: 280,
                               options: [])
    }

    let center = CGPoint(x: 512, y: 540)

    // Anneau fantôme : cercle blanc discret derrière l'éclair
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(64)
    ctx.strokeEllipse(in: CGRect(x: center.x - 250, y: center.y - 250,
                                 width: 500, height: 500))

    // Éclair rempli du dégradé aurora, halo violet
    let boltUnit: [CGPoint] = [
        CGPoint(x: 0.62, y: 1.00), CGPoint(x: 0.00, y: 0.42),
        CGPoint(x: 0.40, y: 0.42), CGPoint(x: 0.34, y: 0.00),
        CGPoint(x: 1.00, y: 0.60), CGPoint(x: 0.56, y: 0.60),
    ]
    let boltWidth: CGFloat = 280
    let boltHeight: CGFloat = 400
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
    ctx.setShadow(offset: .zero, blur: 46,
                  color: CGColor(srgbRed: 0.8, green: 0.4, blue: 0.9, alpha: 0.5))
    ctx.addPath(bolt)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    let boltGradient = CGGradient(colorsSpace: space, colors: [
        auroraColor(at: 0.0), auroraColor(at: 0.25), auroraColor(at: 0.5),
        auroraColor(at: 0.75), auroraColor(at: 0.95),
    ] as CFArray, locations: [0, 0.25, 0.5, 0.75, 1])!
    ctx.drawLinearGradient(boltGradient, start: CGPoint(x: 380, y: 740),
                           end: CGPoint(x: 640, y: 340), options: [])
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
