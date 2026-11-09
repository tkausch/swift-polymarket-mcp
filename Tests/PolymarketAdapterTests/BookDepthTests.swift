import Testing
import Foundation
@testable import PolymarketAdapter

private func book(_ json: String) throws -> OrderBook {
    try JSONDecoder().decode(OrderBook.self, from: Data(json.utf8))
}

extension ClientTests {
    @Test func orderBookGetsBookWithTokenId() async throws {
        StubProtocol.reset { _ in
            .init(body: #"{"asset_id":"tok","bids":[{"price":"0.4","size":"10"}],"asks":[{"price":"0.5","size":"5"}],"tick_size":"0.01","min_order_size":"5"}"#)
        }
        let b = try await stubbedClient().orderBook(tokenId: "tok")
        let req = try #require(StubProtocol.requests.first)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/book")
        #expect(req.url?.query == "token_id=tok")
        #expect(b.tickSize == 0.01 && b.minOrderSize == 5)
        #expect(b.spread.map { abs($0 - 0.1) < 1e-9 } == true)
    }

    @Test func orderBooksOmitsUnknownTokens() async throws {
        StubProtocol.reset { _ in .init(body: #"[{"asset_id":"a","bids":[],"asks":[]}]"#) }
        let books = try await stubbedClient().orderBooks(tokenIds: ["a", "ghost"])
        #expect(books.keys.sorted() == ["a"])
    }

    @Test func depthSortsLevelsAndAccumulatesSize() throws {
        // API order is deliberately not sorted.
        let b = try book(#"{"asset_id":"t","bids":[{"price":"0.1","size":"5"},{"price":"0.3","size":"2"},{"price":"0.2","size":"4"}],"asks":[{"price":"0.9","size":"1"},{"price":"0.5","size":"3"}]}"#)
        let text = b.depthDescription(levels: 2)
        let lines = text.split(separator: "\n").map(String.init)
        let i = try #require(lines.firstIndex(of: "BIDS (3 levels)"))
        #expect(lines[i + 1] == "  0.3 x2.0  (cum 2.00)")
        #expect(lines[i + 2] == "  0.2 x4.0  (cum 6.00)")
        #expect(lines[i + 3] == "ASKS (2 levels)")
        #expect(lines[i + 4] == "  0.5 x3.0  (cum 3.00)")
        #expect(lines[i + 5] == "  0.9 x1.0  (cum 4.00)")
        #expect(!text.contains("0.1 x5"))   // truncated by `levels`
    }

    @Test func emptySidesRenderDash() throws {
        let text = try book(#"{"bids":[],"asks":[]}"#).depthDescription(levels: 3)
        #expect(text.contains("BIDS (0 levels)\n  –"))
        #expect(text.contains("ASKS (0 levels)\n  –"))
        #expect(text.contains("spread –"))
    }

    @Test func sumsAddBestPricesAcrossBooks() throws {
        let a = try book(#"{"bids":[{"price":"0.3","size":"1"}],"asks":[{"price":"0.35","size":"1"},{"price":"0.4","size":"1"}]}"#)
        let b = try book(#"{"bids":[{"price":"0.6","size":"1"}],"asks":[{"price":"0.62","size":"1"}]}"#)
        let s = BookSums(books: [a, b], expected: 2)
        #expect(abs(s.askSum - 0.97) < 1e-9)
        #expect(abs(s.bidSum - 0.9) < 1e-9)
        #expect(s.complete)
        #expect(!s.summary.contains("incomplete"))
    }

    @Test func sumsFlagMissingBooksAndEmptySides() throws {
        let a = try book(#"{"bids":[],"asks":[{"price":"0.35","size":"1"}]}"#)
        let s = BookSums(books: [a], expected: 2)
        #expect(!s.complete)
        #expect(s.summary.contains("incomplete"))
    }
}
