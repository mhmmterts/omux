import AppKit
import SwiftTerm
import XCTest
@testable import omux

/// The parts of the window's furniture that are a choice rather than a default: how soon the
/// project rail opens under the pointer, how far a wheel notch moves a terminal, and whether a
/// terminal carries a scrollbar you can drag.
final class ChromeAffordanceTests: XCTestCase {
    /// The rail used to wait 1.2s, long enough to read as a stall.
    func testTheRailOpensWithoutAWait() {
        XCTAssertLessThanOrEqual(ProjectRail.hoverOpenDelay, 0.2,
                                 "a rest this long on the rail reads as the window hanging")
        XCTAssertGreaterThan(ProjectRail.hoverOpenDelay, 0,
                             "with no delay at all the rail opens when the pointer merely crosses it")
    }

    @MainActor
    func testATerminalScrollsAWheelNotchFurtherThanOneLine() {
        let term = TermView(tabID: UUID())
        XCTAssertGreaterThan(term.scrollSensitivity, 1.0,
                             "SwiftTerm's default of 1.0 moves about a line per notch: a session crawls")
    }

    /// SwiftTerm's default `.overlay` scroller only appears while the wheel is moving, so there
    /// is nothing to grab to get from one end of a long session to the other.
    @MainActor
    func testATerminalKeepsAScrollbarYouCanDrag() {
        let term = TermView(tabID: UUID())
        XCTAssertEqual(term.scrollerStyle, .legacy)
        let scrollers = term.subviews.compactMap { $0 as? NSScroller }
        XCTAssertFalse(scrollers.isEmpty, "the scrollbar should be a subview of the terminal")
        XCTAssertFalse(scrollers.contains { $0.isHidden },
                       "a legacy scrollbar stays on screen rather than fading out")
    }
}

/// What the terminal's scrollbar can and cannot reach. SwiftTerm enables the knob only for the
/// normal buffer: the alternate screen a full-screen program switches to has no scrollback at
/// all, and the program scrolls its own view instead.
final class TerminalScrollbarReachTests: XCTestCase {
    @MainActor
    private func terminal(fedLines count: Int) -> TermView {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let text = (1...count).map { "line \($0)\r\n" }.joined()
        term.feed(byteArray: Array(text.utf8)[...])
        return term
    }

    @MainActor
    func testOutputPastTheScreenMakesTheTerminalScrollable() {
        let term = terminal(fedLines: 400)
        XCTAssertTrue(term.canScroll, "400 lines on a 25-row screen have to leave scrollback")
        XCTAssertLessThan(term.scrollThumbsize, 0.5, "the knob should be small against that much output")
    }

    @MainActor
    func testTheAlternateScreenHasNothingToScroll() {
        let term = terminal(fedLines: 400)
        // What a full-screen program sends when it takes over the screen.
        term.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
        XCTAssertFalse(term.canScroll,
                       "the alternate screen keeps no scrollback, so a scrollbar has nothing to move")
        XCTAssertEqual(term.scrollThumbsize, 0)
        // Leaving it restores the scrollback that was there before.
        term.feed(byteArray: Array("\u{1b}[?1049l".utf8)[...])
        XCTAssertTrue(term.canScroll)
    }
}
