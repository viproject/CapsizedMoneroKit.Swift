// SPDX-License-Identifier: MIT
import Foundation
import HsToolKit
import Combine
import UIKit
import os

public class Kit {
    public static let confirmationsThreshold: UInt64 = 10

    private static let log = OSLog(subsystem: "io.capsized.monerokit", category: "Kit")

    private let moneroCore: MoneroCore
    private let storage: GrdbStorage
    private let kitId = UUID().uuidString
    private let lifecycleQueue = DispatchQueue(label: "io.capsized.monero_kit.kit_lifecycle_queue", qos: .background)
    private let walletDirectoryName: String
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var handledForegroundFromExpiredBackground = false
    private var notSyncedSince: Date?
    private var lastRotationAttempt: Date?
    private let reachabilityManager: ReachabilityManager

    public let nodePool: NodePool
    public weak var delegate: CapsizedMoneroKitDelegate?

    public init(wallet: MoneroWallet, restoreHeight: UInt64 = 0, walletId: String, walletPassword: String? = nil, nodes: [Node], networkType: NetworkType = .mainnet, isNewWallet: Bool = false, reachabilityManager: ReachabilityManager, logger: HsToolKit.Logger?, moneroCoreLogLevel: Int32? = nil) throws {
        precondition(!nodes.isEmpty, "At least one node is required")

        self.reachabilityManager = reachabilityManager
        nodePool = NodePool(nodes: nodes)
        nodePool.isNetworkReachable = { [weak reachabilityManager] in
            reachabilityManager?.isReachable ?? false
        }

        let baseDirectoryName = "CapsizedMoneroKit/\(walletId)/network_\(networkType.rawValue)"
        let baseDirectoryUrl = try FileHandler.directoryURL(for: baseDirectoryName)

        let databasePath = baseDirectoryUrl.appendingPathComponent("storage").path
        storage = GrdbStorage(databaseFilePath: databasePath)

        walletDirectoryName = "\(baseDirectoryName)/monero_core"

        let walletPath = try FileHandler.directoryURL(for: walletDirectoryName).appendingPathComponent("wallet").path
        let logger = logger ?? Logger(minLogLevel: .verbose)

        // walletPassword should always be provided by the caller. Falling back to
        // walletId is insecure because walletId is not a secret value.
        assert(walletPassword != nil, "walletPassword must be provided explicitly — do not rely on the walletId fallback")
        let resolvedPassword = walletPassword ?? walletId

        moneroCore = MoneroCore(
            wallet: wallet,
            walletPath: walletPath,
            walletPassword: resolvedPassword,
            node: nodePool.activeNode,
            restoreHeight: restoreHeight,
            networkType: networkType,
            isNewWallet: isNewWallet,
            reachabilityManager: reachabilityManager,
            logger: logger,
            moneroCoreLogLevel: moneroCoreLogLevel
        )

        moneroCore.delegate = self

        try moneroCore.ensureWalletCreated()

        let accountNumber = moneroCore.numberOfAccounts()
        
        for account in 0..<accountNumber {
            if storage.getAllAddresses(account: account).isEmpty {
                // Use the live wallet pointer to derive addresses — avoids the static
                // derivation path that only supports legacy seeds and produces wrong
                // results for polyseed wallets.
                let primaryAddress = moneroCore.address(index: 0, account: account)
                storage.add(subAddress: SubAddress(address: primaryAddress, index: 0, account: account))

                if account == 0 {
                    if case .watch = wallet {
                        return
                    }

                    let firstSubAddress = moneroCore.address(index: 1, account: account)
                    storage.add(subAddress: SubAddress(address: firstSubAddress, index: 1, account: account))
                }
            }
        }

        subscribeToBackgroundNotifications()
        
    }
    
