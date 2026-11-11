import Foundation

/// Notices two values that keep replacing each other, and puts a stop to it.
///
/// A layout worked out from what the system reports about a screen is meant
/// never to change any of that. If on some device it does after all, each
/// layout brings the other back: the interface never comes to rest, and the
/// system ends an app that has stopped answering it. A value that returns
/// straight after it was replaced, several times in quick succession, is
/// taken for that, and whatever is in place is then kept for a while. A
/// layout a little wrong is better than no app.
public struct FlipFlopGuard<Value: Equatable> {
    /// How many times in ``window`` a value may come straight back before
    /// the one in place is kept.
    public var tolerance: Int
    /// The time within which those returns have to happen, in seconds.
    public var window: TimeInterval
    /// How long the value in place is then kept, in seconds.
    public var hold: TimeInterval

    /// The last values let through, newest last.
    private var recent: [Value] = []
    /// When a value came back that had only just been replaced.
    private var returns: [TimeInterval] = []
    private var heldUntil: TimeInterval = -.infinity

    public init(tolerance: Int = 3, window: TimeInterval = 2, hold: TimeInterval = 5) {
        self.tolerance = tolerance
        self.window = window
        self.hold = hold
    }

    /// Whether `value` may take the place of `current` at `time`, which is
    /// in seconds on any clock that only goes forward.
    ///
    /// Someone turning a device over and back again is a value returning
    /// too, once, and seconds apart: that is let through.
    public mutating func admits(_ value: Value, replacing current: Value?, at time: TimeInterval) -> Bool {
        guard value != current else { return false }
        guard time >= heldUntil else { return false }
        if recent.count >= 2, recent[recent.count - 2] == value {
            returns = returns.filter { time - $0 < window } + [time]
            if returns.count > tolerance {
                returns = []
                heldUntil = time + hold
                return false
            }
        }
        recent = Array((recent + [value]).suffix(3))
        return true
    }
}

extension FlipFlopGuard: Sendable where Value: Sendable {}
