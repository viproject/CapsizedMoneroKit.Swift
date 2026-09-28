// SPDX-License-Identifier: MIT
import Foundation

/// Selects which node-selection/rotation implementation a `Kit`/`NodePool` instance runs.
/// `.legacy` is the 1.0.0 behavior, frozen exactly as it was. `.adaptive` is new in 1.1.0:
/// HTTP-based concurrent probing, health-based scoring, and a watchdog-driven rotation cycle.
public enum NodeRotationMode {
    case legacy
    case adaptive
}

public class NodePool {
    private let lock = NSLock()
    private var metrics: [URL: NodeMetrics] = [:]
    /// Results from a user-initiated "Test all" run, kept entirely separate from `metrics` so
    /// the periodic background probe and the sync-heartbeat success marks (which only ever
    /// touch `metrics`) can never leak into what a manual test displays.
    private var manualMetrics: [URL: NodeMetrics] = [:]
    private var probeTimer: DispatchSourceTimer?
    private var adaptiveProbeTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "io.capsized.node_pool.timer", qos: .utility)
    private let probeQueue = DispatchQueue(label: "io.capsized.node_pool.probe", qos: .utility)
    private var nodeProber: NodeProber?
    private var daemonHealthProbe: DaemonHealthProbe?

    /// Raw sliding window (most recent last) of probe outcomes per node, capped at 10 entries.
    /// Kept out of the public `NodeMetrics` snapshot — only the derived `successRate` is exposed.
    private var outcomeWindows: [URL: [Bool]] = [:]

    /// Highest height (or target height) seen across any node in the pool, ever. Monotonic —
    /// only ever grows. Used as the reference "network tip" for height-lag scoring/detection so
    /// that a probe pass where fewer nodes happen to respond can't make the reference shrink.
    private var maxSeenHeight: UInt64 = 0

    public private(set) var nodes: [Node]
    public private(set) var activeNode: Node
    public let mode: NodeRotationMode

    public var isNetworkReachable: () -> Bool = { true }
    public var onActiveNodeChanged: ((Node) -> Void)?
    public var onNodeProbeResult: ((Node, NodeMetrics) -> Void)?
    /// Fired only by `probeAllNodesSequentially()` (the manual "Test all" path).
    public var onManualProbeResult: ((Node, NodeMetrics) -> Void)?
    /// When set, `bestNodeLocked()`/`adaptiveBestCandidates(excluding:)` only consider nodes
    /// whose URL is in this set — used to keep automatic selection restricted to the app's
    /// hardcoded default nodes. `nil` means no restriction (falls back to considering every
    /// pool node, the previous behavior).
    public var autoSelectableURLs: Set<URL>?

    /// `NodePool(nodes:)` is called from exactly one place in the codebase (`Kit.init`) — it is
    /// not part of the app's dependency surface, so this signature changes directly rather than
    /// going through a deprecated shim.
    public init(nodes: [Node], mode: NodeRotationMode, preferredActive: URL? = nil) {
        precondition(!nodes.isEmpty, "NodePool requires at least one node")
        self.nodes = nodes
        self.mode = mode

        switch mode {
        case .legacy:
            // Exactly today's line. The caller has already reordered `nodes` under .legacy,
            // so nodes[0] is the pinned node when one is pinned.
            self.activeNode = nodes[0]
        case .adaptive:
            self.activeNode = preferredActive.flatMap { url in nodes.first { $0.url == url } }
                ?? nodes[0]
        }

        for node in nodes {
            metrics[node.url] = NodeMetrics()
        }

        nodeProber = NodeProber()
        if mode == .adaptive {
            daemonHealthProbe = DaemonHealthProbe()
        }
    }

    public func addNode(_ node: Node) {
        lock.lock()
        defer { lock.unlock() }
        guard !nodes.contains(node) else { return }
        nodes.append(node)
        metrics[node.url] = NodeMetrics()
    }

    public func removeNode(_ node: Node) {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.count > 1 else { return }
        nodes.removeAll { $0 == node }
        metrics.removeValue(forKey: node.url)
        outcomeWindows.removeValue(forKey: node.url)
        if activeNode == node {
            activeNode = bestNodeLocked()
        }
    }

    public func updateNodes(_ newNodes: [Node]) {
        lock.lock()
        defer { lock.unlock() }
        guard !newNodes.isEmpty else { return }
        let newByURL = Dictionary(newNodes.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let existingURLs = Set(nodes.map(\.url))

        // Replace stored nodes whose URL already exists with the incoming instance, so an
        // edit to login/password/isTrusted (URL unchanged) is picked up rather than silently
        // ignored — `Node` equality only compares `url`, so appending wouldn't do this.
        // `metrics`/`outcomeWindows` stay keyed by URL and don't need touching.
        for i in nodes.indices {
            if let updated = newByURL[nodes[i].url] {
                nodes[i] = updated
            }
        }
        if let updatedActive = newByURL[activeNode.url] {
            activeNode = updatedActive
        }

        for node in newNodes where !existingURLs.contains(node.url) {
            nodes.append(node)
            metrics[node.url] = NodeMetrics()
        }
        nodes.removeAll { node in
            !newNodes.contains(node) && node != activeNode
        }
        let keepURLs = Set(nodes.map(\.url))
        for url in metrics.keys where !keepURLs.contains(url) {
            metrics.removeValue(forKey: url)
            outcomeWindows.removeValue(forKey: url)
        }
    }

    public func markSuccess(node: Node, responseTime: TimeInterval, height: UInt64) {
        lock.lock()
        guard var m = metrics[node.url] else {
            lock.unlock()
            return
        }
        applySuccess(to: &m, responseTime: responseTime, height: height, networkMismatch: false)
        metrics[node.url] = m
        lock.unlock()
        onNodeProbeResult?(node, m)
    }

    public func markFailed(node: Node) {
        guard isNetworkReachable() else { return }
        lock.lock()
        guard var m = metrics[node.url] else {
            lock.unlock()
            return
        }
        applyFailure(to: &m, url: node.url)
        metrics[node.url] = m
        lock.unlock()
        onNodeProbeResult?(node, m)
    }

    public func resetAllFailures() {
        lock.lock()
        for url in metrics.keys {
            metrics[url]?.consecutiveFailures = 0
        }
        lock.unlock()
    }

    /// Halves failure counts and clears quarantines recorded while unreachable, instead of
    /// wiping everything the way `resetAllFailures()` does. Used only by the `.adaptive` path
    /// (`Kit`'s `.idle(daemonReachable: true)` handling) — `resetAllFailures()` is untouched and
    /// keeps being what `.legacy` calls in the same spot.
    internal func decayFailures() {
        lock.lock()
        for url in metrics.keys {
            guard var m = metrics[url] else { continue }
            m.consecutiveFailures /= 2
            if let quarantinedUntil = m.quarantinedUntil, quarantinedUntil <= Date() {
                m.quarantinedUntil = nil
            }
            metrics[url] = m
        }
        lock.unlock()
    }

    /// Updates height/`lastGoodAt` on `.synced` without touching latency — used only by the
    /// `.adaptive` path (`Kit.swift`'s `.synced` handling), which lets real latency keep
    /// flowing in from the probe passes (§1) instead of the `.legacy` branch's hardcoded `0.5`.
    internal func recordSyncedHeight(node: Node, height: UInt64) {
        lock.lock()
        guard var m = metrics[node.url] else { lock.unlock(); return }
        m.lastKnownHeight = height
        m.consecutiveFailures = 0
        m.lastCheckedAt = Date()
        m.lastGoodAt = Date()
        maxSeenHeight = max(maxSeenHeight, height)
        m.heightLag = maxSeenHeight > height ? maxSeenHeight - height : 0
        metrics[node.url] = m
        lock.unlock()
    }

    /// Explicitly pins the active node. Has no effect if `node` is not in the pool.
    public func setActive(_ node: Node) {
        lock.lock()
        guard nodes.contains(node) else { lock.unlock(); return }
        let changed = node != activeNode
        activeNode = node
        lock.unlock()
        if changed { onActiveNodeChanged?(node) }
    }

    public func rotateToNextBest() -> Node {
        guard isNetworkReachable() else { return activeNode }
        lock.lock()
        markFailedInternal(node: activeNode)
        let next = bestNodeLocked()
        if next != activeNode {
            activeNode = next
            lock.unlock()
            onActiveNodeChanged?(next)
        } else {
            lock.unlock()
        }
        return next
    }

    /// The node auto-select would pick right now. Under `.legacy` this is the untouched
    /// fixed-penalty scoring; under `.adaptive` it's health-based scoring with near-best
    /// randomization (§3). Same name/signature/meaning either way — callers never need to know
    /// which mode is behind it.
    public func bestNode() -> Node {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .legacy:
            return bestNodeLocked()
        case .adaptive:
            return adaptiveBestCandidatesLocked(excluding: nil).first ?? bestNodeLocked()
        }
    }

    public func startProbing(interval: TimeInterval = 300) {
        stopProbing()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.probeAllNodes()
        }
        timer.resume()
        probeTimer = timer
    }

    public func stopProbing() {
        probeTimer?.cancel()
        probeTimer = nil
    }

    /// State-aware adaptive scheduler (§7) — `.adaptive` only, not part of the public API since
    /// nothing outside `Kit` calls it. Interval depends on whether the wallet has reached
    /// `.synced`; stops entirely rather than the legacy timer's always-on behavior.
    internal func startAdaptiveProbing(isSynced: @escaping () -> Bool) {
        stopAdaptiveProbing()
        scheduleNextAdaptiveProbe(isSynced: isSynced)
    }

    internal func stopAdaptiveProbing() {
        adaptiveProbeTimer?.cancel()
        adaptiveProbeTimer = nil
    }

    private func scheduleNextAdaptiveProbe(isSynced: @escaping () -> Bool) {
        let interval: TimeInterval = isSynced() ? 600 : 60
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.probeAllNodes()
            self.scheduleNextAdaptiveProbe(isSynced: isSynced)
        }
        timer.resume()
        adaptiveProbeTimer = timer
    }

    /// Kicks off a probe pass and reports results via `onNodeProbeResult`. Same contract either
    /// way; the prober underneath switches with mode (§0.3/§7): serial `NodeProber` under
    /// `.legacy`, concurrent `DaemonHealthProbe` under `.adaptive`.
    public func probeAllNodes() {
        guard isNetworkReachable() else { return }
        lock.lock()
        let nodesToProbe = Array(nodes)
        lock.unlock()

        switch mode {
        case .legacy:
            probeQueue.async { [weak self] in
                guard let self, let prober = self.nodeProber else { return }
                for node in nodesToProbe {
                    guard self.isNetworkReachable() else { return }
                    self.probeNodeSync(node, prober: prober)
                }
            }
        case .adaptive:
            runAdaptiveProbePass(nodes: nodesToProbe, manual: false)
        }
    }

    /// Manual "Test all". Same isolation from `metrics` either way; prober switches with mode.
    public func probeAllNodesSequentially() {
        guard isNetworkReachable() else { return }
        lock.lock()
        let nodesToProbe = Array(nodes)
        manualMetrics.removeAll()
        lock.unlock()

        switch mode {
        case .legacy:
            probeQueue.async { [weak self] in
                guard let self, let prober = self.nodeProber else { return }
                for node in nodesToProbe {
                    guard self.isNetworkReachable() else { return }
                    self.probeNodeManually(node, prober: prober)
                }
            }
        case .adaptive:
            runAdaptiveProbePass(nodes: nodesToProbe, manual: true)
        }
    }

    public func nodeMetrics(for node: Node) -> NodeMetrics? {
        lock.lock()
        let m = metrics[node.url]
        lock.unlock()
        return m
    }

    public func allNodeMetrics() -> [(Node, NodeMetrics)] {
        lock.lock()
        let result = nodes.compactMap { node -> (Node, NodeMetrics)? in
            guard let m = metrics[node.url] else { return nil }
            return (node, m)
        }
        lock.unlock()
        return result
    }

    // MARK: - Legacy internals (untouched)

    private func probeNodeSync(_ node: Node, prober: NodeProber) {
        if let result = prober.probe(node: node) {
            markSuccess(node: node, responseTime: result.responseTime, height: result.height)
        } else {
            guard isNetworkReachable() else { return }
            markFailed(node: node)
        }
    }

    private func probeNodeManually(_ node: Node, prober: NodeProber) {
        if let result = prober.probe(node: node) {
            recordManualSuccess(node: node, responseTime: result.responseTime, height: result.height)
        } else {
            guard isNetworkReachable() else { return }
            recordManualFailure(node: node)
        }
    }

    private func recordManualSuccess(node: Node, responseTime: TimeInterval, height: UInt64) {
        lock.lock()
        var m = manualMetrics[node.url] ?? NodeMetrics()
        m.lastResponseTime = responseTime
        m.lastKnownHeight = height
        m.consecutiveFailures = 0
        m.lastCheckedAt = Date()
        manualMetrics[node.url] = m
        lock.unlock()
        onManualProbeResult?(node, m)
    }

    private func recordManualFailure(node: Node) {
        lock.lock()
        var m = manualMetrics[node.url] ?? NodeMetrics()
        m.consecutiveFailures += 1
        m.lastCheckedAt = Date()
        manualMetrics[node.url] = m
        lock.unlock()
        onManualProbeResult?(node, m)
    }

    private func markFailedInternal(node: Node) {
        guard var m = metrics[node.url] else { return }
        applyFailure(to: &m, url: node.url)
        metrics[node.url] = m
    }

    private func bestNodeLocked() -> Node {
        let candidates = eligibleCandidates()
        var best = candidates[0]
        var bestScore = score(for: candidates[0])

        for node in candidates.dropFirst() {
            let s = score(for: node)
            if s < bestScore {
                bestScore = s
                best = node
            }
        }
        return best
    }

    private func eligibleCandidates() -> [Node] {
        guard let autoSelectableURLs else { return nodes }
        let filtered = nodes.filter { autoSelectableURLs.contains($0.url) }
        return filtered.isEmpty ? nodes : filtered
    }

    private func score(for node: Node) -> Double {
        guard let m = metrics[node.url] else { return .infinity }
        let latencyPenalty = m.lastResponseTime ?? 5.0
        let failurePenalty = Double(m.consecutiveFailures) * 10.0
        let stalePenalty: Double = {
            guard let checked = m.lastCheckedAt else { return 0 }
            let age = Date().timeIntervalSince(checked)
            return age > 600 ? 2.0 : 0
        }()
        return latencyPenalty + failurePenalty + stalePenalty
    }

    // MARK: - Additive metrics population (shared by legacy and adaptive probing)

    /// Updates the original four legacy fields plus the additive health fields (§2) from the
    /// same inputs every probe path already has. Populated unconditionally regardless of mode —
    /// `.legacy`'s own `score(for:)` simply never reads the additive fields.
    private func applySuccess(to m: inout NodeMetrics, responseTime: TimeInterval, height: UInt64, networkMismatch: Bool) {
        m.lastResponseTime = responseTime
        m.lastKnownHeight = height
        m.consecutiveFailures = 0
        m.lastCheckedAt = Date()
        m.lastGoodAt = Date()
        m.networkMismatch = networkMismatch
        m.quarantinedUntil = nil
        m.quarantineStrikes = 0

        m.latencyEWMA = m.latencyEWMA.map { $0 * 0.7 + responseTime * 0.3 } ?? responseTime

        maxSeenHeight = max(maxSeenHeight, height)
        m.heightLag = maxSeenHeight > height ? maxSeenHeight - height : 0
    }

    private func applyFailure(to m: inout NodeMetrics, url: URL) {
        m.consecutiveFailures += 1
        m.lastCheckedAt = Date()
    }

    private func recordOutcome(url: URL, success: Bool, into m: inout NodeMetrics) {
        var window = outcomeWindows[url] ?? []
        window.append(success)
        if window.count > 10 { window.removeFirst(window.count - 10) }
        outcomeWindows[url] = window
        let successes = window.filter { $0 }.count
        m.successRate = window.isEmpty ? 1.0 : Double(successes) / Double(window.count)
    }

    // MARK: - Adaptive internals (`.adaptive` only)

    /// Backoff schedule for quarantine strikes: 30s → 2m → 8m → 30m → 60m cap, ±20% jitter.
    internal func quarantineBackoff(forStrike strikes: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [30, 120, 480, 1800, 3600]
        let index = min(max(strikes, 1), schedule.count) - 1
        let base = schedule[index]
        let jitter = base * Double.random(in: -0.2...0.2)
        return base + jitter
    }

    /// Quarantines a node, applying escalating backoff based on its prior strike count.
    internal func quarantine(_ node: Node) {
        lock.lock()
        guard var m = metrics[node.url] else { lock.unlock(); return }
        m.quarantineStrikes += 1
        let duration = quarantineBackoff(forStrike: m.quarantineStrikes)
        m.quarantinedUntil = Date().addingTimeInterval(duration)
        metrics[node.url] = m
        lock.unlock()
    }

    /// The highest height (or target height) seen across any node in the pool, ever —
    /// monotonic. `Kit`'s watchdog uses this as the network-tip reference for the peer-lag
    /// detector.
    internal var currentMaxSeenHeight: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return maxSeenHeight
    }

    /// True when the best `.adaptive` candidate excluding the active node scores at least 25%
    /// better (lower) than the active node's own score — guard 2 of the throughput-floor
    /// detector's three guards (§4.4).
    internal func hasCandidateMateriallyBetterThanActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .adaptive else { return false }
        let activeScore = adaptiveScore(for: activeNode)
        guard let best = adaptiveBestCandidatesLocked(excluding: activeNode).first else { return false }
        guard activeScore.isFinite else { return true }
        let bestScore = adaptiveScore(for: best)
        return bestScore <= activeScore * 0.75
    }

    /// Probes exactly `candidates` via the adaptive prober, folding results into `metrics` the
    /// same way a passive pass would, then returns them re-ranked by current score. Used by
    /// `Kit`'s rotation cycle to verify candidates immediately before committing to a switch —
    /// the ranking that produced `candidates` may be up to a full probe cycle stale.
    internal func refreshAndRank(_ candidates: [Node]) async -> [Node] {
        guard let daemonHealthProbe, mode == .adaptive, !candidates.isEmpty else { return candidates }
        let results = await daemonHealthProbe.probe(nodes: candidates, maxConcurrent: candidates.count)
        for (node, outcome) in results {
            handleAdaptiveProbeOutcome(node: node, outcome: outcome, manual: false)
        }
        return rankByCurrentScore(candidates)
    }

    private func rankByCurrentScore(_ candidates: [Node]) -> [Node] {
        lock.lock()
        defer { lock.unlock() }
        return candidates.sorted { adaptiveScore(for: $0) < adaptiveScore(for: $1) }
    }

    /// Ranked, near-best-randomized candidates for automatic selection — the private helper both
    /// `bestNode()` and `Kit`'s adaptive rotation cycle (§5) call. Hard exclusions: network
    /// mismatch, active quarantine, not in `autoSelectableURLs`, and (in a rotation context) the
    /// node passed as `excluding`. If exclusions empty the candidate set, falls back to the
    /// least-recently-failed node among the full pool and triggers a fresh probe pass.
    internal func adaptiveBestCandidates(excluding: Node?) -> [Node] {
        lock.lock()
        let result = adaptiveBestCandidatesLocked(excluding: excluding)
        lock.unlock()
        return result
    }

    private func adaptiveBestCandidatesLocked(excluding: Node?) -> [Node] {
        let now = Date()
        var candidates = eligibleCandidates().filter { node in
            guard node != excluding else { return false }
            guard let m = metrics[node.url] else { return true }
            if m.networkMismatch { return false }
            if let quarantinedUntil = m.quarantinedUntil, quarantinedUntil > now { return false }
            return true
        }

        if candidates.isEmpty {
            let fallbackPool = excluding.map { ex in nodes.filter { $0 != ex } } ?? nodes
            let fallback = fallbackPool.isEmpty ? nodes : fallbackPool
            let leastRecentlyFailed = fallback.min { a, b in
                let aChecked = metrics[a.url]?.lastCheckedAt ?? .distantPast
                let bChecked = metrics[b.url]?.lastCheckedAt ?? .distantPast
                return aChecked < bChecked
            }
            if let leastRecentlyFailed {
                probeQueue.async { [weak self] in self?.probeAllNodes() }
                return [leastRecentlyFailed]
            }
            return []
        }

        let scored = candidates.map { ($0, adaptiveScore(for: $0)) }
        let sorted = scored.sorted { $0.1 < $1.1 }
        guard let bestScore = sorted.first?.1 else { return [] }
        let band = max(bestScore * 1.15, bestScore + 0.03)
        let nearBest = sorted.filter { $0.1 <= band }.map(\.0)
        candidates = nearBest.shuffled()
        return candidates
    }

    /// Lower is better; every term normalized to 0…1, unknowns contribute a neutral 0.5 so an
    /// unmeasured node is neither favoured nor condemned.
    private func adaptiveScore(for node: Node) -> Double {
        guard let m = metrics[node.url] else { return .infinity }

        let latTerm: Double = {
            guard let ewma = m.latencyEWMA else { return 0.5 }
            return min(ewma / 2.0, 1.0)
        }()
        let lagTerm: Double = {
            guard let lag = m.heightLag else { return 0.5 }
            return lag <= 2 ? 0 : min(Double(lag) / 100.0, 1.0)
        }()
        let relTerm = 1.0 - m.successRate
        let thrTerm: Double = {
            guard let bps = m.syncBlocksPerSecond else { return 0.5 }
            return 1.0 - min(bps / 400.0, 1.0)
        }()

        var s = 0.40 * latTerm + 0.25 * lagTerm + 0.20 * relTerm + 0.15 * thrTerm

        if m.lastCheckedAt == nil || Date().timeIntervalSince(m.lastCheckedAt!) > 900 {
            s += 0.5
        }
        if node == activeNode {
            s -= 0.05
        }
        return s
    }

    /// One-shot concurrent probe pass over `nodes` using `DaemonHealthProbe`, falling back to
    /// `NodeProber` for nodes that report 401/403 (credentialed nodes gating `/get_info`).
    private func runAdaptiveProbePass(nodes nodesToProbe: [Node], manual: Bool) {
        guard let daemonHealthProbe else { return }
        Task { [weak self] in
            guard let self else { return }
            let results = await daemonHealthProbe.probe(nodes: nodesToProbe, maxConcurrent: 4)
            for (node, outcome) in results {
                guard self.isNetworkReachable() else { return }
                self.handleAdaptiveProbeOutcome(node: node, outcome: outcome, manual: manual)
            }
        }
    }

    private func handleAdaptiveProbeOutcome(node: Node, outcome: NodeProbeOutcome, manual: Bool) {
        switch outcome {
        case let .ok(sample):
            recordAdaptiveSuccess(node: node, sample: sample, manual: manual)
        case .authRequired:
            guard let prober = nodeProber, let result = prober.probe(node: node) else {
                recordAdaptiveUnknown(node: node, manual: manual)
                return
            }
            recordAdaptiveSuccess(
                node: node,
                sample: NodeProbeSample(latency: result.responseTime, height: result.height, targetHeight: 0, isBusySyncing: false, networkMismatch: false),
                manual: manual
            )
        case .failed:
            recordAdaptiveFailure(node: node, manual: manual)
        }
    }

    private func recordAdaptiveSuccess(node: Node, sample: NodeProbeSample, manual: Bool) {
        lock.lock()
        var target = manual ? (manualMetrics[node.url] ?? NodeMetrics()) : (metrics[node.url] ?? NodeMetrics())
        applySuccess(to: &target, responseTime: sample.latency, height: sample.height, networkMismatch: sample.networkMismatch)
        maxSeenHeight = max(maxSeenHeight, sample.targetHeight)
        if !manual {
            recordOutcome(url: node.url, success: true, into: &target)
            metrics[node.url] = target
        } else {
            manualMetrics[node.url] = target
        }
        lock.unlock()
        if manual { onManualProbeResult?(node, target) } else { onNodeProbeResult?(node, target) }
    }

    private func recordAdaptiveFailure(node: Node, manual: Bool) {
        guard manual || isNetworkReachable() else { return }
        lock.lock()
        var target = manual ? (manualMetrics[node.url] ?? NodeMetrics()) : (metrics[node.url] ?? NodeMetrics())
        applyFailure(to: &target, url: node.url)
        if !manual {
            recordOutcome(url: node.url, success: false, into: &target)
            metrics[node.url] = target
        } else {
            manualMetrics[node.url] = target
        }
        lock.unlock()
        if manual { onManualProbeResult?(node, target) } else { onNodeProbeResult?(node, target) }
    }

    /// An unresolved 401/403 with no successful fallback probe — leave the node's metrics as
    /// they were rather than counting it as a failure it may not deserve.
    private func recordAdaptiveUnknown(node: Node, manual: Bool) {
        lock.lock()
        let target = manual ? (manualMetrics[node.url] ?? NodeMetrics()) : (metrics[node.url] ?? NodeMetrics())
        lock.unlock()
        if manual { onManualProbeResult?(node, target) } else { onNodeProbeResult?(node, target) }
    }
}

public struct NodeMetrics {
    public var lastResponseTime: TimeInterval?
    public var lastKnownHeight: UInt64 = 0
    public var consecutiveFailures: Int = 0
    public var lastCheckedAt: Date?

    // Additive, populated unconditionally regardless of mode — only the `.adaptive` scoring
    // path (and its watchdog) reads them.
    public var latencyEWMA: TimeInterval?
    public var successRate: Double = 1.0
    public var heightLag: UInt64?
    public var syncBlocksPerSecond: Double?
    public var lastGoodAt: Date?
    public var quarantinedUntil: Date?
    public var quarantineStrikes: Int = 0
    public var networkMismatch: Bool = false
}
