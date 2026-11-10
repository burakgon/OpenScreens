import CryptoKit
import Foundation

/// The Blowfish block cipher, as far as bcrypt needs it: the key schedule of
/// "expensive key setup" and encryption of single 64-bit blocks.
///
/// Written from the published descriptions: Schneier's "Description of a New
/// Variable-Length Key, 64-Bit Block Cipher (Blowfish)" for the cipher, and
/// Provos and Mazières' "A Future-Adaptable Password Scheme" for the salted
/// key schedule.
///
/// A class because the state lives in memory it allocates itself and has to
/// give back. An instance is made, used and dropped inside one function; it
/// is not meant to be shared.
final class Blowfish {
    private static let subkeyCount = 18
    private static let sboxSize = 256
    private static let wordCount = subkeyCount + 4 * sboxSize

    private static let initialWords = BlowfishInitialState.subkeys + BlowfishInitialState.sboxes

    /// The 18 subkeys followed by the four S-boxes. They share one allocation
    /// because the key schedule rewrites both in a single pass, and unchecked
    /// storage because bcrypt runs the round function tens of millions of
    /// times per derived key.
    private let words: UnsafeMutableBufferPointer<UInt32>

    init() {
        words = .allocate(capacity: Self.wordCount)
        _ = words.initialize(from: Self.initialWords)
    }

    deinit {
        words.deallocate()
    }

