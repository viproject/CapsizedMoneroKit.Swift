# Changelog

## 1.1.2

- Fixed: a crash in `SyncStateManager.stop()` caused by a data race. `state` and related sync bookkeeping (`isRunning`, wallet pointers, height samples, restore height) were read and written from whichever thread `MoneroCore` or the reachability sink ran on. A concurrent write could tear the `WalletState` enum payload. All access is now confined to the manager's serial queue, with reentrancy handled so `state`'s `didSet` callbacks can call back into `start()`/`stop()` without deadlocking. No public API changes.

## 1.1.1

- Added `Kit.isWatchOnly`: true when the wallet was restored from an address + view key only (no spend key). Captured once from the wallet file during `init`.
- Fixed: `Kit.init` for a `.watch` wallet returned early before `subscribeToBackgroundNotifications()` and the `.adaptive` `NodeWatchdog` were set up. It now only skips deriving the second subaddress, matching the behavior of a relaunched watch-only wallet.

## 1.1.0

- Added `NodeRotationMode.adaptive`: concurrent HTTP-based node health probing (`DaemonHealthProbe`), health/latency-based scoring, and watchdog-driven automatic rotation (`NodeWatchdog`).
- Added `Kit.init(..., nodeRotationMode:preferredNodeURL:)`. The previous initializer is deprecated but still works, and defaults to `.legacy` (unchanged 1.0.0 behavior).
- Added `Kit.switchToNode(_:completion:)` and `Kit.isAutoNodeSelectionEnabled` for manual node switching and pinning off automatic failover.
- Added RPC `login`/`password` support to `Node`.
- Added `NodePool.updateNodes(_:)`, `autoSelectableURLs`, `probeAllNodesSequentially()` / `onManualProbeResult`, and `NodeMetrics`.
- **Breaking:** `NodePool.init` now requires a `mode: NodeRotationMode` argument. `NodePool` is constructed internally by `Kit` only, so this isn't reachable through the public `Kit` API — but it is a source break for any code that constructs `NodePool` directly.

## 1.0.0

Initial release.
