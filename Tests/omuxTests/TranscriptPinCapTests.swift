import JavaScriptCore
import XCTest

/// The ceiling on a request held at the top of the transcript. It used to be a fixed 96px, which
/// never held a dictated request on any window; it is now a share of the view, with that 96 as a
/// floor so a short window keeps the behaviour it had.
final class TranscriptPinCapTests: XCTestCase {
    /// `pinCap` as transcript.js defines it, loaded from the file itself so the test fails when
    /// the page's own copy changes.
    private func pinCap() throws -> (Double) -> Double {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/transcript/transcript.js").standardizedFileURL
        let source = try String(contentsOf: file, encoding: .utf8)
        let line = try XCTUnwrap(source.split(separator: "\n").first { $0.contains("function pinCap(") },
                                 "transcript.js no longer defines pinCap")
        let context = JSContext()!
        context.evaluateScript(String(line))
        return { height in context.objectForKeyedSubscript("pinCap").call(withArguments: [height])!.toDouble() }
    }

    func testATallWindowHoldsALongerRequest() throws {
        let cap = try pinCap()
        XCTAssertEqual(cap(1200), 300, "a quarter of the view")
        XCTAssertGreaterThan(cap(1200), 96, "the old fixed ceiling held none of these")
    }

    func testAShortWindowKeepsTheOldFloor() throws {
        let cap = try pinCap()
        XCTAssertEqual(cap(320), 96, "a quarter of 320 is below the floor")
        XCTAssertEqual(cap(0), 96)
    }

    func testTheCapRisesWithTheWindow() throws {
        let cap = try pinCap()
        XCTAssertGreaterThan(cap(1600), cap(800), "a taller window holds a taller request")
    }
}
