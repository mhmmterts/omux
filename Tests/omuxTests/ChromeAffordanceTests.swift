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
        XCTAssertLessThanOrEqual(term.scrollSensitivity, 2.5,
                                 "and much past this a flick overshoots what you were reading")
    }

    /// SwiftTerm's own scroller never enables itself as output arrives, so omux leaves it in
    /// the style that reserves no width and draws its own: see TerminalScrollbarTests.
    @MainActor
    func testTheTerminalLeavesSwiftTermsOwnScrollerOutOfTheWay() {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let text = (1...400).map { "line \($0)\r\n" }.joined()
        term.feed(byteArray: Array(text.utf8)[...])
        XCTAssertEqual(term.scrollerStyle, .overlay, "the legacy style would reserve width for a knob it never draws")
        let scrollers = term.subviews.compactMap { $0 as? NSScroller }
        XCTAssertTrue(scrollers.allSatisfy { !$0.isEnabled },
                      "if SwiftTerm ever starts enabling its scroller, omux would be drawing two")
    }
}

/// The scrollbar omux draws for a terminal: it appears once there is scrollback, its knob is
/// sized by how much of the session fits on screen, and dragging it moves the terminal.
final class TerminalScrollbarTests: XCTestCase {
    @MainActor
    private func scrollbar(fedLines count: Int) -> (TermView, TerminalScrollbar) {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 789, height: 500)
        let bar = TerminalScrollbar(term: term)
        bar.frame = NSRect(x: 789, y: 0, width: TerminalScrollbar.width, height: 500)
        if count > 0 {
            let text = (1...count).map { "line \($0)\r\n" }.joined()
            term.feed(byteArray: Array(text.utf8)[...])
        }
        bar.refresh()
        return (term, bar)
    }

    @MainActor
    func testNothingToScrollShowsNoKnob() {
        let (_, bar) = scrollbar(fedLines: 0)
        XCTAssertTrue(bar.isHidden)
        XCTAssertNil(bar.knobRect())
    }

    @MainActor
    func testScrollbackGivesAKnobSizedByWhatFitsOnScreen() {
        let (term, bar) = scrollbar(fedLines: 400)
        XCTAssertFalse(bar.isHidden)
        guard let knob = bar.knobRect() else { return XCTFail("no knob to grab") }
        XCTAssertGreaterThanOrEqual(knob.height, 26, "a knob has to stay big enough to hit")
        XCTAssertLessThan(knob.height, bar.bounds.height / 2,
                          "400 lines against a 25-row screen is a small share of the session")
        // Pinned to the newest output, the knob sits at the bottom of its track.
        XCTAssertEqual(term.scrollPosition, 1, accuracy: 0.001)
        XCTAssertEqual(knob.maxY, bar.bounds.height - 2.5, accuracy: 0.5)
    }

    @MainActor
    func testDraggingTheKnobToTheTopReachesTheStartOfTheSession() {
        let (term, bar) = scrollbar(fedLines: 400)
        term.scroll(toPosition: 0)
        bar.refresh()
        XCTAssertEqual(term.scrollPosition, 0, accuracy: 0.001)
        guard let knob = bar.knobRect() else { return XCTFail("no knob to grab") }
        XCTAssertEqual(knob.minY, 2.5, accuracy: 0.5, "at the start of the session the knob is at the top")
        // And the first line written is the one on screen.
        XCTAssertTrue(term.lastLines(400).contains("line 1"), "the top of the scrollback is line 1")
    }

    @MainActor
    func testTheKnobFollowsTheTerminalBackToTheBottom() {
        let (term, bar) = scrollbar(fedLines: 400)
        term.scroll(toPosition: 0)
        bar.refresh()
        let top = bar.knobRect()?.minY
        term.scroll(toPosition: 1)
        bar.refresh()
        guard let top, let bottom = bar.knobRect()?.minY else { return XCTFail("no knob to follow") }
        XCTAssertGreaterThan(bottom, top, "the knob moves down as the terminal returns to its newest output")
    }
}

