// SPDX-License-Identifier: MIT
import Foundation

/// Why a verdict fired — named so the `os_log` line in `Kit` can say exactly which detector
/// triggered a rotation.
enum NodeVerdictReason: String {
    case handshakeTimeout
    case notSyncedDwell
    case walletError
    case hardStall
    case nodeLagsPeers
    case nodeSelfSyncing
    case slowThroughput
}

enum NodeVerdict: Equatable {
    case hard(NodeVerdictReason)
    case slow(NodeVerdictReason)
}

/// Pool-level context `Kit` gathers each tick (cheap — all synchronous reads of already-cached
/// `NodeMetrics`, no network) so the throughput detector's guards can be evaluated
/// without `NodeWatchdog` needing a reference to `NodePool` itself.
struct PoolSnapshot {
    let maxSeenHeight: UInt64
    let activeLatencyEWMA: TimeInterval?
    let bestCandidateLatencyEWMA: TimeInterval?
    /// A candidate scores ≥25% better than the active node — guard 2 in §4.4.
    let hasMateriallyBetterCandidate: Bool
    /// False once the throughput-floor detector has been disarmed for the session (§4.4.3).
    let isThroughputDetectorArmed: Bool
}

/// A pure type: no wallet pointer, no network, no clock of its own — time arrives in the
/// sample. That makes every threshold below testable by feeding a synthetic timeline. The only
/// state it holds is the per-detector `since` timestamps needed to require a condition be
/// *sustained* for its window, not just momentarily true.
final class NodeWatchdog {
    // Windows (seconds unless noted).
    private static let handshakeTimeoutWindow: TimeInterval = 20
    private static let notSyncedDwellWindow: TimeInterval = 25
    private static let walletErrorWindow: TimeInterval = 10
    private static let hardStallWindow: TimeInterval = 45
    private static let nodeLagsPeersWindow: TimeInterval = 60
    private static let nodeSelfSyncingWindow: TimeInterval = 60
    private static let throughputFloorWindow: TimeInterval = 90
    private static let postSwitchGraceWindow: TimeInterval = 15

    private static let heightLagThreshold: UInt64 = 10
    private static let targetHeightAheadThreshold: UInt64 = 10
    private static let throughputFloorBlocksPerSecond: Double = 50
    private static let throughputFloorMinRemainingBlocks = 5_000
    private static let hardStallMinRemainingBlocks = 2_000

    private var handshakeSince: Date?
    private var notSyncedSince: Date?
    private var walletErrorSince: Date?
    private var stallSince: Date?
    private var lastWalletHeightForStall: UInt64?
    private var lagSince: Date?
    private var selfSyncingSince: Date?
    private var throughputSince: Date?

    private var gracePeriodEndsAt: Date?

    /// Clears every detector's `since` timestamp — called on `.synced` and on reachability loss.
    /// Does not itself arm the post-switch grace period.
    func clearAllDetectorState() {
        handshakeSince = nil
        notSyncedSince = nil
        walletErrorSince = nil
        stallSince = nil
        lastWalletHeightForStall = nil
        lagSince = nil
        selfSyncingSince = nil
        throughputSince = nil
    }

    /// Called after a successful `switchNode` — resets all detector state and blocks every
    /// verdict for 15s so the new node can handshake and fill a measurement window before being
    /// judged. In practice this only matters for the wallet-error detector's 10s window; every
    /// other detector's own window already exceeds 15s once its `since` is reset to nil.
    func armPostSwitchGrace() {
        clearAllDetectorState()
        gracePeriodEndsAt = Date().addingTimeInterval(Self.postSwitchGraceWindow)
    }

    /// Evaluates one poll tick. Returns `nil` while nothing has fired. Hard beats slow; among
    /// simultaneous hard verdicts, the first in detector order wins — the choice only affects
    /// which reason gets logged, since every hard verdict leads to the same rotation call.
    func evaluate(sample: ActiveNodeSample, snapshot: PoolSnapshot) -> NodeVerdict? {
        if let gracePeriodEndsAt, Date() < gracePeriodEndsAt {
            return nil
        }

        if let verdict = evaluateHandshakeTimeout(sample) { return verdict }
        if let verdict = evaluateNotSyncedDwell(sample) { return verdict }
        if let verdict = evaluateWalletError(sample) { return verdict }
        if let verdict = evaluateHardStall(sample) { return verdict }
        if let verdict = evaluateNodeLagsPeers(sample, snapshot: snapshot) { return verdict }
        if let verdict = evaluateNodeSelfSyncing(sample) { return verdict }
        if let verdict = evaluateThroughputFloor(sample, snapshot: snapshot) { return verdict }
        return nil
    }

    // MARK: - Detector 1: handshake timeout (hard)

