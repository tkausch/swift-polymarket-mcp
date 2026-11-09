import Foundation

// MARK: - Lenient decoding helpers
// Polymarket's Gamma API returns some arrays as JSON-encoded strings
// (e.g. "outcomes": "[\"Yes\",\"No\"]") and some numbers as strings.

extension KeyedDecodingContainer {
    func lenientDouble(_ key: Key) -> Double? {
        if let d = try? decode(Double.self, forKey: key) { return d }
        if let s = try? decode(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func lenientStringArray(_ key: Key) -> [String] {
        if let a = try? decode([String].self, forKey: key) { return a }
        if let s = try? decode(String.self, forKey: key),
           let data = s.data(using: .utf8),
           let a = try? JSONDecoder().decode([String].self, from: data) { return a }
        return []
    }
}

// MARK: - Gamma models

public struct Market: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let question: String
    public let conditionId: String?
    public let slug: String?
    public let description: String?
    public let outcomes: [String]
    public let outcomePrices: [Double]
    /// CLOB token IDs, index-aligned with `outcomes`.
    public let clobTokenIds: [String]
    public let volume: Double?
    public let liquidity: Double?
    public let active: Bool
    public let closed: Bool
    public let endDate: String?
    public let image: String?

    enum CodingKeys: String, CodingKey {
        case id, question, conditionId, slug, description, outcomes, outcomePrices
        case clobTokenIds, volume, volumeNum, liquidity, liquidityNum
        case active, closed, endDate, image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else { id = String(try c.decode(Int.self, forKey: .id)) }
        question = (try? c.decode(String.self, forKey: .question)) ?? ""
        conditionId = try? c.decode(String.self, forKey: .conditionId)
        slug = try? c.decode(String.self, forKey: .slug)
        description = try? c.decode(String.self, forKey: .description)
        outcomes = c.lenientStringArray(.outcomes)
        outcomePrices = c.lenientStringArray(.outcomePrices).compactMap(Double.init)
        clobTokenIds = c.lenientStringArray(.clobTokenIds)
        volume = c.lenientDouble(.volumeNum) ?? c.lenientDouble(.volume)
        liquidity = c.lenientDouble(.liquidityNum) ?? c.lenientDouble(.liquidity)
        active = (try? c.decode(Bool.self, forKey: .active)) ?? false
        closed = (try? c.decode(Bool.self, forKey: .closed)) ?? false
        endDate = try? c.decode(String.self, forKey: .endDate)
        image = try? c.decode(String.self, forKey: .image)
    }

    public var endDateParsed: Date? {
        guard let endDate else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: endDate) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: endDate)
    }

    /// Outcome name → CLOB token ID.
    public var tokenIdsByOutcome: [String: String] {
        Dictionary(zip(outcomes, clobTokenIds), uniquingKeysWith: { a, _ in a })
    }

    /// Outcome name → last-known implied probability (0...1).
    public var pricesByOutcome: [String: Double] {
        Dictionary(zip(outcomes, outcomePrices), uniquingKeysWith: { a, _ in a })
    }
}

public struct Event: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let slug: String?
    public let description: String?
    public let active: Bool
    public let closed: Bool
    public let volume: Double?
    public let liquidity: Double?
    public let markets: [Market]

    enum CodingKeys: String, CodingKey {
        case id, title, slug, description, active, closed, volume, liquidity, markets
    }

    init(copying e: Event, markets: [Market]) {
        id = e.id; title = e.title; slug = e.slug; description = e.description
        active = e.active; closed = e.closed; volume = e.volume
        liquidity = e.liquidity; self.markets = markets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else { id = String(try c.decode(Int.self, forKey: .id)) }
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        slug = try? c.decode(String.self, forKey: .slug)
        description = try? c.decode(String.self, forKey: .description)
        active = (try? c.decode(Bool.self, forKey: .active)) ?? false
        closed = (try? c.decode(Bool.self, forKey: .closed)) ?? false
        volume = c.lenientDouble(.volume)
        liquidity = c.lenientDouble(.liquidity)
        markets = (try? c.decode([Market].self, forKey: .markets)) ?? []
    }
}

struct SearchResponse: Decodable {
    let events: [Event]?
}

// MARK: - CLOB models

public enum Side: String, Sendable { case buy = "BUY", sell = "SELL" }

public struct OrderLevel: Decodable, Sendable, Hashable {
    public let price: Double
    public let size: Double

    enum CodingKeys: String, CodingKey { case price, size }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let p = c.lenientDouble(.price), let s = c.lenientDouble(.size) else {
            throw DecodingError.dataCorruptedError(forKey: .price, in: c,
                debugDescription: "Non-numeric order level")
        }
        price = p; size = s
    }
}

public struct OrderBook: Decodable, Sendable {
    public let market: String?
    public let assetId: String?
    public let bids: [OrderLevel]
    public let asks: [OrderLevel]
    public let tickSize: Double?
    public let minOrderSize: Double?

    enum CodingKeys: String, CodingKey {
        case market, bids, asks
        case assetId = "asset_id"
        case tickSize = "tick_size"
        case minOrderSize = "min_order_size"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        market = try? c.decode(String.self, forKey: .market)
        assetId = try? c.decode(String.self, forKey: .assetId)
        bids = (try? c.decode([OrderLevel].self, forKey: .bids)) ?? []
        asks = (try? c.decode([OrderLevel].self, forKey: .asks)) ?? []
        tickSize = c.lenientDouble(.tickSize)
        minOrderSize = c.lenientDouble(.minOrderSize)
    }

    public var bestBid: OrderLevel? { bids.max { $0.price < $1.price } }
    public var bestAsk: OrderLevel? { asks.min { $0.price < $1.price } }
    public var spread: Double? {
        guard let b = bestBid, let a = bestAsk else { return nil }
        return a.price - b.price
    }
}

public struct PricePoint: Decodable, Sendable, Hashable {
    public let timestamp: Date
    public let price: Double

    enum CodingKeys: String, CodingKey { case t, p }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .t))
        price = try c.decode(Double.self, forKey: .p)
    }
}

public enum HistoryInterval: String, Sendable {
    case oneHour = "1h", sixHours = "6h", oneDay = "1d", oneWeek = "1w", max = "max"
}

// MARK: - Query options

public struct MarketQuery: Sendable {
    public var limit = 20
    public var offset = 0
    public var active: Bool? = true
    public var closed: Bool? = false
    public var order: String? = "volumeNum"
    public var ascending = false
    public var slug: String?
    public init() {}
}

public enum PolymarketError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case notFound(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .http(let s, let b): "HTTP \(s): \(b)"
        case .notFound(let w): "Not found: \(w)"
        case .invalidResponse: "Invalid response from Polymarket"
        }
    }
}
