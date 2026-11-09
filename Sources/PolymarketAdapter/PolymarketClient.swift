import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read-only client for Polymarket's public APIs (Gamma for discovery, CLOB for pricing).
/// No authentication needed. Placing orders is intentionally out of scope: it requires
/// wallet (EIP-712) signing and API-key derivation.
public struct PolymarketClient: Sendable {
    public static let defaultGamma = URL(string: "https://gamma-api.polymarket.com")!
    public static let defaultClob = URL(string: "https://clob.polymarket.com")!

    private let gamma: URL
    private let clob: URL
    private let session: URLSession
    private let maxRetries: Int

    public init(gamma: URL = defaultGamma, clob: URL = defaultClob,
                session: URLSession = .shared, maxRetries: Int = 2) {
        self.gamma = gamma; self.clob = clob
        self.session = session; self.maxRetries = maxRetries
    }

    // MARK: Gamma — discovery

    public func markets(_ q: MarketQuery = .init()) async throws -> [Market] {
        var items: [URLQueryItem] = [
            .init(name: "limit", value: String(q.limit)),
            .init(name: "offset", value: String(q.offset)),
            .init(name: "ascending", value: String(q.ascending)),
        ]
        if let a = q.active { items.append(.init(name: "active", value: String(a))) }
        if let c = q.closed { items.append(.init(name: "closed", value: String(c))) }
        if let o = q.order { items.append(.init(name: "order", value: o)) }
        if let s = q.slug { items.append(.init(name: "slug", value: s)) }
        return try await get(gamma, "markets", items)
    }

    /// Pages through `markets(_:)` until the API returns a short page or `maxMarkets` is reached.
    ///
    /// Uses `q.limit` as the page size and starts at `q.offset`.
    public func allMarkets(_ q: MarketQuery = .init(), maxMarkets: Int = 1000) async throws -> [Market] {
        var query = q
        var result: [Market] = []
        while result.count < maxMarkets {
            let page = try await markets(query)
            result += page
            if page.count < query.limit { break }
            query.offset += query.limit
        }
        return Array(result.prefix(maxMarkets))
    }

    public func market(slug: String) async throws -> Market {
        var q = MarketQuery(); q.slug = slug; q.active = nil; q.closed = nil; q.limit = 1
        guard let m = try await markets(q).first else { throw PolymarketError.notFound(slug) }
        return m
    }

    public func market(id: String) async throws -> Market {
        try await get(gamma, "markets/\(id)", [])
    }

    public func events(limit: Int = 20, offset: Int = 0, active: Bool? = true,
                       closed: Bool? = false, slug: String? = nil) async throws -> [Event] {
        var items: [URLQueryItem] = [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
        ]
        if let active { items.append(.init(name: "active", value: String(active))) }
        if let closed { items.append(.init(name: "closed", value: String(closed))) }
        if let slug { items.append(.init(name: "slug", value: slug)) }
        return try await get(gamma, "events", items)
    }

    /// Full-text search; returns matching events (each containing its markets).
    /// By default resolved/closed events and markets are filtered out.
    public func search(_ query: String, limit: Int = 10,
                       includeClosed: Bool = false) async throws -> [Event] {
        let r: SearchResponse = try await get(gamma, "public-search", [
            .init(name: "q", value: query),
            .init(name: "limit_per_type", value: String(limit)),
        ])
        let events = r.events ?? []
        guard !includeClosed else { return events }
        return events.compactMap { e in
            guard e.active, !e.closed else { return nil }
            let open = e.markets.filter { $0.active && !$0.closed }
            return open.isEmpty ? nil : Event(copying: e, markets: open)
        }
    }

    // MARK: CLOB — pricing

    public func orderBook(tokenId: String) async throws -> OrderBook {
        try await get(clob, "book", [.init(name: "token_id", value: tokenId)])
    }

    /// Fetches many order books with a single request (`POST /books`).
    ///
    /// Tokens the CLOB does not know are silently missing from the result, so the result can be
    /// smaller than `tokenIds`. Keys are token IDs. Requests are split into chunks of `chunkSize`.
    public func orderBooks(tokenIds: [String], chunkSize: Int = 100) async throws -> [String: OrderBook] {
        var result: [String: OrderBook] = [:]
        for start in stride(from: 0, to: tokenIds.count, by: chunkSize) {
            let chunk = tokenIds[start..<min(start + chunkSize, tokenIds.count)]
            let body = try JSONEncoder().encode(chunk.map { ["token_id": $0] })
            let books: [OrderBook] = try await send(clob, "books", method: "POST", body: body)
            for b in books { if let id = b.assetId { result[id] = b } }
        }
        return result
    }

    /// Price quoted by the CLOB for a side. Observed live: `.buy` returns the best bid
    /// and `.sell` the best ask (the API's side is the book side, not the taker's side).
    /// Use `orderBook(tokenId:)` if you need explicit bid/ask.
    public func price(tokenId: String, side: Side) async throws -> Double {
        struct R: Decodable { let price: String }
        let r: R = try await get(clob, "price", [
            .init(name: "token_id", value: tokenId),
            .init(name: "side", value: side.rawValue),
        ])
        guard let p = Double(r.price) else { throw PolymarketError.invalidResponse }
        return p
    }

    public func midpoint(tokenId: String) async throws -> Double {
        struct R: Decodable { let mid: String }
        let r: R = try await get(clob, "midpoint", [.init(name: "token_id", value: tokenId)])
        guard let p = Double(r.mid) else { throw PolymarketError.invalidResponse }
        return p
    }

    public func priceHistory(tokenId: String, interval: HistoryInterval = .oneDay,
                             fidelityMinutes: Int = 60) async throws -> [PricePoint] {
        struct R: Decodable { let history: [PricePoint] }
        let r: R = try await get(clob, "prices-history", [
            .init(name: "market", value: tokenId),
            .init(name: "interval", value: interval.rawValue),
            .init(name: "fidelity", value: String(fidelityMinutes)),
        ])
        return r.history
    }

    // MARK: Transport

    private func get<T: Decodable>(_ base: URL, _ path: String,
                                   _ query: [URLQueryItem]) async throws -> T {
        try await send(base, path, query: query)
    }

    private func send<T: Decodable>(_ base: URL, _ path: String, query: [URLQueryItem] = [],
                                    method: String = "GET", body: Data? = nil) async throws -> T {
        var comps = URLComponents(url: base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = 20

        var attempt = 0
        while true {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw PolymarketError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                return try JSONDecoder().decode(T.self, from: data)
            case 429 where attempt < maxRetries, 500..<600 where attempt < maxRetries:
                attempt += 1
                try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
            case 404:
                throw PolymarketError.notFound(path)
            default:
                throw PolymarketError.http(status: http.statusCode,
                    body: String(decoding: data.prefix(300), as: UTF8.self))
            }
        }
    }
}
