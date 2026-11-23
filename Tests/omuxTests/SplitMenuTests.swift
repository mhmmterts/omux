import AppKit
import SwiftUI
import XCTest
@testable import omux

/// The split button's menu is an NSMenu shown with popUp rather than SwiftUI's Menu, which opened
/// on the press and closed again on the release unless the release landed inside it.
final class SplitMenuTests: XCTestCase {
    private let one = UUID(), two = UUID()

    func testAShellCanBeSplitOffInEitherDirection() {
        var axes: [Axis] = []
        let menu = SplitMenu.build(SplitMenu.Model(onShell: { axes.append($0) }))
        XCTAssertEqual(menu.items.map(\.title), ["New Shell to the Right", "New Shell Below"])
        XCTAssertTrue(menu.items.allSatisfy(\.isEnabled), "every offer in the menu can be picked")
        for item in menu.items { pick(item) }
        XCTAssertEqual(axes, [.horizontal, .vertical])
    }

    func testTheProjectsOtherSessionsComeAfterASeparator() {
        var beside: [UUID] = []
        let model = SplitMenu.Model(others: [("Session 2", one), ("Shell", two)],
                                    onBeside: { beside.append($0) })
        let menu = SplitMenu.build(model)
        XCTAssertEqual(menu.items.map(\.title),
                       ["New Shell to the Right", "New Shell Below", "", "Show beside this session", "Session 2", "Shell"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertFalse(menu.items[3].isEnabled, "the heading is a label, not something to pick")
        XCTAssertFalse(menu.autoenablesItems, "the menu says itself what can be picked; nothing greys out later")

        pick(menu.items[5])
        pick(menu.items[4])
        XCTAssertEqual(beside, [two, one], "each session's item carries its own id")
    }

    func testWithNoOtherSessionsTheMenuIsJustTheTwoShells() {
        let menu = SplitMenu.build(SplitMenu.Model())
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertFalse(menu.items.contains { $0.isSeparatorItem }, "no empty section to scroll past")
    }

    /// What AppKit does when the item is chosen.
    private func pick(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target else {
            return XCTFail("\(item.title) does nothing")
        }
        _ = (target as AnyObject).perform(action)
    }
}
