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
///     OPENSCREENS_DISPLAYS=single|allCombined|twoVirtual
///     OPENSCREENS_KEYBOARD=automatic|keystrokes|unicode
///     OPENSCREENS_OBSERVE=1                           watch without sending input
///     OPENSCREENS_SHARED_CLIPBOARD=1                  share the clipboard (off unless asked for)
///     OPENSCREENS_LOCK_ON_DISCONNECT=1                lock the remote Mac on leaving
///     OPENSCREENS_TOUCH=trackpad|touch                how touches drive the pointer
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
            #endif
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
        if let statistics = session.statistics {
            report["framesPerSecond"] = statistics.framesPerSecond ?? -1
            report["bitrateKbps"] = statistics.bitrateKbps ?? -1
            report["packetLossPercent"] = statistics.packetLossPercent ?? -1
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
