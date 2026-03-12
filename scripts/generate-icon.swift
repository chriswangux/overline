#!/usr/bin/env swift
// generate-icon.swift — Generates Overline app icon
// Usage: swift scripts/generate-icon.swift [output-dir]
// Default output: Resources/Overline.iconset/

import AppKit

let outputDir: String
if CommandLine.arguments.count > 1 {
    outputDir = CommandLine.arguments[1]
} else {
    outputDir = "Resources/Overline.iconset"
}

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))

    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let pad = s * 0.08
    let area = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)

    // Background circle
    let bgPath = CGMutablePath()
    bgPath.addEllipse(in: area)

    let bgColors: [CGColor] = [
        CGColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1.0),
        CGColor(srgbRed: 0.09, green: 0.085, blue: 0.075, alpha: 1.0),
    ]
    let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: bgColors as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawRadialGradient(bgGrad,
                           startCenter: CGPoint(x: area.midX, y: area.midY + area.height * 0.1),
                           startRadius: 0,
                           endCenter: CGPoint(x: area.midX, y: area.midY),
                           endRadius: area.width * 0.55,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // No circle border — clean

    // =========================================================
    // Just the golden bar — centered, with dreamy layered glow
    // Matching E13 canvas version
    // =========================================================
    let cx = area.midX
    let cy = area.midY
    let barW = area.width * 0.42
    let barH = max(4, s * 0.032)
    let barR = max(2, s * 0.012)
    let barX = cx - barW / 2
    let barY = cy - barH / 2

    // Layer 1: Wide atmospheric glow (biggest, softest)
    let glow1Colors: [CGColor] = [
        CGColor(srgbRed: 0.78, green: 0.63, blue: 0.39, alpha: 0.28),
        CGColor(srgbRed: 0.78, green: 0.63, blue: 0.39, alpha: 0.08),
        CGColor(srgbRed: 0.78, green: 0.63, blue: 0.39, alpha: 0.0),
    ]
    let glow1 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: glow1Colors as CFArray, locations: [0, 0.4, 1])!
    ctx.drawRadialGradient(glow1,
                           startCenter: CGPoint(x: cx, y: cy),
                           startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy),
                           endRadius: s * 0.35,
                           options: [])

    // Layer 2: Off-center warm spot (dreamy asymmetry)
    let glow2Colors: [CGColor] = [
        CGColor(srgbRed: 0.86, green: 0.74, blue: 0.55, alpha: 0.06),
        CGColor(srgbRed: 0.78, green: 0.63, blue: 0.39, alpha: 0.0),
    ]
    let glow2 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: glow2Colors as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow2,
                           startCenter: CGPoint(x: cx + s * 0.06, y: cy - s * 0.04),
                           startRadius: 0,
                           endCenter: CGPoint(x: cx + s * 0.06, y: cy - s * 0.04),
                           endRadius: s * 0.18,
                           options: [])

    // Layer 3: Tight bright glow around bar
    let glow3Colors: [CGColor] = [
        CGColor(srgbRed: 0.85, green: 0.72, blue: 0.48, alpha: 0.40),
        CGColor(srgbRed: 0.78, green: 0.63, blue: 0.39, alpha: 0.12),
        CGColor(srgbRed: 0.78, green: 0.63, blue: 0.39, alpha: 0.0),
    ]
    let glow3 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: glow3Colors as CFArray, locations: [0, 0.4, 1])!
    ctx.drawRadialGradient(glow3,
                           startCenter: CGPoint(x: cx, y: cy),
                           startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy),
                           endRadius: s * 0.14,
                           options: [])

    // Layer 4: Innermost bright halo
    let glow4Colors: [CGColor] = [
        CGColor(srgbRed: 0.96, green: 0.88, blue: 0.72, alpha: 0.30),
        CGColor(srgbRed: 0.85, green: 0.72, blue: 0.48, alpha: 0.0),
    ]
    let glow4 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: glow4Colors as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow4,
                           startCenter: CGPoint(x: cx, y: cy),
                           startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy),
                           endRadius: s * 0.08,
                           options: [])

    // Bar body gradient
    let barPath = CGPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH),
                         cornerWidth: barR, cornerHeight: barR, transform: nil)
    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.clip()
    let barColors: [CGColor] = [
        CGColor(srgbRed: 0.96, green: 0.90, blue: 0.75, alpha: 1.0),
        CGColor(srgbRed: 0.78, green: 0.63, blue: 0.39, alpha: 1.0),
        CGColor(srgbRed: 0.58, green: 0.46, blue: 0.27, alpha: 1.0),
    ]
    let barGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: barColors as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(barGrad,
                           start: CGPoint(x: barX, y: barY + barH),
                           end: CGPoint(x: barX, y: barY),
                           options: [])

    // Top highlight
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.fill([CGRect(x: barX + s * 0.008, y: barY + barH - max(0.5, s * 0.004),
                     width: barW - s * 0.016, height: max(0.5, s * 0.004))])

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

for (filename, pixelSize) in sizes {
    let image = drawIcon(size: pixelSize)

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to generate \(filename)")
        continue
    }

    let path = (outputDir as NSString).appendingPathComponent(filename)
    try pngData.write(to: URL(fileURLWithPath: path))
    print("Generated \(filename) (\(pixelSize)x\(pixelSize))")
}

print("Done! Now run: iconutil -c icns \(outputDir) -o Resources/AppIcon.icns")
