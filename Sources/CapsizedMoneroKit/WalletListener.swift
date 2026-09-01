// SPDX-License-Identifier: MIT
import CMonero
import Foundation
import HsToolKit

class WalletListener {
    private var walletListenerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var isRunning = false
    private var lockedBalanceBlockHeight: UInt64?
    private let queue = DispatchQueue(label: "monero.kit.wallet-listener-queue", qos: .background)
    var onNewTransaction: (() -> Void)?

    private func checkListener() {
        guard let walletListenerPointer else { return }

        let hasNewTransaction = MONERO_cw_WalletListener_isNewTransactionExist(walletListenerPointer)
        let listenerHeight = MONERO_cw_WalletListener_height(walletListenerPointer)
        if hasNewTransaction {
            // Has new transaction
            onNewTransaction?()
            MONERO_cw_WalletListener_resetIsNewTransactionExist(walletListenerPointer)
        }

        if let height = lockedBalanceBlockHeight {
            let newHeight = listenerHeight
            if newHeight > height, newHeight - height >= Kit.confirmationsThreshold {
                onNewTransaction?()
                lockedBalanceBlockHeight = nil
            }
        }

        scheduleNextCheck()
    }

    private func scheduleNextCheck() {
        guard isRunning else { return }

        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkListener()
        }
    }

    func start(walletPointer: UnsafeMutableRawPointer?) {
        guard !isRunning else { return }
        isRunning = true

        self.walletPointer = walletPointer

        walletListenerPointer = MONERO_cw_getWalletListener(walletPointer)
        MONERO_Wallet_startRefresh(walletPointer)

        scheduleNextCheck()
    }

    func stop() {
        isRunning = false
        onNewTransaction = nil
        walletListenerPointer = nil

        if let walletPointer {
            MONERO_Wallet_stop(walletPointer)
        }
        walletPointer = nil
    }

    func setLockedBalanceHeight(height: UInt64) {
        if lockedBalanceBlockHeight == nil {
            lockedBalanceBlockHeight = height
        }
    }
}
