import Foundation
import Libavfilter
import Libavutil

/// Inverse telecine for the software-decode path: NTSC transfers of 24fps
/// film (29.97fps with baked 3:2 pulldown) repeat every fifth frame, a
/// pan judder no pacing fix can remove. The graph is FFmpeg's standard
/// IVTC pair: `fieldmatch` reconstructs progressive frames from telecined
/// fields (a near-no-op on already-progressive input) and `decimate` drops
/// the one duplicate per 5-frame cycle, retiming output to 23.976.
///
/// Opt-in per load (`LoadOptions.inverseTelecine`) and additionally gated by
/// the owning decoder on ~29.97fps nominal rate, because decimate always
/// drops one frame per cycle: on genuinely unique 30fps content that would
/// discard real frames.
///
/// PTS contract: output frames carry PTS on `outputTimeBase` (the
/// buffersink's time_base — decimate rescales the link to 4/5 of the input
/// rate), NOT the stream time_base.
///
/// Torn down on seek (fieldmatch/decimate are temporal); lazily rebuilt.
/// Not thread-safe; the owning decoder serializes access with its lock.
final class InverseTelecineFilter {

    /// Time base of the filter output. Valid while `isActive`.
    private(set) var outputTimeBase = AVRational(num: 0, den: 1)

    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var srcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var pixFmt: Int32 = -1

    /// Latched when the linked FFmpeg build lacks the filters; they will not
    /// appear mid-session.
    private var unavailable = false
    private var loggedUnavailable = false

    var isActive: Bool { graph != nil }

    /// Build (or rebuild after a geometry change) the graph. Returns false
    /// when fieldmatch/decimate are not compiled into the linked FFmpeg
    /// build or setup fails; the caller then emits frames unfiltered.
    func ensureGraph(frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational) -> Bool {
        if graph != nil,
           width == frame.pointee.width,
           height == frame.pointee.height,
           pixFmt == frame.pointee.format {
            return true
        }
        teardown()
        guard !unavailable else { return false }
        guard avfilter_get_by_name("fieldmatch") != nil,
              avfilter_get_by_name("decimate") != nil else {
            unavailable = true
            if !loggedUnavailable {
                loggedUnavailable = true
                EngineLog.emit(
                    "[IVTC] fieldmatch/decimate not in the linked FFmpeg build; inverse telecine unavailable",
                    category: .swPlayback
                )
            }
            return false
        }

        guard let g = avfilter_graph_alloc(),
              let bufferFilter = avfilter_get_by_name("buffer"),
              let sinkFilter = avfilter_get_by_name("buffersink") else {
            return false
        }
        var built = false
        var gOpt: UnsafeMutablePointer<AVFilterGraph>? = g
        defer { if !built { avfilter_graph_free(&gOpt) } }

        let sar = frame.pointee.sample_aspect_ratio
        let sarNum = sar.num > 0 ? sar.num : 1
        let sarDen = sar.den > 0 ? sar.den : 1
        var args = "video_size=\(frame.pointee.width)x\(frame.pointee.height)" +
                   ":pix_fmt=\(frame.pointee.format)" +
                   ":time_base=\(timeBase.num)/\(timeBase.den)" +
                   ":pixel_aspect=\(sarNum)/\(sarDen)"
        if frame.pointee.colorspace != AVCOL_SPC_UNSPECIFIED {
            args += ":colorspace=\(frame.pointee.colorspace.rawValue)"
        }
        if frame.pointee.color_range != AVCOL_RANGE_UNSPECIFIED {
            args += ":range=\(frame.pointee.color_range.rawValue)"
        }

        var src: UnsafeMutablePointer<AVFilterContext>?
        var sink: UnsafeMutablePointer<AVFilterContext>?
        let srcRet = avfilter_graph_create_filter(&src, bufferFilter, "in", args, nil, g)
        let sinkRet = avfilter_graph_create_filter(&sink, sinkFilter, "out", nil, nil, g)
        guard srcRet >= 0, sinkRet >= 0, let srcC = src, let sinkC = sink else {
            EngineLog.emit(
                "[IVTC] create_filter failed src=\(srcRet) sink=\(sinkRet) args=\(args)",
                category: .swPlayback
            )
            return false
        }

        let chain = "fieldmatch,decimate"
        var inputs = avfilter_inout_alloc()
        var outputs = avfilter_inout_alloc()
        defer { avfilter_inout_free(&inputs); avfilter_inout_free(&outputs) }
        guard inputs != nil, outputs != nil else { return false }
        outputs!.pointee.name = strdup("in")
        outputs!.pointee.filter_ctx = srcC
        outputs!.pointee.pad_idx = 0
        outputs!.pointee.next = nil
        inputs!.pointee.name = strdup("out")
        inputs!.pointee.filter_ctx = sinkC
        inputs!.pointee.pad_idx = 0
        inputs!.pointee.next = nil

        let parseRet = avfilter_graph_parse_ptr(g, chain, &inputs, &outputs, nil)
        guard parseRet >= 0 else {
            EngineLog.emit("[IVTC] parse_ptr failed ret=\(parseRet) chain=\(chain)", category: .swPlayback)
            return false
        }
        let configRet = avfilter_graph_config(g, nil)
        guard configRet >= 0 else {
            EngineLog.emit("[IVTC] graph_config failed ret=\(configRet)", category: .swPlayback)
            return false
        }

        built = true
        graph = g
        srcCtx = src
        sinkCtx = sink
        outputTimeBase = av_buffersink_get_time_base(sink)
        width = frame.pointee.width
        height = frame.pointee.height
        pixFmt = frame.pointee.format
        EngineLog.emit(
            "[IVTC] engaged: \(width)x\(height) (\(chain)) outTB=\(outputTimeBase.num)/\(outputTimeBase.den)",
            category: .swPlayback
        )
        return true
    }

    /// Feed a decoded frame (takes ownership; frame is reset after the call).
    func push(_ frame: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let src = srcCtx else { return -1 }
        return av_buffersrc_add_frame_flags(src, frame, 0)
    }

    /// Pull the next filtered frame. AVERROR(EAGAIN) while the decimate
    /// cycle fills (~5 frames of latency at engage/seek).
    func pull(into out: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let sink = sinkCtx else { return -1 }
        return av_buffersink_get_frame(sink, out)
    }

    /// Free the graph. Called on seek (temporal state) and close.
    func teardown() {
        if graph != nil {
            avfilter_graph_free(&graph)
        }
        graph = nil
        srcCtx = nil
        sinkCtx = nil
        outputTimeBase = AVRational(num: 0, den: 1)
        width = 0
        height = 0
        pixFmt = -1
    }

    deinit {
        teardown()
    }
}
