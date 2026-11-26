#if os(iOS)
import AVFoundation
import AVKit
import OpenScreensCore
import SwiftUI
import UIKit

/// Shows a session's remote screen in Picture in Picture, so it can be kept
/// an eye on from another app.
///
/// The system's floating window shows a sample-buffer layer, and the remote
/// screen is drawn into it from the same picture screenshots are taken of:
/// in Standard and in High Performance alike, with every display that is
/// shown, scaled down to the window's size, and at the rate the settings
/// ask for. Asked for from a button, it is drawn only while the window is
/// up. To come up by itself on the way out of the app, the window needs a
/// picture already there, so the layer is then kept up to date about once a
/// second for as long as the session is on screen.
///
/// The window's own skip and play buttons send keys of the user's choosing
/// to the remote computer.
@MainActor @Observable
final class PictureInPicture: NSObject {
    /// Whether this device can show Picture in Picture at all.
    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Whether the remote screen is in the floating window, or on its way
    /// there.
    private(set) var isActive = false

    /// How often the window is drawn.
    @ObservationIgnored var frameRate = PictureInPictureFrameRate.fifteen

    /// What the window's skip and play buttons send to the remote computer.
    @ObservationIgnored var keys = PictureInPictureKeys() {
        didSet {
            guard keys != oldValue else { return }
            skips = keys.skips
            controller?.requiresLinearPlayback = !keys.skips
            controller?.invalidatePlaybackState()
        }
    }

    /// Whether leaving the app during the session takes the screen along.
    @ObservationIgnored var startsAutomatically = false {
        didSet {
            controller?.canStartPictureInPictureAutomaticallyFromInline = startsAutomatically
            followFrames()
        }
    }

    /// What the system shows. It has to be in a window for Picture in
    /// Picture to start from it; ``PictureInPictureLayer`` puts it there.
    @ObservationIgnored let layer = AVSampleBufferDisplayLayer()

    @ObservationIgnored private weak var session: RemoteSession?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var frames: Task<Void, Never>?
    @ObservationIgnored private var pool: CVPixelBufferPool?
    @ObservationIgnored private var poolSize = CGSize.zero
    @ObservationIgnored private var lastImage: CGImage?
    /// The High Performance frames counted at the last picture drawn.
    @ObservationIgnored private var lastVideoFrames: [[UInt32: UInt64]]?
    /// Whether the session is on screen and connected.
    @ObservationIgnored private var isPrepared = false
    /// When the session came on screen, on the clock frames are stamped
    /// with: where the window's time range starts.
    @ObservationIgnored nonisolated(unsafe) private var liveSince = CMTime.invalid
    /// What the play button shows. It only ever stands for the key it
    /// sends, so it turns over each time that key is sent.
    @ObservationIgnored nonisolated(unsafe) private var showsPaused = false
    /// Whether either skip button sends a key, for the system to ask from
    /// any thread.
    @ObservationIgnored nonisolated(unsafe) private var skips = false

    /// How far a picture with skip buttons appears to run. The system dims
    /// them for anything live, so the window shows a span this long instead,
    /// renewed for as long as the session goes on.
    private nonisolated static let skippableSpan = CMTime(seconds: 24 * 60 * 60, preferredTimescale: 1)

    /// How often to look for a new picture at the full rate: as often as
    /// the screen here can show one.
    private static let fullRateInterval: Duration = .milliseconds(16)
    /// A frame a second behind the session, for the window to open on.
    private static let standbyFrameInterval: Duration = .seconds(1)

    init(session: RemoteSession) {
        self.session = session
        super.init()
        layer.videoGravity = .resizeAspect
        guard Self.isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // A live screen has nothing to skip through: the skip buttons are
        // dimmed until there are keys for them to send instead.
        controller.requiresLinearPlayback = true
        self.controller = controller
    }

    /// For when the session is on screen and connected.
    func prepare() {
        guard controller != nil, !isPrepared else { return }
        isPrepared = true
        liveSince = Self.now
        controller?.invalidatePlaybackState()
        followFrames()
    }

