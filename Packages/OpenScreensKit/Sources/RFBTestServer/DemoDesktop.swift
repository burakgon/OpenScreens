import CoreGraphics
import Foundation

/// A drawn stand-in for a computer's desktop.
///
/// Tests need a picture with known pixels, and screenshots of the app need a
/// remote screen that is nobody's real desktop. Both get this: a wallpaper,
/// a menu bar, two windows and a Dock, rendered from a few numbers.
public enum DemoDesktop {

    public struct Style: Sendable {
        /// Wallpaper gradient stops, top left to bottom right.
        public var palette: [(red: CGFloat, green: CGFloat, blue: CGFloat)]
        public var isDark: Bool

        public init(palette: [(red: CGFloat, green: CGFloat, blue: CGFloat)], isDark: Bool = false) {
            self.palette = palette
            self.isDark = isDark
        }

        public static let sunrise = Style(palette: [(0.98, 0.55, 0.32), (0.86, 0.24, 0.52), (0.36, 0.20, 0.72)])
        public static let ocean = Style(palette: [(0.20, 0.72, 0.96), (0.22, 0.42, 0.95), (0.42, 0.24, 0.80)])
        public static let midnight = Style(
            palette: [(0.12, 0.16, 0.26), (0.18, 0.30, 0.46), (0.10, 0.48, 0.52)], isDark: true)
    }

