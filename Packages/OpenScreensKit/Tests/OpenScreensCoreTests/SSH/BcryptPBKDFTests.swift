import Foundation
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("bcrypt_pbkdf")
    struct BcryptPBKDFTests {

        struct Vector: Sendable, CustomTestStringConvertible {
            var password: [UInt8]
            var salt: [UInt8]
            var rounds: Int
            /// The derived key, in hexadecimal.
            var key: String

            var testDescription: String {
                "\(rounds) rounds, \(key.count / 2) bytes, password \(password)"
            }
        }

        /// The test vectors that accompany OpenBSD's `bcrypt_pbkdf`. Between
        /// them they cover NUL bytes inside the password and the salt, keys
        /// shorter than, equal to and longer than one output block, and
        /// several round counts.
        static let vectors = [
            Vector(
                password: Array("password".utf8), salt: Array("salt".utf8), rounds: 4,
                key: "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9"),
            Vector(
                password: Array("password".utf8), salt: [0], rounds: 4,
                key: "c12b566235eee04c212598970a579a67"),
            Vector(
                password: [0], salt: Array("salt".utf8), rounds: 4,
                key: "6051be18c2f4f82cbf0efee5471b4bb9"),
            Vector(
                password: Array("password\0".utf8), salt: Array("salt\0".utf8), rounds: 4,
                key: "7410e44cf4fa07bfaac8a928b1727fac001375e7bf7384370f48efd121743050"),
            Vector(
                password: Array("pass\0wor".utf8), salt: Array("sa\0l".utf8), rounds: 4,
                key: "c2bffd9db38f6569efef4372f4de83c0"),
            Vector(
                password: Array("pass\0word".utf8), salt: Array("sa\0lt".utf8), rounds: 4,
                key: "4ba4ac3925c0e8d7f0cdb6bb1684a56f"),
            Vector(
                password: Array("password".utf8), salt: Array("salt".utf8), rounds: 8,
                key: "e1367ec5151a33faac4cc1c144cd23fa15d5548493ecc99b9b5d9c0d3b27bec7"
                    + "6227ea66088b849b20ab7aa478010246e74bba51723fefa9f9474d6508845e8d"),
            Vector(
                password: Array("password".utf8), salt: Array("salt".utf8), rounds: 42,
                key: "833cf0dcf56db65608e8f0dc0ce882bd"),
        ]

        @Test(arguments: vectors)
        func derivesTheKnownKey(_ vector: Vector) throws {
            let key = try #require(BcryptPBKDF.deriveKey(
                password: vector.password,
                salt: vector.salt,
                rounds: vector.rounds,
                length: vector.key.count / 2))
            #expect(key.map { String(format: "%02x", $0) }.joined() == vector.key)
        }

        @Test func aShorterKeyIsNotAPrefixOfALongerOne() throws {
            // The output blocks are interleaved, so asking for more bytes
            // changes where every byte comes from. This is the property that
            // makes the function unlike plain PBKDF2.
            let password = Array("password".utf8), salt = Array("salt".utf8)
            let short = try #require(BcryptPBKDF.deriveKey(
                password: password, salt: salt, rounds: 2, length: 32))
            let long = try #require(BcryptPBKDF.deriveKey(
                password: password, salt: salt, rounds: 2, length: 48))
            #expect(Array(long.prefix(32)) != short)
            // Bytes at even positions of the longer key are the first block.
            #expect((0..<24).map { long[$0 * 2] } == Array(short.prefix(24)))
        }

        @Test func parametersOutsideTheDefinitionAreRefused() {
            let bytes = Array("x".utf8)
            #expect(BcryptPBKDF.deriveKey(password: [], salt: bytes, rounds: 1, length: 16) == nil)
            #expect(BcryptPBKDF.deriveKey(password: bytes, salt: [], rounds: 1, length: 16) == nil)
            #expect(BcryptPBKDF.deriveKey(password: bytes, salt: bytes, rounds: 0, length: 16) == nil)
            #expect(BcryptPBKDF.deriveKey(password: bytes, salt: bytes, rounds: 1, length: 0) == nil)
            #expect(BcryptPBKDF.deriveKey(
                password: bytes, salt: bytes, rounds: 1,
                length: BcryptPBKDF.maximumLength + 1) == nil)
        }
    }
}
