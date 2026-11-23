import AppKit
import XCTest
@testable import omux

/// The window's top strip drags the window, but a press that never moves has to stay with
/// whatever it landed on. A press that started a drag immediately closed any menu the press had
/// just opened — and against a screen edge macOS took the press for its own window tiling, which
/// is why the strip's split button only misbehaved while the window sat in a corner.
final class TitleBarDragTests: XCTestCase {
    /// Records what the strip asks of its window instead of really dragging it.
    private final class RecordingWindow: NSWindow {
        var drags = 0
        var draggedWith: NSEvent?
        override func performDrag(with event: NSEvent) {
            drags += 1
            draggedWith = event
        }
    }

    @MainActor
    private func strip() -> (TitleBarArea.AreaView, RecordingWindow) {
        let window = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let view = TitleBarArea.AreaView(frame: NSRect(x: 0, y: 370, width: 600, height: 30))
        window.contentView?.addSubview(view)
        return (view, window)
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @MainActor
    func testAPressThatDoesNotMoveNeverDragsTheWindow() {
        let (view, window) = strip()
        let at = NSPoint(x: 560, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 1, in: window))
        XCTAssertEqual(window.drags, 0, "the press belongs to the button under it, not to the window")
        view.mouseUp(with: event(.leftMouseUp, at: at, clicks: 1, in: window))
        XCTAssertEqual(window.drags, 0)
    }

    @MainActor
    func testASmallWobbleIsStillAClick() {
        let (view, window) = strip()
        let at = NSPoint(x: 560, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 1, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: at.x + 1, y: at.y + 1), clicks: 1, in: window))
        XCTAssertEqual(window.drags, 0, "a hand that shakes by a point has not asked to move the window")
    }

    @MainActor
    func testMovingThePointerDragsTheWindow() {
        let (view, window) = strip()
        let at = NSPoint(x: 300, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 1, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: at.x + 40, y: at.y - 10), clicks: 1, in: window))
        XCTAssertEqual(window.drags, 1, "the strip still drags the window")
    }

    @MainActor
    func testADragAfterTheMouseIsUpDoesNothing() {
        let (view, window) = strip()
        let at = NSPoint(x: 300, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 1, in: window))
        view.mouseUp(with: event(.leftMouseUp, at: at, clicks: 1, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: at.x + 80, y: at.y), clicks: 1, in: window))
        XCTAssertEqual(window.drags, 0, "a press that already ended cannot start a drag")
    }

    @MainActor
    func testADoubleClickFillsTheScreenInsteadOfDragging() {
        let (view, window) = strip()
        let at = NSPoint(x: 300, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 2, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: at.x + 60, y: at.y), clicks: 2, in: window))
        XCTAssertEqual(window.drags, 0, "a double-click fills or minimizes; it never drags")
    }

    @MainActor
    func testWhileAMenuIsOpenTheStripLeavesTheWindowAlone() {
        let (view, window) = strip()
        TitleBarArea.AreaView.menuIsOpen = true
        defer { TitleBarArea.AreaView.menuIsOpen = false }
        let at = NSPoint(x: 560, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 1, in: window))
        // The press that opened the menu drifts, as a held button does.
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: at.x + 60, y: at.y - 20), clicks: 1, in: window))
        XCTAssertEqual(window.drags, 0, "moving the window would close the menu the press just opened")
    }

    @MainActor
    func testOnceTheMenuIsGoneTheStripDragsAgain() {
        let (view, window) = strip()
        TitleBarArea.AreaView.menuIsOpen = false
        let at = NSPoint(x: 300, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 1, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: at.x + 60, y: at.y), clicks: 1, in: window))
        XCTAssertEqual(window.drags, 1)
    }

    /// `performDrag` takes the window's grab point from the event it is handed. Handing it the
    /// drag event instead of the press moved the grab point to wherever the threshold was crossed,
    /// which showed up as the window sliding out from under the pointer, worst of all across
    /// monitors of different scale.
    @MainActor
    func testTheWindowIsDraggedByWhereItWasGrabbed() {
        let (view, window) = strip()
        let press = NSPoint(x: 300, y: 385)
        view.mouseDown(with: event(.leftMouseDown, at: press, clicks: 1, in: window))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: press.x + 40, y: press.y - 15), clicks: 1, in: window))
        XCTAssertEqual(window.drags, 1)
        XCTAssertEqual(window.draggedWith?.type, .leftMouseDown, "the press, not the drag")
        XCTAssertEqual(window.draggedWith?.locationInWindow, press, "the grab point is where the press landed")
    }

    func testTheThresholdIsAFewPointsInAnyDirection() {
        let origin = NSPoint(x: 10, y: 10)
        XCTAssertFalse(TitleBarArea.AreaView.movedEnough(from: origin, to: origin))
        XCTAssertFalse(TitleBarArea.AreaView.movedEnough(from: origin, to: NSPoint(x: 14, y: 10)),
                       "the drift of a held button is not a request to move the window")
        XCTAssertTrue(TitleBarArea.AreaView.movedEnough(from: origin, to: NSPoint(x: 19, y: 10)))
        XCTAssertTrue(TitleBarArea.AreaView.movedEnough(from: origin, to: NSPoint(x: 10, y: 1)))
        XCTAssertTrue(TitleBarArea.AreaView.movedEnough(from: origin, to: NSPoint(x: 4, y: 17)),
                      "distance, not one axis at a time")
    }
}
