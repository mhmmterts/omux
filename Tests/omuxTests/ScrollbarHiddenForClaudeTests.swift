import XCTest
@testable import omux

/// Claude Code keeping its own full-screen layout draws its own Jump to bottom and never says
/// where in the conversation it is, so omux's knob beside it could only be a handle that tells
/// the reader nothing true. It is hidden there, and only there: vim and htop get to keep it.
@MainActor
final class ScrollbarHiddenForClaudeTests: XCTestCase {
    /// A session on the alternate screen, as a full-screen program leaves it.
    private func fullScreenSession() -> (TermView, TerminalScrollbar) {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 789, height: 500)
        let bar = TerminalScrollbar(term: term)
        bar.frame = NSRect(x: 789, y: 0, width: TerminalScrollbar.width, height: 500)
        // Switch to the alternate buffer.
        term.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
        return (term, bar)
    }

    func testItGoesAwayForAClaudeThatDrawsItsOwn() {
        let (_, bar) = fullScreenSession()
        bar.claudeDrawsItsOwn = { true }
        bar.refresh()
        XCTAssertTrue(bar.isHidden, "two scroll affordances for one conversation, one of them lying")
    }

    func testAnyOtherFullScreenProgramKeepsTheHandle() {
        let (_, bar) = fullScreenSession()
        bar.claudeDrawsItsOwn = { false }
        bar.refresh()
        XCTAssertFalse(bar.isHidden, "vim draws no scrollbar of its own, so this one is all there is")
    }

    /// The session is laid out around the strip, so hiding it has to give the width back.
    func testTheSessionTakesTheWidthBack() {
        let container = TerminalHost.Container(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let term = TermView(tabID: UUID())
        let bar = TerminalScrollbar(term: term)
        container.addSubview(term)
        container.addSubview(bar)
        bar.claudeDrawsItsOwn = { false }
        term.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
        bar.refresh()
        container.place()
        XCTAssertEqual(term.frame.width, 800 - TerminalScrollbar.width, "the knob is there and takes its strip")

        bar.claudeDrawsItsOwn = { true }
        bar.refresh()
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(term.frame.width, 800, "no knob, no strip of empty background beside the session")
    }

    func testSwitchingTheSettingBringsItBack() {
        let (_, bar) = fullScreenSession()
        var fullScreen = true
        bar.claudeDrawsItsOwn = { fullScreen }
        bar.refresh()
        XCTAssertTrue(bar.isHidden)
        fullScreen = false
        bar.refresh()
        XCTAssertFalse(bar.isHidden, "turning the layout off hands the conversation back to the terminal")
    }
}
