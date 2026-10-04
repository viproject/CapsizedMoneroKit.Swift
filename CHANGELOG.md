# Changelog

## 1.1.0

- Added `NodeRotationMode.adaptive`: concurrent HTTP-based node health probing (`DaemonHealthProbe`), health/latency-based scoring, and watchdog-driven automatic rotation (`NodeWatchdog`).
- Added `Kit.init(..., nodeRotationMode:preferredNodeURL:)`. The previous initializer is deprecated but still works, and defaults to `.legacy` (unchanged 1.0.0 behavior).
- Added `Kit.switchToNode(_:completion:)` and `Kit.isAutoNodeSelectionEnabled` for manual node switching and pinning off automatic failover.
- Added RPC `login`/`password` support to `Node`.
- Added `NodePool.updateNodes(_:)`, `autoSelectableURLs`, `probeAllNodesSequentially()` / `onManualProbeResult`, and `NodeMetrics`.
- **Breaking:** `NodePool.init` now requires a `mode: NodeRotationMode` argument. `NodePool` is constructed internally by `Kit` only, so this isn't reachable through the public `Kit` API — but it is a source break for any code that constructs `NodePool` directly.

## 1.0.0

Initial release.
