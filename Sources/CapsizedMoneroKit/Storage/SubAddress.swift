// SPDX-License-Identifier: MIT
import Foundation
import GRDB

public class SubAddress: Record {
    public var address: String
    public var index: Int
    public var transactionsCount: Int
    public var subaddrAccount: Int
    

    init(address: String, index: Int, account: Int, transactionsCount: Int = 0) {
        self.address = address
        self.index = index
        self.transactionsCount = transactionsCount
        self.subaddrAccount = account

        super.init()
    }

    override open class var databaseTableName: String {
        "SubAddresss"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case address
        case index
        case transactionsCount
        case subaddrAccount
    }

    required init(row: Row) throws {
        address = row[Columns.address]
        index = row[Columns.index]
        transactionsCount = row[Columns.transactionsCount]
        subaddrAccount = row[Columns.subaddrAccount]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.address] = address
        container[Columns.index] = index
        container[Columns.transactionsCount] = transactionsCount
        container[Columns.subaddrAccount] = subaddrAccount
    }
}
