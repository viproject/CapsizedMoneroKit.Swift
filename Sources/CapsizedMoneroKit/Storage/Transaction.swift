// SPDX-License-Identifier: MIT
import Foundation
import GRDB


public enum TransactionType: Int, DatabaseValueConvertible, Codable {
    case incoming = 1
    case outgoing = 2
}

class Transaction: Record {
    var uid: String
    var hash: String
    var type: TransactionType
    var blockHeight: UInt64
    var amount: Int64
    var fee: UInt64
    var isPending: Bool
    var isFailed: Bool
    var timestamp: Int
    var note: String?
    var recipientAddress: String?
    public var subaddrAccount: Int

    init(hash: String, type: TransactionType, account: Int, blockHeight: UInt64, amount: Int64, fee: UInt64, isPending: Bool, isFailed: Bool, timestamp: Int, note: String?, recipientAddress: String?) {
        uid = UUID().uuidString
        self.hash = hash
        self.type = type
        self.blockHeight = blockHeight
        self.amount = amount
        self.fee = fee
        self.isPending = isPending
        self.isFailed = isFailed
        self.timestamp = timestamp
        self.note = note
        self.recipientAddress = recipientAddress
        self.subaddrAccount = account

        super.init()
    }

    convenience init(timestamp: Int? = nil) {
        self.init(hash: "", type: .outgoing, account: 0, blockHeight: 0, amount: 0, fee: 0, isPending: true, isFailed: false, timestamp: timestamp ?? Int(Date().timeIntervalSince1970), note: nil, recipientAddress: nil)
    }

    override open class var databaseTableName: String {
        "transactions"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case uid
        case hash
        case type
        case blockHeight
        case amount
        case fee
        case isPending
        case isFailed
        case timestamp
        case note
        case recipientAddress
        case subaddrAccount
    }

    required init(row: Row) throws {
        uid = row[Columns.uid]
        hash = row[Columns.hash]
        type = row[Columns.type]
        blockHeight = row[Columns.blockHeight]
        amount = row[Columns.amount]
        fee = row[Columns.fee]
        isPending = row[Columns.isPending]
        isFailed = row[Columns.isFailed]
        timestamp = row[Columns.timestamp]
        note = row[Columns.note]
        recipientAddress = row[Columns.recipientAddress]
        subaddrAccount = row[Columns.subaddrAccount]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.uid] = uid
        container[Columns.hash] = hash
        container[Columns.type] = type
        container[Columns.blockHeight] = blockHeight
        container[Columns.amount] = amount
        container[Columns.fee] = fee
        container[Columns.isPending] = isPending
        container[Columns.isFailed] = isFailed
        container[Columns.timestamp] = timestamp
        container[Columns.note] = note
        container[Columns.recipientAddress] = recipientAddress
        container[Columns.subaddrAccount] = subaddrAccount
    }
}
