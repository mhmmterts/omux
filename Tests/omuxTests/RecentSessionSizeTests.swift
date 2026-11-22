import XCTest
@testable import omux

/// A row in Open Recent Conversation is named after the first thing typed in it, which says
/// nothing about how large the conversation grew. The size does.
final class RecentSessionSizeTests: XCTestCase {
    private func transcript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func turn(_ tokens: Int) -> String {
        let usage: [String: Any] = ["input_tokens": 2, "cache_read_input_tokens": tokens - 2,
                                    "cache_creation_input_tokens": 0, "output_tokens": 80]
        let object: [String: Any] = ["type": "assistant", "timestamp": "2026-11-22T14:02:00.000Z",
                                     "promptCacheRequested": "1h", "message": ["usage": usage]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testEachConversationIsMeasuredAtItsLastTurn() throws {
        let heavy = UUID(), light = UUID(), silent = UUID(), missing = UUID()
        let files = [heavy: try transcript([turn(120_000), turn(615_700)]),
                     light: try transcript([turn(12_000)]),
                     silent: try transcript([#"{"type":"user","message":{"content":"hi"}}"#])]
        defer { for url in files.values { try? FileManager.default.removeItem(at: url) } }
        let tokens = RecentSessionSize.tokens(of: [heavy, light, silent, missing], transcript: { files[$0] })
        // The last turn is the conversation as it stands, not the one it started as.
        XCTAssertEqual(tokens[heavy], 615_700)
        XCTAssertEqual(tokens[light], 12_000)
        // Nothing sent yet, and no transcript at all: no figure rather than a wrong one.
        XCTAssertNil(tokens[silent])
        XCTAssertNil(tokens[missing])
    }

    /// The row shows it in the words the agent's own warning uses.
    func testTheFigureReadsAsTheWarningDoes() {
        XCTAssertEqual(SessionCacheNote.tokenText(615_700), "616k")
        XCTAssertEqual(SessionCacheNote.tokenText(1_240_000), "1.2M")
    }
}
