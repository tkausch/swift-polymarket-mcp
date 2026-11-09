import Testing
import Foundation
@testable import PolymarketAdapter

@Test func decodesGammaMarketWithStringEncodedArrays() throws {
    let json = #"""
    {"id":"123","question":"Will X happen?","outcomes":"[\"Yes\",\"No\"]",
     "outcomePrices":"[\"0.62\",\"0.38\"]","clobTokenIds":"[\"t1\",\"t2\"]",
     "volume":"1500.5","active":true,"closed":false,"endDate":"2026-12-31T00:00:00Z"}
    """#
    let m = try JSONDecoder().decode(Market.self, from: Data(json.utf8))
    #expect(m.outcomes == ["Yes", "No"])
    #expect(m.pricesByOutcome["Yes"] == 0.62)
    #expect(m.tokenIdsByOutcome["No"] == "t2")
    #expect(m.volume == 1500.5)
    #expect(m.endDateParsed != nil)
}

@Test func orderBookBestPrices() throws {
    let json = #"""
    {"asset_id":"t1","bids":[{"price":"0.40","size":"10"},{"price":"0.45","size":"5"}],
     "asks":[{"price":"0.50","size":"7"},{"price":"0.48","size":"3"}],"tick_size":"0.01"}
    """#
    let b = try JSONDecoder().decode(OrderBook.self, from: Data(json.utf8))
    #expect(b.bestBid?.price == 0.45)
    #expect(b.bestAsk?.price == 0.48)
    #expect(abs((b.spread ?? 0) - 0.03) < 1e-9)
}