/// The scrollbar has to survive the way SwiftUI builds the pane: the container is created at
/// zero size, the views go in, and only then does it get its real size.
final class TerminalPaneLayoutTests: XCTestCase {
    @MainActor
    func testTheScrollbarTakesItsPlaceAfterTheContainerIsSized() {
        let term = TermView(tabID: UUID())
        let container = TerminalHost.Container(frame: .zero)
        container.addSubview(term)
        container.addSubview(TerminalScrollbar(term: term))

        // SwiftUI sets the frame itself and does not run a layout pass for it, so the views
        // have to find their places from the resize alone.
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        guard let bar = container.subviews.compactMap({ $0 as? TerminalScrollbar }).first else {
            return XCTFail("no scrollbar in the pane")
        }
        XCTAssertEqual(bar.frame.width, TerminalScrollbar.width)
        XCTAssertEqual(bar.frame.height, 600, "the scrollbar runs the height of the pane")
        XCTAssertEqual(bar.frame.maxX, 900, "it sits against the right edge")
        XCTAssertEqual(term.frame.width, 900 - TerminalScrollbar.width,
                       "the terminal gives up exactly the scrollbar's width, so no output runs under it")
        XCTAssertEqual(term.frame.height, 600)
    }
}

/// A scrollbar that takes no clicks is a picture of a scrollbar.
final class TerminalScrollbarHitTests: XCTestCase {
    @MainActor
    private func bar(alternateScreen: Bool, lines: Int) -> (TerminalScrollbar, NSView) {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 789, height: 500)
        let container = TerminalHost.Container(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        container.addSubview(term)
        let bar = TerminalScrollbar(term: term)
        container.addSubview(bar)
        container.place()
        if lines > 0 {
            term.feed(byteArray: Array((1...lines).map { "line \($0)\r\n" }.joined().utf8)[...])
        }
        if alternateScreen {
            term.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
        }
        bar.refresh()
        return (bar, container)
    }

    @MainActor
    func testTheKnobTakesClicksWhileAProgramOwnsTheScreen() {
        let (bar, container) = bar(alternateScreen: true, lines: 400)
        guard let knob = bar.knobRect() else { return XCTFail("no handle") }
        let onKnob = bar.convert(CGPoint(x: knob.midX, y: knob.midY), to: container)
        XCTAssertTrue(container.hitTest(onKnob) === bar,
                      "the handle has to receive the drag, or it cannot scroll anything")
    }

    @MainActor
    func testTheKnobTakesClicksWithScrollbackBehindIt() {
        let (bar, container) = bar(alternateScreen: false, lines: 400)
        guard let knob = bar.knobRect() else { return XCTFail("no knob") }
        let onKnob = bar.convert(CGPoint(x: knob.midX, y: knob.midY), to: container)
        XCTAssertTrue(container.hitTest(onKnob) === bar)
    }

    @MainActor
    func testWithNothingToScrollTheStripLetsClicksThrough() {
        let (bar, container) = bar(alternateScreen: false, lines: 0)
        let middle = bar.convert(CGPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: container)
        XCTAssertFalse(container.hitTest(middle) === bar)
    }
}

/// End to end: the bar drags, and the program on the other side of the pty receives wheel.
/// `cat` echoes what it is sent, so the reports come back onto the screen where we can read them.
final class TerminalScrollbarWheelReachesProgramTests: XCTestCase {
    @MainActor
    func testDraggingTheHandleSendsWheelReportsToTheProgram() {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 789, height: 500)
        let bar = TerminalScrollbar(term: term)
        bar.frame = NSRect(x: 789, y: 0, width: TerminalScrollbar.width, height: 500)
        term.startProcess(executable: "/bin/cat")
        // The modes a full-screen program sets: its own screen, mouse tracking, SGR reports —
        // measured from a real agent session.
        term.feed(byteArray: Array("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8)[...])
        bar.refresh()
        XCTAssertFalse(bar.isHidden, "the handle has to be there to drag")

        bar.wheel(byPoints: -30)   // ten notches up

        let echoed = expectation(description: "the program received the wheel")
        var screen = ""
        func look(_ tries: Int) {
            screen = term.lastLines(40).joined()
            // An SGR wheel-up report is ESC [ < 64 ; col ; row M.
            if screen.contains("<64;") || screen.contains("[<64") {
                echoed.fulfill()
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { look(tries - 1) }
            }
        }
        look(15)
        wait(for: [echoed], timeout: 5)
    }
}

/// The microphone over the terminal: where it sits, and that a press reaches it.
final class TerminalDictationButtonTests: XCTestCase {
    @MainActor
    private func pane() -> (TerminalHost.Container, TerminalDictationButton) {
        let term = TermView(tabID: UUID())
        let container = TerminalHost.Container(frame: .zero)
        container.addSubview(term)
        container.addSubview(TerminalScrollbar(term: term))
        let button = TerminalDictationButton(term: term)
        container.addSubview(button)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        return (container, button)
    }

