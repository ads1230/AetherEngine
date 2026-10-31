import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// A source cut short keeps its full-length header (field 2026-10-31: a Jellyfin MKV declaring
/// 1281.9 s whose bytes ended at 554.0 s). The session measures the real end and plans to it.
@Suite("Truncated source: plan to the measured end, not the header's")
struct TruncatedSourcePlanTests {

    // MARK: - pure decisions

    @Test("containers whose duration comes from a header qualify; tail-estimated ones do not")
    func headerDeclaredContainers() {
        #expect(HLSVideoEngine.containerDurationIsHeaderDeclared(formatName: "matroska,webm"))
        #expect(HLSVideoEngine.containerDurationIsHeaderDeclared(formatName: "mov,mp4,m4a,3gp,3g2,mj2"))
        #expect(HLSVideoEngine.containerDurationIsHeaderDeclared(formatName: "avi"))
        #expect(!HLSVideoEngine.containerDurationIsHeaderDeclared(formatName: "mpegts"))
        #expect(!HLSVideoEngine.containerDurationIsHeaderDeclared(formatName: "mpeg"))
        #expect(!HLSVideoEngine.containerDurationIsHeaderDeclared(formatName: "hls"))
        #expect(!HLSVideoEngine.containerDurationIsHeaderDeclared(formatName: nil))
    }

    @Test("an index entry at or past the file size is a header describing bytes never written")
    func indexPastEnd() {
        #expect(HLSVideoEngine.indexClaimsBytesPastEnd(positions: [10, 500, 128_270_336], fileSize: 128_270_336))
        #expect(!HLSVideoEngine.indexClaimsBytesPastEnd(positions: [10, 500, 128_270_335], fileSize: 128_270_336))
        #expect(!HLSVideoEngine.indexClaimsBytesPastEnd(positions: [10, 500], fileSize: nil))
        #expect(!HLSVideoEngine.indexClaimsBytesPastEnd(positions: [], fileSize: 100))
    }

