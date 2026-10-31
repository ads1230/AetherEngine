import Foundation

/// A source whose header describes more media than its bytes hold (a download or remux cut short, a
/// recording that stopped early with its header already written). The declared duration drives the
/// segment plan, the playlist and the host's scrubber, so when it overstates the data the plan
/// advertises segments no producer can cut, AVPlayer fetches one, waits out its 4 s threshold and
/// stalls into -12889, and the gate-starvation re-anchor (#169 round 3) can only ever re-produce the
/// last real segment. Measured in the field on a Jellyfin MKV (2026-10-31): Segment size 276,867,561
/// declared, 128,270,336 bytes served, Duration 1281.882 s declared, last packet 554.027 s; the
/// resume position saved by the previous run was the cut itself.
///
/// The remedy is to measure the real end once, at session build, and plan to it. The measurement is
/// one ranged read of the tail (`Demuxer.measureSourceEndSeconds`), paid only where it can matter:
/// containers whose duration libavformat reads from a header rather than from the tail (an MPEG-TS
/// estimate already comes from the last packets, so a truncated TS reports its true length), and
/// only when the keyframe index already looks wrong, which a truncated file's always does (its Cues
/// or its sample table lie past the last byte).
extension HLSVideoEngine {

    /// Read deadline for the tail probe. The window is 2 MB and the origin has just served the head
    /// and the Cues attempt, so a healthy source answers in a fraction of this; a starved one gives
    /// the header back its say rather than holding the session start.
    static let sourceEndProbeTimeout: TimeInterval = 4.0

    /// How far short of the declared duration the measured end must fall to count as truncation. A
    /// complete file ends within a frame or two of its declaration; a declaration rounded up, or an
    /// audio track a few hundred milliseconds longer than the last video sample, stays with the
    /// #169 tail-park and #287 premature-end rules that already own the last fraction of a second.
    static let truncatedSourceShortfallSeconds: Double = 1.0

    /// Whether libavformat read this container's duration from a header field rather than measuring it
    /// from the tail. Matroska (Info/Duration), ISO BMFF (mvhd), AVI (avih), ASF and FLV all declare;
    /// MPEG-TS/PS, raw ES and anything else estimate from the last timestamps and are already right
    /// about a truncated file. `formatName` is `AVInputFormat.name`, a comma list for shared demuxers.
    nonisolated static func containerDurationIsHeaderDeclared(formatName: String?) -> Bool {
        guard let formatName else { return false }
        let declaring: Set<String> = ["matroska", "webm", "mov", "mp4", "m4a", "3gp", "3g2", "mj2",
                                      "avi", "asf", "flv"]
        return formatName.split(separator: ",").contains { declaring.contains(String($0)) }
    }

    /// True when any indexed keyframe sits at or past the end of the file: the header's index describes
    /// bytes that were never written (a faststart MP4 cut short keeps a complete sample table).
    nonisolated static func indexClaimsBytesPastEnd(positions: [Int64], fileSize: Int64?) -> Bool {
        guard let fileSize, fileSize > 0 else { return false }
        return positions.contains { $0 >= fileSize }
    }

    /// True when the index's last keyframe stops further short of the declared end than the index's own
    /// keyframe spacing can explain. A table read from the container (Cues, stss) reaches to within one
    /// GOP of the end; an index that libavformat built by scanning (what a file without a readable table
    /// leaves) ends wherever the scan did, which on a truncated file is at or before the last byte,
    /// short of the header's duration by the whole missing stretch. The trust rule's own tail witness
    /// allows 60 s, so a file cut less than a minute short passes it with a plan whose final segment
    /// can never be finished; this reads the shortfall against the GOPs instead. The allowance is
    /// generous (one and a half times the largest gap seen, never under two target segments) so a long
    /// final GOP or a duration padded by a trailing audio or subtitle track does not trip it.
    nonisolated static func indexStopsShortOfDeclaredEnd(
        keyframeSeconds: [Double],
        declaredDuration: Double,
        targetSegmentDuration: Double = HLSVideoEngine.targetSegmentDuration
    ) -> Bool {
        guard declaredDuration.isFinite, declaredDuration > 0,
              let last = keyframeSeconds.max(), last.isFinite else { return false }
        let sorted = keyframeSeconds.sorted()
        var largestGap = 0.0
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            largestGap = Swift.max(largestGap, later - earlier)
        }
        let allowance = Swift.max(largestGap * 1.5, targetSegmentDuration * 2)
        return declaredDuration - last > allowance
    }

    /// Whether the tail probe runs. The header has to be where the duration came from (otherwise it is
    /// already measured), the source has to be byte-positionable (a segmented reader has no tail to seek
    /// to and a forward-only or sequential origin cannot rewind from it), a disc title's duration comes
    /// from its playlist, and the index has to look wrong already: untrustworthy, pointing past the end,
    /// or stopping short of the declared end. A healthy file with a dense in-bounds index that reaches
    /// its end never pays for the read.
    nonisolated static func shouldMeasureSourceEnd(
        headerDeclaresDuration: Bool,
        indexTrustworthy: Bool,
        indexClaimsBytesPastEnd: Bool,
        indexStopsShort: Bool,
        hasSegmentedReader: Bool,
        isSourceSeekable: Bool,
        isDiscSource: Bool,
        sequentialOrigin: Bool
    ) -> Bool {
        guard headerDeclaresDuration, isSourceSeekable, !hasSegmentedReader, !isDiscSource, !sequentialOrigin
        else { return false }
        return !indexTrustworthy || indexClaimsBytesPastEnd || indexStopsShort
    }

    /// Whether a measured end contradicts the declared duration by enough to replace it.
    nonisolated static func sourceIsTruncated(declaredDuration: Double, measuredEnd: Double) -> Bool {
        guard declaredDuration.isFinite, measuredEnd.isFinite, measuredEnd > 0 else { return false }
        return measuredEnd < declaredDuration - truncatedSourceShortfallSeconds
    }
}
