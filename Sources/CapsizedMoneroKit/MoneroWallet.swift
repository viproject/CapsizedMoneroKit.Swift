// SPDX-License-Identifier: MIT
public enum MoneroWallet {
    case bip39(seed: [String], passphrase: String)
    case legacy(seed: [String], passphrase: String)
    case polyseed(seed: [String], passphrase: String)
    case keys(address: String, viewKey: String, spendKey: String)
    case watch(address: String, viewKey: String)

    mutating func clear() {
        switch self {
        case .bip39:
            self = .bip39(seed: [], passphrase: "")
        case .legacy:
            self = .legacy(seed: [], passphrase: "")
        case .polyseed:
            self = .polyseed(seed: [], passphrase: "")
        case .keys:
            self = .keys(address: "", viewKey: "", spendKey: "")
        case .watch:
            self = .watch(address: "", viewKey: "")
        }
    }
}
