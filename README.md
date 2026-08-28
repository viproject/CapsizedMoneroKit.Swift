# CapsizedMoneroKit.Swift

A Swift package for integrating Monero wallets into iOS applications.
Handles wallet sync, transactions, accounts, and subaddresses via a precompiled Monero binary.


Based on [MoneroKit.Swift](https://github.com/horizontalsystems/MoneroKit.Swift) originally developed by HorizontalSystems for Unstoppable Wallet.

## Requirements

- iOS 15+
- Swift 5.5+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/viproject/CapsizedMoneroKit.Swift.git", from: "1.0.0")
```

Then add `CapsizedMoneroKit` to your target dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "CapsizedMoneroKit", package: "CapsizedMoneroKit.Swift")
    ]
)
```

## Usage

### Create a wallet instance

```swift
import CapsizedMoneroKit

let kit = try Kit(
    wallet: .polyseed(seed: words, passphrase: ""),
    restoreHeight: 3200000,
    walletId: "unique-wallet-id",
    walletPassword: "secure-password",
    nodes: [Node(url: URL(string: "https://node.example.com:443")!)],
    networkType: .mainnet,
    isNewWallet: false,
    reachabilityManager: ReachabilityManager(),
    logger: nil
)
kit.delegate = self
kit.start()
```

### Implement the delegate

```swift
extension MyClass: CapsizedMoneroKitDelegate {
    func balancesDidChange(balanceInfos: [BalanceInfo]) {
        // Called when balances update across all accounts
    }
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo]) {
        // Called when new transactions arrive or existing ones are updated
    }
    func walletStateDidChange(state: WalletState) {
        // .connecting, .syncing(progress:remainingBlocksCount:), .synced, .idle, .notSynced
    }
    func subAddressesUpdated(subaddresses: [SubAddress]) {
        // Called when subaddress list changes
    }
    func activeNodeDidChange(node: Node) {
        // Called when the active node switches
    }
}
```

### Supported wallet types

| Type | Description |
|------|-------------|
| `.polyseed(seed:passphrase:)` | 16-word modern Monero seed |
| `.legacySeed(seed:)` | 25-word legacy Monero seed |
| `.watch(primaryAddress:viewKey:)` | View-only wallet (no spending) |

### Send XMR

```swift
try kit.send(
    to: "4ABC...",
    amount: .value(piconeroAmount),
    account: 0,
    priority: .default,
    memo: nil
)
```

### Accounts and subaddresses

```swift
kit.addNewAccount(label: "Savings")
kit.addNewSubaddress(accountIndex: 0, label: "Invoice #1")
```

## Third-party components

| Component | License | Source |
|-----------|---------|--------|
| monero_c (compiled binary) | LGPL-3.0 | [MrCyjaneK/monero_c](https://github.com/MrCyjaneK/monero_c) |
| polyseed | LGPL-3.0 | [tevador/polyseed](https://github.com/tevador/polyseed) |
| MoneroKit.Swift (original architecture) | MIT | [horizontalsystems/MoneroKit.Swift](https://github.com/horizontalsystems/MoneroKit.Swift) |

## License

MIT — see [LICENSE](LICENSE)  
Third-party binary notices — see [NOTICES](NOTICES)  
Polyseed license — see [Sources/CPolyseed/LICENSE](Sources/CPolyseed/LICENSE)
