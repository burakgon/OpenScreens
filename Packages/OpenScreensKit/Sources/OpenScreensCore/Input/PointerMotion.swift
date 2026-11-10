import CoreGraphics
import Foundation

/// Turns finger movement on a touch screen into pointer movement, the way a
/// trackpad does: slow movements are precise, fast ones cover distance.
public struct PointerAcceleration: Sendable {
    /// Overall multiplier chosen by the user. 1 is the default feel.
    public var speed: Double

    public init(speed: Double = 1) {
        self.speed = speed
    }

    /// Gain applied to a movement made at `velocity` points per second.
    ///
    /// Below the threshold the pointer follows the finger one to one, so small
    /// targets can be hit. Above it the gain rises smoothly and levels off, so
    /// a flick crosses the screen without the pointer becoming uncontrollable.
    public func gain(forVelocity velocity: CGFloat) -> CGFloat {
        let base = CGFloat(max(0.1, speed))
        let threshold: CGFloat = 120
        guard velocity > threshold else { return base }
        let excess = (velocity - threshold) / 900
        return base * (1 + min(2.6, pow(excess, 1.15) * 1.7))
    }

    /// The pointer movement for a finger movement of `delta` points made over
    /// `interval` seconds.
    public func movement(for delta: CGSize, interval: TimeInterval) -> CGSize {
        guard delta.width.isFinite, delta.height.isFinite else { return .zero }
        let distance = hypot(delta.width, delta.height)
        guard distance > 0 else { return .zero }
        let velocity = distance / CGFloat(max(interval, 1.0 / 240))
        let gain = gain(forVelocity: velocity)
        return CGSize(width: delta.width * gain, height: delta.height * gain)
    }
}

/// The coasting tail of a touch scroll.
///
/// A finger lifted while moving should keep the content gliding and slow to a
/// stop, as it does everywhere else on the device. The remote computer cannot
/// know the finger's velocity, so the tail is generated here and sent as a
/// stream of small scroll samples.
public struct ScrollMomentum: Sendable {
    /// Current velocity in points per second.
    public private(set) var velocity: CGSize

    /// Fraction of velocity kept after one millisecond. Matches the normal
    /// deceleration rate of system scroll views.
    public static let decelerationPerMillisecond = 0.998

    /// Below this speed the scroll is considered finished.
    public static let minimumSpeed: CGFloat = 6

    /// Releases slower than this do not coast at all.
    public static let startThreshold: CGFloat = 40

    public static let maximumSpeed: CGFloat = 9000

    /// Starts a tail from the finger's release velocity. Returns `nil` when
    /// the release was too slow to coast.
    public init?(releaseVelocity: CGSize) {
        guard releaseVelocity.width.isFinite, releaseVelocity.height.isFinite else { return nil }
        let speed = hypot(releaseVelocity.width, releaseVelocity.height)
        guard speed >= ScrollMomentum.startThreshold else { return nil }
        let scale = min(1, ScrollMomentum.maximumSpeed / speed)
        velocity = CGSize(width: releaseVelocity.width * scale, height: releaseVelocity.height * scale)
    }

    public var isFinished: Bool {
        hypot(velocity.width, velocity.height) < ScrollMomentum.minimumSpeed
    }

    /// Advances the tail by `interval` seconds and returns the distance
    /// scrolled in that time.
    public mutating func advance(by interval: TimeInterval) -> CGSize {
        let step = min(max(interval, 0), 0.05)
        let distance = CGSize(width: velocity.width * step, height: velocity.height * step)
        let decay = CGFloat(pow(ScrollMomentum.decelerationPerMillisecond, step * 1000))
        velocity = CGSize(width: velocity.width * decay, height: velocity.height * decay)
        return distance
    }
}

/// Estimates how fast a finger was moving when it lifted.
///
/// The very last samples of a gesture are noisy — a finger rolls as it leaves
/// the glass — so the estimate uses displacement across a short trailing
/// window instead of the final pair of points.
public struct ReleaseVelocityTracker: Sendable {
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    public static let window: TimeInterval = 0.1
    /// A lift this long after the last movement is a rest, not a flick.
    public static let maximumPause: TimeInterval = 0.12

    public init() {}

    public mutating func record(_ point: CGPoint, at time: TimeInterval) {
        samples.append((time, point))
        while samples.count > 2, samples[1].time <= time - ReleaseVelocityTracker.window {
            samples.removeFirst()
        }
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    public func velocity(at releaseTime: TimeInterval) -> CGSize {
        guard let first = samples.first, let last = samples.last,
              releaseTime - last.time <= ReleaseVelocityTracker.maximumPause else { return .zero }
        let span = max(last.time - first.time, 0.02)
        return CGSize(
            width: (last.point.x - first.point.x) / CGFloat(span),
            height: (last.point.y - first.point.y) / CGFloat(span))
    }
}
