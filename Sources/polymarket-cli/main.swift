import Foundation
import PolymarketAdapter

let client = PolymarketClient()
let args = Array(CommandLine.arguments.dropFirst())

func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }

func show(_ m: Market) {
    let odds = zip(m.outcomes, m.outcomePrices).map { "\($0) \(pct($1))" }.joined(separator: " | ")
    print("• \(m.question)\n  \(odds)  vol $\(Int(m.volume ?? 0))  [\(m.slug ?? m.id)]")
}

do {
    switch args.first {
    case "top":
        try await client.markets().forEach(show)
    case "search" where args.count > 1:
        for e in try await client.search(args[1...].joined(separator: " ")) {
            print("# \(e.title)")
            e.markets.prefix(5).forEach(show)
        }
    case "book" where args.count > 1:
        let m = try await client.market(slug: args[1])
        for (outcome, token) in m.tokenIdsByOutcome.sorted(by: { $0.key < $1.key }) {
            let b = try await client.orderBook(tokenId: token)
            print("\(outcome): bid \(b.bestBid?.price ?? .nan) / ask \(b.bestAsk?.price ?? .nan)  spread \(String(format: "%.4f", b.spread ?? .nan))")
        }
    default:
        print("usage: polymarket-cli top | search <query> | book <market-slug>")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