    @MainActor
    func testItSitsAtTheCornerBesideTheProgramsOwnInput() {
        let (container, button) = pane()
        XCTAssertEqual(button.frame.size, CGSize(width: TerminalDictationButton.size, height: TerminalDictationButton.size))
        XCTAssertEqual(button.frame.minY, TerminalDictationButton.inset, "at the bottom of the pane")
        XCTAssertLessThanOrEqual(button.frame.maxX, container.bounds.maxX - TerminalScrollbar.width,
                                 "clear of the scrollbar beside it")
        XCTAssertGreaterThan(button.frame.minX, container.bounds.width * 0.8, "and at the right")
    }

    @MainActor
    func testAPressTapsTheAgentsOwnVoiceMode() {
        let term = TermView(tabID: UUID())
        let button = TerminalDictationButton(term: term)
        var sent: [String] = []
        button.sendKeys = { sent.append($0) }
        button.press()
        XCTAssertEqual(sent, [" "], "the agent's voice mode listens for a tap of the space bar")
        button.press()
        XCTAssertEqual(sent, [" ", " "], "a second tap sends what was said")
    }

    /// The button follows the session, not its own count of taps: a message sent with the
    /// return key leaves no tap to count, and the icon used to go on claiming to listen.
    @MainActor
    func testTheIconFollowsWhatTheSessionIsActuallyDoing() {
        let term = TermView(tabID: UUID())
        let button = TerminalDictationButton(term: term)
        var screen = "› "
        button.screenText = { screen }

        button.readState()
        XCTAssertFalse(button.listening)

        screen = "› \n  listening… · tap to send"
        button.readState()
        XCTAssertTrue(button.listening, "the agent says it is recording")

        screen = "› \n  Transcribing…"
        button.readState()
        XCTAssertTrue(button.listening, "still busy with what was said")

        // Sent with the return key: no second tap, and the session goes back to its prompt.
        screen = "› merhaba\n  auto mode on"
        button.readState()
        XCTAssertFalse(button.listening, "the icon has to stop claiming to listen")
    }

    @MainActor
    func testAPressReachesTheButtonAndIsActedOn() {
        let (container, button) = pane()
        var pressed = 0
        button.onPress = { pressed += 1 }
        let middle = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: container)
        XCTAssertTrue(container.hitTest(middle) === button, "the button has to receive the click")
        button.mouseDown(with: NSEvent())
        XCTAssertEqual(pressed, 1)
    }
}

/// The microphone belongs to a running agent, not to a session that once ran one. A window
/// sitting in a plain shell has nothing to tap, and an agent started later should bring the
/// button with it rather than wait for the pane to be rebuilt.
final class TerminalDictationButtonVisibilityTests: XCTestCase {
    @MainActor
    func testItShowsOnlyWhileAnAgentIsRunning() {
        let term = TermView(tabID: UUID())
        let button = TerminalDictationButton(term: term)
        var running = false
        button.agentRunning = { running }
        button.screenText = { "~/code $ " }

        button.readState()
        XCTAssertTrue(button.isHidden, "a plain shell has no voice mode to start")

        // The reader starts Claude Code in that session.
        running = true
        button.readState()
        XCTAssertFalse(button.isHidden, "the button appears with the agent")

        // And the agent exits.
        running = false
        button.readState()
        XCTAssertTrue(button.isHidden, "and goes away with it")
    }

    @MainActor
    func testWhileHiddenItDoesNotReadTheScreenForListening() {
        let term = TermView(tabID: UUID())
        let button = TerminalDictationButton(term: term)
        button.agentRunning = { false }
        button.screenText = { "listening… · tap to send" }
        button.readState()
        XCTAssertFalse(button.listening, "nothing is listening in a session with no agent in it")
    }
}

