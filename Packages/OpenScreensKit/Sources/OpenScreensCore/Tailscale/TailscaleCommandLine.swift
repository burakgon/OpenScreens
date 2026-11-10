#if os(macOS)

import Foundation

/// Runs the Tailscale command-line tool and collects what it prints.
///
/// The tool is started straight from its path with its arguments as a list.
/// No shell is involved, so nothing in a path or an argument is ever
/// interpreted. Nothing here blocks a thread: output is gathered as it
/// arrives, and the caller is resumed when the tool exits, runs out of time,
/// or the calling task is cancelled.
enum TailscaleCommandLine {
    struct Output: Equatable, Sendable {
        var exitCode: Int32
        var standardOutput: Data
        var standardError: Data
    }

    enum Failure: Error, Equatable {
        /// The system would not start the tool; the text says why.
        case couldNotStart(String)
        /// The tool was still running when its time was up, and was stopped.
        case timedOut
    }

    /// How long the output streams may stay open after the tool has exited
    /// before what has been read is taken as everything.
    static let streamGracePeriod: DispatchTimeInterval = .seconds(2)
    /// How long a tool that was asked to stop has before it is killed.
    static let terminationGracePeriod: DispatchTimeInterval = .seconds(2)

    static func run(
        _ executable: URL,
        arguments: [String] = [],
        timeout: Duration
    ) async throws -> Output {
        let run = Run(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }
}

extension TailscaleCommandLine {
    /// One run of the tool. Its callbacks arrive on several system threads,
    /// so everything that changes is guarded by `lock`.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let outputPipe = Pipe()
        private let errorPipe = Pipe()
        private let timeout: Duration

        private var continuation: CheckedContinuation<Output, any Error>?
        private var timer: (any DispatchSourceTimer)?
        private var wasCancelled = false
        private var output = Data()
        private var errorOutput = Data()
        private var outputEnded = false
        private var errorEnded = false
        private var exitCode: Int32?

        init(executable: URL, arguments: [String], timeout: Duration) {
            self.timeout = timeout
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.qualityOfService = .userInitiated
        }

        func start(_ continuation: CheckedContinuation<Output, any Error>) {
            lock.withLock {
                guard !wasCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation

                // Both streams are read as they fill. A tool that prints more
                // than a pipe holds would otherwise stall, waiting for room.
                outputPipe.fileHandleForReading.readabilityHandler = { [self] handle in
                    read(from: handle, isErrorStream: false)
                }
                errorPipe.fileHandleForReading.readabilityHandler = { [self] handle in
                    read(from: handle, isErrorStream: true)
                }
                process.terminationHandler = { [weak self] process in
                    self?.exited(with: process.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    finish(.failure(Failure.couldNotStart(error.localizedDescription)))
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                let (seconds, attoseconds) = timeout.components
                timer.schedule(deadline: .now() + Double(seconds) + Double(attoseconds) * 1e-18)
                timer.setEventHandler { [weak self] in
                    self?.stop(reportingFailure: Failure.timedOut)
                }
                timer.resume()
                self.timer = timer
            }
        }

        func cancel() {
            lock.withLock { wasCancelled = true }
            stop(reportingFailure: CancellationError())
        }

        /// Called whenever a stream has something to read or has ended;
        /// either way the read returns at once.
        private func read(from handle: FileHandle, isErrorStream: Bool) {
            let chunk = (try? handle.read(upToCount: 1 << 16)) ?? Data()
            lock.withLock {
                if !chunk.isEmpty {
                    if isErrorStream {
                        errorOutput.append(chunk)
                    } else {
                        output.append(chunk)
                    }
                    return
                }
                handle.readabilityHandler = nil
                if isErrorStream {
                    errorEnded = true
                } else {
                    outputEnded = true
                }
                finishIfComplete()
            }
        }

        private func exited(with status: Int32) {
            lock.withLock {
                exitCode = status
                finishIfComplete()
            }
            // The streams normally end with the tool. Should something the
            // tool started be holding them open, what has been read by then
            // is all there will be.
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + TailscaleCommandLine.streamGracePeriod) { [self] in
                    lock.withLock {
                        finish(.success(Output(
                            exitCode: status,
                            standardOutput: output,
                            standardError: errorOutput)))
                    }
                }
        }

        /// Ends the run early, for a timeout or a cancellation.
        private func stop(reportingFailure failure: any Error) {
            lock.withLock {
                guard continuation != nil else { return }
                if process.isRunning {
                    process.terminate()
                    // A tool that ignores being asked to stop is killed
                    // outright a moment later.
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + TailscaleCommandLine.terminationGracePeriod
                    ) { [self] in
                        lock.withLock {
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
                finish(.failure(failure))
            }
        }

        /// Call with `lock` held.
        private func finishIfComplete() {
            guard let exitCode, outputEnded, errorEnded else { return }
            finish(.success(Output(
                exitCode: exitCode, standardOutput: output, standardError: errorOutput)))
        }

        /// Resumes the caller, once. Call with `lock` held.
        private func finish(_ result: Result<Output, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            // The handlers hold this object; letting go of them lets it go.
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            continuation.resume(with: result)
        }
    }
}

#endif