    /// Closes the window and stops drawing, as the session leaves the screen.
    func end() {
        stop()
        isPrepared = false
        followFrames()
        lastImage = nil
        lastVideoFrames = nil
        liveSince = .invalid
        showsPaused = false
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard let controller, !isActive else { return }
        isActive = true
        prepare()
        followFrames()
        presentFrame()
        Task {
            // The window can only come up once the layer has a picture to
            // show, which takes a moment after the first frame.
            for _ in 0..<20 where !controller.isPictureInPicturePossible {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard isActive else { return }
            if controller.isPictureInPicturePossible {
                controller.startPictureInPicture()
            } else {
                isActive = false
                followFrames()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        } else {
            isActive = false
            followFrames()
        }
    }

    // MARK: Frames

    /// Draws while the window is up, and a frame a second while it may
    /// come up by itself; otherwise not at all.
    private func followFrames() {
        let draws = isPrepared && (isActive || startsAutomatically)
        guard draws != (frames != nil) else { return }
        guard draws else {
            frames?.cancel()
            frames = nil
            return
        }
        // The app goes on running behind the window only while it is
        // playing; mixing leaves whatever else is playing alone.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        frames = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                presentFrame()
                try? await Task.sleep(for: isActive ? frameInterval : Self.standbyFrameInterval)
            }
        }
    }

    private func send(_ shortcut: RemoteShortcut?) {
        guard let shortcut else { return }
        session?.send(shortcut)
    }

    private var frameInterval: Duration {
        frameRate.framesPerSecond.map { .seconds(1) / $0 } ?? Self.fullRateInterval
    }

    private func presentFrame() {
        guard let session else { return }
        // A High Performance picture is a new image every time it is asked
        // for, and costly to make: ask only once a new frame has come in.
        if session.engine.isHighPerformanceMode {
            let frames = session.engine.videoSourceFrames.snapshot()
            guard frames != lastVideoFrames else { return }
            lastVideoFrames = frames
        }
        guard let image = session.screenshot() else { return }
        // A Standard screen that has not changed is the same image.
        guard image !== lastImage else { return }
        lastImage = image
        guard let size = PictureInPictureFrame.pixelSize(
                for: CGSize(width: image.width, height: image.height)),
              let buffer = pixelBuffer(drawing: image, at: size),
              let sample = Self.sampleBuffer(for: buffer) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    private func pixelBuffer(drawing image: CGImage, at size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    private nonisolated static var now: CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private static func sampleBuffer(for buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return nil }
        // Shown as it arrives, as a live picture is.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        // Started from the button, or by the system on the way out.
        MainActor.assumeIsolated {
            isActive = true
            followFrames()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            isActive = false
            followFrames()
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            isActive = false
            followFrames()
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The session screen is still there, behind the window.
        completionHandler(true)
    }
}

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController, setPlaying playing: Bool
    ) {
        MainActor.assumeIsolated {
            guard let key = keys.playPause else { return }
            send(key)
            showsPaused = !playing
            self.controller?.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        guard liveSince.isValid else { return .invalid }
        guard skips else {
            // Without an end: the system shows it as live, with nothing to
            // skip through.
            return CMTimeRange(start: liveSince, duration: .positiveInfinity)
        }
        let elapsed = CMTimeSubtract(Self.now, liveSince)
        return CMTimeRange(start: liveSince, duration: CMTimeAdd(elapsed, Self.skippableSpan))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        showsPaused
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            send(skipInterval.seconds < 0 ? keys.skipBack : keys.skipForward)
        }
        completionHandler()
    }
}

/// Puts the Picture in Picture layer in the window, behind the remote
/// screen, where the system can take it from.
struct PictureInPictureLayer: UIViewRepresentable {
    let pictureInPicture: PictureInPicture

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.layer.addSublayer(pictureInPicture.layer)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {}

    final class HostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}
#endif
