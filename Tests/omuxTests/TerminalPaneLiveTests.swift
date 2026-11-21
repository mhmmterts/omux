import AppKit
import SwiftUI
import XCTest
@testable import omux

/// The pane as SwiftUI actually builds it: a hosting view, a window, a layout pass. Hand-built
/// AppKit containers hid a bug that only this path shows.
final class TerminalPaneLiveTests: XCTestCase {
    @MainActor
    func testTheScrollbarIsInThePaneSwiftUIBuilds() {
        let term = TermView(tabID: UUID())
        let host = NSHostingView(rootView: TerminalHost(termView: term, theme: Theme.current))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI run its update and hand the representable its size.
        let settled = expectation(description: "laid out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
            if let hit = view as? V { return hit }
            for child in view.subviews {
                if let hit = find(type, in: child) { return hit }
            }
            return nil
        }
        guard let bar = find(TerminalScrollbar.self, in: host) else {
            return XCTFail("SwiftUI's pane has no scrollbar in it at all")
        }
        XCTAssertEqual(bar.frame.width, TerminalScrollbar.width, "the scrollbar has no width in the real pane")
        XCTAssertGreaterThan(bar.frame.height, 100, "the scrollbar has no height in the real pane")
        XCTAssertNotNil(bar.window, "the scrollbar never reached the window")
        XCTAssertEqual(term.frame.width, bar.superview!.bounds.width - TerminalScrollbar.width, accuracy: 0.5)
    }
}
