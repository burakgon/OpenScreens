#if DEBUG
import Foundation
import OpenScreensCore
import rootshellVNC
import SwiftUI

/// Scripted launches for development and end-to-end checks.
///
/// Debug builds read a few environment variables at launch so a connection
/// can be opened, exercised and reported on without touching the interface:
///
///     OPENSCREENS_CONNECT=vnc://user:password@host   open this address
///     OPENSCREENS_QUALITY=highPerformance|standard|fullQuality
///     OPENSCREENS_RESOLUTION=matchWindow|remote
///     OPENSCREENS_MORE_SPACE=1                        a desktop at least 1024 points wide
///     OPENSCREENS_DISPLAYS=single|allCombined|twoVirtual
///     OPENSCREENS_KEYBOARD=automatic|keystrokes|unicode
///     OPENSCREENS_OBSERVE=1                           watch without sending input
///     OPENSCREENS_SHARED_CLIPBOARD=1                  share the clipboard (off unless asked for)
///     OPENSCREENS_LOCK_ON_DISCONNECT=1                lock the remote Mac on leaving
///     OPENSCREENS_TOUCH=trackpad|touch                how touches drive the pointer
///     OPENSCREENS_DECK=1                              start with the trackpad deck out
///     OPENSCREENS_STATISTICS=1                        show the statistics overlay
///     OPENSCREENS_SECTION=favorites|recents|nearby|tailscale   open the library there
///     OPENSCREENS_TRUST_HOST_KEY=1                    accept the SSH server's key when asked
///     OPENSCREENS_SSH_PASSWORD=secret                 answer the SSH sign-in when asked
///     OPENSCREENS_KEYS="t=text|tap=cmd+c|…"           run a key script (see below)
///     OPENSCREENS_TYPE="text"                         type this once connected
///     OPENSCREENS_TYPE_AFTER=1                        seconds to wait before typing
///     OPENSCREENS_CLICK=640,400                       click at this remote pixel first
///     OPENSCREENS_REPORT=/path/prefix                 write prefix.json and prefix.png
///     OPENSCREENS_REPORT_AFTER=6                      seconds to wait after connecting
///     OPENSCREENS_EXIT=1                              quit after reporting
///     OPENSCREENS_ENGINE_LOG=info|debug|trace         print the engine's log
///
/// None of this exists in release builds.
enum DebugAutomation {
    private static var didStart = false

    /// Whether sessions start with the trackpad deck out.
    static var startsWithDeck: Bool {
        ProcessInfo.processInfo.environment["OPENSCREENS_DECK"] == "1"
    }

    /// The library section to open at launch, from `OPENSCREENS_SECTION`.
    static var requestedSection: LibraryFilter? {
        switch ProcessInfo.processInfo.environment["OPENSCREENS_SECTION"] {
        case "favorites": .favorites
        case "recents": .recents
        case "nearby": .nearby
        case "tailscale": .tailscale
        default: nil
        }
    }