    private func subscribeToBackgroundNotifications() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleDidEnterBackground()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleDidBecomeActive()
            }
            .store(in: &cancellables)
        
        BackgroundModeObserver.shared.foregroundFromExpiredBackgroundPublisher
            .sink { [weak self] in
                self?.handleForegroundFromExpiredBackground()
            }
            .store(in: &cancellables)
    }
    
    private func handleDidEnterBackground() {
        lifecycleQueue.async { [weak self] in
            guard let self, started else { return }
            handledForegroundFromExpiredBackground = false
            moneroCore.pause()
        }
    }
    
    private func handleForegroundFromExpiredBackground() {
        lifecycleQueue.async { [weak self] in
            guard let self, started else { return }
            handledForegroundFromExpiredBackground = true
            _restart()
        }
    }
    
    private func handleDidBecomeActive() {
        lifecycleQueue.async { [weak self] in
            guard let self, started else { return }
            if !handledForegroundFromExpiredBackground {
                moneroCore.resume()
            }
        }
    }

    deinit {
        _stop()
    }

    // Methods interacting with wallet cache in storage

    public var lastBlockInfo: UInt64 {
        var walletHeight = moneroCore.blockHeights?.0
        if walletHeight == nil {
            walletHeight = storage.getBlockHeights().map { UInt64($0.walletHeight) }
        }

        return walletHeight ?? 0
    }

    public var walletState: WalletState {
        moneroCore.state
    }

    public func balanceInfo(account: Int) -> BalanceInfo {
        let balanceRecord = storage.getBalance(account: account)
        return balanceRecord.map { BalanceInfo(balance: $0) } ?? .init(all: 0, unlocked: 0)
    }
    
    public func getSubaddresses(forAccount accountIndex: UInt32) -> [(String, Int, Int)] {
        return storage.getAllAddresses(account: Int(accountIndex)).map{($0.address, $0.index, $0.transactionsCount)}
    }

    public func subaddressLabel(accountIndex: UInt32, addressIndex: UInt32) -> String? {
        moneroCore.subaddressLabel(accountIndex: accountIndex, addressIndex: addressIndex)
    }

    public func setSubaddressLabel(accountIndex: UInt32, addressIndex: UInt32, label: String) {
        moneroCore.setSubaddressLabel(accountIndex: accountIndex, addressIndex: addressIndex, label: label)
    }

    public func receiveAddress(account: Int) -> String {
        storage.getLastUnusedAddress(account: account)?.address ?? ""
    }

    public func usedAddresses(account: Int) -> [SubAddress] {
        storage.getAllAddresses(account: account)
    }
    
    public var statusInfo: [(String, Any)] {
        var status = [(String, Any)]()

        let (walletHeight, daemonHeight) = moneroCore.blockHeights.map { ("\($0)", "\($1)") } ?? ("n/a", "n/a")
        let lastSyncedWalletHeight = storage.getBlockHeights().map { "\($0.walletHeight)" } ?? "n/a"
        status.append(("Wallet Status", walletState.description))
        status.append(("Last Block Height", "\(lastBlockInfo)"))
        status.append(("Last Synced Wallet Height", lastSyncedWalletHeight))
        status.append(("Wallet Height", walletHeight))
        status.append(("Daemon Height", daemonHeight))
        status.append(("Kit started", started ? "yes" : "no"))
        status.append(("Node", moneroCore.node.description))
        status.append(("Available Nodes", "\(nodePool.nodes.count)"))

        return status
    }

    public var activeNodeDescription: String {
        moneroCore.node.url.absoluteString
    }

    public func transactions(fromHash: String? = nil, descending: Bool, type: TransactionFilterType?, limit: Int?) -> [TransactionInfo] {
        var resolvedTimestamp: Int?

        if let fromHash, let transaction = storage.transaction(byHash: fromHash) {
            resolvedTimestamp = transaction.timestamp
        }

        return storage
            .transactions(fromTimestamp: resolvedTimestamp, descending: descending, type: type, limit: limit)
            .map { TransactionInfo(transaction: $0, privateTxData: storage.getPrivateTxData(byHash: $0.hash)) }
    }

    // Methods interacting with moneroCore

    private func _start() {
        guard !started else { return }
        started = true

        // EXPERIMENTAL: The KitManager waiting loop has been removed.
        // Previously, this method polled KitManager every 1 second until the previously
        // running Kit finished stopping, serializing all wallet start/stop operations.
        // This is unnecessary because the Monero C++ library supports concurrent wallet
        // instances — each Wallet* has independent state, its own refresh thread, and its
        // own per-instance LOCK_REFRESH() mutex. The old kit continues closing on its own
        // lifecycleQueue while this kit starts immediately, eliminating the switch delay.
        //
        // Old code:
        // var kitState = KitManager.shared.checkAndGetInitialState(kitId: kitId)
        // while kitState == .waiting {
        //     moneroCore.setConnectingState(waiting: true)
        //     Thread.sleep(forTimeInterval: 1.0)
        //     kitState = KitManager.shared.checkAndGetState(kitId: kitId)
        // }
        // if kitState == .running {
        //     moneroCore.setConnectingState(waiting: false)
        //     ... start ...
        // }
        moneroCore.setConnectingState(waiting: false)
        do {
            try moneroCore.start()
        } catch {
            if let coreError = error as? MoneroCoreError, case .restoreHeightDontMatch = coreError {
                do {
                    try FileHandler.remove(for: walletDirectoryName)
                    _ = try FileHandler.directoryURL(for: walletDirectoryName).appendingPathComponent("wallet").path
                    storage.clearStorage()
                    try moneroCore.start()
                    let balanceRecords = storage.getAllBalances()
                    let balanceInfos = balanceRecords.map { BalanceInfo(balance: $0) }
                    delegate?.balancesDidChange(balanceInfos: balanceInfos)
                } catch {
                    os_log(.error, log: Kit.log, "Failed to restart MoneroCore: %{public}@", "\(error)")
                }
            }
        }
    }

    private func _stop() {
        guard started else { return }
        started = false

        moneroCore.stop()
        // EXPERIMENTAL: KitManager.shared.removeRunning removed — no longer serializing kits.
        // Old code: KitManager.shared.removeRunning(kitId: kitId)
    }

    private func _restart() {
        if case .idle = moneroCore.state { return }

        _stop()

        // EXPERIMENTAL: Previously guarded by KitManager.shared.waitingKitExists() to skip
        // restart when another kit was queued to take over. No longer needed.
        // Old code: if !KitManager.shared.waitingKitExists() { _start() }
        _start()
    }

    public func start() {
        moneroCore.setConnectingState(waiting: false)
        lifecycleQueue.async { [weak self] in self?._start() }
        nodePool.probeAllNodes()
        nodePool.startProbing()
    }

    /// Delivers cached storage data to the delegate immediately, before the network sync begins.
    /// Call this right after setting the delegate so the UI can show existing data without waiting
    /// for a node connection.
    public func preloadCachedData() {
        let txs = transactions(fromHash: nil, descending: true, type: nil, limit: nil)
        if !txs.isEmpty {
            delegate?.transactionsUpdated(inserted: [], updated: txs)
        }

        let balanceInfos = storage.getAllBalances().map { BalanceInfo(balance: $0) }
        if !balanceInfos.isEmpty {
            delegate?.balancesDidChange(balanceInfos: balanceInfos)
        }
    }

    public func stop() {
        nodePool.stopProbing()
        lifecycleQueue.async { [weak self] in self?._stop() }
    }

    private func attemptNodeRotation() {
        guard reachabilityManager.isReachable else { return }

        let now = Date()
        if let last = lastRotationAttempt, now.timeIntervalSince(last) < 15 {
            return
        }
        lastRotationAttempt = now

        guard nodePool.nodes.count > 1 else { return }

        let newNode = nodePool.rotateToNextBest()
        guard newNode != moneroCore.node else { return }

        lifecycleQueue.async { [weak self] in
            guard let self, self.started else { return }
            do {
                try self.moneroCore.switchNode(newNode)
                self.notSyncedSince = nil
                self.delegate?.activeNodeDidChange(node: newNode)
            } catch {
                // switchNode failed for the new node too — will retry next cycle
            }
        }
    }

    public func refresh() {
        lifecycleQueue.async { [weak self] in
            // EXPERIMENTAL: Replaced KitManager.shared.isRunning(kitId:) with just `started`.
            // The isRunning check was only meaningful under the old serialization model.
            // Old code: guard let self, started, KitManager.shared.isRunning(kitId: self.kitId) else { return }
            guard let self, started else { return }
            switch moneroCore.state {
            case .connecting, .syncing, .synced: self.moneroCore.refresh()
            case .notSynced: restart()
            case .idle: ()
            }
        }
    }

    public func restart() {
        lifecycleQueue.async { [weak self] in self?._restart() }
    }

    public func send(to address: String, amount: SendAmount, account: UInt32, priority: SendPriority = .default, memo: String?) throws {

        let result = try moneroCore.send(to: address, amount: amount, account: account, priority: priority, memo: memo)

        for (index, txHash) in result.txHashes.enumerated() {
            if index < result.txKeys.count {
                let privateTxData = PrivateTxData(txHash: txHash, txKey: result.txKeys[index], recipientAddress: result.recipientAddress)
                storage.savePrivateTxData(privateTxData)
            }
        }

        moneroCore.refresh()
    }

    public func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        try moneroCore.estimateFee(address: address, amount: amount, priority: priority)
    }
    
    public var currentWalletPolyseed: String? {
        let polyseed = moneroCore.currentWalletPolyseed
        return polyseed
    }
    
    public var currentWalletSeed: String? {
        let seed = moneroCore.currentWalletSeed
        return seed
    }
    
    public static var newPolyseed: String? {
        MoneroCore.newPolyseed
    }

    public static func newPolyseed(language: String) -> String? {
        MoneroCore.newPolyseed(language: language)
    }

    public static func newLegacySeed(language: String) -> String? {
        MoneroCore.newLegacySeed(language: language)
    }
    
    public static func validatePolyseed(_ phrase: String) -> PolyseedValidationResult {
        PolyseedValidator.validate(phrase)
    }
    
    public static func validateLegacySeed(_ phrase: String) -> LegacySeedValidationResult {
        LegacySeedValidator.validate(phrase)
    }
    
    public var primaryAddress: String? {
        return moneroCore.primaryAddress
    }
    
    public var secretViewKey: String? {
        return moneroCore.secretViewKey
    }
    
    public var publicViewKey: String? {
        return moneroCore.publicViewKey
    }
    
    public var secretSpendKey: String? {
        return moneroCore.secretSpendKey
    }
    
    public var publicSpendKey: String? {
        return moneroCore.publicSpendKey
    }
    public var walletPath: String? {
        return moneroCore.walletPath
    }

    public var walletRestoreHeight: UInt64 {
        return moneroCore.walletRestoreHeight
    }
    
    public func accountLabel(for accountIndex: UInt32) -> String? {
        let label = moneroCore.accountLabel(for: accountIndex)
        return label
        
    }

    public func setAccountLabel(accountIndex: UInt32, label: String) {
        moneroCore.setAccountLabel(accountIndex: accountIndex, label: label)
    }
    
    public func addNewAccount(label: String) {
        moneroCore.addNewAccount(label: label)
    }
    
    public func numberOfAccounts() -> Int {
        return moneroCore.numberOfAccounts()
    }
    
    public func switchToNode(_ node: Node) {
        lifecycleQueue.async { [weak self] in
            guard let self, self.started else { return }
            do {
                try self.moneroCore.switchNode(node)
                self.notSyncedSince = nil
                self.delegate?.activeNodeDidChange(node: node)
            } catch {
                // Failed to switch
            }
        }
    }

    @discardableResult
    public func addNewSubaddress(accountIndex: UInt32, label: String) -> String? {
        moneroCore.addNewSubaddress(label: label, accountIndex: accountIndex)
        let subaddresses = moneroCore.getSubaddresses(accountIndex: accountIndex)
        return subaddresses.last?.address
    }
}

