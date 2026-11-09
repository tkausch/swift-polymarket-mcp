import Foundation
import PolymarketAdapter

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Read-only Polymarket tools.
// All logic lives in PolymarketTools; this file only does stdin/stdout.
// Logs go to stderr only; stdout is reserved for protocol messages.

let tools = PolymarketTools()

func send(_ obj: JSON) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
          var s = String(data: d, encoding: .utf8) else { return }
    s.append("\n")
    FileHandle.standardOutput.write(Data(s.utf8))
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let d = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: d) as? JSON else { continue }
    if let response = await tools.handle(msg) { send(response) }
}
