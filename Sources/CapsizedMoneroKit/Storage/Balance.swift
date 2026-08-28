// SPDX-License-Identifier: MIT
import Foundation
import GRDB

class Balance: Record {
    var id: String
    var all: Int64
    var unlocked: Int64
    var subaddrAccount: Int
    var label: String

    init(all: Int64, unlocked: Int64, account: Int, label: String = "") {
        self.all = Int64(clamping: all)
        self.unlocked = Int64(clamping: unlocked)
        self.subaddrAccount = account
        self.label = label
        self.id = UUID().uuidString

        super.init()
    }

    override open class var databaseTableName: String {
        "Balance"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case id
        case all
        case unlocked
        case subaddrAccount
        case label
    }

    required init(row: Row) throws {
        id = row[Columns.id]
        all = row[Columns.all] as Int64
        unlocked = row[Columns.unlocked] as Int64
        subaddrAccount = row[Columns.subaddrAccount]
        label = row[Columns.label] ?? ""

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.all] = all
        container[Columns.unlocked] = unlocked
        container[Columns.subaddrAccount] = subaddrAccount
        container[Columns.label] = label
        container[Columns.id] = id
    }
}
