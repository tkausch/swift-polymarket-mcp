import Testing
import Foundation
@testable import PolymarketAdapter

private let marketJSON = #"{"id":"1","question":"Will X?","slug":"will-x","outcomes":"[\"Yes\",\"No\"]","outcomePrices":"[\"0.6\",\"0.4\"]","clobTokenIds":"[\"t1\",\"t2\"]","volume":"1000","active":true,"closed":false}"#
private func eventMarket(_ n: Int) -> String {
    #"{"id":"\#(n)","question":"Cand \#(n)?","slug":"c\#(n)","outcomes":"[\"Yes\",\"No\"]","outcomePrices":"[\"0.5\",\"0.5\"]","clobTokenIds":"[\"y\#(n)\",\"n\#(n)\"]","active":true,"closed":false}"#
}
private func bookJSON(_ id: String, bid: String, ask: String) -> String {
    #"{"asset_id":"\#(id)","bids":[{"price":"\#(bid)","size":"10"}],"asks":[{"price":"\#(ask)","size":"20"}],"tick_size":"0.01","min_order_size":"5"}"#
}

/// Routes by path so one stub serves Gamma and CLOB.
private func route(_ req: URLRequest) -> StubProtocol.Response {
    let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    switch req.url!.path {
    case "/markets": return .init(body: "[\(marketJSON)]")
    case "/events":
        return .init(body: #"[{"id":"9","title":"Election","slug":"election","active":true,"closed":false,"markets":[\#(eventMarket(1)),\#(eventMarket(2))]}]"#)
    case "/public-search":
        return .init(body: #"{"events":[{"id":"9","title":"Election","active":true,"closed":false,"markets":[\#(marketJSON)]}]}"#)
    case "/book":
        let t = q.first { $0.name == "token_id" }?.value ?? ""
        return .init(body: bookJSON(t, bid: "0.4", ask: "0.5"))
    case "/books":
        let ids = (try? JSONDecoder().decode([[String: String]].self, from: req.httpBody ?? Data()))?.compactMap { $0["token_id"] } ?? []
        // Pretend "y2" is unknown to the CLOB.
        return .init(body: "[" + ids.filter { $0 != "y2" }.map { bookJSON($0, bid: "0.3", ask: "0.4") }.joined(separator: ",") + "]")
    case "/prices-history": return .init(body: #"{"history":[{"t":1700000000,"p":0.55}]}"#)
    default: return .init(status: 404, body: "")
    }
}

private func tools() -> PolymarketTools { PolymarketTools(client: stubbedClient()) }

extension ClientTests {
    @Test func toolDefinitionsAreWellFormed() {
        let names = PolymarketTools.definitions.compactMap { $0["name"] as? String }
        #expect(names == ["top_markets", "search_markets", "get_market", "order_book",
                          "book_depth", "order_books", "price_history"])
        for d in PolymarketTools.definitions {
            #expect(d["description"] is String)
            #expect((d["inputSchema"] as? JSON)?["type"] as? String == "object")
        }
    }

    @Test func topMarketsCapsLimitAndFormatsOdds() async throws {
        StubProtocol.reset(route)
        let out = try await tools().call("top_markets", ["limit": 500])
        #expect(out.contains("Will X?") && out.contains("Yes 60.0%") && out.contains("[will-x]"))
        #expect(StubProtocol.requests.first?.url?.query?.contains("limit=50") == true)
    }

    @Test func searchMarketsGroupsByEvent() async throws {
        StubProtocol.reset(route)
        let out = try await tools().call("search_markets", ["query": "x"])
        #expect(out.hasPrefix("# Election\n• Will X?"))
        await #expect(throws: ToolError.self) { _ = try await tools().call("search_markets", [:]) }
    }

    @Test func getMarketListsTokens() async throws {
        StubProtocol.reset(route)
        let out = try await tools().call("get_market", ["slug": "will-x"])
        #expect(out.contains("No: t2") && out.contains("Yes: t1"))
    }

    @Test func orderBookShowsBestBidAskPerOutcome() async throws {
        StubProtocol.reset(route)
        let out = try await tools().call("order_book", ["slug": "will-x"])
        #expect(out.contains("Yes: bid 0.4 x10.0 / ask 0.5 x20.0  spread 0.1000"))
        #expect(out.contains("No:"))
    }

    @Test func bookDepthByTokenIdAndBySlugOutcome() async throws {
        StubProtocol.reset(route)
        let direct = try await tools().call("book_depth", ["token_id": "t1"])
        #expect(direct.contains("token t1") && direct.contains("BIDS (1 levels)"))
        let bySlug = try await tools().call("book_depth", ["slug": "will-x", "outcome": "no", "levels": 1])
        #expect(bySlug.contains("token t2"))
        await #expect(throws: ToolError.self) {
            _ = try await tools().call("book_depth", ["slug": "will-x", "outcome": "Maybe"])
        }
        await #expect(throws: ToolError.self) { _ = try await tools().call("book_depth", [:]) }
    }

    @Test func orderBooksByTokenIdsReportsMissing() async throws {
        StubProtocol.reset(route)
        let out = try await tools().call("order_books", ["token_ids": ["y1", "y2"]])
        #expect(out.contains("== y1") && out.contains("No book for: y2"))
        #expect(!out.contains("sum"))   // no event scan
    }

    @Test func orderBooksEventScanSumsYesTokens() async throws {
        StubProtocol.reset(route)
        let out = try await tools().call("order_books", ["event_slug": "election"])
        #expect(out.contains("== Cand 1?"))
        #expect(out.contains("No book for: y2"))
        #expect(out.contains("over 2 markets (some sides empty; sums incomplete)"))
        let req = try #require(StubProtocol.requests.first { $0.url?.path == "/books" })
        #expect(String(decoding: req.httpBody ?? Data(), as: UTF8.self) == #"[{"token_id":"y1"},{"token_id":"y2"}]"#)
    }

    @Test func orderBooksValidatesInput() async throws {
        StubProtocol.reset(route)
        await #expect(throws: ToolError.self) { _ = try await tools().call("order_books", [:]) }
        let many = (0..<501).map(String.init)
        await #expect(throws: ToolError.self) { _ = try await tools().call("order_books", ["token_ids": many]) }
    }

    @Test func priceHistoryResolvesOutcome() async throws {
        StubProtocol.reset(route)
        let out = try await tools().call("price_history", ["slug": "will-x", "outcome": "yes"])
        #expect(out.hasSuffix("55.0%"))
        let h = try #require(StubProtocol.requests.first { $0.url?.path == "/prices-history" })
        #expect(h.url?.query?.contains("market=t1") == true)
    }

    @Test func unknownToolThrows() async {
        await #expect(throws: ToolError.self) { _ = try await tools().call("nope", [:]) }
    }

    @Test func jsonRpcInitializeListCallAndErrors() async throws {
        StubProtocol.reset(route)
        let t = tools()
        let initResp = try #require(await t.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                  "params": ["protocolVersion": "2024-11-05"]]))
        #expect((initResp["result"] as? JSON)?["protocolVersion"] as? String == "2024-11-05")
        let list = try #require(await t.handle(["id": 2, "method": "tools/list"]))
        #expect(((list["result"] as? JSON)?["tools"] as? [JSON])?.count == 7)
        let call = try #require(await t.handle(["id": 3, "method": "tools/call",
            "params": ["name": "book_depth", "arguments": ["token_id": "t1"]]]))
        #expect(((call["result"] as? JSON)?["isError"]) == nil)
        let bad = try #require(await t.handle(["id": 4, "method": "tools/call", "params": ["name": "nope"]]))
        #expect((bad["result"] as? JSON)?["isError"] as? Bool == true)
        let unknown = try #require(await t.handle(["id": 5, "method": "wat"]))
        #expect(((unknown["error"] as? JSON)?["code"] as? Int) == -32601)
        #expect(await t.handle(["method": "notifications/initialized"]) == nil)
        #expect(await t.handle(["id": 6]) == nil)
    }
}