/// With the agent writing into the terminal's own buffer, the bar is the terminal's: the knob
/// is the share of the conversation on screen and its place is how far back you are — the
/// same numbers the terminal scrolls by, with nothing estimated.
final class TerminalScrollbarIsTheTerminalsOwnTests: XCTestCase {
    @MainActor
    private func session(lines: Int) -> (TermView, TerminalScrollbar) {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 789, height: 500)
        let bar = TerminalScrollbar(term: term)
        bar.frame = NSRect(x: 789, y: 0, width: TerminalScrollbar.width, height: 500)
        if lines > 0 {
            term.feed(byteArray: Array((1...lines).map { "line \($0)\r\n" }.joined().utf8)[...])
        }
        bar.refresh()
        return (term, bar)
    }

    @MainActor
    func testTheKnobIsTheShareOfTheConversationOnScreen() {
        let (_, short) = session(lines: 60)
        let (_, long) = session(lines: 3000)
        guard let big = short.knobRect()?.height, let small = long.knobRect()?.height else {
            return XCTFail("no handles to compare")
        }
        XCTAssertLessThan(small, big, "a longer conversation, a smaller knob — in proportion to it")
        XCTAssertGreaterThanOrEqual(small, 26)
    }

    @MainActor
    func testDraggingToTheTopReachesTheFirstLineAndBackAgain() {
        let (term, bar) = session(lines: 3000)
        let track = bar.bounds.insetBy(dx: TerminalScrollbar.knobInset, dy: TerminalScrollbar.knobInset)

        term.scroll(toPosition: 0)
        bar.refresh()
        XCTAssertEqual(bar.knobRect()!.minY, track.minY, accuracy: 0.5)
        XCTAssertTrue(term.lastLines(3000).contains("line 1"), "the first line of the session is on screen")

        term.scroll(toPosition: 1)
        bar.refresh()
        XCTAssertEqual(bar.knobRect()!.maxY, track.maxY, accuracy: 0.5)
        XCTAssertEqual(term.scrollPosition, 1, accuracy: 0.001)
    }

    @MainActor
    func testHalfwayDownTheTrackIsHalfwayThroughTheConversation() {
        let (term, bar) = session(lines: 3000)
        term.scroll(toPosition: 0.5)
        bar.refresh()
        XCTAssertEqual(term.scrollPosition, 0.5, accuracy: 0.01)
        let track = bar.bounds.insetBy(dx: TerminalScrollbar.knobInset, dy: TerminalScrollbar.knobInset)
        let knob = bar.knobRect()!
        XCTAssertEqual(knob.minY + knob.height / 2, track.midY, accuracy: track.height * 0.03)
    }

    @MainActor
    func testASessionThatFitsOnScreenHasNoScrollbarAtAll() {
        let (_, bar) = session(lines: 5)
        XCTAssertTrue(bar.isHidden)
        XCTAssertNil(bar.knobRect())
    }
}

/// One session, one handle. SwiftTerm draws a scroller of its own, which now that the
/// conversation is in the terminal's buffer flashes beside omux's while you scroll.
final class TerminalHasOneScrollbarTests: XCTestCase {
    @MainActor
    func testSwiftTermsOwnScrollerIsGivenNoWidth() {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        term.feed(byteArray: Array((1...400).map { "line \($0)\r\n" }.joined().utf8)[...])
        term.hideBuiltInScroller()

        // Auto Layout runs, as it does in the window: a width set by hand would come back.
        term.layoutSubtreeIfNeeded()
        let built = term.subviews.filter { $0 is NSScroller || $0.identifier?.rawValue == "SwiftTermOverlayScrollerIndicator" }
        XCTAssertTrue(built.isEmpty, "SwiftTerm's own scroller and its knob must be out of the pane")
    }

    @MainActor
    func testItStaysOutAfterTheTerminalScrolls() {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        term.feed(byteArray: Array((1...400).map { "line \($0)\r\n" }.joined().utf8)[...])
        term.hideBuiltInScroller()
        term.scroll(toPosition: 0.3)      // what makes SwiftTerm show its overlay knob
        term.layoutSubtreeIfNeeded()
        XCTAssertTrue(term.subviews.allSatisfy { !($0 is NSScroller) && $0.identifier?.rawValue != "SwiftTermOverlayScrollerIndicator" },
                      "scrolling must not bring it back")
    }

