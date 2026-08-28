// SPDX-License-Identifier: MIT
import Foundation

public struct Node: Equatable, Hashable {
    public let url: URL
    public let isTrusted: Bool
    public let login: String?
    public let password: String?

    public init(url: URL, isTrusted: Bool, login: String? = nil, password: String? = nil) {
        self.url = url
        self.isTrusted = isTrusted
        self.login = login
        self.password = password
    }

    public var description: String {
        "\(url.absoluteString) (\(isTrusted ? "trusted" : "untrusted")) \(login == nil ? "no credentials" : "has credentials")"
    }

    public static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.url == rhs.url
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
