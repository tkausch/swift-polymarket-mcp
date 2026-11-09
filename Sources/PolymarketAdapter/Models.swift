import Foundation

// MARK: - Lenient decoding helpers
// Polymarket's Gamma API returns some arrays as JSON-encoded strings
// (e.g. "outcomes": "[\"Yes\",\"No\"]") and some numbers as strings.

extension KeyedDecodingContainer {
    /// Decodes a number that the API may send either as a JSON number or as a numeric string.
    ///
    /// - Returns: The value as a `Double`, or `nil` if the key is missing, `null`, or not numeric.
    ///   Never throws, so one malformed field does not fail the whole object.
    func lenientDouble(_ key: Key) -> Double? {
        if let d = try? decode(Double.self, forKey: key) { return d }
        if let s = try? decode(String.self, forKey: key) { return Double(s) }
        return nil
    }

    /// Decodes a string array that the API may send either as a real JSON array or as a
    /// JSON-encoded string containing an array (e.g. `"[\"Yes\",\"No\"]"`).
    ///
    /// - Returns: The decoded array, or an empty array if the key is missing or unparseable.
    func lenientStringArray(_ key: Key) -> [String] {
        if let a = try? decode([String].self, forKey: key) { return a }
        if let s = try? decode(String.self, forKey: key),
           let data = s.data(using: .utf8),
           let a = try? JSONDecoder().decode([String].self, from: data) { return a }
        return []
    }
}

// MARK: - Gamma models

/// A single tradable question on Polymarket, e.g. "Will X happen before 2027?".
///
/// Decoded from the Gamma API. Decoding is deliberately forgiving: apart from `id`, missing or
/// malformed fields fall back to empty/`nil`/`false` instead of throwing. A market usually has
/// two outcomes ("Yes"/"No"), and `outcomes`, `outcomePrices` and `clobTokenIds` are
/// index-aligned with each other.
public struct Market: Decodable, Sendable, Identifiable, Hashable {
    /// Gamma market ID. Decoded from either a string or an integer.
    public let id: String
    /// The question being traded. Empty if the API did not provide one.
    public let question: String
    /// On-chain condition ID that identifies the market's outcome tokens.
    public let conditionId: String?
    /// URL slug, e.g. `will-the-us-invade-iran-before-2027`. Used to look the market up.
    public let slug: String?
    /// Resolution rules and background text.
    public let description: String?
    /// Outcome names in API order, e.g. `["Yes", "No"]`.
    public let outcomes: [String]
    /// Last-known price per outcome, index-aligned with `outcomes`.
    /// Prices are implied probabilities between 0 and 1.
    public let outcomePrices: [Double]
    /// CLOB token IDs, index-aligned with `outcomes`.
    public let clobTokenIds: [String]
    /// Total traded volume in USD. Prefers the numeric `volumeNum` field over `volume`.
    public let volume: Double?
    /// Current liquidity in USD. Prefers the numeric `liquidityNum` field over `liquidity`.
    public let liquidity: Double?
    /// Whether the market is currently open for trading.
    public let active: Bool
    /// Whether the market has been closed (no longer tradable). Closed does not imply resolved.
    public let closed: Bool
    /// Scheduled end date as the raw ISO 8601 string from the API. See ``endDateParsed``.
    public let endDate: String?
    /// URL of the market's image.
    public let image: String?
    /// Whether this market belongs to a "negative risk" group of mutually exclusive outcomes
    /// (exactly one market in the group resolves Yes). `false` if the API did not say.
    public let negRisk: Bool
    /// Whether the market trades on the CLOB order book. `false` if the API did not say.
    public let enableOrderBook: Bool
    /// Whether the market currently accepts new orders. `false` if the API did not say.
    public let acceptingOrders: Bool
    /// Minimum price increment of the market's order book (e.g. 0.01 or 0.001).
    public let orderPriceMinTickSize: Double?

    enum CodingKeys: String, CodingKey {
        case id, question, conditionId, slug, description, outcomes, outcomePrices
        case clobTokenIds, volume, volumeNum, liquidity, liquidityNum
        case active, closed, endDate, image
        case negRisk, enableOrderBook, acceptingOrders, orderPriceMinTickSize
    }

    /// Decodes a market, tolerating the API's inconsistent field types.
    ///
    /// - Throws: Only if `id` is missing or is neither a string nor an integer.
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
        negRisk = (try? c.decode(Bool.self, forKey: .negRisk)) ?? false
        enableOrderBook = (try? c.decode(Bool.self, forKey: .enableOrderBook)) ?? false
        acceptingOrders = (try? c.decode(Bool.self, forKey: .acceptingOrders)) ?? false
        orderPriceMinTickSize = c.lenientDouble(.orderPriceMinTickSize)
    }

    /// `endDate` parsed as a `Date`.
    ///
    /// Accepts ISO 8601 with or without fractional seconds. Returns `nil` if `endDate` is
    /// missing or in another format.
    public var endDateParsed: Date? {
        guard let endDate else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: endDate) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: endDate)
    }

    /// Outcome name → CLOB token ID.
    ///
    /// Pairs `outcomes` with `clobTokenIds` by index; extra entries on the longer array are
    /// dropped. If an outcome name repeats, the first token wins.
    public var tokenIdsByOutcome: [String: String] {
        Dictionary(zip(outcomes, clobTokenIds), uniquingKeysWith: { a, _ in a })
    }

    /// Outcome name → last-known implied probability (0...1).
    ///
    /// Pairs `outcomes` with `outcomePrices` by index. If an outcome name repeats, the first
    /// price wins.
    public var pricesByOutcome: [String: Double] {
        Dictionary(zip(outcomes, outcomePrices), uniquingKeysWith: { a, _ in a })
    }
}

