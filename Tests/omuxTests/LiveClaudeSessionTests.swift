import XCTest
@testable import omux

/// Claude Code's conversation id changes under a session — a /clear, "Start a new conversation"
/// at a cold resume, a `claude --continue` in the shell — and the tab has to follow it.
@MainActor
final class LiveClaudeSessionTests: XCTestCase {
    private let pinned = "55d1c5a6-6351-429e-8aee-3aa6d21471eb"
    private let cleared = "3df8eddf-4c5a-4c0b-8e1f-26d84bdd6353"

    private func effective(_ live: [String], have: Set<String>) -> String {
        Store.effectiveClaudeSession(pinned: pinned, live: live, hasTranscript: { have.contains($0) })
    }

    func testTheSessionFollowsTheRunningConversation() {
        // After a /clear the terminal is on a new conversation with a transcript of its own.
        XCTAssertEqual(effective([cleared], have: [pinned, cleared]), cleared)
        // Nothing running: the tab's own conversation is all there is to go on.
        XCTAssertEqual(effective([], have: [pinned]), pinned)
        // A conversation that has said nothing yet has no transcript, so there is nothing to
        // follow and nothing to measure: the tab stays where it is.
        XCTAssertEqual(effective([cleared], have: [pinned]), pinned)
        // A session already on its own conversation has nothing to adopt.
        XCTAssertEqual(effective([pinned], have: [pinned]), pinned)
    }

    /// The transcript the panel shows and the id the tab is pinned to are now the same answer.
    func testTheTranscriptIsTheRunningConversations() {
        let urls = [pinned, cleared].reduce(into: [String: URL]()) { $0[$1] = URL(fileURLWithPath: "/tmp/\($1).jsonl") }
        XCTAssertEqual(Store.claudeTranscriptURL(pinned: pinned, live: [cleared], lookup: { urls[$0] }),
                       urls[cleared])
        XCTAssertEqual(Store.claudeTranscriptURL(pinned: pinned, live: [cleared], lookup: { $0 == self.pinned ? urls[$0] : nil }),
                       urls[pinned])
    }

    /// Open Recent Conversation reuses a session only when it is on that conversation. A cleared
    /// session is still pinned to the old one until it ticks, and jumping to it would have shown
    /// a different conversation than the row that was clicked.
    func testAClearedSessionIsNotTheConversationItWasPinnedTo() {
        XCTAssertNotEqual(effective([cleared], have: [pinned, cleared]), pinned)
        XCTAssertEqual(effective([cleared], have: [pinned, cleared]), cleared)
    }
}
