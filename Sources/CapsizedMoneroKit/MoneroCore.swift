// SPDX-License-Identifier: MIT
import CMonero
import Combine
import Foundation
import HsToolKit

class MoneroCore {
    weak var delegate: MoneroCoreDelegate?

    private let globalEventQueue = DispatchQueue.global(qos: .background)
    private let walletQueue = DispatchQueue(label: "io.capsized.monero_kit.wallet_queue", qos: .background)

    private var wallet: MoneroWallet
    private var stateManager: SyncStateManager
    private var walletListener: WalletListener
    private var networkType: NetworkType = .mainnet
    private var walletManagerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPath: UnsafeMutablePointer<CChar>?
    private var swiftWalletPath: String?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private let logger: Logger?
    private let moneroCoreLogLevel: Int32? // 0..4
    private var restoreHeight: UInt64 = 0
    var walletRestoreHeight: UInt64 {
        guard let walletPointer else { return 0 }
        return MONERO_Wallet_getRefreshFromBlockHeight(walletPointer)
    }
    private var daemonInitialized = false
    private var isNewWallet: Bool
    var node: Node

    private var transactions: [Transaction] = [] {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self else { return }
                delegate?.transactionsDidChange(transactions: transactions)
            }
        }
    }

    private var subAddresses: [[SubAddress]] = [] {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self else { return }
                delegate?.subAddresssesDidChange(subAddresses: subAddresses)
            }
        }
    }

    private var balances: [Balance] = [] {
        didSet {
            guard oldValue != balances else { return }

            globalEventQueue.async { [weak self] in
                guard let self else { return }
                delegate?.balancesDidChange(balances: balances)
            }
        }
    }

    var state: WalletState {
        stateManager.state
    }

    var blockHeights: (UInt64, UInt64)? {
        stateManager.blockHeights
    }

    init(wallet: MoneroWallet, walletPath: String, walletPassword: String, node: Node, restoreHeight: UInt64, networkType: NetworkType, isNewWallet: Bool = false, reachabilityManager: ReachabilityManager, logger: Logger?, moneroCoreLogLevel: Int32?) {
        self.wallet = wallet
        self.isNewWallet = isNewWallet
        swiftWalletPath = walletPath
        cWalletPath = strdup((walletPath as NSString).utf8String)
        cWalletPassword = strdup((walletPassword as NSString).utf8String)
        self.node = node
        self.restoreHeight = restoreHeight
        self.networkType = networkType
        self.logger = logger
        self.moneroCoreLogLevel = moneroCoreLogLevel
        stateManager = SyncStateManager(logger: logger, restoreHeight: restoreHeight, reachabilityManager: reachabilityManager)
        walletListener = WalletListener()
        walletManagerPointer = MONERO_WalletManagerFactory_getWalletManager()

        stateManager.onSyncStateChanged = { [weak self] in
            self?.onSyncStateChanged()
        }

        walletListener.onNewTransaction = { [weak self] in
            self?.startStateManager()
        }
    }

    deinit {
        wallet.clear()

        // Zero wallet password before freeing to reduce the window where it can
        // be recovered from a heap dump after deallocation.
        if let ptr = cWalletPassword {
            let len = strlen(ptr)
            _ = memset(ptr, 0, len)
            free(ptr)
        }
        if let ptr = cWalletPath { free(ptr) }
    }

    private func startStateManager() {
        guard let walletPointer, let cWalletPassword else { return }

        stateManager.start(walletPointer: walletPointer, cWalletPassword: cWalletPassword)
    }

    func ensureWalletCreated() throws {
        guard walletPointer == nil else { return }

        if let moneroCoreLogLevel {
            MONERO_WalletManagerFactory_setLogLevel(moneroCoreLogLevel)
        }

        guard let walletManagerPointer, let cWalletPath else { return }

        let walletExists = MONERO_WalletManager_walletExists(walletManagerPointer, cWalletPath)

        if !walletExists && !isNewWallet {
            throw MoneroCoreError.walletFilesMissing
        }

        var recoveredWalletPtr: UnsafeMutableRawPointer?

        if walletExists {
            recoveredWalletPtr = MONERO_WalletManager_openWallet(walletManagerPointer, cWalletPath, cWalletPassword, networkType.rawValue)
        } else {
            switch wallet {
            case let .bip39(mnemonic, passphrase):
                let legacySeed = try legacySeedFromBip39(mnemonic: mnemonic, passphrase: passphrase)

                recoveredWalletPtr = MONERO_WalletManager_recoveryWallet(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    (legacySeed as NSString).utf8String,
                    networkType.rawValue,
                    restoreHeight,
                    1,
                    ""
                )

            case let .legacy(mnemonic, passphrase):
                // NFKC (precomposed): normalises compatibility chars (e.g. full-width Japanese)
                // while keeping accented characters composed (á, ñ, é …) as the C word list expects.
                // NFKD would decompose á → a + combining-acute, breaking Spanish/French/etc. seeds.
                let seed = mnemonic.joined(separator: " ").precomposedStringWithCompatibilityMapping

                recoveredWalletPtr = MONERO_WalletManager_recoveryWallet(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    (seed as NSString).utf8String,
                    networkType.rawValue,
                    restoreHeight,
                    1,
                    passphrase
                )

            case let .polyseed(mnemonic, passphrase):
                if mnemonic.isEmpty {
                    recoveredWalletPtr = MONERO_WalletManager_createWallet(
                        walletManagerPointer,
                        cWalletPath,
                        cWalletPassword,
                        "English",
                        networkType.rawValue
                    )
                }
                else {
                    let seed = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping

                    recoveredWalletPtr = MONERO_WalletManager_createWalletFromPolyseed(
                        walletManagerPointer,
                        cWalletPath,
                        cWalletPassword,
                        networkType.rawValue,
                        (seed as NSString).utf8String,
                        passphrase,
                        false,
                        restoreHeight,
                        1
                    )
                }

            case let .keys(address, viewKey, spendKey):
                recoveredWalletPtr = MONERO_WalletManager_createWalletFromKeys(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    "",
                    networkType.rawValue,
                    restoreHeight,
                    (address as NSString).utf8String,
                    (viewKey as NSString).utf8String,
                    (spendKey as NSString).utf8String,
                    1
                )

            case let .watch(address, viewKey):
                recoveredWalletPtr = MONERO_WalletManager_createWalletFromKeys(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    "",
                    networkType.rawValue,
                    restoreHeight,
                    (address as NSString).utf8String,
                    (viewKey as NSString).utf8String,
                    "",
                    1
                )
            }
        }

        guard let walletPtr = recoveredWalletPtr else {
            let errorCStr = MONERO_WalletManager_errorString(walletManagerPointer)
            let msg = stringFromCString(errorCStr) ?? "Unknown recovery error"
            logger?.error("Error recovering wallet: \(msg)")
            throw MoneroCoreError.walletRecoveryFailed(msg)
        }

        // Wallets restored from keys or watch-only have no seed language set, which causes
        // the C++ library to report status != 0 with "seed_language not set". Set English
        // as a default to prevent that error.
        if case .keys = wallet {
            MONERO_Wallet_setSeedLanguage(walletPtr, "English")
        } else if case .watch = wallet {
            MONERO_Wallet_setSeedLanguage(walletPtr, "English")
        }

        // Polyseed wallets store the seed language as the polyseed library's native name
        // (e.g. "español"), but the Monero electrum word-list system only recognises English
        // names (e.g. "Spanish"). Map native names to their English equivalents so that:
        //   1. wallet2::get_seed() can generate the 25-word legacy electrum seed in that
        //      language — without this mapping, bytes_to_words() fails silently and the
        //      legacy seed tab shows nothing.
        //   2. WalletImpl::init() validates the language without setting a status error
        //      (the openWallet() caller also temporarily overrides to "English" as a
        //      belt-and-suspenders guard for languages that have no electrum equivalent).
        //
        // The Monero binary's getPolyseed() looks up polyseed languages by both their
        // native name (.name) and English name (.name_en), so storing "Spanish" instead
        // of "español" still returns words from the Spanish polyseed word list.
        //
        // Languages that have no electrum equivalent (Korean "한국어", Czech "čeština",
        // Chinese Traditional "中文(繁體)") are intentionally omitted — a legacy seed
        // cannot be generated for those language families regardless.
        let polyseedNativeToElectrum: [String: String] = [
            "español":    "Spanish",
            "français":   "French",
            "italiano":   "Italian",
            "português":  "Portuguese",
            "日本語":     "Japanese",
            "中文(简体)":  "Chinese (Simplified)",
        ]
        let storedLang = stringFromCString(MONERO_Wallet_getSeedLanguage(walletPtr)) ?? ""
        if let electrumLang = polyseedNativeToElectrum[storedLang] {
            electrumLang.withCString { MONERO_Wallet_setSeedLanguage(walletPtr, $0) }
        }

        // For newly created wallets, verify the C++ library reports no error.
        // createWalletFromPolyseed (and other creation APIs) can return a non-null pointer
        // that is in an error state (e.g. bad mnemonic → scalar-1 spend key) without
        // returning nil, so we must check status explicitly.
        if !walletExists {
            let walletStatus = MONERO_Wallet_status(walletPtr)
            if walletStatus != 0 {
                let errorCStr = MONERO_Wallet_errorString(walletPtr)
                let msg = stringFromCString(errorCStr) ?? "Unknown wallet creation error"
                logger?.error("Wallet creation error (status \(walletStatus)): \(msg)")
                throw MoneroCoreError.walletRecoveryFailed(msg)
            }
        }

        // Only override the scan start height for newly created wallets.
        // For existing wallets, the C++ file already knows its restore height —
        // overriding it with today's date (the default passed by callers that
        // don't store the original height) would skip all historical blocks.
        if !walletExists && restoreHeight > 0 {
            MONERO_Wallet_setRefreshFromBlockHeight(walletPtr, restoreHeight)
        }

        // Sync the state manager's restore height with the actual value stored in
        // the C++ wallet file.  For existing wallets the caller passes today's date
        // as a placeholder; this corrects it to the real original restore height so
        // that progress calculations and chunkOfBlocksSynced work correctly.
        stateManager.updateRestoreHeight(MONERO_Wallet_getRefreshFromBlockHeight(walletPtr))

        storeWallet(walletPointer: walletPtr)
        walletPointer = walletPtr
        wallet.clear()
    }

    private func openWallet() throws {
        try ensureWalletCreated()
        isNewWallet = false

        guard let walletPtr = walletPointer else { return }

        let daemonAddress = node.url.absoluteString
        let daemonLogin = node.login ?? ""
        let daemonPassword = node.password ?? ""

        logger?.debug("Initializing wallet with daemon: \(daemonAddress)")

        let cDaemonAddress = strdup((daemonAddress as NSString).utf8String)
        let cDaemonLogin = strdup((daemonLogin as NSString).utf8String)
        let cDaemonPassword = strdup((daemonPassword as NSString).utf8String)

        defer {
            free(cDaemonAddress)
            free(cDaemonLogin)
            free(cDaemonPassword)
        }
        let initSuccess = MONERO_Wallet_init(walletPtr, cDaemonAddress, 0, cDaemonLogin, cDaemonPassword, true, false, "")
        guard initSuccess else {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown daemon init error"
            logger?.error("Error initializing wallet with daemon: \(msg)")
            throw MoneroCoreError.daemonInitFailed(msg)
        }

        MONERO_Wallet_setTrustedDaemon(walletPtr, node.isTrusted)
        daemonInitialized = true
    }

    private func onSyncStateChanged() {
        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.walletStateDidChange(state: state)
        }

        switch state {
        case .connecting, .notSynced: ()

        case .synced:
            refresh()
            stateManager.walletStored()

        case .syncing:
            if stateManager.chunkOfBlocksSynced {
                refresh()
                stateManager.walletStored()
            }

        case let .idle(daemonReachable):
            daemonReachable ? startWalletServices() : stopWalletServices()
        }
    }

    private func storeWallet(walletPointer: UnsafeMutableRawPointer) {
        _ = MONERO_Wallet_store(walletPointer, cWalletPath)
    }

    private func updateBalances(walletPointer: UnsafeMutableRawPointer) {
        
        guard let numAcc = UInt32(exactly: numberOfAccounts()) else { return }
        
        var newBalances: [Balance] = []
        for account in 0..<numAcc {
            let allBalance = MONERO_Wallet_balance(walletPointer, account)
            let unlocked = MONERO_Wallet_unlockedBalance(walletPointer, account)
            let label = accountLabel(for: account) ?? ""
            let newValue = Balance(all: Int64(allBalance), unlocked: Int64(unlocked), label: label)
            newBalances.append(newValue)
        }
        
        balances = newBalances
        
    }

    private func fetchSubaddresses(walletPointer: UnsafeMutableRawPointer) {
        
        guard let numAcc = UInt32(exactly: numberOfAccounts()) else { return }
        
        var fetchedAddresses: [[SubAddress]] = []

        for account in 0..<numAcc {
            var accountAddresses: [SubAddress] = []
            let count = MONERO_Wallet_numSubaddresses(walletPointer, account)

            for i in 0..<count {
                if let address = stringFromCString(MONERO_Wallet_address(walletPointer, UInt64(account), UInt64(i))) {
                    accountAddresses.append(.init(address: address, index: i))
                }
            }

            fetchedAddresses.append(accountAddresses)
        }

        subAddresses = fetchedAddresses
    }

    private func fetchTransactions(walletPointer: UnsafeMutableRawPointer) {
        let historyPtr = MONERO_Wallet_history(walletPointer)
        guard let historyPtr else { return }
        MONERO_TransactionHistory_refresh(historyPtr)

        let count = MONERO_TransactionHistory_count(historyPtr)
        var fetchedTransactions: [Transaction] = []

        for i in 0 ..< count {
            let txInfoPtr = MONERO_TransactionHistory_transaction(historyPtr, i)

            guard let txInfoPtr else { continue }
            
            let directionRaw = MONERO_TransactionInfo_direction(txInfoPtr)
            guard let direction = Transaction.Direction(rawValue: directionRaw) else { continue }
            
            let hash = stringFromCString(MONERO_TransactionInfo_hash(txInfoPtr)) ?? "N/A"

            var subaddrIndices: [Int] = []
            if let subaddrIndicesStr = stringFromCString(MONERO_TransactionInfo_subaddrIndex(txInfoPtr, " ")) {
                subaddrIndices = subaddrIndicesStr.split(separator: " ").compactMap { Int($0) }
            }

            var note: String? = stringFromCString(MONERO_Wallet_getUserNote(walletPointer, hash))
            if let _note = note, _note.isEmpty { note = nil }

            let transaction = Transaction(
                direction: direction,
                isPending: MONERO_TransactionInfo_isPending(txInfoPtr),
                isFailed: MONERO_TransactionInfo_isFailed(txInfoPtr),
                amount: MONERO_TransactionInfo_amount(txInfoPtr),
                fee: MONERO_TransactionInfo_fee(txInfoPtr),
                subaddrIndices: subaddrIndices,
                subaddrAccount: MONERO_TransactionInfo_subaddrAccount(txInfoPtr),
                blockHeight: MONERO_TransactionInfo_blockHeight(txInfoPtr),
                confirmations: MONERO_TransactionInfo_confirmations(txInfoPtr),
                hash: hash,
                timestamp: Date(timeIntervalSince1970: TimeInterval(MONERO_TransactionInfo_timestamp(txInfoPtr))),
                note: note
            )

            fetchedTransactions.append(transaction)

        }

        transactions = fetchedTransactions.sorted(by: { $0.timestamp > $1.timestamp })

        // Biggest number of confirmations amoung unconfirmed (less than 10 blocks) transactions
        var biggestConfirmations: UInt64 = 0
        var hasUnconfirmedTransactions = false

        for transaction in transactions {
            if transaction.confirmations >= Kit.confirmationsThreshold {
                continue
            }

            if transaction.confirmations > biggestConfirmations {
                biggestConfirmations = transaction.confirmations
                hasUnconfirmedTransactions = true
            }
        }

        if hasUnconfirmedTransactions, biggestConfirmations < Kit.confirmationsThreshold {
            let height: UInt64
            if stateManager.walletHeight < biggestConfirmations {
                height = stateManager.walletHeight
            } else {
                height = stateManager.walletHeight - biggestConfirmations
            }
            walletListener.setLockedBalanceHeight(height: height)
        }
    }

    private func startCore() throws {
        guard !daemonInitialized else { return }
        do {
            try openWallet()
        } catch {
            if let coreError = error as? MoneroCoreError, case .restoreHeightDontMatch = coreError {
                throw error
            } else {
                stateManager.state = .notSynced(error: .startError(error.localizedDescription))
            }
        }
    }

    private func stopCore() {
        daemonInitialized = false

        let wp: UnsafeMutableRawPointer? = walletQueue.sync {
            let wp = walletPointer
            walletPointer = nil
            return wp
        }

        guard let wmp = walletManagerPointer, let wp else { return }
        
        // Store wallet before closing. MONERO_Wallet_store routes through
        // WalletImpl::store() which acquires LOCK_REFRESH(), ensuring the
        // C++ refresh thread has stopped before serializing. Calling
        // closeWallet with store=true would bypass this lock and race with
        // the refresh thread, crashing in wallet2::get_cache_file_data().
        _ = MONERO_Wallet_store(wp, cWalletPath)
        MONERO_WalletManager_closeWallet(wmp, wp, false)
    }

    private func startWalletServices() {
        guard let walletPointer else { return }
        stateManager.state = .connecting(waiting: false)
        startStateManager()
        walletListener.start(walletPointer: walletPointer)
    }

    private func stopWalletServices() {
        stateManager.stop()
        walletListener.stop()
    }

    func start() throws {
        guard walletManagerPointer != nil else {
            logger?.error("Error: Could not get WalletManager instance.")
            return
        }

        stateManager.validateReachable()
        try startCore()
        startWalletServices()
    }

    func stop() {
        stopWalletServices()
        stopCore()
    }
    
    func switchNode(_ newNode: Node) throws {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        stopWalletServices()

        // Same guard as openWallet(): for polyseed languages with no electrum equivalent
        // (Korean, Czech, Chinese Traditional), temporarily set "English" so
        // WalletImpl::init() doesn't set a status error, then restore the native name.
        let unmappedPolyseedLanguages: Set<String> = ["한국어", "čeština", "中文(繁體)"]
        let originalLang = stringFromCString(MONERO_Wallet_getSeedLanguage(walletPtr)) ?? "English"
        if unmappedPolyseedLanguages.contains(originalLang) {
            MONERO_Wallet_setSeedLanguage(walletPtr, "English")
        }
        defer {
            if unmappedPolyseedLanguages.contains(originalLang) {
                originalLang.withCString { MONERO_Wallet_setSeedLanguage(walletPtr, $0) }
            }
        }

        let daemonAddress = newNode.url.absoluteString
        let daemonLogin = newNode.login ?? ""
        let daemonPassword = newNode.password ?? ""

        let cDaemonAddress = strdup((daemonAddress as NSString).utf8String)
        let cDaemonLogin = strdup((daemonLogin as NSString).utf8String)
        let cDaemonPassword = strdup((daemonPassword as NSString).utf8String)

        defer {
            free(cDaemonAddress)
            free(cDaemonLogin)
            free(cDaemonPassword)
        }

        let initSuccess = MONERO_Wallet_init(walletPtr, cDaemonAddress, 0, cDaemonLogin, cDaemonPassword, true, false, "")
        guard initSuccess else {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown daemon init error"
            throw MoneroCoreError.daemonInitFailed(msg)
        }

        MONERO_Wallet_setTrustedDaemon(walletPtr, newNode.isTrusted)
        node = newNode

        startWalletServices()
    }

    func pause() {
        stopWalletServices()

        walletQueue.sync { [weak self] in
            guard let self, let walletPtr = walletPointer else { return }
            MONERO_Wallet_pauseRefresh(walletPtr)
            storeWallet(walletPointer: walletPtr)
        }
    }
    
    func resume() {
        guard let walletPtr = walletPointer else { return }
        
        MONERO_Wallet_startRefresh(walletPtr)
        startWalletServices()
    }

    func refresh() {
        
        walletQueue.async { [weak self] in
            guard let self, let walletPtr = walletPointer else { return }
            updateBalances(walletPointer: walletPtr)
            fetchSubaddresses(walletPointer: walletPtr)
            fetchTransactions(walletPointer: walletPtr)
            storeWallet(walletPointer: walletPtr)
        }
        
    }

    func setConnectingState(waiting: Bool) {
        stateManager.state = .connecting(waiting: waiting)
    }
    
    func address(index: Int, account: Int) -> String {
        guard let walletPtr = walletPointer else { return "" }
        return stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(index))) ?? ""
    }
    
    struct SendResult {
        let txHashes: [String]
        let txKeys: [String]
        let recipientAddress: String
    }

    func send(to address: String, amount: SendAmount, account: UInt32, priority: SendPriority = .default, memo: String? = nil) throws -> SendResult {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        let cAddress = (address as NSString).utf8String
        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, cAddress, "", amount.value, 0, Int32(priority.rawValue), account, "", "")

        guard let txPtr = pendingTxPtr else {
            let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "Unknown transaction creation error"
            throw MoneroCoreError.transactionSendFailed(error)
        }

        let status = MONERO_PendingTransaction_status(txPtr)
        guard status == 0 else {
            let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown pending transaction error"
            throw MoneroCoreError.match(error) ?? MoneroCoreError.transactionSendFailed(error)
        }

        guard let txIds = stringFromCString(MONERO_PendingTransaction_txid(txPtr, "|")), !txIds.isEmpty else {
            throw MoneroCoreError.transactionSendFailed("Failed to get transaction ID from pending transaction")
        }
        let txKeys = stringFromCString(MONERO_PendingTransaction_txKey(txPtr, "|")) ?? ""

        guard MONERO_PendingTransaction_commit(txPtr, "", false) else {
            let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown commit error"
            throw MoneroCoreError.transactionCommitFailed(error)
        }
        
        let txIdArray = txIds.split(separator: "|").map { String($0) }
        let txKeyArray = txKeys.split(separator: "|").map { String($0) }
        
        for txId in txIdArray {
            if let memo {
                let cTxId = (txId as NSString).utf8String
                MONERO_Wallet_setUserNote(walletPtr, cTxId, memo)
            }
        }

        startStateManager()
        
        return SendResult(txHashes: txIdArray, txKeys: txKeyArray, recipientAddress: address)
    }

    func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        let cAddress = (address as NSString).utf8String
        let cAmount = ("\(amount.value)" as NSString).utf8String
        let fee = MONERO_Wallet_estimateTransactionFee(walletPtr, cAddress, "", cAmount, "", Int32(priority.rawValue))
        let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? ""
        if !error.isEmpty, error != "No error" {
            throw MoneroCoreError.match(error) ?? MoneroCoreError.transactionEstimationFailed(error)
        }
        return fee
    }
    
    var currentWalletPolyseed: String? {
        guard let walletPointer else {
            return nil
        }
        return secureStringFromCString(MONERO_Wallet_getPolyseed(walletPointer, ""))
    }

    var currentWalletSeed: String? {
        guard let walletPointer else { return nil }
        return secureStringFromCString(MONERO_Wallet_seed(walletPointer, ""))
    }
    
    static var newPolyseed: String? {
        newPolyseed(language: "English")
    }

    static func newPolyseed(language: String) -> String? {
        secureStringFromCString(MONERO_Wallet_createPolyseed(language))
    }

    static func newLegacySeed(language: String) -> String? {
        guard let wm = MONERO_WalletManagerFactory_getWalletManager() else { return nil }

        let tempPath = NSTemporaryDirectory() + "temp_legacy_\(UUID().uuidString)"
        let cPath = strdup((tempPath as NSString).utf8String)
        let cPassword = strdup(("" as NSString).utf8String)
        defer {
            free(cPath)
            free(cPassword)
            let fm = FileManager.default
            try? fm.removeItem(atPath: tempPath)
            try? fm.removeItem(atPath: tempPath + ".keys")
            try? fm.removeItem(atPath: tempPath + ".address.txt")
        }

        guard let walletPtr = MONERO_WalletManager_createWallet(
            wm, cPath, cPassword,
            (language as NSString).utf8String,
            NetworkType.mainnet.rawValue
        ) else { return nil }

        let seed = secureStringFromCString(MONERO_Wallet_seed(walletPtr, cPassword))
        MONERO_WalletManager_closeWallet(wm, walletPtr, false)

        return seed
    }
    
    var primaryAddress: String? {
        guard let walletPointer else { return nil }
        return stringFromCString(MONERO_Wallet_address(walletPointer, 0, 0))
    }

    var secretViewKey: String? {
        guard let walletPointer else { return nil }
        return secureStringFromCString(MONERO_Wallet_secretViewKey(walletPointer))
    }

    var publicViewKey: String? {
        guard let walletPointer else { return nil }
        return stringFromCString(MONERO_Wallet_publicViewKey(walletPointer))
    }

    var secretSpendKey: String? {
        guard let walletPointer else { return nil }
        return secureStringFromCString(MONERO_Wallet_secretSpendKey(walletPointer))
    }

    var publicSpendKey: String? {
        guard let walletPointer else { return nil }
        return stringFromCString(MONERO_Wallet_publicSpendKey(walletPointer))
    }
    var walletPath: String? {
        guard let walletPointer else { return nil }
        return stringFromCString(MONERO_Wallet_path(walletPointer))
    }
    
    func accountLabel(for accountIndex: UInt32) -> String? {
        
        guard let walletPointer else { return nil }
        
        let subAddressPtr = MONERO_Wallet_subaddressAccount(walletPointer)
        MONERO_SubaddressAccount_refresh(subAddressPtr)
        
        // Check bounds AFTER refresh — the refreshed vector may have a different
        // count than numberOfAccounts() reported before the refresh, which would
        // cause an out-of-bounds std::vector subscript crash.
        let actualSize = MONERO_SubaddressAccount_getAll_size(subAddressPtr)
        guard Int32(accountIndex) < Int32(actualSize) else { return nil }
        
        let subAddressRowPtr = MONERO_SubaddressAccount_getAll_byIndex(subAddressPtr, Int32(accountIndex))
        
        return stringFromCString(MONERO_SubaddressAccountRow_getLabel(subAddressRowPtr))
    }
    
    func subaddressLabel(accountIndex: UInt32, addressIndex: UInt32) -> String? {
        guard let walletPointer else { return nil }
        let subaddressPtr = MONERO_Wallet_subaddress(walletPointer)
        MONERO_Subaddress_refresh(subaddressPtr, accountIndex)
        let count = MONERO_Subaddress_getAll_size(subaddressPtr)
        guard Int(addressIndex) < count else { return nil }
        let rowPtr = MONERO_Subaddress_getAll_byIndex(subaddressPtr, Int32(addressIndex))
        return stringFromCString(MONERO_SubaddressRow_getLabel(rowPtr))
    }

    func setAccountLabel(accountIndex: UInt32, label: String) {
        guard let walletPointer else { return }
        let subAddressAccountPtr = MONERO_Wallet_subaddressAccount(walletPointer)
        MONERO_SubaddressAccount_setLabel(subAddressAccountPtr, accountIndex, label)
        MONERO_Wallet_store(walletPointer, "")
    }

    func setSubaddressLabel(accountIndex: UInt32, addressIndex: UInt32, label: String) {
        guard let walletPointer else { return }
        let subaddressPtr = MONERO_Wallet_subaddress(walletPointer)
        MONERO_Subaddress_setLabel(subaddressPtr, accountIndex, addressIndex, label)
        MONERO_Wallet_store(walletPointer, "")
    }

    func addNewSubaddress(label: String, accountIndex: UInt32) {
        guard let walletPointer else { return }
        MONERO_Wallet_addSubaddress(walletPointer, accountIndex, label)
        MONERO_Wallet_store(walletPointer, "")
        
        refresh()
    }
    
    func addNewAccount(label: String) {

        guard let walletPointer else { return }
        
        MONERO_Wallet_addSubaddressAccount(walletPointer, label)
        
        MONERO_Wallet_store(walletPointer, "")
        
        refresh()
    }
    
    func numberOfAccounts() -> Int {
        
        guard let walletPointer else { return 0 }
                
        let count = MONERO_Wallet_numSubaddressAccounts(walletPointer)
        
        return count
    }
    
    func getBalance(accountIndex: UInt32) -> Balance {
        
        guard let walletPointer else { return Balance(all: 0, unlocked: 0, label: "") }
        
        let allBalance = MONERO_Wallet_balance(walletPointer, accountIndex)
        let unlocked = MONERO_Wallet_unlockedBalance(walletPointer, accountIndex)
        let balance = Balance(all: Int64(allBalance), unlocked: Int64(unlocked), label: accountLabel(for: accountIndex) ?? "")
        return balance
        
    }
    
    func getSubaddresses(accountIndex: UInt32) -> [SubAddress] {
        
        guard let walletPointer else { return [] }
        
        var fetchedAddresses: [SubAddress] = []
        let count = MONERO_Wallet_numSubaddresses(walletPointer, accountIndex)

        for i in 0 ..< count {
            if let address = stringFromCString(MONERO_Wallet_address(walletPointer, UInt64(accountIndex), UInt64(i))) {
                fetchedAddresses.append(.init(address: address, index: i))
            }
        }

        return fetchedAddresses
    }

    struct Transaction {
        public enum Direction: Int32 {
            case `in` = 0
            case out = 1
        }

        let direction: Direction
        let isPending: Bool
        let isFailed: Bool
        let amount: Int64
        let fee: UInt64
        let subaddrIndices: [Int]
        let subaddrAccount: UInt32
        let blockHeight: UInt64
        let confirmations: UInt64
        let hash: String
        let timestamp: Date
        let note: String?
    }

    struct SubAddress {
        let address: String
        let index: Int
    }

    struct Balance: Equatable {
        let all: Int64
        let unlocked: Int64
        let label: String

        static func == (lhs: Balance, rhs: Balance) -> Bool {
            lhs.all == rhs.all && lhs.unlocked == rhs.unlocked && lhs.label == rhs.label
        }
    }
}

