import XCTest
@testable import omux

/// Whether Claude Code keeps its own full-screen layout. On, it holds the request at the top of
/// the view and offers Jump to bottom; off, omux asks it for the terminal's buffer instead so the
/// scrollbar can show where in the conversation you are.
final class ClaudeFullScreenPrefTests: XCTestCase {
    private let key = Prefs.claudeFullScreen

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    @MainActor
    func testItIsOnWhenNothingHasBeenChosen() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(Store.claudeFullScreen, "Claude Code behaves as it does everywhere else until told otherwise")
    }

    @MainActor
    func testTurningItOffIsWhatAsksForTheTerminalsBuffer() {
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(Store.claudeFullScreen)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(Store.claudeFullScreen)
    }

    /// Settings' Reset clears what it knows about; a key left out would survive one.
    func testResetKnowsAboutIt() {
        XCTAssertTrue(Prefs.all.contains(key))
    }
}
