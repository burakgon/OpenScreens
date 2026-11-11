import Foundation
import RFBTransport

/// Point-in-time session statistics combining transport traffic with
/// decode-side progress. Obtain via ``VNCSession/currentStatistics()``.
public struct VNCSessionStatistics: Sendable, Equatable {
    /// Wire-level traffic and negotiated-mode counters.
    public let transport: TransportStatistics

    // Video decode pipeline (High Performance mode), summed across displays.
    public let framesSubmitted: UInt64
    public let framesDecoded: UInt64
    public let lossGapsDetected: Int
    public let framesDroppedWhileGated: Int
    /// Whether this device decodes the video stream in hardware. False
    /// means VideoToolbox fell back to decoding on the CPU, which no device
    /// keeps up with at these sizes. Nil when there is no video stream, or
    /// when VideoToolbox would not say.
    public let usesHardwareVideoDecoder: Bool?

    public let capturedAt: Date
}
