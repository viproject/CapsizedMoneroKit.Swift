// SPDX-License-Identifier: MIT
import Foundation
import GRDB

class PrivateTxData: Record {
    var txHash: String
    var txKey: String
    var recipientAddress: String

    init(txHash: String, txKey: String, recipientAddress: String) {
        self.txHash = txHash
        self.txKey = txKey
        self.recipientAddress = recipientAddress

        super.init()
    }

    override open class var databaseTableName: String {
        "private_tx_data"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case txHash
        case txKey
        case recipientAddress
    }

    required init(row: Row) throws {
        txHash = row[Columns.txHash]
        txKey = row[Columns.txKey]
        recipientAddress = row[Columns.recipientAddress]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.txHash] = txHash
        container[Columns.txKey] = txKey
        container[Columns.recipientAddress] = recipientAddress
    }
}