    /// The round function F: the four bytes of `x` each index one S-box, and
    /// the results are combined with addition modulo 2³² and XOR.
    @inline(__always)
    private func mix(_ x: UInt32) -> UInt32 {
        let sboxes = Self.subkeyCount
        let a = words[sboxes + Int(x >> 24)]
        let b = words[sboxes + Self.sboxSize + Int((x >> 16) & 0xFF)]
        let c = words[sboxes + 2 * Self.sboxSize + Int((x >> 8) & 0xFF)]
        let d = words[sboxes + 3 * Self.sboxSize + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    /// Encrypts one block, held as two 32-bit halves: a 16-round Feistel
    /// network with a subkey XORed in before every round and after the last.
    @inline(__always)
    func encipher(_ left: inout UInt32, _ right: inout UInt32) {
        var l = left ^ words[0]
        var r = right
        var round = 1
        while round < 17 {
            r ^= mix(l) ^ words[round]
            l ^= mix(r) ^ words[round + 1]
            round += 2
        }
        left = r ^ words[17]
        right = l
    }

    /// The salted key schedule. `key` is XORed into the subkeys; then every
    /// word of the state is replaced, two at a time, by repeatedly encrypting
    /// a block that has the next 64 bits of `salt` XORed into it first.
    func expandState(salt: [UInt8], key: [UInt8]) {
        mixIntoSubkeys(key)
        var saltWords = CyclicWords(salt)
        var left: UInt32 = 0
        var right: UInt32 = 0
        var index = 0
        while index < Self.wordCount {
            left ^= saltWords.next()
            right ^= saltWords.next()
            encipher(&left, &right)
            words[index] = left
            words[index + 1] = right
            index += 2
        }
    }

    /// The same schedule without a salt: the classic Blowfish key setup,
    /// applied to the current state instead of the initial one.
    func expandState(key: [UInt8]) {
        mixIntoSubkeys(key)
        var left: UInt32 = 0
        var right: UInt32 = 0
        var index = 0
        while index < Self.wordCount {
            encipher(&left, &right)
            words[index] = left
            words[index + 1] = right
            index += 2
        }
    }

    private func mixIntoSubkeys(_ key: [UInt8]) {
        var keyWords = CyclicWords(key)
        for index in 0..<Self.subkeyCount {
            words[index] ^= keyWords.next()
        }
    }

    /// Reads big-endian 32-bit words from a byte string, starting over at the
    /// beginning whenever it runs out.
    struct CyclicWords {
        private let bytes: [UInt8]
        private var position = 0

        init(_ bytes: [UInt8]) {
            precondition(!bytes.isEmpty, "Blowfish needs a non-empty key")
            self.bytes = bytes
        }

        mutating func next() -> UInt32 {
            var word: UInt32 = 0
            for _ in 0..<4 {
                if position == bytes.count { position = 0 }
                word = word << 8 | UInt32(bytes[position])
                position += 1
            }
            return word
        }
    }
}

/// `bcrypt_pbkdf`, the key derivation function that protects OpenSSH private
/// key files.
///
/// It is PBKDF2 with two changes: the pseudo-random function is a bcrypt
/// variant fed with SHA-512 digests of the password and salt, and the output
/// blocks are interleaved rather than concatenated, so that no part of the
/// derived key can be had for less than the full cost. The function was
/// introduced by OpenBSD and is specified by its implementation; this one
/// follows that definition step for step.
enum BcryptPBKDF {
    /// Bytes produced by one bcrypt core.
    static let blockSize = 32

    /// The longest key the function is defined for.
    static let maximumLength = blockSize * blockSize

    /// The fixed 256-bit plaintext every bcrypt core encrypts.
    private static let plaintext = [UInt8]("OxychromaticBlowfishSwatDynamite".utf8)

    /// Derives `length` bytes of key material.
    ///
    /// - Returns: `nil` when a parameter is outside what the function is
    ///   defined for: an empty password or salt, fewer than one round, or a
    ///   length that is zero or above ``maximumLength``.
    static func deriveKey(
        password: [UInt8],
        salt: [UInt8],
        rounds: Int,
        length: Int
    ) -> [UInt8]? {
        guard !password.isEmpty, !salt.isEmpty, rounds >= 1,
              length >= 1, length <= maximumLength else { return nil }

        // Output byte i of block n lands at i * stride + n: the blocks are
        // dealt out like cards rather than laid end to end.
        let stride = (length + blockSize - 1) / blockSize
        var amount = (length + stride - 1) / stride

        let passwordDigest = [UInt8](SHA512.hash(data: password))
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var blockNumber: UInt32 = 1

        while remaining > 0 {
            // First round: the salt is the caller's salt and the block number.
            var hasher = SHA512()
            hasher.update(data: salt)
            withUnsafeBytes(of: blockNumber.bigEndian) { hasher.update(bufferPointer: $0) }
            var saltDigest = [UInt8](hasher.finalize())

            var block = hash(passwordDigest: passwordDigest, saltDigest: saltDigest)
            var output = block
            for _ in 1..<rounds {
                // Later rounds: the salt is the previous round's output.
                saltDigest = [UInt8](SHA512.hash(data: block))
                block = hash(passwordDigest: passwordDigest, saltDigest: saltDigest)
                for index in output.indices {
                    output[index] ^= block[index]
                }
            }

            amount = min(amount, remaining)
            var produced = 0
            while produced < amount {
                let destination = produced * stride + Int(blockNumber - 1)
                if destination >= length { break }
                key[destination] = output[produced]
                produced += 1
            }
            remaining -= produced
            blockNumber += 1
        }
        return key
    }

    /// One bcrypt core: build a Blowfish state from the two digests with the
    /// expensive key schedule, then encrypt the fixed plaintext 64 times.
    private static func hash(passwordDigest: [UInt8], saltDigest: [UInt8]) -> [UInt8] {
        let cipher = Blowfish()
        cipher.expandState(salt: saltDigest, key: passwordDigest)
        for _ in 0..<64 {
            cipher.expandState(key: saltDigest)
            cipher.expandState(key: passwordDigest)
        }

        var source = Blowfish.CyclicWords(plaintext)
        var block = (0..<blockSize / 4).map { _ in source.next() }
        for _ in 0..<64 {
            for index in stride(from: 0, to: block.count, by: 2) {
                var left = block[index]
                var right = block[index + 1]
                cipher.encipher(&left, &right)
                block[index] = left
                block[index + 1] = right
            }
        }

        // The words go in big-endian and come out little-endian. The swap is
        // part of the function's definition, not an accident of this code.
        return block.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { [UInt8]($0) }
        }
    }
}