    private func evaluateHandshakeTimeout(_ sample: ActiveNodeSample) -> NodeVerdict? {
        guard case .connecting = sample.state, sample.daemonHeight == 0 else {
            handshakeSince = nil
            return nil
        }
        let since = handshakeSince ?? sample.at
        handshakeSince = since
        guard sample.at.timeIntervalSince(since) >= Self.handshakeTimeoutWindow else { return nil }
        return .hard(.handshakeTimeout)
    }

    // MARK: - Detector 2: not-synced dwell (hard)

    private func evaluateNotSyncedDwell(_ sample: ActiveNodeSample) -> NodeVerdict? {
        guard case .notSynced = sample.state else {
            notSyncedSince = nil
            return nil
        }
        let since = notSyncedSince ?? sample.at
        notSyncedSince = since
        guard sample.at.timeIntervalSince(since) >= Self.notSyncedDwellWindow else { return nil }
        return .hard(.notSyncedDwell)
    }

    // MARK: - Detector 3: wallet error (hard)

    private func evaluateWalletError(_ sample: ActiveNodeSample) -> NodeVerdict? {
        guard sample.walletStatusError != nil else {
            walletErrorSince = nil
            return nil
        }
        let since = walletErrorSince ?? sample.at
        walletErrorSince = since
        guard sample.at.timeIntervalSince(since) >= Self.walletErrorWindow else { return nil }
        return .hard(.walletError)
    }

    // MARK: - Detector 4: hard stall (hard, subject to Kit's stall budget)

    private func evaluateHardStall(_ sample: ActiveNodeSample) -> NodeVerdict? {
        guard case .syncing = sample.state, sample.remainingBlocks > Self.hardStallMinRemainingBlocks else {
            stallSince = nil
            lastWalletHeightForStall = sample.walletHeight
            return nil
        }

        guard lastWalletHeightForStall == sample.walletHeight else {
            lastWalletHeightForStall = sample.walletHeight
            stallSince = sample.at
            return nil
        }

        let since = stallSince ?? sample.at
        stallSince = since
        guard sample.at.timeIntervalSince(since) >= Self.hardStallWindow else { return nil }
        return .hard(.hardStall)
    }

    // MARK: - Detector 5: node lags peers (slow)

    private func evaluateNodeLagsPeers(_ sample: ActiveNodeSample, snapshot: PoolSnapshot) -> NodeVerdict? {
        guard snapshot.maxSeenHeight > sample.daemonHeight,
              snapshot.maxSeenHeight - sample.daemonHeight > Self.heightLagThreshold else {
            lagSince = nil
            return nil
        }
        let since = lagSince ?? sample.at
        lagSince = since
        guard sample.at.timeIntervalSince(since) >= Self.nodeLagsPeersWindow else { return nil }
        return .slow(.nodeLagsPeers)
    }

    // MARK: - Detector 6: node self-syncing (slow)

    private func evaluateNodeSelfSyncing(_ sample: ActiveNodeSample) -> NodeVerdict? {
        guard sample.daemonTargetHeight > sample.daemonHeight + Self.targetHeightAheadThreshold else {
            selfSyncingSince = nil
            return nil
        }
        let since = selfSyncingSince ?? sample.at
        selfSyncingSince = since
        guard sample.at.timeIntervalSince(since) >= Self.nodeSelfSyncingWindow else { return nil }
        return .slow(.nodeSelfSyncing)
    }

    // MARK: - Detector 7: throughput floor (slow, three guards from §4.4)

    private func evaluateThroughputFloor(_ sample: ActiveNodeSample, snapshot: PoolSnapshot) -> NodeVerdict? {
        let armed = throughputFloorConditionHolds(sample, snapshot: snapshot)
        guard armed else {
            throughputSince = nil
            return nil
        }
        let since = throughputSince ?? sample.at
        throughputSince = since
        guard sample.at.timeIntervalSince(since) >= Self.throughputFloorWindow else { return nil }
        return .slow(.slowThroughput)
    }

    private func throughputFloorConditionHolds(_ sample: ActiveNodeSample, snapshot: PoolSnapshot) -> Bool {
        guard snapshot.isThroughputDetectorArmed else { return false }
        guard !sample.isPreRestorePhase, sample.remainingBlocks > Self.throughputFloorMinRemainingBlocks else { return false }
        guard let bps = sample.blocksPerSecond, bps < Self.throughputFloorBlocksPerSecond else { return false }

        // Guard 1: comparative latency — only the node's fault if its own latency is
        // competitive is ruled out, i.e. the active node must be markedly worse than the best
        // candidate for a slow-node verdict to make sense.
        guard let activeLatency = snapshot.activeLatencyEWMA,
              let candidateLatency = snapshot.bestCandidateLatencyEWMA,
              activeLatency >= candidateLatency * 1.5 else { return false }

        // Guard 2: a materially better candidate must exist.
        guard snapshot.hasMateriallyBetterCandidate else { return false }

        return true
    }
}
