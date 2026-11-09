import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PolymarketAdapter

/// Serves canned responses so client tests never touch the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Response { var status = 200; var body = "[]" }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        // URLProtocol receives bodies as streams; capture them for assertions.
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            req.httpBody = data
        }
        Self.requests.append(req)
        let r = Self.handler?(req) ?? Response()
        let http = HTTPURLResponse(url: req.url!, statusCode: r.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset(_ h: @escaping @Sendable (URLRequest) -> Response) { requests = []; handler = h }
}

func stubbedClient(maxRetries: Int = 2) -> PolymarketClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return PolymarketClient(session: URLSession(configuration: cfg), maxRetries: maxRetries)
}

@Suite(.serialized) struct ClientTests {
    @Test func decodesNewMarketFields() throws {
        let json = #"{"id":1,"negRisk":true,"enableOrderBook":true,"acceptingOrders":true,"orderPriceMinTickSize":0.001}"#
        let m = try JSONDecoder().decode(Market.self, from: Data(json.utf8))
        #expect(m.negRisk && m.enableOrderBook && m.acceptingOrders)
        #expect(m.orderPriceMinTickSize == 0.001)
        let bare = try JSONDecoder().decode(Market.self, from: Data(#"{"id":"2"}"#.utf8))
        #expect(!bare.negRisk && bare.orderPriceMinTickSize == nil)
    }

    @Test func orderBooksPostsBatchAndKeysByTokenId() async throws {
        StubProtocol.reset { _ in
            .init(body: #"[{"asset_id":"a","bids":[{"price":"0.4","size":"1"}],"asks":[]},{"asset_id":"b","bids":[],"asks":[{"price":"0.6","size":"2"}]}]"#)
        }
        let books = try await stubbedClient().orderBooks(tokenIds: ["a", "b"])
        #expect(books["a"]?.bestBid?.price == 0.4)
        #expect(books["b"]?.bestAsk?.price == 0.6)
        let req = try #require(StubProtocol.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/books")
        #expect(String(decoding: req.httpBody ?? Data(), as: UTF8.self) == #"[{"token_id":"a"},{"token_id":"b"}]"#)
    }

    @Test func orderBooksSplitsIntoChunks() async throws {
        StubProtocol.reset { _ in .init() }
        _ = try await stubbedClient().orderBooks(tokenIds: ["1", "2", "3"], chunkSize: 2)
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func allMarketsPagesUntilShortPage() async throws {
        StubProtocol.reset { req in
            let offset = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value
            switch offset {
            case "0": return .init(body: #"[{"id":"1"},{"id":"2"}]"#)
            case "2": return .init(body: #"[{"id":"3"}]"#)
            default: return .init()
            }
        }
        var q = MarketQuery(); q.limit = 2
        let ms = try await stubbedClient().allMarkets(q)
        #expect(ms.map(\.id) == ["1", "2", "3"])
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func retriesOn429ThenSucceeds() async throws {
        let counter = Counter()
        StubProtocol.reset { _ in
            counter.next() == 1 ? .init(status: 429, body: "slow down") : .init(body: #"[{"id":"1"}]"#)
        }
        let ms = try await stubbedClient().markets()
        #expect(ms.count == 1)
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func notFoundForMissingSlug() async throws {
        StubProtocol.reset { _ in .init() }
        await #expect(throws: PolymarketError.self) {
            _ = try await stubbedClient().market(slug: "nope")
        }
    }

    @Test func httpErrorCarriesStatusAndBody() async throws {
        StubProtocol.reset { _ in .init(status: 400, body: "bad") }
        do {
            _ = try await stubbedClient().markets()
            Issue.record("expected throw")
        } catch PolymarketError.http(let status, let body) {
            #expect(status == 400 && body == "bad")
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
