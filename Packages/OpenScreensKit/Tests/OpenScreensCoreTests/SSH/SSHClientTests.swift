import Foundation
import Network
import NIOCore
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SSHClient")
    struct SSHClientTests {
        @Test func aPeerThatGoesSilentIsGivenUpAfterTheSameTimeIdleOrNot() {
            let options = SSHClient.tcpOptions(timeout: .seconds(15))

            // An idle connection: probes after 20 seconds, six of them ten
            // seconds apart.
            #expect(options.enableKeepalive)
            #expect(options.keepaliveIdle == 20)
            #expect(options.keepaliveInterval == 10)
            #expect(options.keepaliveCount == 6)
            // A connection with data on its way gets no probes. What is
            // given up on there is the retrying, after as long.
            #expect(options.connectionDropTime == 80)

            // The rest is as the caller asked.
            #expect(options.connectionTimeout == 15)
            #expect(options.noDelay)
            #expect(SSHClient.tcpOptions(timeout: .seconds(3)).connectionTimeout == 3)
        }
    }
}
