import CommonCrypto
import CoreGraphics
import Foundation
import Network

/// A small, self-contained RFB 3.8 server for tests and demos.
///
/// It serves a framebuffer over the Raw encoding, optionally behind classic
/// VNC authentication, and records every input event it receives. That is
/// enough to exercise a client end to end — handshake, picture, pointer and
/// keyboard — on a loopback socket, with nothing else installed.
///
/// It is deliberately not a real VNC server: there is no screen behind it,
/// and it implements only what a well-behaved client needs.
public final class RFBTestServer: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var name: String
        /// Port to listen on. 0 picks a free one.
        public var port: UInt16
        /// When set, clients must authenticate with this VNC password.
        public var password: String?
        /// Accept connections from other machines, not only this one.
        public var allowsRemoteConnections: Bool

        public init(
            name: String = "OpenScreens Demo",
            port: UInt16 = 0,
            password: String? = nil,
            allowsRemoteConnections: Bool = false
        ) {
            self.name = name
            self.port = port
            self.password = password
            self.allowsRemoteConnections = allowsRemoteConnections
        }
    }

    /// Something a client sent.
    public enum Event: Equatable, Sendable {
        case connected
        case authenticated
        case authenticationFailed
        case setEncodings([Int32])
        case key(keysym: UInt32, isDown: Bool)
        case pointer(x: Int, y: Int, buttons: UInt8)
        case cutText(String)
        case disconnected
    }

    public let width: Int
    public let height: Int
    private let configuration: Configuration

    private let queue = DispatchQueue(label: "RFBTestServer")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    private let lock = NSLock()
    private var framebuffer: [UInt8]          // BGRX, top row first
    private var recordedEvents: [Event] = []
    private var waiters: [(predicate: @Sendable ([Event]) -> Bool, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Creates a server showing `image`.
    public init(image: CGImage, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        width = image.width
        height = image.height
        framebuffer = Self.pixels(of: image)
    }

    // MARK: - Lifecycle

    /// Starts listening and returns the port in use.
    @discardableResult
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if !configuration.allowsRemoteConnections {
            parameters.requiredInterfaceType = .loopback
        }
        let port: NWEndpoint.Port = configuration.port == 0
            ? .any
            : NWEndpoint.Port(rawValue: configuration.port) ?? .any
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if resumed.set() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.close()
            }
            clients.removeAll()
        }
    }

    // MARK: - Inspection

    /// Everything received so far, in order.
    public var events: [Event] {
        lock.withLock { recordedEvents }
    }

    public func clearEvents() {
        lock.withLock { recordedEvents.removeAll() }
    }

    /// Waits until the recorded events satisfy `predicate`.
    /// - Returns: `false` if `timeout` passed first.
    public func waitForEvents(
        timeout: Duration = .seconds(5),
        where predicate: @escaping @Sendable ([Event]) -> Bool
    ) async -> Bool {
        if predicate(events) { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.lock.withLock {
                        if predicate(self.recordedEvents) {
                            continuation.resume(returning: true)
                        } else {
                            self.waiters.append((predicate, continuation))
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                self.expireWaiters()
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func expireWaiters() {
        let pending = lock.withLock {
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.continuation.resume(returning: false)
        }
    }

    fileprivate func record(_ event: Event) {
        var ready: [CheckedContinuation<Bool, Never>] = []
        lock.withLock {
            recordedEvents.append(event)
            waiters.removeAll { waiter in
                guard waiter.predicate(recordedEvents) else { return false }
                ready.append(waiter.continuation)
                return true
            }
        }
        for continuation in ready {
            continuation.resume(returning: true)
        }
    }

    /// The colour the server is showing at a pixel, as (red, green, blue).
    public func color(atX x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        lock.withLock {
            let offset = (y * width + x) * 4
            return (framebuffer[offset + 2], framebuffer[offset + 1], framebuffer[offset])
        }
    }

    /// Replaces what the server shows. Connected clients receive the change
    /// with their next update request.
    public func setImage(_ image: CGImage) {
        precondition(image.width == width && image.height == height, "The image must match the server size")
        let pixels = Self.pixels(of: image)
        lock.withLock { framebuffer = pixels }
        queue.async { [self] in
            for client in clients.values {
                client.markDirty()
            }
        }
    }

    fileprivate func copyRegion(x: Int, y: Int, width regionWidth: Int, height regionHeight: Int) -> [UInt8] {
        lock.withLock {
            var out = [UInt8]()
            out.reserveCapacity(regionWidth * regionHeight * 4)
            for row in y..<(y + regionHeight) {
                let start = (row * width + x) * 4
                out.append(contentsOf: framebuffer[start..<(start + regionWidth * 4)])
            }
            return out
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection, server: self, configuration: configuration, queue: queue)
        clients[ObjectIdentifier(client)] = client
        client.onClose = { [weak self, weak client] in
            guard let self, let client else { return }
            self.clients[ObjectIdentifier(client)] = nil
            self.record(.disconnected)
        }
        record(.connected)
        client.start()
    }

    private static func pixels(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                // Little-endian 32-bit with alpha skipped first is B, G, R, X in memory.
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}

/// A one-shot latch for resuming a continuation exactly once.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Sets the flag. Returns `true` only for the first caller.
    func set() -> Bool {
        lock.withLock {
            if isSet { return false }
            isSet = true
            return true
        }
    }
}

// MARK: - One client

/// The server side of one RFB connection. All work happens on the server queue.
private final class Client: @unchecked Sendable {
    private let connection: NWConnection
    private unowned let server: RFBTestServer
    private let configuration: RFBTestServer.Configuration
    private let queue: DispatchQueue
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var pendingRead: (count: Int, handler: (Data) -> Void)?
    private var isClosed = false

    private var pixelFormat = PixelFormat.native
    private var isDirty = true
    private var pendingRequest: (x: Int, y: Int, width: Int, height: Int)?

    init(
        connection: NWConnection,
        server: RFBTestServer,
        configuration: RFBTestServer.Configuration,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.server = server
        self.configuration = configuration
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        send(Data("RFB 003.008\n".utf8))
        read(12) { [weak self] _ in
            self?.negotiateSecurity()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose?()
    }

    func markDirty() {
        isDirty = true
        answerPendingRequest()
    }

    // MARK: Byte plumbing

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func read(_ count: Int, handler: @escaping (Data) -> Void) {
        pendingRead = (count, handler)
        drain()
    }

    private func drain() {
        while let pending = pendingRead, buffer.count >= pending.count {
            let chunk = buffer.prefix(pending.count)
            buffer.removeFirst(pending.count)
            pendingRead = nil
            pending.handler(Data(chunk))
        }
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    // MARK: Handshake

    private func negotiateSecurity() {
        let type: UInt8 = configuration.password == nil ? 1 : 2
        send(Data([1, type]))
        read(1) { [weak self] choice in
            guard let self else { return }
            guard choice.first == type else {
                self.close()
                return
            }
            if let password = self.configuration.password {
                self.authenticate(password)
            } else {
                self.send(Data([0, 0, 0, 0]))
                self.server.record(.authenticated)
                self.awaitClientInit()
            }
        }
    }

    private func authenticate(_ password: String) {
        var challenge = Data(count: 16)
        challenge.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        send(challenge)
        read(16) { [weak self] response in
            guard let self else { return }
            if response == Self.vncResponse(to: challenge, password: password) {
                self.send(Data([0, 0, 0, 0]))
                self.server.record(.authenticated)
                self.awaitClientInit()
            } else {
                let reason = Data("Authentication failed".utf8)
                var failure = Data([0, 0, 0, 1])
                failure.append(Self.bigEndian(UInt32(reason.count)))
                failure.append(reason)
                self.send(failure)
                self.server.record(.authenticationFailed)
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.close() }
            }
        }
    }

    /// Classic VNC authentication: DES-encrypt the challenge with the
    /// password as the key, each key byte bit-reversed.
    private static func vncResponse(to challenge: Data, password: String) -> Data {
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                reversed |= 1 << (7 - bit)
            }
            key[index] = reversed
        }
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        challenge.withUnsafeBytes { input in
            _ = CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmDES),
                CCOptions(kCCOptionECBMode),
                key, kCCKeySizeDES,
                nil,
                input.baseAddress, 16,
                &output, 16,
                &moved)
        }
        return Data(output)
    }

    private func awaitClientInit() {
        read(1) { [weak self] _ in
            guard let self else { return }
            var message = Data()
            message.append(Self.bigEndian(UInt16(self.server.width)))
            message.append(Self.bigEndian(UInt16(self.server.height)))
            message.append(PixelFormat.native.encoded)
            let name = Data(self.configuration.name.utf8)
            message.append(Self.bigEndian(UInt32(name.count)))
            message.append(name)
            self.send(message)
            self.readMessage()
        }
    }

    // MARK: Messages

    private func readMessage() {
        read(1) { [weak self] type in
            guard let self, let type = type.first else { return }
            switch type {
            case 0: // SetPixelFormat
                self.read(19) { body in
                    if let format = PixelFormat(body.dropFirst(3)) {
                        self.pixelFormat = format
                        self.isDirty = true
                    }
                    self.readMessage()
                }
            case 2: // SetEncodings
                self.read(3) { header in
                    let count = Int(Self.uint16(header, at: 1))
                    self.read(count * 4) { body in
                        let encodings = (0..<count).map { Int32(bitPattern: Self.uint32(body, at: $0 * 4)) }
                        self.server.record(.setEncodings(encodings))
                        self.readMessage()
                    }
                }
            case 3: // FramebufferUpdateRequest
                self.read(9) { body in
                    let incremental = body[body.startIndex] != 0
                    let request = (
                        x: Int(Self.uint16(body, at: 1)),
                        y: Int(Self.uint16(body, at: 3)),
                        width: Int(Self.uint16(body, at: 5)),
                        height: Int(Self.uint16(body, at: 7)))
                    if !incremental {
                        self.isDirty = true
                    }
                    self.pendingRequest = request
                    self.answerPendingRequest()
                    self.readMessage()
                }
            case 4: // KeyEvent
                self.read(7) { body in
                    self.server.record(.key(
                        keysym: Self.uint32(body, at: 3),
                        isDown: body[body.startIndex] != 0))
                    self.readMessage()
                }
            case 5: // PointerEvent
                self.read(5) { body in
                    self.server.record(.pointer(
                        x: Int(Self.uint16(body, at: 1)),
                        y: Int(Self.uint16(body, at: 3)),
                        buttons: body[body.startIndex]))
                    self.readMessage()
                }
            case 6: // ClientCutText
                self.read(7) { header in
                    let length = Int(Self.uint32(header, at: 3))
                    self.read(length) { body in
                        self.server.record(.cutText(String(decoding: body, as: UTF8.self)))
                        self.readMessage()
                    }
                }
            default:
                // An extension this server never advertised.
                self.close()
            }
        }
    }

    /// Sends the requested region if anything has changed since the last
    /// update; otherwise keeps the request until something does.
    private func answerPendingRequest() {
        guard isDirty, let request = pendingRequest else { return }
        let x = min(max(0, request.x), server.width)
        let y = min(max(0, request.y), server.height)
        let width = min(request.width, server.width - x)
        let height = min(request.height, server.height - y)
        guard width > 0, height > 0 else { return }
        pendingRequest = nil
        isDirty = false

        var message = Data([0, 0, 0, 1])
        message.append(Self.bigEndian(UInt16(x)))
        message.append(Self.bigEndian(UInt16(y)))
        message.append(Self.bigEndian(UInt16(width)))
        message.append(Self.bigEndian(UInt16(height)))
        message.append(Self.bigEndian(UInt32(0))) // Raw
        let native = server.copyRegion(x: x, y: y, width: width, height: height)
        message.append(pixelFormat.convert(native))
        send(message)
    }

    // MARK: Encoding helpers

    static func bigEndian(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        return UInt16(data[start]) << 8 | UInt16(data[start + 1])
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) << 24 | UInt32(data[start + 1]) << 16
            | UInt32(data[start + 2]) << 8 | UInt32(data[start + 3])
    }
}