    @Test("the probe runs for a header-declared, byte-positionable source whose index looks wrong")
    func probeGate() {
        // The field case: Matroska without usable Cues over HTTP.
        #expect(HLSVideoEngine.shouldMeasureSourceEnd(
            headerDeclaresDuration: true, indexTrustworthy: false, indexClaimsBytesPastEnd: false, indexStopsShort: false,
            hasSegmentedReader: false, isSourceSeekable: true, isDiscSource: false, sequentialOrigin: false))
        // A faststart MP4 cut short: dense index, entries past the end.
        #expect(HLSVideoEngine.shouldMeasureSourceEnd(
            headerDeclaresDuration: true, indexTrustworthy: true, indexClaimsBytesPastEnd: true, indexStopsShort: false,
            hasSegmentedReader: false, isSourceSeekable: true, isDiscSource: false, sequentialOrigin: false))
        // A healthy file with a dense in-bounds index never pays for the read.
        #expect(!HLSVideoEngine.shouldMeasureSourceEnd(
            headerDeclaresDuration: true, indexTrustworthy: true, indexClaimsBytesPastEnd: false, indexStopsShort: false,
            hasSegmentedReader: false, isSourceSeekable: true, isDiscSource: false, sequentialOrigin: false))
        // MPEG-TS: libavformat measured the duration from the tail already.
        #expect(!HLSVideoEngine.shouldMeasureSourceEnd(
            headerDeclaresDuration: false, indexTrustworthy: false, indexClaimsBytesPastEnd: false, indexStopsShort: false,
            hasSegmentedReader: false, isSourceSeekable: true, isDiscSource: false, sequentialOrigin: false))
        // Nowhere to seek to: forward-only, segmented, sequential, or a disc title.
        for (seekable, segmented, disc, sequential) in [(false, false, false, false), (true, true, false, false),
                                                         (true, false, true, false), (true, false, false, true)] {
            #expect(!HLSVideoEngine.shouldMeasureSourceEnd(
                headerDeclaresDuration: true, indexTrustworthy: false, indexClaimsBytesPastEnd: false, indexStopsShort: false,
                hasSegmentedReader: segmented, isSourceSeekable: seekable, isDiscSource: disc,
                sequentialOrigin: sequential))
        }
    }

    @Test("an index that stops further short of the declared end than its GOPs explain is suspect")
    func indexStopsShort() {
        // The fixture's shape: 2 s GOPs scanned to 16 s of a declared 30 s.
        #expect(HLSVideoEngine.indexStopsShortOfDeclaredEnd(
            keyframeSeconds: stride(from: 0.0, through: 16.0, by: 2.0).map { $0 }, declaredDuration: 30.021))
        // A Cues-backed 10 s GOP file reaching to within one GOP of its end.
        #expect(!HLSVideoEngine.indexStopsShortOfDeclaredEnd(
            keyframeSeconds: stride(from: 0.0, through: 1270.0, by: 10.0).map { $0 }, declaredDuration: 1281.882))
        // A duration padded a few seconds by a trailing audio tail stays inside the allowance.
        #expect(!HLSVideoEngine.indexStopsShortOfDeclaredEnd(
            keyframeSeconds: stride(from: 0.0, through: 28.0, by: 2.0).map { $0 }, declaredDuration: 30.5))
        // Nothing indexed, or no declaration: nothing to compare.
        #expect(!HLSVideoEngine.indexStopsShortOfDeclaredEnd(keyframeSeconds: [], declaredDuration: 30))
        #expect(!HLSVideoEngine.indexStopsShortOfDeclaredEnd(keyframeSeconds: [0, 2], declaredDuration: 0))
        // A trusted-but-short index is enough on its own to run the probe.
        #expect(HLSVideoEngine.shouldMeasureSourceEnd(
            headerDeclaresDuration: true, indexTrustworthy: true, indexClaimsBytesPastEnd: false, indexStopsShort: true,
            hasSegmentedReader: false, isSourceSeekable: true, isDiscSource: false, sequentialOrigin: false))
    }

    @Test("only a measured end clearly short of the declaration replaces it")
    func truncationVerdict() {
        #expect(HLSVideoEngine.sourceIsTruncated(declaredDuration: 1281.882, measuredEnd: 554.027))
        // Rounded-up declarations and a slightly longer audio tail stay with the tail-park rules.
        #expect(!HLSVideoEngine.sourceIsTruncated(declaredDuration: 30.021, measuredEnd: 29.6))
        #expect(!HLSVideoEngine.sourceIsTruncated(declaredDuration: 30.0, measuredEnd: 30.0))
        #expect(!HLSVideoEngine.sourceIsTruncated(declaredDuration: 30.0, measuredEnd: 31.0))
        #expect(!HLSVideoEngine.sourceIsTruncated(declaredDuration: 30.0, measuredEnd: 0))
        #expect(!HLSVideoEngine.sourceIsTruncated(declaredDuration: .nan, measuredEnd: 10))
    }

    @Test("the demuxer reports the shorter of the declaration and the measured end")
    func durationCap() {
        #expect(Demuxer.durationApplyingMeasuredSourceEnd(1281.882, measuredEnd: 554.027) == 554.027)
        #expect(Demuxer.durationApplyingMeasuredSourceEnd(30, measuredEnd: nil) == 30)
        #expect(Demuxer.durationApplyingMeasuredSourceEnd(30, measuredEnd: 30) == 30)
        #expect(Demuxer.durationApplyingMeasuredSourceEnd(30, measuredEnd: 45) == 30)
        #expect(Demuxer.durationApplyingMeasuredSourceEnd(30, measuredEnd: 0) == 30)
    }

    // MARK: - the fixture: a 30 s MKV cut at 60 % of its bytes (data ends near 18 s)

    static let fixture = "truncated-header-duration.mkv"

    @Test("the demuxer measures where the data ends while the header still says 30 s",
          .enabled(if: fixtureExists(fixture), "run Scripts/fetch-fixtures.sh to generate the clip"))
    func demuxerMeasuresEnd() throws {
        let dem = Demuxer()
        defer { dem.close() }
        try dem.open(url: fixtureURL(Self.fixture))
        let declared = dem.duration
        #expect(abs(declared - 30.0) < 0.5, "header declares \(declared)s")
        let measured = try #require(dem.measureSourceEndSeconds())
        #expect(measured > 15 && measured < 20, "data ends at \(measured)s")
        dem.measuredSourceEndSeconds = measured
        #expect(dem.duration == measured)
        // The probe left the context at EOF; a reposition to the head still reads.
        #expect(dem.seek(to: 0))
        let packet = try #require(try dem.readPacket())
        var maybe: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&maybe)
    }

    @Test("the session plans to the measured end and its last segment is producible",
          .enabled(if: fixtureExists(fixture), "run Scripts/fetch-fixtures.sh to generate the clip"),
          .timeLimit(.minutes(2)))
    func sessionPlansToMeasuredEnd() throws {
        let log = LogRecorder()
        EngineLog.structuredHandler = { line, _, _ in log.record(line) }
        defer { EngineLog.structuredHandler = nil }
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        let planLines = log.lines.filter { $0.contains("truncated") || $0.contains("segment plan") }
        #expect(planLines.contains { $0.contains("truncated source: the container declares") },
                Comment(rawValue: "the session must report the truncation:\n" + log.lines.joined(separator: "\n")))
        let mediaURL = try #require(engine.mediaPlaylistURL)
        let playlist = try String(contentsOf: mediaURL, encoding: .utf8)
        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        let uris = lines.filter { $0.hasSuffix(".mp4") && !$0.hasPrefix("#") }
        let total = durations.reduce(0, +)
        #expect(total > 15 && total < 20,
                Comment(rawValue: "EXTINF sums to \(total)s for a source whose data ends near 18 s:\n\(playlist)\n"
                + planLines.joined(separator: "\n")))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        // Every advertised segment, the last one included, is cut from bytes that exist.
        let last = try #require(uris.last)
        let data = try Data(contentsOf: mediaURL.deletingLastPathComponent().appendingPathComponent(last))
        #expect(!data.isEmpty, "the final segment \(last) must be producible")
    }
}

/// Engine log lines captured through `EngineLog.structuredHandler` for the session assertions.
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func record(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}
