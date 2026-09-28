import Foundation
import NexusSync
import Testing

@Suite struct PayloadCipherTests {
    @Test func sealsAndOpens() throws {
        let cipher = try PayloadCipher(keyData: PayloadCipher.generateKeyData())
        let plaintext = Data("observed 23.1 V at TP1".utf8)
        let sealed = try cipher.seal(plaintext, associatedData: Data("record-1".utf8))
        #expect(sealed.count == plaintext.count + 29)
        #expect(sealed.first == 1)
        #expect(sealed.range(of: plaintext) == nil)
        #expect(try cipher.open(sealed, associatedData: Data("record-1".utf8)) == plaintext)
        // Fresh nonce every time.
        #expect(try cipher.seal(plaintext, associatedData: Data("record-1".utf8)) != sealed)
    }

    @Test func rejectsTamperingWrongKeysAndMovedPayloads() throws {
        let cipher = try PayloadCipher(keyData: PayloadCipher.generateKeyData())
        let sealed = try cipher.seal(Data("payload".utf8), associatedData: Data("a".utf8))

        var flipped = sealed
        flipped[flipped.count - 1] ^= 0x01
        #expect(throws: PayloadCipherError.authenticationFailed) { try cipher.open(flipped, associatedData: Data("a".utf8)) }
        #expect(throws: PayloadCipherError.authenticationFailed) { try cipher.open(sealed, associatedData: Data("b".utf8)) }
        let other = try PayloadCipher(keyData: PayloadCipher.generateKeyData())
        #expect(throws: PayloadCipherError.authenticationFailed) { try other.open(sealed, associatedData: Data("a".utf8)) }
        #expect(throws: PayloadCipherError.malformedPayload) { try cipher.open(Data([1, 2, 3])) }
        var wrongVersion = sealed
        wrongVersion[0] = 9
        #expect(throws: PayloadCipherError.malformedPayload) { try cipher.open(wrongVersion, associatedData: Data("a".utf8)) }
    }

    @Test func keysAreThirtyTwoBytes() throws {
        #expect(PayloadCipher.generateKeyData().count == 32)
        #expect(PayloadCipher.generateKeyData() != PayloadCipher.generateKeyData())
        #expect(throws: PayloadCipherError.invalidKeyLength(16)) { try PayloadCipher(keyData: Data(count: 16)) }
    }

    @Test func matchesAKnownAnswer() throws {
        // NIST GCM test case 13 (256-bit zero key, zero IV, empty plaintext): the tag.
        let cipher = try PayloadCipher(keyData: Data(count: 32))
        let tag = Data([0x53, 0x0f, 0x8a, 0xfb, 0xc7, 0x45, 0x36, 0xb9, 0xa9, 0x63, 0xb4, 0xf1, 0xc4, 0xcb, 0x73, 0x8b])
        var sealed = Data([1]) + Data(count: 12) + tag
        #expect(try cipher.open(sealed) == Data())
        sealed[13] ^= 0xff
        #expect(throws: PayloadCipherError.authenticationFailed) { try cipher.open(sealed) }
    }
}
