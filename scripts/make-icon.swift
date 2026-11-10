#!/usr/bin/env swift
//
// Renders the OpenScreens app icon and writes it into the asset catalog.
//
//     swift scripts/make-icon.swift
//
// The artwork is drawn in code so it stays editable and reviewable: there is
// no binary source file to keep in sync. Run this again after changing the
// design and commit the regenerated PNGs.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root.appending(path: "Apps/Shared/Assets.xcassets/AppIcon.appiconset")

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

/// Draws the icon artwork into a unit square of `size` pixels.
///
/// - Parameter shaped: Draw the macOS icon shape (a rounded square inset from
///   the canvas with a soft shadow). iOS icons are full-bleed squares that the
///   system masks itself.
func drawIcon(size: CGFloat, shaped: Bool) -> CGImage {
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high

    // The plate the artwork sits on, following Apple's macOS icon grid:
    // an 824pt rounded square centred on a 1024pt canvas.
    let plate: CGRect
    let radius: CGFloat
    if shaped {
        let inset = size * (100.0 / 1024.0)
        plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        radius = plate.width * 0.2237
    } else {
        plate = CGRect(x: 0, y: 0, width: size, height: size)
        radius = 0
    }
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    if shaped {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.012),
            blur: size * 0.03,
            color: color(0, 0, 0, 0.32))
        context.addPath(platePath)
        context.setFillColor(color(0.2, 0.4, 0.95))
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(platePath)
    context.clip()

    // Background: indigo into azure, lit from the top left.
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.36, 0.33, 0.98), color(0.16, 0.53, 1.0), color(0.10, 0.78, 0.96)] as CFArray,
        locations: [0, 0.55, 1])!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: [])
    let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1, 1, 1, 0.34), color(1, 1, 1, 0)] as CFArray,
        locations: [0, 1])!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: plate.minX + plate.width * 0.22, y: plate.maxY - plate.height * 0.12),
        startRadius: 0,
        endCenter: CGPoint(x: plate.minX + plate.width * 0.22, y: plate.maxY - plate.height * 0.12),
        endRadius: plate.width * 0.85,
        options: [])

    // Coordinates below are fractions of the plate, origin at its top left.
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(
            x: plate.minX + x * plate.width,
            y: plate.maxY - (y + height) * plate.height,
            width: width * plate.width,
            height: height * plate.height)
    }
    let unit = plate.width

    // The far screen: a sheet of glass.
    let far = rect(0.15, 0.20, 0.56, 0.40)
    let farPath = CGPath(
        roundedRect: far, cornerWidth: unit * 0.055, cornerHeight: unit * 0.055, transform: nil)
    context.addPath(farPath)
    context.setFillColor(color(1, 1, 1, 0.24))
    context.fillPath()
    context.addPath(farPath)
    context.setStrokeColor(color(1, 1, 1, 0.62))
    context.setLineWidth(unit * 0.014)
    context.strokePath()

    // The near screen: solid, lifted off the far one.
    let near = rect(0.33, 0.39, 0.52, 0.39)
    let nearPath = CGPath(
        roundedRect: near, cornerWidth: unit * 0.06, cornerHeight: unit * 0.06, transform: nil)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -unit * 0.018),
        blur: unit * 0.05,
        color: color(0.03, 0.10, 0.40, 0.42))
    context.addPath(nearPath)
    context.setFillColor(color(1, 1, 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(nearPath)
    context.clip()
    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1, 1, 1), color(0.90, 0.95, 1.0)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: near.minX, y: near.maxY),
        end: CGPoint(x: near.minX, y: near.minY),
        options: [])
    context.restoreGState()

    // A pointer on the near screen — the thing you actually move.
    let pointerOrigin = CGPoint(x: near.minX + near.width * 0.36, y: near.maxY - near.height * 0.22)
    let scale = unit * 0.20
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: pointerOrigin.x + x * scale, y: pointerOrigin.y - y * scale)
    }
    let pointer = CGMutablePath()
    pointer.move(to: point(0, 0))
    pointer.addLine(to: point(0, 1.0))
    pointer.addLine(to: point(0.27, 0.76))
    pointer.addLine(to: point(0.46, 1.17))
    pointer.addLine(to: point(0.63, 1.09))
    pointer.addLine(to: point(0.44, 0.69))
    pointer.addLine(to: point(0.78, 0.69))
    pointer.closeSubpath()
    context.saveGState()
    context.setLineJoin(.round)
    context.addPath(pointer)
    context.clip()
    let ink = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.33, 0.30, 0.96), color(0.13, 0.50, 1.0)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        ink, start: point(0, 0), end: point(0.7, 1.1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    context.restoreGState()
    return context.makeImage()!
}

func write(_ image: CGImage, named name: String) throws {
    let url = iconSet.appending(path: name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var images: [[String: String]] = []

// iOS, iPadOS: one full-bleed 1024pt image.
try write(drawIcon(size: 1024, shaped: false), named: "icon-ios-1024.png")
images.append(["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])

// macOS: every size in the classic grid, each rendered at its own resolution.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = "icon-mac-\(points)@\(scale)x.png"
    try write(drawIcon(size: CGFloat(pixels), shaped: true), named: name)
    images.append([
        "filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)",
    ])
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: iconSet.appending(path: "Contents.json"))
print("Wrote \(images.count) icon images to \(iconSet.path)")
