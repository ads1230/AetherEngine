import Foundation
import CoreGraphics

/// Engine-owned DVB subtitle page state: the display set currently on screen.
///
/// DVB bitmap subtitles are page-STATE updates, not timed cues: a display set is the complete
/// on-screen composition from its PTS until the next display set replaces it, an empty set (page
/// erase) clears it, or the page timeout expires without a refresh. The retained cue store cannot
/// express that — `alignCueEnds` closes every bitmap cue at the next stored packet's PTS (usually
/// the first ~0.5-2s re-send), so a held page would publish as a chain of short-window cues with
/// fresh ids, and every host grew lead/trail/recent-window tolerances plus a silence timeout to
/// reconstruct the page from that tiling. This tracker keeps the page state at the one place the
/// engine actually knows it: display-set event application. Hosts paint `AetherEngine.dvbSubtitlePage`
/// verbatim.
///
/// The tracker is the ONLY home of decoded DVB bitmaps: page-based cues never enter the retained
/// store (nothing reads them there — seek backscans re-decode from the packet store, and the
/// SW-PiP compositor is fed the page via `subtitleCompositorFeedCues`), so a live session no
/// longer retains a decoded RGBA image per re-send.
struct DVBSubtitlePageTracker {
    private struct Entry {
        var cue: SubtitleCue
        /// Absolute source PTS past which the page expires when the broadcast stops refreshing it
        /// (the decoder's page timeout, capped at `maxDVBBitmapDisplaySeconds`). Re-sends extend it,
        /// so an on-air page never expires mid-show; an end-of-programme page with no clear event
        /// leaves the screen at its authored timeout instead of hanging.
        var expiresAt: Double
    }

    private var entries: [Entry] = []

    /// The on-screen page, in event order. Ids are stable across re-sends.
    var cues: [SubtitleCue] { entries.map(\.cue) }

    /// Apply one DVB display-set event (`SubtitleEvent.dvbPageReplaceAt != nil`). `eventCues` is the
    /// complete new composition; empty means page erase. `nextID` is the engine's session-monotonic
    /// cue id source, consumed only for genuinely new content.
    mutating func apply(_ eventCues: [SubtitleCue], nextID: inout Int) {
        guard !eventCues.isEmpty else {
            entries.removeAll()
            return
        }
        for newcomer in eventCues {
            guard case .image(let newImage) = newcomer.body else { continue }
            // Re-send of a region already on screen: identical geometry (position, canvas, pixel
            // dims) is the same on-air content. Keep the shown cue's id and image so hosts never
            // re-upload a texture; only the timeout refreshes.
            if let i = entries.firstIndex(where: { $0.cue.body.matchesGeometry(of: newImage) }) {
                entries[i].expiresAt = max(entries[i].expiresAt, newcomer.endTime)
                continue
            }
            // New content replaces whatever it overlaps (a display set is complete page state), but
            // non-overlapping regions survive: SD services emit a two-row sentence as separate
            // region updates a frame or two apart, and a purely wholesale replacement would erase
            // row one when row two arrives.
            entries.removeAll { entry in
                guard case .image(let shown) = entry.cue.body else { return false }
                return shown.position.intersects(newImage.position)
            }
            entries.append(Entry(cue: newcomer.with(id: nextID), expiresAt: newcomer.endTime))
            nextID += 1
        }
    }

    /// Drop regions whose page timeout passed without a refresh. Driven by the playhead, so a
    /// paused clock holds the page (the pause-hold contract) and end-of-programme pages clear at
    /// their authored timeout.
    mutating func expire(at playhead: Double) {
        entries.removeAll { $0.expiresAt <= playhead }
    }

    /// Seek/teardown: the page belongs to the position being left. A reset tick's backscan
    /// re-applies the display sets behind the new landing, so the page at the landing point
    /// reconstructs within the same tick.
    mutating func clear() {
        entries.removeAll()
    }
}

private extension SubtitleCue.Body {
    /// The fold-in identity key from `insertCueSorted`: position, canvas and pixel dimensions.
    func matchesGeometry(of image: SubtitleImage) -> Bool {
        guard case .image(let own) = self else { return false }
        return own.position == image.position
            && own.canvasSize == image.canvasSize
            && own.cgImage.width == image.cgImage.width
            && own.cgImage.height == image.cgImage.height
    }
}
