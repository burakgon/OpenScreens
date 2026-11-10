#if DEBUG
import CoreGraphics
import Foundation
import OpenScreensCore

/// Sample library content for development, previews and screenshots.
///
/// Launch a debug build with `OPENSCREENS_SAMPLE_DATA=1` to fill an empty
/// library with a handful of invented computers, each with a drawn stand-in
/// for its last-seen screen. Nothing here refers to a real machine.
enum DebugSampleData {
    static func seedIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.environment["OPENSCREENS_SAMPLE_DATA"] == "1" else { return }
        // Invented computers stand in for the network too: a screenshot
        // should not show what is really around.
        model.nearby.stop()
        model.tailscale.stop()
        model.sampleDiscovery = SampleDiscovery(
            nearby: [
                NearbyComputer(name: "Mac Studio", host: "mac-studio.local", kind: .mac, supportsSSH: true),
                NearbyComputer(name: "Living Room iMac", host: "living-room-imac.local", kind: .mac, model: "iMac21,1"),
                NearbyComputer(name: "Raspberry Pi", host: "raspberrypi.local", kind: .raspberryPi, supportsSSH: true),
                NearbyComputer(name: "Office NAS", host: "office-nas.local", kind: .linux),
            ],
            tailscale: [
                TailscaleDevice(
                    id: "n1", name: "mini", dnsName: "mini.tailnet-example.ts.net",
                    addresses: ["100.64.0.11"], os: "macOS", isOnline: true),
                TailscaleDevice(
                    id: "n2", name: "office-imac", dnsName: "office-imac.tailnet-example.ts.net",
                    addresses: ["100.64.0.12"], os: "macOS", isOnline: true),
                TailscaleDevice(
                    id: "n3", name: "build-box", dnsName: "build-box.tailnet-example.ts.net",
                    addresses: ["100.64.0.13"], os: "linux", isOnline: true),
                TailscaleDevice(
                    id: "n4", name: "old-laptop", dnsName: "old-laptop.tailnet-example.ts.net",
                    addresses: ["100.64.0.14"], os: "windows", isOnline: false),
            ])
        guard model.library.computers.isEmpty else { return }

        let home = model.library.addGroup(named: "Home", symbolName: "house")
        let work = model.library.addGroup(named: "Studio", symbolName: "building.2")

        struct Sample {
            var name: String
            var host: String
            var username: String?
            var kind: ComputerKind
            var group: UUID?
            var favorite = false
            var tags: [String] = []
            var connectedMinutesAgo: Double?
            var palette: [(CGFloat, CGFloat, CGFloat)]
            var darkDesktop = false
        }

        let samples: [Sample] = [
            Sample(
                name: "Mac Studio", host: "mac-studio.local", username: "alex", kind: .mac,
                group: work.id, favorite: true, tags: ["render"], connectedMinutesAgo: 12,
                palette: [(0.98, 0.55, 0.32), (0.86, 0.24, 0.52), (0.36, 0.20, 0.72)]),
            Sample(
                name: "MacBook Air", host: "macbook-air.local", username: "alex", kind: .mac,
                group: home.id, favorite: true, connectedMinutesAgo: 190,
                palette: [(0.20, 0.72, 0.96), (0.22, 0.42, 0.95), (0.42, 0.24, 0.80)]),
            Sample(
                name: "Mac mini Server", host: "mini.tailnet-example.ts.net", username: "admin", kind: .mac,
                group: work.id, tags: ["server", "ci"], connectedMinutesAgo: 1500,
                palette: [(0.12, 0.16, 0.26), (0.18, 0.30, 0.46), (0.10, 0.48, 0.52)], darkDesktop: true),
            Sample(
                name: "Gaming PC", host: "192.168.1.42", username: nil, kind: .windows,
                group: home.id, connectedMinutesAgo: 4300,
                palette: [(0.10, 0.44, 0.86), (0.06, 0.62, 0.86), (0.30, 0.82, 0.90)]),
            Sample(
                name: "Build Box", host: "ubuntu-build.local", username: nil, kind: .linux,
                group: work.id, tags: ["ci"],
                palette: [(0.90, 0.36, 0.18), (0.62, 0.18, 0.38), (0.24, 0.10, 0.30)], darkDesktop: true),
            Sample(
                name: "Raspberry Pi", host: "raspberrypi.local", username: nil, kind: .raspberryPi,
                group: home.id,
                palette: [(0.80, 0.16, 0.36), (0.56, 0.12, 0.44), (0.22, 0.14, 0.40)], darkDesktop: true),
        ]

