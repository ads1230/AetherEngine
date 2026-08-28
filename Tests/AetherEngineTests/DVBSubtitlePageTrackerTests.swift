import Testing
import CoreGraphics
@testable import AetherEngine

// The DVB page tracker behind `dvbSubtitlePage`: display-set events are complete page state
// (replace / erase / timeout), re-sends keep the shown cue's identity, and partial-row SD
// updates survive alongside each other. See DVBSubtitlePageTracker.
@Suite("DVBSubtitlePageTracker display-set semantics")
struct DVBSubtitlePageTrackerTests {

    private func body(width: Int = 1, height: Int = 1,
                      position: CGRect = CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.1)) -> SubtitleCue.Body {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return .image(SubtitleImage(cgImage: ctx.makeImage()!, position: position,
                                    canvasSize: CGSize(width: 720, height: 576), isPageBased: true))
    }

    private func cue(id: Int, start: Double, end: Double, body: SubtitleCue.Body) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: body)
    }

    @Test("A display set shows and a page erase clears it")
    func showAndErase() {
        var tracker = DVBSubtitlePageTracker()
        var nextID = 100
        tracker.apply([cue(id: 0, start: 10, end: 18, body: body())], nextID: &nextID)
        #expect(tracker.cues.count == 1)
        #expect(tracker.cues[0].id == 100)
        tracker.apply([], nextID: &nextID)
        #expect(tracker.cues.isEmpty)
    }

    @Test("A geometry-identical re-send keeps the shown cue's id and extends the timeout")
    func resendKeepsIdentity() {
        var tracker = DVBSubtitlePageTracker()
        var nextID = 0
        let page = body()
        tracker.apply([cue(id: 0, start: 10, end: 18, body: page)], nextID: &nextID)
        let shownID = tracker.cues[0].id
        tracker.apply([cue(id: 1, start: 12, end: 20, body: page)], nextID: &nextID)
        #expect(tracker.cues.count == 1)
        #expect(tracker.cues[0].id == shownID)
        // The re-send refreshed the timeout: the page survives past the original end...
        tracker.expire(at: 19)
        #expect(tracker.cues.count == 1)
        // ...and expires at the refreshed one.
        tracker.expire(at: 20)
        #expect(tracker.cues.isEmpty)
    }

    @Test("New content replaces the overlapping region")
    func overlapReplaces() {
        var tracker = DVBSubtitlePageTracker()
        var nextID = 0
        tracker.apply([cue(id: 0, start: 10, end: 18, body: body())], nextID: &nextID)
        // Same screen region, different pixel size: a new caption, not a re-send.
        tracker.apply([cue(id: 1, start: 12, end: 20, body: body(width: 2))], nextID: &nextID)
        #expect(tracker.cues.count == 1)
        #expect(tracker.cues[0].id == 1)   // second id stamped from the session counter
        #expect(tracker.cues[0].startTime == 12)
    }

    @Test("SD two-row updates a frame apart both stay on screen")
    func partialRowUpdatesCoexist() {
        var tracker = DVBSubtitlePageTracker()
        var nextID = 0
        let rowOne = body(position: CGRect(x: 0.3, y: 0.75, width: 0.4, height: 0.08))
        let rowTwo = body(position: CGRect(x: 0.3, y: 0.85, width: 0.4, height: 0.08))
        tracker.apply([cue(id: 0, start: 10.00, end: 18, body: rowOne)], nextID: &nextID)
        tracker.apply([cue(id: 1, start: 10.04, end: 18, body: rowTwo)], nextID: &nextID)
        #expect(tracker.cues.count == 2)
    }

    @Test("An unrefreshed page leaves the screen at its authored timeout")
    func timeoutClears() {
        var tracker = DVBSubtitlePageTracker()
        var nextID = 0
        tracker.apply([cue(id: 0, start: 10, end: 18, body: body())], nextID: &nextID)
        tracker.expire(at: 17.9)
        #expect(tracker.cues.count == 1)
        tracker.expire(at: 18)
        #expect(tracker.cues.isEmpty)
    }

    @Test("clear() empties the page for a seek reset")
    func clearForSeek() {
        var tracker = DVBSubtitlePageTracker()
        var nextID = 0
        tracker.apply([cue(id: 0, start: 10, end: 18, body: body())], nextID: &nextID)
        tracker.clear()
        #expect(tracker.cues.isEmpty)
    }
}