    /// Renders a desktop of the given pixel size.
    public static func image(width: Int = 2560, height: Int = 1600, style: Style = .ocean) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [red, green, blue, alpha]) ?? CGColor(gray: 0, alpha: 1)
        }
        let w = CGFloat(width)
        let h = CGFloat(height)
        // Everything is laid out for a 1280-wide desktop and scaled up.
        let unit = w / 1280
        let palette = style.palette.isEmpty ? Style.ocean.palette : style.palette

        if let gradient = CGGradient(
            colorsSpace: space,
            colors: palette.map { color($0.red, $0.green, $0.blue) } as CFArray,
            locations: nil) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        if let glow = CGGradient(
            colorsSpace: space,
            colors: [color(1, 1, 1, 0.30), color(1, 1, 1, 0)] as CFArray,
            locations: nil) {
            let center = CGPoint(x: w * 0.72, y: h * 0.78)
            context.drawRadialGradient(
                glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: w * 0.55, options: [])
        }

        func fill(_ rect: CGRect, radius: CGFloat, _ fill: CGColor) {
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: min(radius, rect.width / 2),
                cornerHeight: min(radius, rect.height / 2),
                transform: nil))
            context.setFillColor(fill)
            context.fillPath()
        }

        let chrome = style.isDark ? color(0.13, 0.14, 0.17, 0.94) : color(0.98, 0.98, 0.99, 0.96)
        let subtle = style.isDark ? color(1, 1, 1, 0.10) : color(0, 0, 0, 0.07)
        let ink = style.isDark ? color(1, 1, 1, 0.55) : color(0, 0, 0, 0.42)

        func window(_ rect: CGRect, accent: CGColor) {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -14 * unit), blur: 40 * unit, color: color(0, 0, 0, 0.35))
            fill(rect, radius: 18 * unit, chrome)
            context.restoreGState()

            let top = rect.maxY - 26 * unit
            for (index, dot) in [color(1.0, 0.37, 0.34), color(1.0, 0.74, 0.18), color(0.16, 0.79, 0.25)].enumerated() {
                context.setFillColor(dot)
                context.fillEllipse(in: CGRect(
                    x: rect.minX + (20 + CGFloat(index) * 22) * unit, y: top - 7 * unit,
                    width: 14 * unit, height: 14 * unit))
            }

            let sidebar = CGRect(
                x: rect.minX, y: rect.minY, width: rect.width * 0.26, height: rect.height - 52 * unit)
            context.saveGState()
            context.addPath(CGPath(
                roundedRect: rect, cornerWidth: 18 * unit, cornerHeight: 18 * unit, transform: nil))
            context.clip()
            context.setFillColor(subtle)
            context.fill(sidebar)
            context.restoreGState()
            for row in 0..<5 {
                fill(
                    CGRect(
                        x: sidebar.minX + 18 * unit,
                        y: sidebar.maxY - (34 + CGFloat(row) * 30) * unit,
                        width: sidebar.width - (36 + CGFloat(row % 3) * 22) * unit,
                        height: 12 * unit),
                    radius: 6 * unit, row == 1 ? accent : subtle)
            }
            let contentX = sidebar.maxX + 26 * unit
            let contentWidth = rect.maxX - contentX - 26 * unit
            fill(
                CGRect(x: contentX, y: rect.maxY - 100 * unit, width: contentWidth * 0.5, height: 18 * unit),
                radius: 9 * unit, ink)
            for row in 0..<6 {
                fill(
                    CGRect(
                        x: contentX,
                        y: rect.maxY - (140 + CGFloat(row) * 26) * unit,
                        width: contentWidth * (row % 2 == 0 ? 0.92 : 0.74),
                        height: 10 * unit),
                    radius: 5 * unit, subtle)
            }
            fill(
                CGRect(
                    x: contentX, y: rect.minY + 26 * unit,
                    width: contentWidth, height: max(40 * unit, rect.height * 0.26)),
                radius: 12 * unit, accent)
        }

        let first = palette[0]
        let second = palette[min(1, palette.count - 1)]
        window(
            CGRect(x: w * 0.08, y: h * 0.20, width: w * 0.52, height: h * 0.58),
            accent: color(first.red, first.green, first.blue, 0.85))
        window(
            CGRect(x: w * 0.46, y: h * 0.14, width: w * 0.44, height: h * 0.50),
            accent: color(second.red, second.green, second.blue, 0.85))

        // Menu bar.
        context.setFillColor(style.isDark ? color(0, 0, 0, 0.34) : color(1, 1, 1, 0.38))
        context.fill(CGRect(x: 0, y: h - 30 * unit, width: w, height: 30 * unit))
        for index in 0..<6 {
            fill(
                CGRect(
                    x: (22 + CGFloat(index) * 62) * unit, y: h - 20 * unit,
                    width: (index == 0 ? 16 : 44) * unit, height: 9 * unit),
                radius: 4.5 * unit, color(1, 1, 1, 0.82))
        }
        for index in 0..<4 {
            fill(
                CGRect(
                    x: w - (40 + CGFloat(index) * 34) * unit, y: h - 21 * unit,
                    width: 20 * unit, height: 11 * unit),
                radius: 5 * unit, color(1, 1, 1, 0.7))
        }

        // Dock.
        let dock = CGRect(x: w * 0.27, y: 12 * unit, width: w * 0.46, height: 68 * unit)
        fill(dock, radius: 22 * unit, style.isDark ? color(0.1, 0.1, 0.12, 0.55) : color(1, 1, 1, 0.42))
        let icons = 9
        let size = 46 * unit
        let gap = (dock.width - CGFloat(icons) * size) / CGFloat(icons + 1)
        for index in 0..<icons {
            let tint = palette[index % palette.count]
            fill(
                CGRect(
                    x: dock.minX + gap + CGFloat(index) * (size + gap), y: dock.minY + 11 * unit,
                    width: size, height: size),
                radius: 12 * unit,
                color(
                    min(1, tint.red * 0.6 + 0.35 * CGFloat((index * 37) % 10) / 10 + 0.15),
                    min(1, tint.green * 0.6 + 0.35 * CGFloat((index * 53) % 10) / 10 + 0.15),
                    min(1, tint.blue * 0.6 + 0.35 * CGFloat((index * 71) % 10) / 10 + 0.15)))
        }
        return context.makeImage()
    }

    /// A flat test card: four coloured quadrants, so a test can tell which
    /// way up a picture arrived and whether its channels are in order.
    public static func testCard(width: Int = 320, height: Int = 200) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let halfWidth = CGFloat(width) / 2
        let halfHeight = CGFloat(height) / 2
        // Core Graphics draws from the bottom left; quadrants are named for
        // where they appear on screen.
        let quadrants: [(CGRect, [CGFloat])] = [
            (CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), [1, 0, 0, 1]),          // top left: red
            (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), [0, 1, 0, 1]),  // top right: green
            (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), [0, 0, 1, 1]),                   // bottom left: blue
            (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), [1, 1, 1, 1]),           // bottom right: white
        ]
        for (rect, components) in quadrants {
            context.setFillColor(CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0, alpha: 1))
            context.fill(rect)
        }
        return context.makeImage()
    }
}