/// An RFB true-colour pixel format.
private struct PixelFormat: Equatable {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: Bool
    var redMax: UInt16
    var greenMax: UInt16
    var blueMax: UInt16
    var redShift: UInt8
    var greenShift: UInt8
    var blueShift: UInt8

    /// The server's own layout: 32-bit little-endian, bytes B, G, R, X.
    static let native = PixelFormat(
        bitsPerPixel: 32, depth: 24, bigEndian: false,
        redMax: 255, greenMax: 255, blueMax: 255,
        redShift: 16, greenShift: 8, blueShift: 0)

    init(
        bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool,
        redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
        redShift: UInt8, greenShift: UInt8, blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// Parses the 16-byte wire form. Only true-colour formats are supported.
    init?(_ data: Data) {
        guard data.count >= 16 else { return nil }
        let bytes = [UInt8](data.prefix(16))
        guard bytes[3] != 0, [8, 16, 32].contains(bytes[0]) else { return nil }
        self.init(
            bitsPerPixel: bytes[0], depth: bytes[1], bigEndian: bytes[2] != 0,
            redMax: UInt16(bytes[4]) << 8 | UInt16(bytes[5]),
            greenMax: UInt16(bytes[6]) << 8 | UInt16(bytes[7]),
            blueMax: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
            redShift: bytes[10], greenShift: bytes[11], blueShift: bytes[12])
    }

    var encoded: Data {
        var data = Data([bitsPerPixel, depth, bigEndian ? 1 : 0, 1])
        data.append(Client.bigEndian(redMax))
        data.append(Client.bigEndian(greenMax))
        data.append(Client.bigEndian(blueMax))
        data.append(contentsOf: [redShift, greenShift, blueShift, 0, 0, 0])
        return data
    }

    /// Converts native BGRX pixels into this format.
    func convert(_ native: [UInt8]) -> Data {
        if self == PixelFormat.native {
            return Data(native)
        }
        let bytesPerPixel = Int(bitsPerPixel) / 8
        var out = Data(capacity: native.count / 4 * bytesPerPixel)
        var index = 0
        while index + 3 < native.count {
            let blue = UInt32(native[index])
            let green = UInt32(native[index + 1])
            let red = UInt32(native[index + 2])
            let value = (red * UInt32(redMax) / 255) << UInt32(redShift)
                | (green * UInt32(greenMax) / 255) << UInt32(greenShift)
                | (blue * UInt32(blueMax) / 255) << UInt32(blueShift)
            for byte in 0..<bytesPerPixel {
                let shift = bigEndian ? (bytesPerPixel - 1 - byte) * 8 : byte * 8
                out.append(UInt8((value >> UInt32(shift)) & 0xFF))
            }
            index += 4
        }
        return out
    }
}