/// A group of related markets, e.g. all candidates in one election.
///
/// Returned by the Gamma events and public-search endpoints. Like ``Market``, decoding is
/// forgiving: only `id` is required.
public struct Event: Decodable, Sendable, Identifiable, Hashable {
    /// Gamma event ID. Decoded from either a string or an integer.
    public let id: String
    /// Human-readable event title. Empty if the API did not provide one.
    public let title: String
    /// URL slug of the event.
    public let slug: String?
    /// Background text and resolution rules.
    public let description: String?
    /// Whether the event is currently open for trading.
    public let active: Bool
    /// Whether the event has been closed.
    public let closed: Bool
    /// Total traded volume in USD across the event's markets.
    public let volume: Double?
    /// Current liquidity in USD across the event's markets.
    public let liquidity: Double?
    /// The markets that belong to this event. Empty if none were returned.
    public let markets: [Market]

    enum CodingKeys: String, CodingKey {
        case id, title, slug, description, active, closed, volume, liquidity, markets
    }

    /// Creates a copy of `e` with its markets replaced, e.g. to keep only open markets.
    init(copying e: Event, markets: [Market]) {
        id = e.id; title = e.title; slug = e.slug; description = e.description
        active = e.active; closed = e.closed; volume = e.volume
        liquidity = e.liquidity; self.markets = markets
    }

    /// Decodes an event, tolerating missing or malformed fields.
    ///
    /// - Throws: Only if `id` is missing or is neither a string nor an integer.
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

/// Envelope of the Gamma `public-search` response. Internal: callers get `[Event]`.
struct SearchResponse: Decodable {
    let events: [Event]?
}

// MARK: - CLOB models

/// Side of the order book for a price query.
///
/// This is the *book* side, not the taker's side: per ``PolymarketClient/price(tokenId:side:)``,
/// `.buy` returns the best bid and `.sell` the best ask.
public enum Side: String, Sendable { case buy = "BUY", sell = "SELL" }

/// One price level in an order book: a price and the total size resting at it.
public struct OrderLevel: Decodable, Sendable, Hashable {
    /// Price per share in USD, between 0 and 1 (equal to the implied probability).
    public let price: Double
    /// Number of shares available at `price`.
    public let size: Double

    enum CodingKeys: String, CodingKey { case price, size }

    /// Decodes a level whose price and size may be numbers or numeric strings.
    ///
    /// - Throws: `DecodingError.dataCorrupted` if either value is missing or non-numeric.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let p = c.lenientDouble(.price), let s = c.lenientDouble(.size) else {
            throw DecodingError.dataCorruptedError(forKey: .price, in: c,
                debugDescription: "Non-numeric order level")
        }
        price = p; size = s
    }
}

/// The CLOB order book for one outcome token.
///
/// Each outcome of a market has its own book. The Yes and No books of a binary market mirror
/// each other: a bid at 0.11 on Yes is an ask at 0.89 on No.
public struct OrderBook: Decodable, Sendable {
    /// Condition ID of the market this book belongs to.
    public let market: String?
    /// CLOB token ID of the outcome (JSON key `asset_id`).
    public let assetId: String?
    /// Resting buy orders, in API order. Use ``bestBid`` rather than relying on the order.
    public let bids: [OrderLevel]
    /// Resting sell orders, in API order. Use ``bestAsk`` rather than relying on the order.
    public let asks: [OrderLevel]
    /// Minimum price increment (JSON key `tick_size`).
    public let tickSize: Double?
    /// Minimum order size in shares (JSON key `min_order_size`).
    public let minOrderSize: Double?

    enum CodingKeys: String, CodingKey {
        case market, bids, asks
        case assetId = "asset_id"
        case tickSize = "tick_size"
        case minOrderSize = "min_order_size"
    }

    /// Decodes a book. A missing `bids` or `asks` list decodes as empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        market = try? c.decode(String.self, forKey: .market)
        assetId = try? c.decode(String.self, forKey: .assetId)
        bids = (try? c.decode([OrderLevel].self, forKey: .bids)) ?? []
        asks = (try? c.decode([OrderLevel].self, forKey: .asks)) ?? []
        tickSize = c.lenientDouble(.tickSize)
        minOrderSize = c.lenientDouble(.minOrderSize)
    }

    /// The highest bid, or `nil` if there are no bids.
    public var bestBid: OrderLevel? { bids.max { $0.price < $1.price } }
    /// The lowest ask, or `nil` if there are no asks.
    public var bestAsk: OrderLevel? { asks.min { $0.price < $1.price } }
    /// Best ask minus best bid, or `nil` if either side of the book is empty.
    public var spread: Double? {
        guard let b = bestBid, let a = bestAsk else { return nil }
        return a.price - b.price
    }
}

