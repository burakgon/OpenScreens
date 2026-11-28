import Foundation

/// Waits for a size to stop changing before anything is asked for it.
///
/// A folding phone being unfolded passes its window through a run of sizes in
/// a few hundred milliseconds. A desktop that follows the screen is rebuilt
/// for every one of them, and a Mac takes long enough over each rebuild that
/// the next has begun before the last is on the screen. So the request waits
/// until the size has held still for ``settle`` seconds.
///
/// A size that never holds still is not waited on for ever either: after
/// ``deadline`` seconds from the first change, whatever the size is then gets
/// asked for. Someone folding a device back and forth on purpose is better
/// served by a picture of the wrong shape than by no picture at all.
public struct ResizeSettler<Value: Equatable> {
    /// How long the value has to hold still before it is acted on, in seconds.
    public var settle: TimeInterval
    /// How long it is ever waited on, however steadily the value changes, in
    /// seconds.
    public var deadline: TimeInterval

    /// The value being waited on, and when it and the run of changes began.
    private var waiting: (value: Value, since: TimeInterval, first: TimeInterval)?

    public init(settle: TimeInterval = 0.3, deadline: TimeInterval = 2) {
        self.settle = settle
        self.deadline = deadline
    }

    /// Whether anything is being waited on, and what.
    public var waitingFor: Value? { waiting?.value }

    /// A value changed to `value` at `time`, which is in seconds on any clock
    /// that only goes forward.
    ///
    /// Returns how long to wait before `value` should be acted on, or nil when
    /// the wait already under way is for this value and nothing new needs
    /// scheduling. A wait of zero says to act now, which is what happens at
    /// the end of ``deadline``.
    public mutating func delay(for value: Value, at time: TimeInterval) -> TimeInterval? {
        if let waiting, waiting.value == value { return nil }
        let first = waiting?.first ?? time
        waiting = (value, time, first)
        return min(settle, max(0, deadline - (time - first)))
    }

    /// The wait is over and the value has been acted on. The next change
    /// begins a fresh run, with the whole of ``deadline`` in front of it.
    public mutating func stopWaiting() {
        waiting = nil
    }
}

extension ResizeSettler: Sendable where Value: Sendable {}