extension Kit: MoneroCoreDelegate {
    
    func balancesDidChange(balances: [MoneroCore.Balance]) {
        var balanceInfos: [BalanceInfo] = []
        var balancesStorage: [Balance] = []
        
        for (account, balance) in balances.enumerated() {
            let balanceRecord = Balance(all: balance.all, unlocked: balance.unlocked, account: account, label: balance.label)
            balancesStorage.append(balanceRecord)
            balanceInfos.append(BalanceInfo(balance: balanceRecord))
        }
        
        storage.update(balances: balancesStorage)
        delegate?.balancesDidChange(balanceInfos: balanceInfos)
        
    }
    
    func subAddresssesDidChange(subAddresses: [[MoneroCore.SubAddress]]) {
        
        var allAddresses: [SubAddress] = []
        for (account, addresses) in subAddresses.enumerated() {
            let subAddresses = addresses.map { SubAddress(address: $0.address, index: $0.index, account: account) }
            allAddresses.append(contentsOf: subAddresses)
        }
        
        storage.update(subAddresses: allAddresses)
        delegate?.subAddressesUpdated(subaddresses: allAddresses)
    }
    
    func walletStateDidChange(state: WalletState) {
        delegate?.walletStateDidChange(state: state)

        if let (walletHeight, daemonHeight) = moneroCore.blockHeights {
            storage.update(blockHeights: BlockHeights(daemonHeight: Int(daemonHeight), walletHeight: Int(walletHeight)))
        }

        switch state {
        case .synced:
            notSyncedSince = nil
            nodePool.markSuccess(node: moneroCore.node, responseTime: 0.5, height: moneroCore.blockHeights?.1 ?? 0)
            ensureFreshSubaddressIfNeeded()
        case .notSynced:
            guard reachabilityManager.isReachable else {
                notSyncedSince = nil
                break
            }
            if notSyncedSince == nil {
                notSyncedSince = Date()
            } else if let since = notSyncedSince, Date().timeIntervalSince(since) > 30 {
                nodePool.markFailed(node: moneroCore.node)
                attemptNodeRotation()
            }
        case .connecting:
            guard reachabilityManager.isReachable else {
                notSyncedSince = nil
                break
            }
            if notSyncedSince == nil {
                notSyncedSince = Date()
            } else if let since = notSyncedSince, Date().timeIntervalSince(since) > 45 {
                nodePool.markFailed(node: moneroCore.node)
                attemptNodeRotation()
            }
        case .syncing:
            notSyncedSince = nil
        case .idle(let daemonReachable):
            if daemonReachable {
                nodePool.resetAllFailures()
            }
            notSyncedSince = nil
        }
    }