/// One point of a price time series.
public struct PricePoint: Decodable, Sendable, Hashable {
    /// Time of the sample (JSON key `t`, Unix seconds).
    public let timestamp: Date
    /// Price at that time, between 0 and 1 (JSON key `p`).
    public let price: Double

    enum CodingKeys: String, CodingKey { case t, p }

    /// Decodes a point from the CLOB `{ "t": <unix seconds>, "p": <price> }` shape.
    ///
    /// - Throws: If `t` or `p` is missing or not a number.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .t))
        price = try c.decode(Double.self, forKey: .p)
    }
}

/// Time window for a price-history request. Raw values are what the CLOB API expects.
public enum HistoryInterval: String, Sendable {
    /// The last hour.
    case oneHour = "1h"
    /// The last six hours.
    case sixHours = "6h"
    /// The last day.
    case oneDay = "1d"
    /// The last week.
    case oneWeek = "1w"
    /// The market's entire history.
    case max = "max"
}

// MARK: - Query options

/// Filter and paging options for listing markets.
///
/// The defaults give the 20 most active open markets by volume. Set `active` or `closed` to
/// `nil` to leave that filter out of the request.
public struct MarketQuery: Sendable {
    /// Maximum number of markets to return. Default 20.
    public var limit = 20
    /// Number of markets to skip, for paging. Default 0.
    public var offset = 0
    /// Only active markets when `true`, only inactive when `false`, no filter when `nil`.
    /// Default `true`.
    public var active: Bool? = true
    /// Only closed markets when `true`, only open when `false`, no filter when `nil`.
    /// Default `false`.
    public var closed: Bool? = false
    /// Gamma field to sort by, e.g. `"volumeNum"` (the default) or `"liquidityNum"`.
    /// `nil` uses the API's own order.
    public var order: String? = "volumeNum"
    /// Sort ascending when `true`. Default `false` (largest first).
    public var ascending = false
    /// Restrict the result to the market with this slug.
    public var slug: String?
    /// Creates a query with the default values above.
    public init() {}
}

/// Errors thrown by ``PolymarketClient``.
public enum PolymarketError: Error, LocalizedError, Sendable {
    /// The server answered with a non-success HTTP status. `body` is the response text.
    case http(status: Int, body: String)
    /// The requested market, event or token does not exist. The payload describes what was looked up.
    case notFound(String)
    /// The response was not a valid HTTP response or could not be interpreted.
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .http(let s, let b): "HTTP \(s): \(b)"
        case .notFound(let w): "Not found: \(w)"
        case .invalidResponse: "Invalid response from Polymarket"
        }
    }
}

// MARK: - Depth helpers

extension OrderBook {
    /// Human-readable depth: bids high→low and asks low→high, each level with its size and
    /// cumulative size, limited to `levels` per side.
    public func depthDescription(levels: Int) -> String {
        func side(_ ls: [OrderLevel]) -> String {
            var cum = 0.0
            let rows = ls.prefix(levels).map { l -> String in
                cum += l.size
                return "  \(l.price) x\(l.size)  (cum \(String(format: "%.2f", cum)))"
            }
            return rows.isEmpty ? "  –" : rows.joined(separator: "\n")
        }
        let sortedBids = bids.sorted { $0.price > $1.price }
        let sortedAsks = asks.sorted { $0.price < $1.price }
        let tick = tickSize.map { String($0) } ?? "–"
        let minSize = minOrderSize.map { String($0) } ?? "–"
        let spreadText = spread.map { String(format: "%.4f", $0) } ?? "–"
        return "token \(assetId ?? "?")  tick \(tick)  min size \(minSize)  spread \(spreadText)\n"
            + "BIDS (\(bids.count) levels)\n\(side(sortedBids))\nASKS (\(asks.count) levels)\n\(side(sortedAsks))"
    }
}

/// Sums of best asks and best bids across the Yes books of one event, for the
/// "outcomes don't add up to 100%" check.
public struct BookSums: Sendable {
    public let askSum: Double
    public let bidSum: Double
    /// Number of markets expected (including those with no book).
    public let expected: Int
    /// `true` only if every expected market has both a best bid and a best ask.
    public let complete: Bool

    public init(books: [OrderBook], expected: Int) {
        let asks = books.compactMap { $0.bestAsk?.price }
        let bids = books.compactMap { $0.bestBid?.price }
        askSum = asks.reduce(0, +); bidSum = bids.reduce(0, +)
        self.expected = expected
        complete = asks.count == expected && bids.count == expected
    }

    public var summary: String {
        "Yes best asks sum \(String(format: "%.4f", askSum)), best bids sum \(String(format: "%.4f", bidSum)) over \(expected) markets"
            + (complete ? "" : " (some sides empty; sums incomplete)")
            + ". Only meaningful for mutually exclusive, exhaustive (neg-risk) events; asks < 1 or bids > 1 may be an arbitrage before fees and size limits."
    }
}
