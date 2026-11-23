import XCTest
@testable import omux

/// How far a notch of the wheel goes. The terminal scrolls its own scrollback by as many lines as
/// it is scaled for; a full-screen program is sent mouse reports instead and moves by its own
/// step, and a burst of them is no faster than one, so it is sent exactly one a notch.
final class TerminalScrollSpeedTests: XCTestCase {
    @MainActor
    func testATerminalStartsOnItsOwnScrollbacksScaling() {
        let term = TermView(tabID: UUID())
        XCTAssertEqual(term.scrollSensitivity, TermView.scrollSensitivityDefault,
                       "a session begins on the normal screen")
    }

    /// A mouse wheel counts in lines already; the scaling applies and nothing is carried.
    @MainActor
    func testAWheelNotchAsksForTheScaledNumberOfLines() {
        let (lines, carry) = TermView.wheelLines(deltaY: 3, precise: false, cellHeight: 20, carried: 0)
        XCTAssertEqual(lines, Int(3 * TermView.scrollSensitivityDefault), "no step given, so none divided out")
        XCTAssertEqual(carry, 0, accuracy: 0.0001)
    }

    /// A trackpad counts in pixels, so a cell's worth of travel is one line before scaling.
    @MainActor
    func testATrackpadIsMeasuredInCells() {
        let (lines, _) = TermView.wheelLines(deltaY: 20, precise: true, cellHeight: 20, carried: 0)
        XCTAssertEqual(lines, Int(TermView.scrollSensitivityDefault))
    }

    /// Travel too small to be a line is kept, so slow dragging still moves rather than rounding
    /// away to nothing on every event.
    @MainActor
    func testWhatIsTooSmallToSendIsCarried() {
        var carried: CGFloat = 0
        var sent = 0
        for _ in 0..<10 {
            let (lines, carry) = TermView.wheelLines(deltaY: 2, precise: true, cellHeight: 20, carried: carried)
            carried = carry
            sent += lines
        }
        XCTAssertEqual(sent, Int(10 * 2 / 20 * TermView.scrollSensitivityDefault),
                       "ten tenths of a cell add up to the lines a whole cell would have sent")
    }

    /// Reports have to be spaced for the program to act on each; a burst is one notch to it.
    /// A program that moves several lines for one report must be sent proportionally fewer, or
    /// the same turn of the wheel covers several times the distance it does in the scrollback.
    @MainActor
    func testAProgramWithABiggerStepIsSentFewerReports() {
        let (plain, _) = TermView.wheelLines(deltaY: 6, precise: false, cellHeight: 20, carried: 0)
        let (stepped, _) = TermView.wheelLines(deltaY: 6, precise: false, cellHeight: 20, carried: 0,
                                               step: TermView.alternateReportStep)
        XCTAssertEqual(stepped, plain / Int(TermView.alternateReportStep))
        XCTAssertGreaterThan(TermView.alternateReportStep, 1, "a notch means more than a line to a TUI")
    }

    @MainActor
    func testReportsAreSpacedAndBounded() {
        XCTAssertGreaterThan(TermView.wheelReportGap, 0, "sent together they reach it in one read")
        XCTAssertLessThanOrEqual(TermView.wheelReportGap, 1.0 / 60, "no slower than the program redraws")
        XCTAssertGreaterThan(TermView.maxOwedWheelLines, 0)
        XCTAssertLessThanOrEqual(Double(TermView.maxOwedWheelLines) * TermView.wheelReportGap, 0.5,
                                 "a flick must stop soon after the hand does, not coast")
    }

    @MainActor
    func testTheScrollbackIsNotLeftAtTheLibrarysDefault() {
        XCTAssertNotEqual(TermView.scrollSensitivityDefault, 1.0, "the scrollback moves more than a line a notch")
    }
}