    static func runIfRequested(model: AppModel, present: @escaping (RemoteSession) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard !didStart,
              let address = environment["OPENSCREENS_CONNECT"],
              var target = ConnectionTarget(text: address) else { return }
        didStart = true
        if environment["OPENSCREENS_STATISTICS"] == "1" {
            model.settings.showsStatisticsOverlay = true
        }
        if let level = environment["OPENSCREENS_ENGINE_LOG"] {
            // The engine logs privately to the system log, which cannot be
            // read back; this is the same stream on standard error.
            VNCDebugLogging.install(minimumLevel: level) { level, category, message in
                FileHandle.standardError.write(Data("[engine \(level) \(category)] \(message)\n".utf8))
            }
        }
        if let kind = environment["OPENSCREENS_KIND"].flatMap(ComputerKind.init(rawValue:)) {
            target.kind = kind
        }

        let session = model.sessions.open(target)
        session.update { settings in
            if let quality = environment["OPENSCREENS_QUALITY"].flatMap(QualityMode.init(rawValue:)) {
                settings.quality = quality
                if quality != .highPerformance {
                    settings.resolution = .remote
                }
            }
            if let resolution = environment["OPENSCREENS_RESOLUTION"].flatMap(ResolutionMode.init(rawValue:)) {
                settings.resolution = resolution
            }
            settings.moreSpace = environment["OPENSCREENS_MORE_SPACE"] == "1"
            if let displays = environment["OPENSCREENS_DISPLAYS"].flatMap(DisplayLayout.init(rawValue:)) {
                settings.displays = displays
            }
            if let keyboard = environment["OPENSCREENS_KEYBOARD"].flatMap(KeyboardInputMode.init(rawValue:)) {
                settings.keyboardInput = keyboard
            }
            // A scripted session leaves this device's clipboard alone, and
            // the other computer's, unless the clipboard is what is tested.
            settings.sharedClipboard = environment["OPENSCREENS_SHARED_CLIPBOARD"] == "1"
            if environment["OPENSCREENS_OBSERVE"] == "1" {
                settings.observeOnly = true
            }
            if environment["OPENSCREENS_LOCK_ON_DISCONNECT"] == "1" {
                settings.lockOnDisconnect = true
            }
            if let touch = environment["OPENSCREENS_TOUCH"].flatMap(TouchInputMode.init(rawValue:)) {
                settings.touchInput = touch
            }
        }
        present(session)

        guard let reportPrefix = environment["OPENSCREENS_REPORT"] else { return }
        let delay = Double(environment["OPENSCREENS_REPORT_AFTER"] ?? "") ?? 6
        let text = environment["OPENSCREENS_TYPE"]
        let exits = environment["OPENSCREENS_EXIT"] == "1"

        Task {
            // Wait for the connection to settle one way or the other,
            // answering what a person would be asked on the way.
            let deadline = Date.now.addingTimeInterval(40)
            var prompts: [String] = []
            while Date.now < deadline {
                switch session.phase {
                case .connected, .failed, .ended: break
                case .awaitingHostKey(let prompt):
                    prompts.append("hostKey \(prompt.keyType) changed=\(prompt.keyHasChanged)")
                    session.answerHostKey(trust: environment["OPENSCREENS_TRUST_HOST_KEY"] == "1")
                    continue
                case .awaitingCredentials(let prompt) where prompt.purpose == .secureTunnel:
                    prompts.append("tunnelSignIn user=\(prompt.username) message=\(prompt.message ?? "-")")
                    guard let password = environment["OPENSCREENS_SSH_PASSWORD"], prompts.count < 6 else { break }
                    session.submitCredentials(username: prompt.username, password: password, remember: false)
                    continue
                case .awaitingCredentials(let prompt):
                    // Nobody is here to sign in to screen sharing.
                    prompts.append("signIn user=\(prompt.username) message=\(prompt.message ?? "-")")
                default:
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                break
            }
            print("automation: prompts \(prompts)")
            if session.phase == .connected {
                session.setStatisticsActive(true)
                let wait = Double(environment["OPENSCREENS_TYPE_AFTER"] ?? "") ?? 1
                if let click = environment["OPENSCREENS_CLICK"] {
                    // "x,y" in remote pixels.
                    let parts = click.split(separator: ",").compactMap { Double($0) }
                    if parts.count == 2 {
                        try? await Task.sleep(for: .seconds(wait))
                        print("automation: click at \(parts) canSendInput=\(session.canSendInput)")
                        session.click(.left, at: CGPoint(x: parts[0], y: parts[1]))
                    }
                }
                if let source = environment["OPENSCREENS_KEYBOARD_SOURCE"] {
                    try? await Task.sleep(for: .seconds(wait))
                    print("automation: keyboard source \(source)")
                    session.engine.setKeyboardInputSource(source)
                }
                if let text {
                    try? await Task.sleep(for: .seconds(wait))
                    print("automation: typing \(text.count) characters canSendInput=\(session.canSendInput)")
                    session.type(text)
                }
                if let script = environment["OPENSCREENS_KEYS"] {
                    try? await Task.sleep(for: .seconds(wait))
                    await runKeyScript(script, on: session)
                }
                try? await Task.sleep(for: .seconds(delay))
            }
            writeReport(for: session, prefix: reportPrefix)
            if exits {
                session.end()
                try? await Task.sleep(for: .milliseconds(400))
                exit(0)
            }
        }
    }

    /// Opens a computer's files, or exercises them without the interface.
    ///
    ///     OPENSCREENS_FILES=vnc://user:password@host        open the Files window
    ///     OPENSCREENS_FILES_TEST=vnc://user:password@host   make a folder, copy a file
    ///                                                      there and back, compare,
    ///                                                      clean up; report as JSON
    static func runFilesIfRequested(model: AppModel, browse: @escaping (Computer) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        func computer(from address: String?) -> Computer? {
            guard let address, let target = ConnectionTarget(text: address) else { return nil }
            let computer = Computer(
                name: target.name ?? "", host: target.host, username: target.username, kind: target.kind)
            if let password = target.password {
                try? model.credentials.setPassword(password, for: computer.id)
            }
            return computer
        }
        if let computer = computer(from: environment["OPENSCREENS_FILES"]) {
            browse(computer)
        }
        guard let computer = computer(from: environment["OPENSCREENS_FILES_TEST"]),
              let reportPrefix = environment["OPENSCREENS_REPORT"] else { return }
        Task {
            let report = await exerciseFiles(of: computer, model: model)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: reportPrefix + ".json"))
            }
            if environment["OPENSCREENS_EXIT"] == "1" {
                exit(0)
            }
        }
    }

    private static func exerciseFiles(of computer: Computer, model: AppModel) async -> [String: Any] {
        var report: [String: Any] = [:]
        let browser = FileBrowser(
            computer: computer, credentials: model.credentials,
            sshKeys: model.sshKeys, knownHosts: model.knownHosts)
        defer { browser.close() }

        func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = Date.now.addingTimeInterval(seconds)
            while Date.now < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }

        browser.start()
        var prompts: [String] = []
        _ = await wait(30) {
            if case .hostKey(let prompt) = browser.phase {
                prompts.append("hostKey \(prompt.keyType)")
                browser.answerHostKey(trust: true)
            }
            switch browser.phase {
            case .ready, .failed, .signIn: return true
            default: return false
            }
        }
        _ = await wait(10) { !browser.isLoading && !browser.path.isEmpty || browser.phase != .ready }
        report["prompts"] = prompts
        report["phase"] = String(describing: browser.phase)
        guard browser.phase == .ready else { return report }
        report["home"] = browser.path
        report["homeItemCount"] = browser.items.count

        // A folder of our own, so nothing of the computer's is touched.
        let folder = "openscreens-check-\(Int(Date.now.timeIntervalSince1970))"
        let home = browser.path
        browser.makeFolder(named: folder)
        report["madeFolder"] = await wait(10) { browser.items.contains { $0.name == folder && $0.isDirectory } }
        browser.go(to: home + "/" + folder)
        _ = await wait(10) { browser.path.hasSuffix(folder) }

        // A few megabytes that do not compress or repeat, there and back.
        let scratch = FileManager.default.temporaryDirectory.appending(path: folder)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<(3 * 1024 * 1024 + 123)).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let local = scratch.appending(path: "Sample ş 日本.bin")
        try? payload.write(to: local)
        browser.upload([local])
        report["uploaded"] = await wait(60) { browser.transfers.last?.state == .finished }
        report["uploadState"] = String(describing: browser.transfers.last?.state)
        _ = await wait(10) { browser.items.contains { $0.name == local.lastPathComponent } }
        report["listedSize"] = browser.items.first { $0.name == local.lastPathComponent }?.size ?? -1
        report["expectedSize"] = payload.count

        if let item = browser.items.first(where: { $0.name == local.lastPathComponent }) {
            let downloads = scratch.appending(path: "Downloads")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            browser.download([item], to: downloads)
            report["downloaded"] = await wait(60) { browser.transfers.last?.state == .finished }
            let copy = try? Data(contentsOf: downloads.appending(path: item.name))
            report["roundTripMatches"] = copy == payload
            browser.rename(item, to: "Renamed.bin")
            report["renamed"] = await wait(10) { browser.items.contains { $0.name == "Renamed.bin" } }
        }

        // Clean up, which also checks deleting a folder with something in it.
        browser.go(to: home)
        _ = await wait(10) { browser.path == home && browser.items.contains { $0.name == folder } }
        if let made = browser.items.first(where: { $0.name == folder }) {
            browser.delete([made])
            report["deleted"] = await wait(15) { !browser.items.contains { $0.name == folder } }
        }
        report["error"] = browser.errorMessage ?? ""
        return report
    }

    /// Runs a key script: steps separated by `|`.
    ///
    ///     t=text            type text
    ///     tap=cmd+shift+c   press and release a key with modifiers
    ///     s=cmd+c           send a shortcut the way the toolbar does
    ///     k=ff51,123,p      raw key event: keysym (hex), key code or `-`,
    ///                       then d (down), u (up) or p (press and release)
    ///     e=6,os,p          key event through the canvas (macOS): key code,
    ///                       modifier flags (s, o, c, t, l), then d, u or p
    ///     f=58,o            modifier change through the canvas (macOS): key
    ///                       code and the flags that are down afterwards
    ///     c=640,400         click at this pixel of the picture
    ///     win=1100x640      resize the session's window (macOS), in points
    ///     drop=/path@640,400  drop a file on the picture at that pixel
    ///     drag=300,300>900,200  press at the first pixel, drag to the second, let go
    ///     send=/path>~/Downloads  copy a file straight into a folder on the Mac
    ///     clip=text         put text on the remote clipboard
    ///     curtain=on|off    hide or show the remote Mac's own screen
    ///     lock=1            end the session, as closing its window does
    ///     w=250             wait, in milliseconds
    private static func runKeyScript(_ script: String, on session: RemoteSession) async {
        for step in script.split(separator: "|") {
            guard let separator = step.firstIndex(of: "=") else { continue }
            let verb = step[..<separator]
            let argument = String(step[step.index(after: separator)...])
            switch verb {
            case "t":
                session.type(argument)
            case "tap":
                if let (modifiers, key) = parseCombination(argument) {
                    session.tap(key, modifiers: modifiers)
                }
            case "s":
                if let (modifiers, key) = parseCombination(argument) {
                    session.send(RemoteShortcut(name: argument, modifiers: modifiers, key: key))
                    try? await Task.sleep(for: .milliseconds(150))
                }
            case "k":
                let parts = argument.split(separator: ",")
                guard parts.count == 3, let keysym = UInt32(parts[0], radix: 16) else { continue }
                let keyCode = UInt16(parts[1])
                for isDown in [true, false] where parts[2] == "p" || (parts[2] == "d") == isDown {
                    if let keyCode {
                        session.engine.sendKeyEvent(downFlag: isDown, key: keysym, keyCode: keyCode)
                    } else {
                        session.engine.sendKeyEvent(downFlag: isDown, key: keysym)
                    }
                }
            #if os(macOS)
            case "e", "f":
                sendCanvasEvent(isModifier: verb == "f", argument)
            case "win":
                let parts = argument.split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2,
                      let window = NSApp.windows.lazy.compactMap({ findCanvas(in: $0.contentView)?.window }).first
                else { continue }
                var frame = window.frame
                frame.origin.y += frame.height - parts[1]
                frame.size = CGSize(width: parts[0], height: parts[1])
                window.setFrame(frame, display: true)
            #endif
            case "c":
                let parts = argument.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                // Paced like a hand: some controls, a Mac's status items
                // among them, ignore a press that arrives with its release.
                let point = CGPoint(x: parts[0], y: parts[1])
                session.pointer(buttons: [], at: point)
                try? await Task.sleep(for: .milliseconds(200))
                session.pointer(buttons: .left, at: point)
                try? await Task.sleep(for: .milliseconds(90))
                session.pointer(buttons: [], at: point)
                try? await Task.sleep(for: .milliseconds(250))
            case "drop":
                guard let at = argument.lastIndex(of: "@") else { continue }
                let url = URL(fileURLWithPath: String(argument[..<at]))
                let parts = argument[argument.index(after: at)...].split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                let point = CGPoint(x: parts[0], y: parts[1])
                // As a drag does: arrive beside the place, move onto it, let go.
                let start = CGPoint(x: point.x - 60, y: point.y - 40)
                guard session.beginFileDrag(names: [url.lastPathComponent], at: start) else {
                    print("automation: the Mac did not take the drag")
                    continue
                }
                for step in 1...6 {
                    try? await Task.sleep(for: .milliseconds(120))
                    let t = Double(step) / 6
                    session.moveFileDrag(to: CGPoint(
                        x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t))
                }
                try? await Task.sleep(for: .milliseconds(500))
                session.dropFiles([url], at: point)
            case "send":
                let parts = argument.split(separator: ">", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[1] == "~/Downloads" {
                    // The way the Send Files command does it.
                    session.sendFiles([URL(fileURLWithPath: parts[0])])
                } else {
                    session.fileTransfers.upload([URL(fileURLWithPath: parts[0])], toRemoteFolder: parts[1])
                }
            case "drag":
                let ends = argument.split(separator: ">").map {
                    $0.split(separator: ",").compactMap { Double($0) }
                }
                guard ends.count == 2, ends[0].count == 2, ends[1].count == 2 else { continue }
                let from = CGPoint(x: ends[0][0], y: ends[0][1])
                let to = CGPoint(x: ends[1][0], y: ends[1][1])
                session.pointer(buttons: [], at: from)
                try? await Task.sleep(for: .milliseconds(250))
                session.pointer(buttons: .left, at: from)
                try? await Task.sleep(for: .milliseconds(350))
                for step in 1...24 {
                    let t = Double(step) / 24
                    session.pointer(buttons: .left, at: CGPoint(
                        x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                    try? await Task.sleep(for: .milliseconds(60))
                }
                try? await Task.sleep(for: .milliseconds(900))
                session.pointer(buttons: [], at: to)
            case "clip":
                // Straight to the remote clipboard, leaving this device's alone.
                session.engine.sendClipboardText(argument)
            case "curtain":
                session.setCurtain(argument == "on", message: "Back soon")
            case "lock":
                session.end()
            case "w":
                try? await Task.sleep(for: .milliseconds(Int(argument) ?? 100))
                continue
            default:
                print("automation: unknown key step \(step)")
            }
            // Keep steps apart so the log on the other side reads in order.
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    #if os(macOS)
    /// Hands the session's canvas a key event, as the window would.
    private static func sendCanvasEvent(isModifier: Bool, _ argument: String) {
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, let keyCode = UInt16(parts[0]),
              let canvas = NSApp.windows.lazy.compactMap({ findCanvas(in: $0.contentView) }).first,
              let window = canvas.window else {
            print("automation: no canvas for \(argument)")
            return
        }
        var flags: NSEvent.ModifierFlags = []
        for flag in parts[1] {
            switch flag {
            case "s": flags.insert(.shift)
            case "o": flags.insert(.option)
            case "c": flags.insert(.command)
            case "t": flags.insert(.control)
            case "l": flags.insert(.capsLock)
            default: break
            }
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode)
        }
        if isModifier {
            event(.flagsChanged).map(canvas.flagsChanged(with:))
            return
        }
        let action = parts.count > 2 ? parts[2] : "p"
        if action == "d" || action == "p" {
            event(.keyDown).map(canvas.keyDown(with:))
        }
        if action == "u" || action == "p" {
            event(.keyUp).map(canvas.keyUp(with:))
        }
    }

    private static func findCanvas(in view: NSView?) -> RemoteCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? RemoteCanvasView {
            return canvas
        }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }
    #endif

    private static func parseCombination(_ text: String) -> (KeyModifiers, RemoteKey)? {
        var modifiers: KeyModifiers = []
        var key: RemoteKey?
        for part in text.split(separator: "+", omittingEmptySubsequences: false) {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            case "": key = .character("+")
            default:
                if let special = SpecialKey(rawValue: String(part)) {
                    key = .special(special)
                } else if part.count > 1, part.hasPrefix("f"), let number = Int(part.dropFirst()) {
                    key = .function(number)
                } else {
                    key = .character(String(part))
                }
            }
        }
        return key.map { (modifiers, $0) }
    }

    private static func writeReport(for session: RemoteSession, prefix: String) {
        var report: [String: Any] = [
            "phase": String(describing: session.phase),
            "requestedQuality": session.requestedQuality.rawValue,
            "activeQuality": session.activeQuality.rawValue,
            "isHighPerformance": session.engine.isHighPerformanceMode,
            "serverName": session.engine.serverName,
            "framebuffer": [session.engine.framebufferWidth, session.engine.framebufferHeight],
            "presentedSize": [session.remoteSize.width, session.remoteSize.height],
            "viewSize": [session.viewport.viewSize.width, session.viewport.viewSize.height],
            "contentRect": [
                session.viewport.contentRect.minX, session.viewport.contentRect.minY,
                session.viewport.contentRect.width, session.viewport.contentRect.height,
            ],
            "displayCount": session.engine.activeVideoDisplayCount,
            "displayFrames": session.arrangement.frames.map { [$0.minX, $0.minY, $0.width, $0.height] },
            "canDropFiles": session.canDropFiles,
            "canFetchFiles": session.canFetchFiles,
            "fileTransfers": session.fileTransfers.transfers.map { transfer in
                [
                    "name": transfer.name,
                    "direction": transfer.direction == .upload ? "upload" : "download",
                    "state": String(describing: transfer.state),
                    "bytes": [transfer.completedBytes, transfer.totalBytes],
                    "remoteFolder": transfer.remoteFolder ?? "",
                    "local": transfer.localURLs.map(\.path),
                ] as [String: Any]
            },
            "supportsCurtain": session.supportsCurtain,
            "isCurtained": session.isCurtained,
            "appleModifiers": session.engine.serverUsesAppleModifierConvention,
            "takesKeyCodes": session.engine.serverTakesKeyCodes,
            "cursor": String(describing: session.engine.remoteCursorPresence),
            "cursorRendering": session.engine.activeCursorRendering.rawValue,
            "encryption": String(describing: session.engine.negotiatedContentEncryption),
            "clipboardRequest": session.engine.supportsRemoteClipboardRequest,
        ]
        if let reason = session.fallbackReason {
            report["fallbackReason"] = reason
        }
        #if os(iOS)
        if let layout = session.canvasBridge.chromeLayout {
            report["safeArea"] = [layout.safeArea.top, layout.safeArea.left, layout.safeArea.bottom, layout.safeArea.right]
            report["controls"] = String(describing: layout.controls)
            report["showsStatusBar"] = layout.showsStatusBar
            report["pictureInsets"] = [
                layout.pictureInsets.top, layout.pictureInsets.left,
                layout.pictureInsets.bottom, layout.pictureInsets.right,
            ]
        }
        #endif
        if let statistics = session.statistics {
            report["framesPerSecond"] = statistics.framesPerSecond ?? -1
            report["bitrateKbps"] = statistics.bitrateKbps ?? -1
            report["packetLossPercent"] = statistics.packetLossPercent ?? -1
            if let hardware = statistics.usesHardwareDecoder {
                report["hardwareDecoder"] = hardware
            }
        }
        report["diagnostics"] = session.engine.getDiagnostics().summary()

        var hasImage = false
        if let image = session.screenshot(), let data = ScreenshotEncoder.pngData(image) {
            hasImage = (try? data.write(to: URL(fileURLWithPath: prefix + ".png"))) != nil
            report["imageSize"] = [image.width, image.height]
        }
        report["hasImage"] = hasImage

        if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: prefix + ".json"))
        }
    }
}
#endif
