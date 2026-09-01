// SPDX-License-Identifier: MIT
import Foundation


public enum TransactionFilterType {
    case incoming, outgoing

    var types: [TransactionType] {
        switch self {
        case .incoming: return [.incoming]
        case .outgoing: return [.outgoing]
        }
    }
}

public struct TransactionInfo: Identifiable {
    public var id: String { hash }
    public let uid: String
    public let hash: String
    public let type: TransactionType
    public let account: Int
    public let blockHeight: UInt64
    public let amount: Int64
    public let fee: UInt64
    public let isPending: Bool
    public let isFailed: Bool
    public let timestamp: Int
    public let memo: String?
    public let txKey: String?
    public let recipientAddress: String?

    init(transaction: Transaction, privateTxData: PrivateTxData? = nil) {
        uid = transaction.uid
        hash = transaction.hash
        type = transaction.type
        account = transaction.subaddrAccount
        blockHeight = transaction.blockHeight
        amount = transaction.amount
        fee = transaction.fee
        isPending = transaction.isPending
        isFailed = transaction.isFailed
        timestamp = transaction.timestamp
        memo = transaction.note
        txKey = privateTxData?.txKey
        recipientAddress = transaction.recipientAddress ?? privateTxData?.recipientAddress
    }
}

public struct BalanceInfo: Equatable {
    public let all: Int64
    public let unlocked: Int64
    public let label: String

    init(balance: Balance) {
        all = balance.all
        unlocked = balance.unlocked
        label = balance.label
    }

    public init(all: Int64, unlocked: Int64) {
        self.all = all
        self.unlocked = unlocked
        self.label = ""
    }

    public static func == (lhs: BalanceInfo, rhs: BalanceInfo) -> Bool {
        lhs.all == rhs.all && lhs.unlocked == rhs.unlocked && lhs.label == rhs.label
    }
}

public enum SendPriority: Int, CaseIterable {
    case `default`, low, medium, high
}

public enum NetworkType: Int32, CaseIterable {
    case mainnet = 0
    case testnet = 1
}

public enum WalletCoreStatus {
    case unknown, ok, error(Error?), critical(Error?)

    init?(_ status: Int32, error: String?) {
        switch status {
        case 0:
            self = .ok
        case 1:
            self = .error(MoneroCoreError.walletStatusError(error))
        case 2:
            self = .critical(MoneroCoreError.walletStatusError(error))
        default:
            return nil
        }
    }
}

public enum WalletState: Equatable {
    case synced(lastBlockHeight: UInt64)
    case connecting(waiting: Bool)
    case syncing(progress: Int, remainingBlocksCount: Int)
    case notSynced(error: WalletStateError)
    case idle(daemonReachable: Bool)

    public static func == (lhs: WalletState, rhs: WalletState) -> Bool {
        switch (lhs, rhs) {
        case let (.synced(lhsHeight), .synced(rhsHeight)): return lhsHeight == rhsHeight
        case let (.connecting(lhsWaiting), .connecting(rhsWaiting)): return lhsWaiting == rhsWaiting
        case let (.syncing(lhsProgress, lhsRemaining), .syncing(rhsProgress, rhsRemaining)): return lhsProgress == rhsProgress && lhsRemaining == rhsRemaining
        case let (.notSynced(lhsError), .notSynced(rhsError)): return lhsError == rhsError
        case let (.idle(lhsDaemonReachable), .idle(rhsDaemonReachable)): return lhsDaemonReachable == rhsDaemonReachable
        default: return false
        }
    }

    var description: String {
        switch self {
        case .synced: return "Synced"
        case let .connecting(waiting): return waiting ? "Connecting (waiting)" : "Connecting"
        case let .syncing(progress, remainingBlocksCount): return "Syncing (\(progress)%, remaining blocks: \(remainingBlocksCount))"
        case let .notSynced(error: error): return "Not synced (\(error.description))"
        case let .idle(daemonReachable: daemonReachable): return "Idle daemon (\(daemonReachable ? "reachable" : "unreachable"))"
        }
    }
}

public enum WalletStateError: Error, Equatable {
    case notStarted
    case startError(String?)
    case statusError(String?)

    public var description: String {
        switch self {
        case .notStarted: return "Not started"
        case let .startError(message): return "Start error: \(message ?? "No message")"
        case let .statusError(message): return "Status error: \(message ?? "No message")"
        }
    }
}

public enum SendAmount {
    case value(Int)
    case all

    var value: UInt64 {
        switch self {
        case .all: return UInt64(0)
        case let .value(value): return UInt64(value)
        }
    }
}
