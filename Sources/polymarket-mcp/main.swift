import Foundation
import PolymarketAdapter

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Read-only Polymarket tools.
// Logs go to stderr only; stdout is reserved for protocol messages.

typealias JSON = [String: Any]
let client = PolymarketClient()

func send(_ obj: JSON) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
          var s = String(data: d, encoding: .utf8) else { return }
    s.append("\n")
    FileHandle.standardOutput.write(Data(s.utf8))
}

func schema(_ props: JSON, required: [String] = []) -> JSON {
    ["type": "object", "properties": props, "required": required]
}
let str: (String) -> JSON = { ["type": "string", "description": $0] }
let int: (String) -> JSON = { ["type": "integer", "description": $0] }

let tools: [JSON] = [
    ["name": "top_markets", "description": "Top active Polymarket markets by volume, with implied odds.",
     "inputSchema": schema(["limit": int("Max results (default 10)")])],
    ["name": "search_markets", "description": "Search active Polymarket events/markets by text.",
     "inputSchema": schema(["query": str("Search text"), "limit": int("Max events (default 5)")], required: ["query"])],
    ["name": "get_market", "description": "Details, odds and CLOB token IDs for one market by slug.",
     "inputSchema": schema(["slug": str("Market slug")], required: ["slug"])],
    ["name": "order_book", "description": "Best bid/ask and spread per outcome for a market slug.",
     "inputSchema": schema(["slug": str("Market slug")], required: ["slug"])],
    ["name": "price_history", "description": "Price history for one outcome of a market.",
     "inputSchema": schema(["slug": str("Market slug"), "outcome": str("Outcome name, e.g. Yes"),
                            "interval": str("1h, 6h, 1d, 1w or max (default 1d)")],
                           required: ["slug", "outcome"])],
]

func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }

func describe(_ m: Market) -> String {
    let odds = zip(m.outcomes, m.outcomePrices).map { "\($0) \(pct($1))" }.joined(separator: " | ")
    return "• \(m.question)\n  \(odds)  vol $\(Int(m.volume ?? 0))  [\(m.slug ?? m.id)]"
}

@MainActor func callTool(_ name: String, _ a: JSON) async throws -> String {
    switch name {
    case "top_markets":
        var q = MarketQuery(); q.limit = min(a["limit"] as? Int ?? 10, 50)
        return try await client.markets(q).map(describe).joined(separator: "\n")
    case "search_markets":
        guard let query = a["query"] as? String else { throw ToolError("missing query") }
        let events = try await client.search(query, limit: min(a["limit"] as? Int ?? 5, 20))
        if events.isEmpty { return "No active results." }
        return events.map { e in
            "# \(e.title)\n" + e.markets.prefix(8).map(describe).joined(separator: "\n")
        }.joined(separator: "\n\n")
    case "get_market":
        guard let slug = a["slug"] as? String else { throw ToolError("missing slug") }
        let m = try await client.market(slug: slug)
        let tokens = m.tokenIdsByOutcome.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n  ")
        return describe(m) + "\n  end: \(m.endDate ?? "–")  liquidity $\(Int(m.liquidity ?? 0))  active=\(m.active) closed=\(m.closed)\n  tokens:\n  \(tokens)\n\n\(m.description ?? "")"
    case "order_book":
        guard let slug = a["slug"] as? String else { throw ToolError("missing slug") }
        let m = try await client.market(slug: slug)
        var out: [String] = []
        for (outcome, token) in m.tokenIdsByOutcome.sorted(by: { $0.key < $1.key }) {
            let b = try await client.orderBook(tokenId: token)
            out.append("\(outcome): bid \(b.bestBid.map { "\($0.price) x\($0.size)" } ?? "–") / ask \(b.bestAsk.map { "\($0.price) x\($0.size)" } ?? "–")  spread \(b.spread.map { String(format: "%.4f", $0) } ?? "–")")
        }
        return out.joined(separator: "\n")
    case "price_history":
        guard let slug = a["slug"] as? String, let outcome = a["outcome"] as? String else { throw ToolError("missing slug/outcome") }
        let m = try await client.market(slug: slug)
        guard let token = m.tokenIdsByOutcome.first(where: { $0.key.lowercased() == outcome.lowercased() })?.value
        else { throw ToolError("unknown outcome '\(outcome)'; options: \(m.outcomes.joined(separator: ", "))") }
        let interval = HistoryInterval(rawValue: a["interval"] as? String ?? "1d") ?? .oneDay
        let pts = try await client.priceHistory(tokenId: token, interval: interval)
        let f = ISO8601DateFormatter()
        return pts.map { "\(f.string(from: $0.timestamp)) \(pct($0.price))" }.joined(separator: "\n")
    default:
        throw ToolError("unknown tool \(name)")
    }
}

struct ToolError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

@MainActor func handle(_ msg: JSON) async {
    let id = msg["id"]
    guard let method = msg["method"] as? String else { return }
    func reply(_ result: JSON) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    switch method {
    case "initialize":
        let requested = (msg["params"] as? JSON)?["protocolVersion"] as? String ?? "2025-03-26"
        reply(["protocolVersion": requested, "capabilities": ["tools": JSON()],
               "serverInfo": ["name": "polymarket", "version": "0.1.0"]])
    case "ping": reply([:])
    case "tools/list": reply(["tools": tools])
    case "tools/call":
        let p = msg["params"] as? JSON ?? [:]
        do {
            let text = try await callTool(p["name"] as? String ?? "", p["arguments"] as? JSON ?? [:])
            reply(["content": [["type": "text", "text": text]]])
        } catch {
            reply(["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
        }
    default:
        if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]) }
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let d = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: d) as? JSON else { continue }
    await handle(msg)
}
