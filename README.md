# CapsizedMoneroKit.Swift

A Swift package for integrating Monero wallets into iOS applications.
Handles wallet sync, transactions, accounts, and subaddresses via a precompiled Monero binary. 

See [CHANGELOG.md](CHANGELOG.md) for release history.

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
    nodes: [Node(url: URL(string: "https://node.example.com:443")!, isTrusted: false)],
    networkType: .mainnet,
    isNewWallet: false,
    reachabilityManager: ReachabilityManager(),
    logger: nil,
    nodeRotationMode: .adaptive
)
kit.delegate = self
kit.start()
```

> A deprecated `init(...)` overload without `nodeRotationMode:` is still available for source compatibility — it defaults to `.legacy`, the original 1.0.0 node-selection behavior.

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
        // .connecting(waiting:), .syncing(progress:remainingBlocksCount:),
        // .synced(lastBlockHeight:), .idle(daemonReachable:), .notSynced(error:)
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
| `.legacy(seed:passphrase:)` | 25-word legacy Monero seed |
| `.bip39(seed:passphrase:)` | BIP39 mnemonic seed |
| `.keys(address:viewKey:spendKey:)` | Import from raw spend/view keys |
| `.watch(address:viewKey:)` | View-only wallet (no spending) |

### Node management

`Kit` supports two node-selection strategies via the `nodeRotationMode: NodeRotationMode` initializer parameter:

| Mode | Behavior |
|------|----------|
| `.legacy` | Original 1.0.0 behavior, frozen as-is |
| `.adaptive` | Concurrent HTTP health probing, health/latency-based scoring, and watchdog-driven automatic rotation (1.1.0+) |

Nodes can carry optional RPC credentials:

```swift
Node(url: URL(string: "https://my-node.example.com:18081")!, isTrusted: true, login: "user", password: "pass")
```

Pass `preferredNodeURL:` to `Kit.init` to start on a specific node instead of the pool's default pick.

Switch nodes manually, or pin the wallet off automatic failover:

```swift
kit.isAutoNodeSelectionEnabled = false // disables automatic rotation; pins to the current node
kit.switchToNode(someNode) { result in
    // .success(()) or .failure(Error)
}
```

`kit.nodePool` exposes the live node pool:

```swift
kit.nodePool.updateNodes(newNodeList)              // replace the node list (adds/edits/removes by URL)
kit.nodePool.autoSelectableURLs = Set(trustedURLs) // restrict automatic selection to these URLs
kit.nodePool.onManualProbeResult = { node, metrics in
    // fired by probeAllNodesSequentially(), isolated from the periodic background probe
}
kit.nodePool.probeAllNodesSequentially()           // manual "test all nodes" pass
```

`NodeMetrics` reports `lastResponseTime`, `successRate`, `heightLag`, and more per node (see `NodePool.swift`).

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

### Other APIs

- `kit.preloadCachedData()` — populate balances/transactions from local storage immediately, before the first sync completes
- `kit.estimateFee(address:amount:priority:)` — estimate the network fee for a send
- `Kit.newPolyseed(language:)` / `Kit.newLegacySeed(language:)` — generate a new seed phrase
- `Kit.validatePolyseed(_:)` / `Kit.validateLegacySeed(_:)` — validate a seed phrase
- `RestoreHeight.getHeight(date:)` — estimate a restore height from a wallet creation date
- `Kit.removeWallet(path:)` — delete a wallet's on-disk files

## Third-party components

| Component | License | Source |
|-----------|---------|--------|
| monero_c (compiled binary) | LGPL-3.0 | [MrCyjaneK/monero_c](https://github.com/MrCyjaneK/monero_c) |
| polyseed | LGPL-3.0 | [tevador/polyseed](https://github.com/tevador/polyseed) |
| MoneroKit.Swift (original architecture) | MIT | [horizontalsystems/MoneroKit.Swift](https://github.com/horizontalsystems/MoneroKit.Swift) |

## Contributing

Bug reports, feature suggestions, and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. Please note our [Code of Conduct](CODE_OF_CONDUCT.md). To report a security vulnerability privately, see [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE)  
Third-party binary notices — see [NOTICES](NOTICES)  
Polyseed license — see [Sources/CPolyseed/LICENSE](Sources/CPolyseed/LICENSE)