        for sample in samples {
            var computer = Computer(
                name: sample.name,
                host: sample.host,
                username: sample.username,
                kind: sample.kind,
                groupID: sample.group,
                isFavorite: sample.favorite,
                tags: sample.tags,
                settings: sample.kind.isApple ? ConnectionSettings() : .defaults(for: sample.kind))
            computer = model.library.add(computer)
            if let minutes = sample.connectedMinutesAgo {
                model.library.update(computer.id) {
                    $0.lastConnectedAt = Date.now.addingTimeInterval(-minutes * 60)
                }
            }
            if let preview = desktopPreview(palette: sample.palette, kind: sample.kind, dark: sample.darkDesktop) {
                PreviewStore.shared.save(preview, for: computer.id)
            }
        }
        model.library.saveNow()
    }

    /// Draws a schematic desktop — wallpaper, menu bar, a couple of windows
    /// and a dock — to stand in for a real last-seen screen.
    private static func desktopPreview(
        palette: [(CGFloat, CGFloat, CGFloat)],
        kind: ComputerKind,
        dark: Bool
    ) -> CGImage? {
        let width = 1280
        let height = 800
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, a]) ?? CGColor(gray: 0, alpha: 1)
        }
        let w = CGFloat(width)
        let h = CGFloat(height)

        // Wallpaper.
        let colors = palette.map { color($0.0, $0.1, $0.2) } as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: nil) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        if let glow = CGGradient(
            colorsSpace: space,
            colors: [color(1, 1, 1, 0.30), color(1, 1, 1, 0)] as CFArray,
            locations: nil) {
            context.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: w * 0.72, y: h * 0.78), startRadius: 0,
                endCenter: CGPoint(x: w * 0.72, y: h * 0.78), endRadius: w * 0.55,
                options: [])
        }

        func roundedRect(_ rect: CGRect, radius: CGFloat, fill: CGColor) {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(fill)
            context.fillPath()
        }

        let chrome = dark ? color(0.13, 0.14, 0.17, 0.92) : color(0.98, 0.98, 0.99, 0.94)
        let subtle = dark ? color(1, 1, 1, 0.10) : color(0, 0, 0, 0.07)
        let ink = dark ? color(1, 1, 1, 0.55) : color(0, 0, 0, 0.42)

        // Windows.
        func window(_ rect: CGRect, accent: CGColor) {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: color(0, 0, 0, 0.35))
            roundedRect(rect, radius: 18, fill: chrome)
            context.restoreGState()
            // Title bar controls.
            let top = rect.maxY - 26
            if kind.isApple {
                for (index, dot) in [color(1.0, 0.37, 0.34), color(1.0, 0.74, 0.18), color(0.16, 0.79, 0.25)].enumerated() {
                    context.setFillColor(dot)
                    context.fillEllipse(in: CGRect(x: rect.minX + 20 + CGFloat(index) * 22, y: top - 7, width: 14, height: 14))
                }
            } else {
                for index in 0..<3 {
                    roundedRect(
                        CGRect(x: rect.maxX - 34 - CGFloat(index) * 34, y: top - 2, width: 16, height: 4),
                        radius: 2, fill: ink)
                }
            }
            // Sidebar and content placeholders.
            let sidebar = CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.26, height: rect.height - 52)
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.clip()
            context.setFillColor(subtle)
            context.fill(sidebar)
            context.restoreGState()
            for row in 0..<5 {
                roundedRect(
                    CGRect(x: sidebar.minX + 18, y: sidebar.maxY - 34 - CGFloat(row) * 30, width: sidebar.width - 36 - CGFloat(row % 3) * 22, height: 12),
                    radius: 6, fill: row == 1 ? accent : subtle)
            }
            let contentX = sidebar.maxX + 26
            let contentWidth = rect.maxX - contentX - 26
            roundedRect(
                CGRect(x: contentX, y: rect.maxY - 100, width: contentWidth * 0.5, height: 18),
                radius: 9, fill: ink)
            for row in 0..<6 {
                roundedRect(
                    CGRect(x: contentX, y: rect.maxY - 140 - CGFloat(row) * 26, width: contentWidth * (row % 2 == 0 ? 0.92 : 0.74), height: 10),
                    radius: 5, fill: subtle)
            }
            roundedRect(
                CGRect(x: contentX, y: rect.minY + 26, width: contentWidth, height: max(40, rect.height * 0.26)),
                radius: 12, fill: accent)
        }

        let accent = color(palette[0].0, palette[0].1, palette[0].2, 0.85)
        window(CGRect(x: w * 0.08, y: h * 0.20, width: w * 0.52, height: h * 0.58), accent: accent)
        window(CGRect(x: w * 0.46, y: h * 0.14, width: w * 0.44, height: h * 0.50), accent: color(palette[1].0, palette[1].1, palette[1].2, 0.85))

        if kind.isApple {
            // Menu bar and Dock.
            context.setFillColor(dark ? color(0, 0, 0, 0.34) : color(1, 1, 1, 0.38))
            context.fill(CGRect(x: 0, y: h - 30, width: w, height: 30))
            for index in 0..<6 {
                roundedRect(
                    CGRect(x: 22 + CGFloat(index) * 62, y: h - 20, width: index == 0 ? 16 : 44, height: 9),
                    radius: 4.5, fill: color(1, 1, 1, 0.82))
            }
            let dock = CGRect(x: w * 0.27, y: 12, width: w * 0.46, height: 68)
            roundedRect(dock, radius: 22, fill: dark ? color(0.1, 0.1, 0.12, 0.55) : color(1, 1, 1, 0.42))
            let icons = 9
            let size: CGFloat = 46
            let gap = (dock.width - CGFloat(icons) * size) / CGFloat(icons + 1)
            for index in 0..<icons {
                let tint = palette[index % palette.count]
                roundedRect(
                    CGRect(x: dock.minX + gap + CGFloat(index) * (size + gap), y: dock.minY + 11, width: size, height: size),
                    radius: 12,
                    fill: color(
                        min(1, tint.0 * 0.6 + 0.35 * CGFloat((index * 37) % 10) / 10 + 0.15),
                        min(1, tint.1 * 0.6 + 0.35 * CGFloat((index * 53) % 10) / 10 + 0.15),
                        min(1, tint.2 * 0.6 + 0.35 * CGFloat((index * 71) % 10) / 10 + 0.15)))
            }
        } else {
            // Taskbar.
            context.setFillColor(color(0.08, 0.09, 0.12, 0.82))
            context.fill(CGRect(x: 0, y: 0, width: w, height: 46))
            for index in 0..<7 {
                roundedRect(
                    CGRect(x: w * 0.36 + CGFloat(index) * 44, y: 9, width: 28, height: 28),
                    radius: 7, fill: color(1, 1, 1, index == 0 ? 0.9 : 0.28))
            }
        }
        return context.makeImage()
    }
}
#endif
