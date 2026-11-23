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

    // MARK: - Finding the conversation when the process tree cannot say

    private func record(_ pid: Int32, _ session: String, cwd: String? = nil, at: Double = 0,
                        spare: Bool = false) -> Store.ClaudeSessionRecord {
        Store.ClaudeSessionRecord(pid: pid, session: session, cwd: cwd, updatedAt: at, spare: spare)
    }

    /// Every process in these tests is running unless a test says otherwise.
    private func live(_ records: [Store.ClaudeSessionRecord], descendants: Set<Int32> = [],
                      cwd: String? = "/work", pinnedElsewhere: Set<String> = [],
                      running: @escaping (Int32) -> Bool = { _ in true }) -> [String] {
        Store.liveClaudeSessionIDs(records: records, descendants: descendants, cwd: cwd,
                                   pinnedElsewhere: pinnedElsewhere, isRunning: running)
    }

    func testASpareTheDaemonHasNotHandedOutIsNotAConversation() {
        let records = [record(10, "unclaimed-spare", cwd: "/work", at: 300, spare: true),
                       record(11, "the-real-one", cwd: "/work", at: 200)]
        XCTAssertEqual(live(records), ["the-real-one"], "a spare is newer and still not the answer")
        XCTAssertEqual(live(records, descendants: [10, 11]), ["the-real-one"],
                       "not even when it runs under the session's own shell")
    }

    func testTheRecordOfAProcessThatHasGoneIsIgnored() {
        let records = [record(10, "left-behind", cwd: "/work", at: 300),
                       record(11, "still-here", cwd: "/work", at: 200)]
        XCTAssertEqual(live(records, running: { $0 != 10 }), ["still-here"])
        XCTAssertEqual(live(records, descendants: [10], running: { $0 != 10 }), ["still-here"],
                       "a dead process under the shell doesn't shadow a living one")
    }

    func testAClaudeUnderTheSessionsOwnShellIsTheAnswer() {
        let records = [record(10, "under-the-shell", cwd: "/work", at: 1),
                       record(99, "someone-elses", cwd: "/work", at: 9)]
        XCTAssertEqual(live(records, descendants: [10]),
                       ["under-the-shell"], "the process tree is certain; a newer record elsewhere doesn't outrank it")
    }

    /// Claude Code hands the terminal a process the daemon spawned, which belongs to launchd:
    /// nothing under the shell reports a conversation, and the tab used to stay pinned to the one
    /// it started on, so a restart reopened a conversation that had stopped growing.
    func testWithNothingUnderTheShellTheFoldersNewestRecordAnswers() {
        let records = [record(10, "older", cwd: "/work", at: 100),
                       record(11, "newest", cwd: "/work", at: 300),
                       record(12, "middle", cwd: "/work", at: 200),
                       record(13, "other-folder", cwd: "/elsewhere", at: 999)]
        XCTAssertEqual(live(records), ["newest", "middle", "older"], "the session's own folder, newest first")
    }

    func testAConversationAnotherTabIsPinnedToIsLeftAlone() {
        let records = [record(10, "another-tabs", cwd: "/work", at: 300),
                       record(11, "mine", cwd: "/work", at: 200)]
        XCTAssertEqual(live(records, pinnedElsewhere: ["another-tabs"]),
                       ["mine"], "two sessions in one folder don't steal each other's conversation")
    }

    func testWithoutAFolderThereIsNothingToGoOn() {
        let records = [record(10, "somewhere", cwd: "/work", at: 1)]
        XCTAssertEqual(live(records, cwd: nil), [])
        XCTAssertEqual(live(records, cwd: ""), [])
        XCTAssertEqual(live([], descendants: [10]), [])
    }

    /// Reading what Claude Code actually writes, rather than a shape we assumed.
    func testTheRecordsAreReadFromClaudeCodesOwnFiles() throws {
        let folder = NSTemporaryDirectory() + "sessions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let real = """
        {"pid":10447,"sessionId":"AA3FF073-7B83-4E53-8497-4E2424","cwd":"/Users/me/project",\
        "kind":"bg","updatedAt":1795475397943,"status":"busy"}
        """.replacingOccurrences(of: "\\\n", with: "")
        try real.write(toFile: folder + "/10447.json", atomically: true, encoding: .utf8)
        try "not json".write(toFile: folder + "/broken.json", atomically: true, encoding: .utf8)
        try "{}".write(toFile: folder + "/12.json", atomically: true, encoding: .utf8)
        try "ignored".write(toFile: folder + "/10447.key", atomically: true, encoding: .utf8)

        let records = Store.claudeSessionRecords(in: folder)
        XCTAssertEqual(records.count, 1, "a record without a conversation, and anything unreadable, is skipped")
        XCTAssertEqual(records.first?.pid, 10447)
        XCTAssertEqual(records.first?.session, "aa3ff073-7b83-4e53-8497-4e2424", "ids compare in one case")
        XCTAssertEqual(records.first?.cwd, "/Users/me/project")
        XCTAssertEqual(records.first?.updatedAt, 1795475397943)
    }
}