    @MainActor
    func testThePaneKeepsItOutOfTheWayOnEveryLayout() {
        let term = TermView(tabID: UUID())
        let container = TerminalHost.Container(frame: .zero)
        container.addSubview(term)
        container.addSubview(TerminalScrollbar(term: term))
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let scrollers = term.subviews.compactMap { $0 as? NSScroller }
        XCTAssertTrue(scrollers.allSatisfy { $0.frame.width == 0 },
                      "a resize must not bring the second handle back")
    }
}

/// The knob has to be worth aiming at, and a little easier to hit once the pointer is on it.
final class TerminalScrollbarKnobIsGrabbableTests: XCTestCase {
    @MainActor
    func testTheKnobIsWideEnoughToClick() {
        let term = TermView(tabID: UUID())
        term.frame = NSRect(x: 0, y: 0, width: 789, height: 500)
        term.feed(byteArray: Array((1...600).map { "line \($0)\r\n" }.joined().utf8)[...])
        let bar = TerminalScrollbar(term: term)
        bar.frame = NSRect(x: 789, y: 0, width: TerminalScrollbar.width, height: 500)
        bar.refresh()

        guard let knob = bar.knobRect() else { return XCTFail("no knob") }
        XCTAssertGreaterThanOrEqual(knob.width, 8, "a knob thinner than this is a nuisance to hit")

        // Under the pointer it swells.
        bar.mouseEntered(with: NSEvent())
        guard let hovered = bar.knobRect() else { return XCTFail("no knob") }
        XCTAssertGreaterThan(hovered.width, knob.width)
        bar.mouseExited(with: NSEvent())
        XCTAssertEqual(bar.knobRect()?.width, knob.width)
    }
}

/// Whether an agent is running is omux's own business: it knows when one has connected and
/// what it is doing. Reading the terminal's modes for it was roundabout and broke as soon as
/// the agent stopped taking the alternate screen.
final class TerminalDictationButtonKnowsTheAgentTests: XCTestCase {
    private func running(_ runtime: TabRuntime) -> Bool {
        runtime.provider == .claude && !runtime.exited
            && (runtime.agentConnected || runtime.statusState != nil)
    }

    func testAConnectedAgentCounts() {
        var runtime = TabRuntime()
        runtime.provider = .claude
        runtime.agentConnected = true
        XCTAssertTrue(running(runtime))
    }

    func testOneThatIsOnlyReportingItsStateCountsToo() {
        var runtime = TabRuntime()
        runtime.provider = .claude
        runtime.statusState = .working
        XCTAssertTrue(running(runtime), "it is plainly there, whatever the connection is doing")
    }

    func testASessionThatMerelyRanOneDoesNot() {
        var runtime = TabRuntime()
        runtime.provider = .claude       // what it last ran
        XCTAssertFalse(running(runtime), "back at a shell prompt there is nothing to dictate to")
    }

    func testAnAgentThatHasExitedDoesNot() {
        var runtime = TabRuntime()
        runtime.provider = .claude
        runtime.agentConnected = true
        runtime.exited = true
        XCTAssertFalse(running(runtime))
    }

    func testAShellSessionDoesNot() {
        var runtime = TabRuntime()
        runtime.provider = .shell
        runtime.agentConnected = true
        XCTAssertFalse(running(runtime))
    }
}

/// The microphone is a target for a pointer, not a decoration.
final class TerminalDictationButtonSizeTests: XCTestCase {
    @MainActor
    func testItIsBigEnoughToHitAndSquare() {
        let term = TermView(tabID: UUID())
        let container = TerminalHost.Container(frame: .zero)
        container.addSubview(term)
        let button = TerminalDictationButton(term: term)
        container.addSubview(button)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        XCTAssertGreaterThanOrEqual(TerminalDictationButton.size, 28, "a smaller button is fiddly to hit")
        XCTAssertEqual(button.frame.width, button.frame.height, "square, like the window's other buttons")
        let corner = button.convert(CGPoint(x: button.bounds.minX + 2, y: button.bounds.minY + 2), to: container)
        XCTAssertTrue(container.hitTest(corner) === button, "its whole face takes the click")
    }
}
