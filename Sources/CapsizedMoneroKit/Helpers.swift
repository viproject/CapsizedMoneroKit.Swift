// SPDX-License-Identifier: MIT
import BigInt
import CMonero
import Foundation
import HdWalletKit
import HsToolKit

private let saltPrefix = "mnemonic"
private let coinType: UInt32 = 128
private let ed25519CurveOrderHex = "1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED"

func stringFromCString(_ cString: UnsafePointer<Int8>!) -> String? {
    guard let cString else { return nil }
    let swiftString = String(cString: cString)
    MONERO_free(UnsafeMutableRawPointer(mutating: cString))
    return swiftString
}

// Use for sensitive values (seeds, private keys) — zeros the C buffer before freeing.
// Note: the returned Swift String cannot itself be securely wiped (Swift runtime limitation);
// callers should minimise the lifetime of the returned value.
func secureStringFromCString(_ cString: UnsafePointer<Int8>!) -> String? {
    guard let cString else { return nil }
    let length = strlen(cString)
    let swiftString = String(cString: cString)
    memset(UnsafeMutableRawPointer(mutating: cString), 0, length)
    MONERO_free(UnsafeMutableRawPointer(mutating: cString))
    return swiftString
}

func legacySeedFromBip39(mnemonic: [String], passphrase: String = "") throws -> String {
    guard let seed = Mnemonic.seed(mnemonic: mnemonic, prefix: saltPrefix, passphrase: passphrase) else {
        throw CapsizedMoneroKitError.invalidSeed
    }

    let hdWallet = HDWallet(seed: seed, coinType: coinType, xPrivKey: HDExtendedKeyVersion.xprv.rawValue)
    let secp256kPrivateKey = try hdWallet.privateKey(account: 0, index: 0, chain: .external).raw
    let spendKey = Data(reduceECKey(secp256kPrivateKey.bytes))

    guard let legacySeed = legacySeedFromKey(key: spendKey.hs.hex) else {
        throw CapsizedMoneroKitError.invalidSeed
    }

    return legacySeed
}

func legacySeedFromKey(key: String) -> String? {
    let wordsCString = MONERO_Wallet_bytesToWords(key)
    return stringFromCString(wordsCString)
}

func reduceECKey(_ buffer: [UInt8]) -> [UInt8] {
    let curveOrder = BigUInt(ed25519CurveOrderHex, radix: 16)!
    let bigNumber = readBytes(buffer)

    var result = bigNumber % curveOrder

    // Convert result (BigUInt) to little-endian [UInt8] with 32 bytes
    var resultBuffer = [UInt8](repeating: 0, count: 32)
    for i in 0 ..< 32 {
        resultBuffer[i] = UInt8(result & 0xFF)
        result >>= 8
    }

    return resultBuffer
}

func readBytes(_ bytes: [UInt8]) -> BigUInt {
    var result = BigUInt(0)
    for (i, byte) in bytes.enumerated() {
        result += BigUInt(byte) << (8 * i)
    }
    return result
}
