import XCTest
import CoreVideo
import CoreGraphics
@testable import AetherEngine

/// SW-PiP burn-in round trip: video pixels AWAY from the subtitle must come
/// back byte-identical, or PiP visibly shifts brightness for the lifetime of
/// every cue (field report 2026-08-28: DVB cues lightened the whole picture).
final class SubtitleCompositorRoundTripTests: XCTestCase {

    private func makeBuffer(width: Int, height: Int, luma: UInt8, tagged601: Bool) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let yBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height { memset(yBase.advanced(by: row * yBPR), Int32(luma), width) }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let cBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(height / 2) { memset(cBase.advanced(by: row * cBPR), 128, width) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if tagged601 {
            // What a PAL SD decode carries.
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_EBU_3213, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        }
        return buffer
    }

    private func lumaAt(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return base.advanced(by: y * bpr + x).assumingMemoryBound(to: UInt8.self).pointee
    }

    func testVideoRangeLumaSurvivesCompositing() {
        for tagged in [false, true] {
            for lumaIn: UInt8 in [16, 60, 126, 200, 235] {
                let src = makeBuffer(width: 704, height: 576, luma: lumaIn, tagged601: tagged)
                let compositor = SubtitleFrameCompositor()
                compositor.update(
                    cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Hello"))],
                    enabled: true)
                let out = compositor.composite(src, ptsSeconds: 5)
                XCTAssertTrue(out !== src, "compositor passed through; cue not composited")
                // Sample far from the bottom-band subtitle.
                let got = lumaAt(out, x: 32, y: 32)
                print("BENCH tagged601=\(tagged) yIn=\(lumaIn) yOut=\(got) drift=\(Int(got) - Int(lumaIn))")
                XCTAssertLessThanOrEqual(
                    abs(Int(got) - Int(lumaIn)), 1,
                    "luma drifted (tagged601=\(tagged), yIn=\(lumaIn)): asymmetric decode/encode colorimetry")
            }
        }
    }
}