    func transactionsDidChange(transactions: [MoneroCore.Transaction]) {
        let transactionRecords = transactions.compactMap { transaction in
            let type = transaction.direction == .in ? TransactionType.incoming : .outgoing
            var recipientAddress: String? = nil

            if type == .incoming,
               let subAddressIndex = transaction.subaddrIndices.first,
               let address = storage.getAddress(index: subAddressIndex, account: Int(transaction.subaddrAccount))
            {
                recipientAddress = address.address
            }

            return Transaction(
                hash: transaction.hash,
                type: type,
                account: Int(transaction.subaddrAccount),
                blockHeight: transaction.blockHeight,
                amount: transaction.amount,
                fee: transaction.fee,
                isPending: transaction.isPending,
                isFailed: transaction.isFailed,
                timestamp: Int(transaction.timestamp.timeIntervalSince1970),
                note: transaction.note,
                recipientAddress: recipientAddress
            )
        }

        storage.update(transactions: transactionRecords)

        let transactionInfos = transactionRecords.map { TransactionInfo(transaction: $0, privateTxData: storage.getPrivateTxData(byHash: $0.hash)) }
        delegate?.transactionsUpdated(inserted: [], updated: transactionInfos)

        // Mark used addresses
        var usedAddresses: [Int: [Int: Int]] = [:]
        for transaction in transactions {
            guard transaction.direction == .in else { continue }

            let account = transaction.subaddrAccount
            for index in transaction.subaddrIndices {
                usedAddresses[Int(account), default: [:]][index, default: 0] += 1
            }
        }

        for (account, indices) in usedAddresses {
            for (index, txCount) in indices {
                storage.setAddressTransactionsCount(index: index, account: account, txCount: txCount)
            }
        }

        if hasBeenSyncedBefore {
            ensureFreshSubaddressIfNeeded()
        }

    }

