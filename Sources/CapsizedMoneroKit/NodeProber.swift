// SPDX-License-Identifier: MIT
import CMonero
import Foundation

class NodeProber {
    private let walletManagerPtr: UnsafeMutableRawPointer
    private var walletPtr: UnsafeMutableRawPointer?
    private let tempPath: String

    init?() {
        guard let wmPtr = MONERO_WalletManagerFactory_getWalletManager() else { return nil }
        walletManagerPtr = wmPtr

        tempPath = NSTemporaryDirectory() + "node_probe_\(UUID().uuidString)"
        let cPath = strdup((tempPath as NSString).utf8String)
        let cPassword = strdup(("" as NSString).utf8String)
        defer {
            free(cPath)
            free(cPassword)
        }

        guard let wPtr = MONERO_WalletManager_createWallet(
            wmPtr, cPath, cPassword,
            ("English" as NSString).utf8String,
            NetworkType.mainnet.rawValue
        ) else { return nil }

        walletPtr = wPtr
    }

    deinit {
        cleanup()
    }

    struct ProbeResult {
        let responseTime: TimeInterval
        let height: UInt64
    }

    func probe(node: Node) -> ProbeResult? {
        guard let wPtr = walletPtr else { return nil }

        let daemonAddress = node.url.absoluteString
        let daemonLogin = node.login ?? ""
        let daemonPassword = node.password ?? ""

        let cAddress = strdup((daemonAddress as NSString).utf8String)
        let cLogin = strdup((daemonLogin as NSString).utf8String)
        let cPassword = strdup((daemonPassword as NSString).utf8String)
        defer {
            free(cAddress)
            free(cLogin)
            free(cPassword)
        }

        let start = CFAbsoluteTimeGetCurrent()

        let initSuccess = MONERO_Wallet_init(wPtr, cAddress, 0, cLogin, cPassword, true, false, "")
        guard initSuccess else { return nil }

        MONERO_Wallet_setTrustedDaemon(wPtr, node.isTrusted)

        let height = MONERO_Wallet_daemonBlockChainHeight(wPtr)
        guard height > 0 else { return nil }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        return ProbeResult(responseTime: elapsed, height: height)
    }

    private func cleanup() {
        if let wPtr = walletPtr {
            MONERO_WalletManager_closeWallet(walletManagerPtr, wPtr, false)
            walletPtr = nil
        }

        let fm = FileManager.default
        try? fm.removeItem(atPath: tempPath)
        try? fm.removeItem(atPath: tempPath + ".keys")
        try? fm.removeItem(atPath: tempPath + ".address.txt")
    }
}
