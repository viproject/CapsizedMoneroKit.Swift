// SPDX-License-Identifier: MIT
import Foundation

/// Result of a single successful `/get_info` probe.
struct NodeProbeSample {
    let latency: TimeInterval
    let height: UInt64
    /// 0 when the node reports itself synced (no known target ahead of its own height).
    let targetHeight: UInt64
    let isBusySyncing: Bool
    /// `nettype` was present in the response and did not match the network this wallet expects.
    let networkMismatch: Bool
}

enum NodeProbeOutcome {
    case ok(NodeProbeSample)
    /// The node reached us but gated `/get_info` behind auth (401/403) — not itself a failure;
    /// many public nodes restrict this endpoint. Callers should fall back to a credentialed
    /// prober once before treating the node as unknown.
    case authRequired
    case failed(reason: String)
}

/// Concurrent HTTP-based node health probe, used only by the `.adaptive` node-rotation path
/// (`NodePool.mode == .adaptive`). `NodeProber` (wallet2-based) remains the `.legacy` path's only
/// prober and this type's fallback for nodes that require RPC credentials.
final class DaemonHealthProbe {
    private let session: URLSession
    /// Expected network type string as reported by `/get_info`'s `nettype` field for mainnet.
    private let expectedNettype = "mainnet"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// Probes every node concurrently, bounded at `maxConcurrent` in flight, so a full pass over
    /// a handful of nodes costs roughly one timeout rather than one timeout per dead node.
    func probe(nodes: [Node], maxConcurrent: Int = 4) async -> [(Node, NodeProbeOutcome)] {
        await withTaskGroup(of: (Node, NodeProbeOutcome).self) { group in
            var results: [(Node, NodeProbeOutcome)] = []
            results.reserveCapacity(nodes.count)
            var iterator = nodes.makeIterator()

            func addNext() {
                guard let node = iterator.next() else { return }
                group.addTask { [weak self] in
                    guard let self else { return (node, .failed(reason: "prober deallocated")) }
                    return (node, await self.probeOne(node))
                }
            }

            for _ in 0..<maxConcurrent { addNext() }
            while let result = await group.next() {
                results.append(result)
                addNext()
            }
            return results
        }
    }

    private func probeOne(_ node: Node) async -> NodeProbeOutcome {
        guard let url = URL(string: "get_info", relativeTo: node.url) else {
            return .failed(reason: "invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let login = node.login, let password = node.password {
            let credentials = "\(login):\(password)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        let start = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        guard let http = response as? HTTPURLResponse else {
            return .failed(reason: "non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .authRequired
        }
        guard (200...299).contains(http.statusCode) else {
            return .failed(reason: "HTTP \(http.statusCode)")
        }

        guard let decoded = try? JSONDecoder().decode(GetInfoResponse.self, from: data) else {
            return .failed(reason: "undecodable response")
        }

        let networkMismatch = decoded.nettype.map { $0 != expectedNettype } ?? false
        let sample = NodeProbeSample(
            latency: elapsed,
            height: decoded.height,
            targetHeight: decoded.target_height ?? 0,
            isBusySyncing: decoded.busy_syncing ?? false,
            networkMismatch: networkMismatch
        )
        return .ok(sample)
    }

    private struct GetInfoResponse: Decodable {
        let status: String
        let height: UInt64
        let target_height: UInt64?
        let synced: Bool?
        let busy_syncing: Bool?
        let nettype: String?
        let untrusted: Bool?
        let restricted: Bool?
    }
}