    private var hasBeenSyncedBefore: Bool {
        !storage.transactions(fromTimestamp: nil, descending: false, type: nil, limit: 1).isEmpty
    }

    private func ensureFreshSubaddressIfNeeded() {
        let accountCount = moneroCore.numberOfAccounts()
        for account in 0..<accountCount {
            guard storage.getLastUnusedAddress(account: account) == nil else { continue }
            moneroCore.addNewSubaddress(label: "", accountIndex: UInt32(account))
        }
    }
}

public extension Kit {
    static func removeAll(except excludedFiles: [String]) throws {
        try FileHandler.removeAll(except: excludedFiles)
    }

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MoneroCore.isValid(address: address, networkType: networkType)
    }

    static func isValid(viewKey: String, address: String, isViewKey: Bool, networkType: NetworkType) -> Bool {
        MoneroCore.isValid(viewKey: viewKey, address: address, isViewKey: isViewKey, networkType: networkType)
    }

    static func keyValidationError(key: String, address: String, isViewKey: Bool, networkType: NetworkType) -> String? {
        MoneroCore.keyValidationError(key: key, address: address, isViewKey: isViewKey, networkType: networkType)
    }

    static func key(wallet: MoneroWallet, privateKey: Bool, spendKey: Bool) throws -> String? {
        try MoneroCore.key(wallet: wallet, privateKey: privateKey, spendKey: spendKey)
    }
    
    static func address(wallet: MoneroWallet, account: UInt32, index: UInt32) throws -> String? {
        try MoneroCore.address(wallet: wallet, account: account, index: index, networkType: .mainnet)
    }
    
    static func removeWallet(path: String) {
        let fileManager = FileManager.default
        let filesToDelete = [
            path,           // main wallet file
            path + ".keys", // keys file
            path + ".address.txt" // optional address cache
        ]
        for file in filesToDelete {
            try? fileManager.removeItem(atPath: file)
        }
    }
}

public enum CapsizedMoneroKitError: Error {
    case invalidWalletId
    case invalidSeed
}

public protocol CapsizedMoneroKitDelegate: AnyObject {
    func balancesDidChange(balanceInfos: [BalanceInfo])
    func subAddressesUpdated(subaddresses: [SubAddress])
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func walletStateDidChange(state: WalletState)
    func activeNodeDidChange(node: Node)
}