extension MoneroCore {
    private static func resolveMnemonic(mnemonic: MoneroWallet) throws -> (String, String) {
        let resolvedSeedPhrase: String
        let resolvedPassphrase: String

        switch mnemonic {
        case let .bip39(mnemonic, passphrase):
            resolvedSeedPhrase = try legacySeedFromBip39(mnemonic: mnemonic, passphrase: passphrase)
            resolvedPassphrase = ""

        case let .legacy(mnemonic, passphrase):
            // NFKC keeps accented characters composed, matching the C word list encoding.
            resolvedSeedPhrase = mnemonic.joined(separator: " ").precomposedStringWithCompatibilityMapping
            resolvedPassphrase = passphrase

        case let .polyseed(mnemonic, passphrase):
            resolvedSeedPhrase = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping
            resolvedPassphrase = passphrase

        case .keys:
            resolvedSeedPhrase = ""
            resolvedPassphrase = ""

        case .watch:
            resolvedSeedPhrase = ""
            resolvedPassphrase = ""
        }

        return (resolvedSeedPhrase, resolvedPassphrase)
    }

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MONERO_Wallet_addressValid((address as NSString).utf8String, networkType.rawValue)
    }

    static func isValid(viewKey: String, address: String, isViewKey: Bool, networkType: NetworkType) -> Bool {
        MONERO_Wallet_keyValid((viewKey as NSString).utf8String, (address as NSString).utf8String, isViewKey, networkType.rawValue)
    }

    static func keyValidationError(key: String, address: String, isViewKey: Bool, networkType: NetworkType) -> String? {
        let error = stringFromCString(
            MONERO_Wallet_keyValid_error(
                (key as NSString).utf8String,
                (address as NSString).utf8String,
                isViewKey,
                networkType.rawValue
            )
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        return error?.isEmpty == false ? error : nil
    }

    static func key(wallet: MoneroWallet, privateKey: Bool = false, spendKey: Bool = false) throws -> String? {
        switch wallet {
        case .polyseed:
            // MONERO_Wallet_generateKey only handles legacy 25-word seeds.
            // Polyseed uses a different key derivation; calling the legacy function
            // with polyseed words produces a wrong spend/view key.
            // Callers must use the live wallet's secretSpendKey / secretViewKey instead.
            throw MoneroCoreError.notSupported("Static key derivation is not supported for polyseed wallets. Use the live wallet instance.")

        case .bip39, .legacy:
            let (resolvedSeedPhrase, resolvedPassphrase) = try resolveMnemonic(mnemonic: wallet)

            guard !resolvedSeedPhrase.isEmpty else {
                return nil
            }

            let cSeed = strdup((resolvedSeedPhrase as NSString).utf8String)
            let cPassphrase = strdup((resolvedPassphrase as NSString).utf8String)
            let keyPtr = MONERO_Wallet_generateKey(cSeed, cPassphrase, privateKey, spendKey)

            return stringFromCString(keyPtr)

        case let .keys(_, viewKey, spendKey_):
            if privateKey, !spendKey {
                return viewKey
            } else if privateKey, spendKey {
                return spendKey_
            } else {
                return ""
            }

        case let .watch(_, viewKey):
            if privateKey, !spendKey {
                return viewKey
            } else {
                return ""
            }
        }
    }

    static func address(wallet: MoneroWallet, account: UInt32, index: UInt32, networkType: NetworkType) throws -> String {
        switch wallet {
        case .bip39, .legacy:
            let (resolvedSeedPhrase, resolvedPassphrase) = try resolveMnemonic(mnemonic: wallet)

            let testnet = networkType != .mainnet
            let cAddressString = MONERO_Wallet_generateAddress(resolvedSeedPhrase, resolvedPassphrase, account, index, testnet)

            return stringFromCString(cAddressString) ?? ""

        case .polyseed:
            // MONERO_Wallet_generateAddress only handles legacy 25-word seeds.
            // Polyseed uses a different key derivation (PBKDF2-based); calling the
            // legacy function with polyseed words produces a wrong address.
            // Callers must use the live wallet pointer (moneroCore.address(index:account:)) instead.
            throw MoneroCoreError.notSupported("Static address derivation is not supported for polyseed wallets. Use the live wallet instance.")

        case let .keys(address, _, _):
            if account == 0, index == 0 {
                return address
            } else {
                return ""
            }

        case let .watch(address, _):
            if account == 0, index == 0 {
                return address
            } else {
                return ""
            }
        }
    }
    
    
}

protocol MoneroCoreDelegate: AnyObject {
    func balancesDidChange(balances: [MoneroCore.Balance])
    func transactionsDidChange(transactions: [MoneroCore.Transaction])
    func subAddresssesDidChange(subAddresses: [[MoneroCore.SubAddress]])
    func walletStateDidChange(state: WalletState)
}
