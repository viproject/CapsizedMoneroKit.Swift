// SPDX-License-Identifier: MIT
import Foundation

public class NodePool {
    private let lock = NSLock()
    private var metrics: [URL: NodeMetrics] = [:]
    private var probeTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "io.capsized.node_pool.timer", qos: .utility)
    private let probeQueue = DispatchQueue(label: "io.capsized.node_pool.probe", qos: .utility)
    private var nodeProber: NodeProber?

    public private(set) var nodes: [Node]
    public private(set) var activeNode: Node

    public var isNetworkReachable: () -> Bool = { true }
    public var onActiveNodeChanged: ((Node) -> Void)?
    public var onNodeProbeResult: ((Node, NodeMetrics) -> Void)?

    public init(nodes: [Node]) {
        precondition(!nodes.isEmpty, "NodePool requires at least one node")
        self.nodes = nodes
        self.activeNode = nodes[0]

        for node in nodes {
            metrics[node.url] = NodeMetrics()
        }

        nodeProber = NodeProber()
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
        if activeNode == node {
            activeNode = bestNodeLocked()
        }
    }

    public func updateNodes(_ newNodes: [Node]) {
        lock.lock()
        defer { lock.unlock() }
        guard !newNodes.isEmpty else { return }
        let existingURLs = Set(nodes.map(\.url))
        for node in newNodes where !existingURLs.contains(node.url) {
            nodes.append(node)
            metrics[node.url] = NodeMetrics()
        }
        nodes.removeAll { node in
            !newNodes.contains(node) && node != activeNode
        }
    }

    public func markSuccess(node: Node, responseTime: TimeInterval, height: UInt64) {
        lock.lock()
        guard var m = metrics[node.url] else {
            lock.unlock()
            return
        }
        m.lastResponseTime = responseTime
        m.lastKnownHeight = height
        m.consecutiveFailures = 0
        m.lastCheckedAt = Date()
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
        m.consecutiveFailures += 1
        m.lastCheckedAt = Date()
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

    public func bestNode() -> Node {
        lock.lock()
        let result = bestNodeLocked()
        lock.unlock()
        return result
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

    public func probeAllNodes() {
        guard isNetworkReachable() else { return }
        lock.lock()
        let nodesToProbe = Array(nodes)
        lock.unlock()

        probeQueue.async { [weak self] in
            guard let self, let prober = self.nodeProber else { return }
            for node in nodesToProbe {
                guard self.isNetworkReachable() else { return }
                self.probeNodeSync(node, prober: prober)
            }
        }
    }

    public func probeAllNodesSequentially() {
        guard isNetworkReachable() else { return }
        lock.lock()
        let nodesToProbe = Array(nodes)
        for url in metrics.keys {
            metrics[url] = NodeMetrics()
        }
        lock.unlock()

        probeQueue.async { [weak self] in
            guard let self, let prober = self.nodeProber else { return }
            for node in nodesToProbe {
                guard self.isNetworkReachable() else { return }
                self.probeNodeSync(node, prober: prober)
            }
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

    private func probeNodeSync(_ node: Node, prober: NodeProber) {
        if let result = prober.probe(node: node) {
            markSuccess(node: node, responseTime: result.responseTime, height: result.height)
        } else {
            guard isNetworkReachable() else { return }
            markFailed(node: node)
        }
    }

    private func markFailedInternal(node: Node) {
        guard var m = metrics[node.url] else { return }
        m.consecutiveFailures += 1
        m.lastCheckedAt = Date()
        metrics[node.url] = m
    }

    private func bestNodeLocked() -> Node {
        var best: Node = nodes[0]
        var bestScore = score(for: nodes[0])

        for node in nodes.dropFirst() {
            let s = score(for: node)
            if s < bestScore {
                bestScore = s
                best = node
            }
        }
        return best
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
}

public struct NodeMetrics {
    public var lastResponseTime: TimeInterval?
    public var lastKnownHeight: UInt64 = 0
    public var consecutiveFailures: Int = 0
    public var lastCheckedAt: Date?
}
