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

    public let nodeRotationMode: NodeRotationMode

    // MARK: - `.adaptive` rotation state (unused, untouched under `.legacy`)

    private var nodeWatchdog: NodeWatchdog?
    private var rotationInFlight = false
    private var nextRotationAllowedAt: Date = .distantPast
    private var nextRotationBackoff: TimeInterval = 20
    private var consecutiveStallRotations = 0
    private var slowRotationIneffectiveCount = 0
    private var throughputDetectorArmed = true
    private var lastHealthSample: ActiveNodeSample?

    public let nodePool: NodePool
    public weak var delegate: CapsizedMoneroKitDelegate?

    /// When false, automatic rotation off the current node on repeated sync failures is
    /// disabled — used to honor a user's manually pinned node. Gates `attemptNodeRotation()`
    /// under `.legacy` and the watchdog-driven rotation cycle under `.adaptive`.
    public var isAutoNodeSelectionEnabled: Bool = true

    @available(*, deprecated, message: "Use init(..., nodeRotationMode:) to opt into adaptive node health monitoring and rotation, introduced in 1.1.0. This initializer keeps the 1.0.0 behavior unchanged and will be removed in a future major version.")
    public convenience init(wallet: MoneroWallet, restoreHeight: UInt64 = 0, walletId: String, walletPassword: String? = nil, nodes: [Node], networkType: NetworkType = .mainnet, isNewWallet: Bool = false, reachabilityManager: ReachabilityManager, logger: HsToolKit.Logger?, moneroCoreLogLevel: Int32? = nil) throws {
        try self.init(wallet: wallet, restoreHeight: restoreHeight, walletId: walletId, walletPassword: walletPassword, nodes: nodes, networkType: networkType, isNewWallet: isNewWallet, reachabilityManager: reachabilityManager, logger: logger, moneroCoreLogLevel: moneroCoreLogLevel, nodeRotationMode: .legacy)
    }

    public init(wallet: MoneroWallet, restoreHeight: UInt64 = 0, walletId: String, walletPassword: String? = nil, nodes: [Node], networkType: NetworkType = .mainnet, isNewWallet: Bool = false, reachabilityManager: ReachabilityManager, logger: HsToolKit.Logger?, moneroCoreLogLevel: Int32? = nil, nodeRotationMode: NodeRotationMode, preferredNodeURL: URL? = nil) throws {
        precondition(!nodes.isEmpty, "At least one node is required")

        self.reachabilityManager = reachabilityManager
        self.nodeRotationMode = nodeRotationMode
        nodePool = NodePool(nodes: nodes, mode: nodeRotationMode, preferredActive: preferredNodeURL)
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

        if nodeRotationMode == .adaptive {
            nodeWatchdog = NodeWatchdog()
            moneroCore.onHealthSample = { [weak self] sample in
                self?.lifecycleQueue.async { self?.processHealthSample(sample) }
            }
        }
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
            if nodeRotationMode == .adaptive {
                nodePool.stopAdaptiveProbing()
            }
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
            if nodeRotationMode == .adaptive {
                nodePool.startAdaptiveProbing(isSynced: { [weak self] in
                    guard case .synced = self?.moneroCore.state else { return false }
                    return true
                })
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

        switch nodeRotationMode {
        case .legacy:
            nodePool.startProbing()
        case .adaptive:
            nodePool.startAdaptiveProbing(isSynced: { [weak self] in
                guard case .synced = self?.moneroCore.state else { return false }
                return true
            })
        }
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
        switch nodeRotationMode {
        case .legacy:
            nodePool.stopProbing()
        case .adaptive:
            nodePool.stopAdaptiveProbing()
        }
        lifecycleQueue.async { [weak self] in self?._stop() }
    }

    private func attemptNodeRotation() {
        guard isAutoNodeSelectionEnabled else { return }
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

    // MARK: - `.adaptive` rotation cycle (new in 1.1.0, unused under `.legacy`)

    /// Runs on `lifecycleQueue` — one poll tick's worth of health data, evaluated against the
    /// watchdog. A verdict kicks off `performAdaptiveRotation(reason:)` on its own `Task`;
    /// `rotationInFlight` (checked inside that method) keeps overlapping ticks from starting a
    /// second cycle while one is already in progress.
    private func processHealthSample(_ sample: ActiveNodeSample) {
        guard nodeRotationMode == .adaptive, let nodeWatchdog else { return }
        lastHealthSample = sample

        let activeNode = nodePool.activeNode
        let bestCandidate = nodePool.adaptiveBestCandidates(excluding: activeNode).first
        let snapshot = PoolSnapshot(
            maxSeenHeight: nodePool.currentMaxSeenHeight,
            activeLatencyEWMA: nodePool.nodeMetrics(for: activeNode)?.latencyEWMA,
            bestCandidateLatencyEWMA: bestCandidate.flatMap { nodePool.nodeMetrics(for: $0)?.latencyEWMA },
            hasMateriallyBetterCandidate: nodePool.hasCandidateMateriallyBetterThanActive(),
            isThroughputDetectorArmed: throughputDetectorArmed
        )

        guard let verdict = nodeWatchdog.evaluate(sample: sample, snapshot: snapshot) else { return }
        let reason: NodeVerdictReason
        switch verdict {
        case let .hard(r): reason = r
        case let .slow(r): reason = r
        }

        Task { [weak self] in
            await self?.performAdaptiveRotation(reason: reason)
        }
    }

    /// Verify-before-commit rotation cycle (§5): quarantines the current node, ranks
    /// candidates, probes the top few fresh before committing to any of them, and backs off
    /// rather than retrying every cycle when nothing works. Not a public method, not a variant
    /// of `rotateToNextBest()` — an independent cycle that only runs under `.adaptive`.
    private func performAdaptiveRotation(reason: NodeVerdictReason) async {
        guard isAutoNodeSelectionEnabled, reachabilityManager.isReachable, !rotationInFlight else { return }
        if reason == .hardStall, consecutiveStallRotations >= 3 { return }

        let now = Date()
        guard now >= nextRotationAllowedAt else { return }
        guard nodePool.nodes.count > 1 else { return }

        rotationInFlight = true
        defer { rotationInFlight = false }

        let current = moneroCore.node
        nodePool.quarantine(current)

        let candidates = nodePool.adaptiveBestCandidates(excluding: current)
        guard !candidates.isEmpty else {
            applyRotationBackoff()
            return
        }

        let ranked = await nodePool.refreshAndRank(Array(candidates.prefix(3)))

        for candidate in ranked {
            guard started else { return }
            do {
                try await switchNodeAwaitingHandshake(candidate)
                commitAdaptiveRotation(to: candidate, reason: reason)
                return
            } catch {
                nodePool.quarantine(candidate)
                continue
            }
        }

        applyRotationBackoff()
    }

    /// `moneroCore.switchNode` only confirms the daemon accepted the connection parameters, not
    /// that it is actually responsive — so this polls `blockHeights` for up to 12s afterward,
    /// mirroring the "verify before commit" intent of §5's pseudocode.
    private func switchNodeAwaitingHandshake(_ node: Node) async throws {
        try moneroCore.switchNode(node)

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if (moneroCore.blockHeights?.1 ?? 0) > 0 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw MoneroCoreError.daemonInitFailed("handshake timed out")
    }

    private func commitAdaptiveRotation(to node: Node, reason: NodeVerdictReason) {
        notSyncedSince = nil
        nodePool.setActive(node)
        nodeWatchdog?.armPostSwitchGrace()
        nextRotationAllowedAt = Date().addingTimeInterval(20)
        nextRotationBackoff = 20
        delegate?.activeNodeDidChange(node: node)

        os_log(.info, log: Kit.log, "Adaptive rotation: switched to %{public}@ (reason: %{public}@)",
               node.url.absoluteString, reason.rawValue)

        switch reason {
        case .hardStall:
            consecutiveStallRotations += 1
        case .slowThroughput:
            scheduleSlowThroughputEffectivenessCheck()
        default:
            break
        }
    }

    /// All rotation attempts on this cycle failed to produce a working node — back off instead
    /// of retrying every tick, doubling up to a 5-minute cap.
    private func applyRotationBackoff() {
        nextRotationAllowedAt = Date().addingTimeInterval(nextRotationBackoff)
        nextRotationBackoff = min(nextRotationBackoff * 2, 300)
    }

    /// §4.4.3's self-correction: re-measure throughput 90s after a slowness-triggered rotation;
    /// if it didn't meaningfully improve, count it as ineffective. After 2 ineffective attempts,
    /// disarm the throughput detector for the rest of the session rather than keep oscillating
    /// between nodes that are all equally fine.
    private func scheduleSlowThroughputEffectivenessCheck() {
        let baselineBps = lastHealthSample?.blocksPerSecond ?? 0
        lifecycleQueue.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self else { return }
            let newBps = self.lastHealthSample?.blocksPerSecond ?? 0
            let improved = baselineBps > 0 ? (newBps >= baselineBps * 1.3) : newBps > 0
            guard !improved else { return }

            self.slowRotationIneffectiveCount += 1
            if self.slowRotationIneffectiveCount >= 2 {
                self.throughputDetectorArmed = false
                os_log(.info, log: Kit.log, "Adaptive rotation: disarming throughput detector for the session after %d ineffective rotations", self.slowRotationIneffectiveCount)
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
    
    public func switchToNode(_ node: Node, completion: ((Result<Void, Error>) -> Void)? = nil) {
        // QoS override only for this block — a user-initiated tap shouldn't inherit the
        // queue's .background baseline used by backgrounding/pause/resume housekeeping.
        lifecycleQueue.async(qos: .userInitiated) { [weak self] in
            guard let self, self.started else {
                DispatchQueue.main.async { completion?(.failure(MoneroCoreError.walletNotInitialized)) }
                return
            }
            do {
                try self.moneroCore.switchNode(node)
                self.notSyncedSince = nil
                self.nodePool.setActive(node)
                self.delegate?.activeNodeDidChange(node: node)
                DispatchQueue.main.async { completion?(.success(())) }
            } catch {
                DispatchQueue.main.async { completion?(.failure(error)) }
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

        switch nodeRotationMode {
        case .legacy:
            // Untouched — 1.0.0 behavior, exactly as it was.
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

        case .adaptive:
            // Rotation itself is driven by the watchdog via `onHealthSample`/
            // `processHealthSample`, not by this state-change callback — so `.notSynced`,
            // `.connecting`, and `.syncing` are no-ops here. Only `.synced` and `.idle` need
            // mode-specific handling (real latency instead of a fabricated sample; decay
            // instead of a full reset).
            switch state {
            case .synced:
                if let height = moneroCore.blockHeights?.1 {
                    nodePool.recordSyncedHeight(node: moneroCore.node, height: height)
                }
                nodeWatchdog?.clearAllDetectorState()
                consecutiveStallRotations = 0
                slowRotationIneffectiveCount = 0
                throughputDetectorArmed = true
                ensureFreshSubaddressIfNeeded()
            case .notSynced, .connecting, .syncing:
                break
            case .idle(let daemonReachable):
                if daemonReachable {
                    nodePool.decayFailures()
                } else {
                    nodeWatchdog?.clearAllDetectorState()
                }
            }
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
