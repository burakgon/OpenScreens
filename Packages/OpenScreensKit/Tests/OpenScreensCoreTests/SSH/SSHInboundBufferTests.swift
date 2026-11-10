import Foundation
import NIOCore
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SSH inbound buffer")
    struct SSHInboundBufferTests {

        private func buffer(chunks: [[UInt8]]) -> SSHInboundBuffer {
            var buffer = SSHInboundBuffer()
            for chunk in chunks {
                buffer.append(ByteBuffer(bytes: chunk))
            }
            return buffer
        }

        @Test func startsEmpty() {
            var buffer = SSHInboundBuffer()
            #expect(buffer.count == 0)
            #expect(buffer.take(0).makeData().isEmpty)
        }

        @Test func aReadInsideOneChunkLeavesTheRestInPlace() {
            var buffer = buffer(chunks: [[1, 2, 3, 4, 5]])

            #expect(buffer.take(2).makeData() == Data([1, 2]))
            #expect(buffer.count == 3)
            #expect(buffer.take(3).makeData() == Data([3, 4, 5]))
            #expect(buffer.count == 0)
        }

        @Test func aReadCanSpanChunks() {
            var buffer = buffer(chunks: [[1, 2], [3], [4, 5, 6], [7]])
            #expect(buffer.count == 7)

            // Ends in the middle of the third chunk.
            let taken = buffer.take(5)
            #expect(taken.count == 5)
            #expect(taken.makeData() == Data([1, 2, 3, 4, 5]))
            #expect(buffer.count == 2)
            // The remainder keeps its order across the chunk boundary.
            #expect(buffer.take(2).makeData() == Data([6, 7]))
        }

        @Test func bytesComeOutInTheOrderTheyWentIn() {
            let payload = Data.testPattern(count: 100_000)
            var buffer = SSHInboundBuffer()
            // Feed in chunks of uneven sizes…
            var fed = 0
            var chunkSize = 1
            while fed < payload.count {
                let size = min(chunkSize, payload.count - fed)
                buffer.append(ByteBuffer(bytes: payload[fed..<fed + size]))
                fed += size
                chunkSize = chunkSize * 3 % 4099 + 1
            }
            #expect(buffer.count == payload.count)

            // …and read in pieces of other uneven sizes.
            var read = Data()
            var readSize = 7
            while buffer.count > 0 {
                read.append(buffer.take(min(readSize, buffer.count)).makeData())
                readSize = readSize * 5 % 6151 + 1
            }
            #expect(read == payload)
        }

        @Test func emptyChunksAreIgnored() {
            var buffer = buffer(chunks: [[], [9], []])
            #expect(buffer.count == 1)
            #expect(buffer.take(1).makeData() == Data([9]))
        }

        @Test func removeAllDiscardsEverything() {
            var buffer = buffer(chunks: [[1, 2], [3]])
            buffer.removeAll()
            #expect(buffer.count == 0)
            buffer.append(ByteBuffer(bytes: [4]))
            #expect(buffer.take(1).makeData() == Data([4]))
        }

        @Test func aSingleChunkIsHandedOverWithoutCopying() throws {
            let chunk = ByteBuffer(bytes: [1, 2, 3, 4])
            var buffer = SSHInboundBuffer()
            buffer.append(chunk)

            // The slice shares the chunk's storage; nothing was copied.
            let slice = buffer.take(4).makeBuffer(allocator: ByteBufferAllocator())
            #expect(slice == chunk)
            let sameStorage = chunk.withUnsafeReadableBytes { original in
                slice.withUnsafeReadableBytes { $0.baseAddress == original.baseAddress }
            }
            #expect(sameStorage)
        }

        @Test func chunksAreJoinedIntoOneBufferWhenNeeded() {
            var buffer = buffer(chunks: [[1, 2], [3, 4, 5]])
            let joined = buffer.take(4).makeBuffer(allocator: ByteBufferAllocator())
            #expect(joined == ByteBuffer(bytes: [1, 2, 3, 4]))
            #expect(buffer.take(0).makeBuffer(allocator: ByteBufferAllocator()).readableBytes == 0)
        }
    }
}
