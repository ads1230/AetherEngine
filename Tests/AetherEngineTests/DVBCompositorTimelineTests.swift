import XCTest
import CoreGraphics
@testable import AetherEngine

/// SW-PiP burn-in reads the DVB feed at frame-enqueue time, ~1-2s ahead of the
/// playhead, so the compositor feed must be a PTS-windowed timeline covering
/// the decoded-ahead (deferred) display sets — not just the on-screen page
/// (which made every PiP subtitle one render-cushion late, 2026-08-28).
final class DVBCompositorTimelineTests: XCTestCase {

    private func imageCue(id: Int, start: Double, end: Double,
                          x: CGFloat = 0.1, y: CGFloat = 0.8) -> SubtitleCue {
        let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = SubtitleImage(
            cgImage: ctx.makeImage()!,
            position: CGRect(x: x, y: y, width: 0.5, height: 0.1),
            canvasSize: CGSize(width: 720, height: 576),
            isPageBased: true)
        return SubtitleCue(id: id, startTime: start, endTime: end, body: .image(image))
    }

    private func activeIDs(_ timeline: [SubtitleCue], at pts: Double) -> [Int] {
        SubtitleFrameCompositor.activeCues(in: timeline, at: pts).map(\.id)
    }

    func testCurrentPageBoundedAtFirstFutureEvent() {
        var tracker = DVBSubtitlePageTracker()
        var id = 1
        tracker.apply([imageCue(id: 0, start: 100, end: 108)], nextID: &id)
        let page = tracker.cues
        let future = imageCue(id: 0, start: 103, end: 111, x: 0.11)

        let timeline = AetherEngine.dvbCompositorTimeline(
            page: page, tracker: tracker,
            deferred: [(presentationTime: 103, cues: [future])])

        // Cushion frames before the future event burn the current page…
        XCTAssertEqual(activeIDs(timeline, at: 101), page.map(\.id))
        // …frames past it burn the NEW page (replaces overlapping region),
        // which is the whole delay fix: this pts is ahead of the playhead.
        let after = activeIDs(timeline, at: 104)
        XCTAssertEqual(after.count, 1)
        XCTAssertNotEqual(after, page.map(\.id))
        XCTAssertTrue(after.allSatisfy { $0 < 0 }, "simulated content must use negative ids")
    }

    func testEraseEventEndsTimeline() {
        var tracker = DVBSubtitlePageTracker()
        var id = 1
        tracker.apply([imageCue(id: 0, start: 100, end: 108)], nextID: &id)

        let timeline = AetherEngine.dvbCompositorTimeline(
            page: tracker.cues, tracker: tracker,
            deferred: [(presentationTime: 102.5, cues: [])])

        XCTAssertFalse(activeIDs(timeline, at: 101).isEmpty)
        XCTAssertTrue(activeIDs(timeline, at: 103).isEmpty,
                      "page erase must clear the lookahead timeline from its PTS")
    }

    func testConsecutiveFutureEventsGetDisjointIntervals() {
        let timeline = AetherEngine.dvbCompositorTimeline(
            page: [], tracker: DVBSubtitlePageTracker(),
            deferred: [
                (presentationTime: 100, cues: [imageCue(id: 0, start: 100, end: 108)]),
                (presentationTime: 102, cues: [imageCue(id: 0, start: 102, end: 110, x: 0.12)]),
            ])

        XCTAssertTrue(activeIDs(timeline, at: 99).isEmpty)
        XCTAssertEqual(activeIDs(timeline, at: 101).count, 1)
        XCTAssertEqual(activeIDs(timeline, at: 103).count, 1)
        XCTAssertNotEqual(activeIDs(timeline, at: 101), activeIDs(timeline, at: 103))
        // Stable across recomputes: the overlay cache keys on these ids.
        let again = AetherEngine.dvbCompositorTimeline(
            page: [], tracker: DVBSubtitlePageTracker(),
            deferred: [
                (presentationTime: 100, cues: [imageCue(id: 0, start: 100, end: 108)]),
                (presentationTime: 102, cues: [imageCue(id: 0, start: 102, end: 110, x: 0.12)]),
            ])
        XCTAssertEqual(activeIDs(timeline, at: 103), activeIDs(again, at: 103))
    }

    func testNoDeferredKeepsPageOpenEnded() {
        var tracker = DVBSubtitlePageTracker()
        var id = 1
        tracker.apply([imageCue(id: 0, start: 100, end: 108)], nextID: &id)

        let timeline = AetherEngine.dvbCompositorTimeline(
            page: tracker.cues, tracker: tracker, deferred: [])

        XCTAssertEqual(activeIDs(timeline, at: 500), tracker.cues.map(\.id),
                       "without lookahead the page stays open-ended, as before")
    }
}
