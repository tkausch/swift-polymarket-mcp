import Foundation

public typealias JSON = [String: Any]

/// Error reported to the MCP caller as a tool failure.
public struct ToolError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// The read-only Polymarket tools exposed over MCP, plus the JSON-RPC 2.0 request handling.
public struct PolymarketTools {
    public let client: PolymarketClient
    public init(client: PolymarketClient = PolymarketClient()) { self.client = client }

    static func schema(_ props: JSON, required: [String] = []) -> JSON {
        ["type": "object", "properties": props, "required": required]
    }
    static func str(_ d: String) -> JSON { ["type": "string", "description": d] }
    static func int(_ d: String) -> JSON { ["type": "integer", "description": d] }

    /// Tool definitions returned by `tools/list`.
    public static var definitions: [JSON] { [
    ["name": "top_markets", "description": "Top active Polymarket markets by volume, with implied odds.",
     "inputSchema": schema(["limit": int("Max results (default 10)")])],
    ["name": "search_markets", "description": "Search active Polymarket events/markets by text.",
     "inputSchema": schema(["query": str("Search text"), "limit": int("Max events (default 5)")], required: ["query"])],
    ["name": "get_market", "description": "Details, odds and CLOB token IDs for one market by slug.",
     "inputSchema": schema(["slug": str("Market slug")], required: ["slug"])],
    ["name": "order_book", "description": "Best bid/ask and spread per outcome for a market slug.",
     "inputSchema": schema(["slug": str("Market slug")], required: ["slug"])],
    ["name": "book_depth", "description": "Full order book depth (bid/ask levels with sizes and cumulative size) for one outcome token, via CLOB GET /book. Provide token_id, or slug + outcome.",
     "inputSchema": schema(["token_id": str("CLOB token ID"), "slug": str("Market slug (with outcome)"),
                            "outcome": str("Outcome name, e.g. Yes"), "levels": int("Levels per side (default 10)")])],
    ["name": "order_books", "description": "Batch order books via CLOB POST /books (up to 500 tokens). Provide token_ids, or event_slug to scan every market's Yes token and check whether the best asks/bids sum to 100%.",
     "inputSchema": schema(["token_ids": ["type": "array", "items": ["type": "string"], "description": "CLOB token IDs (max 500)"],
                            "event_slug": str("Event slug; scans the Yes token of each market"),
                            "levels": int("Levels per side (default 3)")])],
    ["name": "price_history", "description": "Price history for one outcome of a market.",
     "inputSchema": schema(["slug": str("Market slug"), "outcome": str("Outcome name, e.g. Yes"),
                            "interval": str("1h, 6h, 1d, 1w or max (default 1d)")],
                           required: ["slug", "outcome"])],
    ] }

    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }

    static func describe(_ m: Market) -> String {
        let odds = zip(m.outcomes, m.outcomePrices).map { "\($0) \(Self.pct($1))" }.joined(separator: " | ")
        return "• \(m.question)\n  \(odds)  vol $\(Int(m.volume ?? 0))  [\(m.slug ?? m.id)]"
    }

        /// Runs one tool and returns its text output.
        ///
        /// - Throws: ``ToolError`` for bad arguments or unknown tools, or a client error.
        public func call(_ name: String, _ a: JSON) async throws -> String {
        switch name {
        case "top_markets":
            var q = MarketQuery(); q.limit = min(a["limit"] as? Int ?? 10, 50)
            return try await client.markets(q).map(Self.describe).joined(separator: "\n")
        case "search_markets":
            guard let query = a["query"] as? String else { throw ToolError("missing query") }
            let events = try await client.search(query, limit: min(a["limit"] as? Int ?? 5, 20))
            if events.isEmpty { return "No active results." }
            return events.map { e in
                "# \(e.title)\n" + e.markets.prefix(8).map(Self.describe).joined(separator: "\n")
            }.joined(separator: "\n\n")
        case "get_market":
            guard let slug = a["slug"] as? String else { throw ToolError("missing slug") }
            let m = try await client.market(slug: slug)
            let tokens = m.tokenIdsByOutcome.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n  ")
            return Self.describe(m) + "\n  end: \(m.endDate ?? "–")  liquidity $\(Int(m.liquidity ?? 0))  active=\(m.active) closed=\(m.closed)\n  tokens:\n  \(tokens)\n\n\(m.description ?? "")"
        case "order_book":
            guard let slug = a["slug"] as? String else { throw ToolError("missing slug") }
            let m = try await client.market(slug: slug)
            var out: [String] = []
            for (outcome, token) in m.tokenIdsByOutcome.sorted(by: { $0.key < $1.key }) {
                let b = try await client.orderBook(tokenId: token)
                out.append("\(outcome): bid \(b.bestBid.map { "\($0.price) x\($0.size)" } ?? "–") / ask \(b.bestAsk.map { "\($0.price) x\($0.size)" } ?? "–")  spread \(b.spread.map { String(format: "%.4f", $0) } ?? "–")")
            }
            return out.joined(separator: "\n")
        case "book_depth":
            let levels = max(1, min(a["levels"] as? Int ?? 10, 100))
            var token = a["token_id"] as? String
            if token == nil {
                guard let slug = a["slug"] as? String, let outcome = a["outcome"] as? String
                else { throw ToolError("provide token_id, or slug and outcome") }
                let m = try await client.market(slug: slug)
                token = m.tokenIdsByOutcome.first(where: { $0.key.lowercased() == outcome.lowercased() })?.value
                if token == nil { throw ToolError("unknown outcome '\(outcome)'; options: \(m.outcomes.joined(separator: ", "))") }
            }
            return try await client.orderBook(tokenId: token!).depthDescription(levels: levels)
        case "order_books":
            let levels = max(1, min(a["levels"] as? Int ?? 3, 100))
            var labels: [String: String] = [:]
            var ids = a["token_ids"] as? [String] ?? []
            var scan = false
            if let es = a["event_slug"] as? String {
                guard let e = try await client.events(active: nil, closed: nil, slug: es).first
                else { throw ToolError("event not found: \(es)") }
                for m in e.markets {
                    guard let t = m.tokenIdsByOutcome.first(where: { $0.key.lowercased() == "yes" })?.value else { continue }
                    ids.append(t); labels[t] = m.question
                }
                scan = true
            }
            guard !ids.isEmpty else { throw ToolError("provide token_ids or event_slug") }
            guard ids.count <= 500 else { throw ToolError("max 500 tokens per call") }
            let books = try await client.orderBooks(tokenIds: ids)
            var out = ids.compactMap { id in books[id].map { "== \(labels[id] ?? id)\n" + $0.depthDescription(levels: levels) } }
            let missing = ids.filter { books[$0] == nil }
            if !missing.isEmpty { out.append("No book for: \(missing.joined(separator: ", "))") }
            if scan {
                out.append(BookSums(books: ids.compactMap { books[$0] }, expected: ids.count).summary)
            }
            return out.joined(separator: "\n\n")
        case "price_history":
            guard let slug = a["slug"] as? String, let outcome = a["outcome"] as? String else { throw ToolError("missing slug/outcome") }
            let m = try await client.market(slug: slug)
            guard let token = m.tokenIdsByOutcome.first(where: { $0.key.lowercased() == outcome.lowercased() })?.value
            else { throw ToolError("unknown outcome '\(outcome)'; options: \(m.outcomes.joined(separator: ", "))") }
            let interval = HistoryInterval(rawValue: a["interval"] as? String ?? "1d") ?? .oneDay
            let pts = try await client.priceHistory(tokenId: token, interval: interval)
            let f = ISO8601DateFormatter()
            return pts.map { "\(f.string(from: $0.timestamp)) \(Self.pct($0.price))" }.joined(separator: "\n")
        default:
            throw ToolError("unknown tool \(name)")
        }
    }

    /// Handles one JSON-RPC message and returns the response object, or `nil` for
    /// notifications and messages without a method.
    public func handle(_ msg: JSON) async -> JSON? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return nil }
        func reply(_ result: JSON) -> JSON? { id.map { ["jsonrpc": "2.0", "id": $0, "result": result] } }
        switch method {
        case "initialize":
            let requested = (msg["params"] as? JSON)?["protocolVersion"] as? String ?? "2025-03-26"
            return reply(["protocolVersion": requested, "capabilities": ["tools": JSON()],
                          "serverInfo": ["name": "polymarket", "version": "0.1.0"]])
        case "ping": return reply([:])
        case "tools/list": return reply(["tools": Self.definitions])
        case "tools/call":
            let p = msg["params"] as? JSON ?? [:]
            do {
                let text = try await call(p["name"] as? String ?? "", p["arguments"] as? JSON ?? [:])
                return reply(["content": [["type": "text", "text": text]]])
            } catch {
                return reply(["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
            }
        default:
            return id.map { ["jsonrpc": "2.0", "id": $0, "error": ["code": -32601, "message": "Method not found: \(method)"]] }
        }
    }
}
