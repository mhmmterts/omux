import XCTest
@testable import omux

final class SessionCacheNoteTests: XCTestCase {
    private func entry(tokens: Int, at: String, ttl: String = "1h") -> String {
        let usage: [String: Any] = ["input_tokens": 2, "cache_read_input_tokens": tokens - 2,
                                    "cache_creation_input_tokens": 0, "output_tokens": 120]
        let object: [String: Any] = ["type": "assistant", "timestamp": at, "promptCacheRequested": ttl,
                                     "message": ["model": "claude-opus-5", "usage": usage]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func reading(_ tokens: Int, _ at: Date, ttl: String? = "1h") -> SessionCacheNote.Reading {
        .init(contextTokens: tokens, at: at, ttl: ttl)
    }

    private let noon = ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z")!

    func testAWarmCacheSaysNothing() {
        let held = reading(711_000, noon)
        XCTAssertNil(SessionCacheNote.note(for: held, now: noon.addingTimeInterval(59 * 60)),
                     "within the hour the conversation is still cached: nothing to warn about")
        XCTAssertEqual(SessionCacheNote.state(for: held, now: noon.addingTimeInterval(59 * 60)),
                       .warm(minutesLeft: 1))
        // The hour is the session's own: a turn that asked for five minutes gets five.
        let brief = reading(711_000, noon, ttl: "5m")
        XCTAssertNotNil(SessionCacheNote.note(for: brief, now: noon.addingTimeInterval(6 * 60)))
    }

    func testAColdCacheSaysWhatTheNextMessageCosts() {
        let note = SessionCacheNote.note(for: reading(711_000, noon), now: noon.addingTimeInterval(3 * 86_400 + 23 * 3600))
        XCTAssertEqual(note, "Idle 3d 23h. The prompt cache has likely expired, so your next message will re-cache about 711k tokens.")
    }

    func testASessionWithNothingToGoOnSaysNothing() {
        XCTAssertNil(SessionCacheNote.note(for: nil, now: noon))
        XCTAssertEqual(SessionCacheNote.state(for: nil, now: noon), .unknown)
        // A transcript that doesn't record which cache the turn asked for says nothing either.
        XCTAssertNil(SessionCacheNote.note(for: reading(711_000, noon.addingTimeInterval(-86_400), ttl: nil), now: noon))
    }

    func testAConversationThatWasSentButNotCountedStillWarns() {
        let note = SessionCacheNote.note(for: reading(0, noon), now: noon.addingTimeInterval(2 * 3600))
        XCTAssertEqual(note, "Idle 2h 0m. The prompt cache has likely expired, so your next message will re-cache the conversation.")
    }

    func testHowLongItHasBeenIdle() {
        XCTAssertEqual(SessionCacheNote.idleText(14 * 60), "14m")
        XCTAssertEqual(SessionCacheNote.idleText(2 * 3600 + 5 * 60), "2h 5m")
        XCTAssertEqual(SessionCacheNote.idleText(3 * 3600), "3h 0m")
        XCTAssertEqual(SessionCacheNote.idleText(3 * 86_400 + 23 * 3600), "3d 23h")
        XCTAssertEqual(SessionCacheNote.idleText(2 * 86_400), "2d 0h")
    }

    func testHowTheTokensAreCounted() {
        XCTAssertEqual(SessionCacheNote.tokenText(711_000), "711k")
        XCTAssertEqual(SessionCacheNote.tokenText(222_000), "222k")
        XCTAssertEqual(SessionCacheNote.tokenText(1_240_000), "1.2M")
        XCTAssertEqual(SessionCacheNote.tokenText(711_600), "712k", "rounded, not truncated")
        XCTAssertEqual(SessionCacheNote.tokenText(640), "640")
    }

    func testItReadsTheLastTurnFromATranscript() {
        let tail = [entry(tokens: 100_000, at: "2026-11-20T09:00:00.000Z"),
                    entry(tokens: 222_000, at: "2026-11-21T10:30:00.000Z")].joined(separator: "\n")
        guard let reading = SessionCacheNote.reading(inTranscriptTail: tail) else {
            return XCTFail("the transcript's last turn should be readable")
        }
        XCTAssertEqual(reading.contextTokens, 222_000, "the conversation as the model last saw it")
        XCTAssertEqual(reading.at.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-11-21T10:30:00Z")!.timeIntervalSince1970, accuracy: 1)
    }

    func testATailThatStartsMidLineIsStillRead() {
        let whole = entry(tokens: 222_000, at: "2026-11-21T10:30:00.000Z")
        let tail = "ken\":1234}}\n" + whole      // what a seek into the middle of a file gives
        XCTAssertEqual(SessionCacheNote.reading(inTranscriptTail: tail)?.contextTokens, 222_000)
    }

    func testTurnsWithoutUsageAreSkipped() {
        let tail = [entry(tokens: 222_000, at: "2026-11-21T10:30:00.000Z"),
                    "{\"type\":\"user\",\"message\":{\"content\":\"merhaba\"}}",
                    "{\"type\":\"api-request\"}"].joined(separator: "\n")
        XCTAssertEqual(SessionCacheNote.reading(inTranscriptTail: tail)?.contextTokens, 222_000,
                       "the last turn that was actually sent to the model is the one that counts")
    }

    func testItReadsOnlyTheEndOfALongFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID()).jsonl")
        let padding = (1...4000).map { _ in entry(tokens: 1_000, at: "2026-11-01T09:00:00.000Z") }.joined(separator: "\n")
        try (padding + "\n" + entry(tokens: 711_000, at: "2026-11-21T10:30:00.000Z") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int, 1 << 19,
                             "the file has to be larger than the tail that gets read")
        XCTAssertEqual(SessionCacheNote.reading(ofTranscriptAt: url)?.contextTokens, 711_000)
    }
}
