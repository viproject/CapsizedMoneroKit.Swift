// SPDX-License-Identifier: MIT
import CMonero
import Combine
import Foundation
import HsToolKit

class SyncStateManager {
    static let storeBlocksCount: UInt64 = 2000
    static let connectTimeout: TimeInterval = 30

    private var cancellables = Set<AnyCancellable>()
    private var reachabilityManager: ReachabilityManager
    private let logger: Logger?
    private var isRunning = false
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?

    private let queue = DispatchQueue(label: "io.capsized.monero_kit.core_state_queue", qos: .background)

    private var connectStartTime: Date?
    private var backgroundSyncSetupSuccess: Bool = false
    private var restoreHeight: UInt64
    private var lastStoredBlockHeight: UInt64 = 0
    private var status: WalletCoreStatus = .unknown
    private var isSynchronized: Bool = false
    private var daemonHeight: UInt64 = 0
    private(set) var walletHeight: UInt64 = 0
    private(set) var blockHeights: (UInt64, UInt64)?

    var onSyncStateChanged: (() -> Void)?

    var state: WalletState = .notSynced(error: WalletStateError.notStarted) {
        didSet {
            if oldValue != state {
                onSyncStateChanged?()
            }
        }
    }

    var chunkOfBlocksSynced: Bool {
        // Blocks before restore height are synced without transactions
        if lastStoredBlockHeight < restoreHeight {
            return false
        }

        return lastStoredBlockHeight <= walletHeight && walletHeight - lastStoredBlockHeight >= Self.storeBlocksCount
    }

    init(logger: Logger?, restoreHeight: UInt64, reachabilityManager: ReachabilityManager) {
        self.logger = logger
        self.reachabilityManager = reachabilityManager
        self.restoreHeight = restoreHeight

        reachabilityManager.$isReachable
            .receive(on: queue)
            .sink { [weak self] isReachable in
                self?.state = .idle(daemonReachable: isReachable)
            }
            .store(in: &cancellables)
    }

    private func evaluateState() -> WalletState {
        guard reachabilityManager.isReachable else {
            return .idle(daemonReachable: false)
        }

        // Still waiting for the daemon to respond with a block height.
        guard daemonHeight > 0 else {
            if let connectStartTime, Date().timeIntervalSince(connectStartTime) > Self.connectTimeout {
                return .notSynced(error: .statusError("Connection timed out"))
            }
            return .connecting(waiting: false)
        }

        if daemonHeight == walletHeight, isSynchronized {
            return .synced(lastBlockHeight: walletHeight)
        }

        // The wallet is still fast-scanning pre-restore-height empty blocks.
        // Show syncing at 0% so the UI reflects activity rather than "connecting".
        guard walletHeight >= restoreHeight else {
            return .syncing(progress: 0, remainingBlocksCount: Int(daemonHeight - restoreHeight))
        }

        let numberOfBlocksToSync = Int(daemonHeight - restoreHeight)
        let numberOfBlocksSynced = Int(walletHeight - restoreHeight)
        if numberOfBlocksToSync == 0 {
            return .syncing(progress: 100, remainingBlocksCount: 0)
        }

        let progress = numberOfBlocksSynced * 100 / numberOfBlocksToSync
        let remaining = numberOfBlocksToSync - numberOfBlocksSynced
        return .syncing(progress: progress, remainingBlocksCount: remaining)
    }

    private func checkSyncState() {
        guard let walletPtr = walletPointer else { return }

        let previousWalletHeight = walletHeight
        walletHeight = MONERO_Wallet_blockChainHeight(walletPtr)
        isSynchronized = MONERO_Wallet_synchronized(walletPtr)
        let status = MONERO_Wallet_status(walletPtr)

        if status != 0 {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let errorStr = stringFromCString(errorCStr)
            logger?.error("Wallet is in error state (\(status)): \(errorStr ?? "Unknown wallet error").")
            state = .notSynced(error: WalletStateError.statusError(errorStr))
            
            // Continue polling - the wallet may recover
            scheduleNextCheck()

            return
        }

        if lastStoredBlockHeight < restoreHeight {
            lastStoredBlockHeight = walletHeight
        }

        let previousDaemonHeight = daemonHeight
        daemonHeight = MONERO_Wallet_daemonBlockChainHeight(walletPtr)
        
        if previousWalletHeight != walletHeight || previousDaemonHeight != daemonHeight {
            blockHeights = (walletHeight, daemonHeight)
        }

        state = evaluateState()

        scheduleNextCheck()
    }

    private func scheduleNextCheck() {
        guard isRunning else { return }

        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkSyncState()
        }
    }

    func validateReachable() {
        if !reachabilityManager.isReachable {
            state = .idle(daemonReachable: false)
        }
    }

    func start(walletPointer: UnsafeMutableRawPointer?, cWalletPassword: UnsafeMutablePointer<CChar>?) {
        guard let walletPointer, let cWalletPassword else { return }

        if isRunning { return }
        isRunning = true

        self.walletPointer = walletPointer
        self.cWalletPassword = cWalletPassword
        connectStartTime = Date()

        scheduleNextCheck()
    }

    func stop() {
        isRunning = false

        connectStartTime = nil

        walletPointer = nil
        cWalletPassword = nil
    }

    func walletStored() {
        lastStoredBlockHeight = walletHeight
    }

    /// Corrects the restore height after the C++ wallet file has been opened.
    /// For existing wallets the caller may have passed today's block height as a
    /// placeholder; this updates it to the value actually stored in the file.
    func updateRestoreHeight(_ height: UInt64) {
        restoreHeight = height
    }

    enum BackgroundSyncType: Int32 {
        case none = 0
        case `default` = 1
        case customPassword = 2
    }
}
