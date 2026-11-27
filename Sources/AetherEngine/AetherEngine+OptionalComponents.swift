import Foundation
import os

extension AetherEngine {

    /// The parts of the engine that are compiled only when a host enables their package trait, all off
    /// by default (README, "Optional components"). Without its trait a component is not in the binary
    /// and the option that asks for it changes nothing, so a host reads `isBuiltIn` to hide a setting
    /// that would do nothing in its build.
    public enum OptionalComponent: String, CaseIterable, Sendable {
        /// TrueHD Atmos object rendering for `LoadOptions.objectAudioRendering` (trait `TrueHDObjectAudio`).
        case trueHDObjectAudio = "TrueHDObjectAudio"
        /// DTS:X height and object rendering for `LoadOptions.objectAudioRendering` (trait `DTSXObjectAudio`).
        case dtsxObjectAudio = "DTSXObjectAudio"
        /// Profile 7 FEL dual-layer composition for `LoadOptions.preferDualLayerDolbyVision`
        /// (trait `DualLayerDolbyVision`).
        case dualLayerDolbyVision = "DualLayerDolbyVision"
        /// Stills (scrub thumbnails, I-frame stills, held pictures) of Dolby Vision Profile 5 / 10.0
        /// sources, which have no base layer to show (trait `DolbyVisionStillReshaping`).
        case dolbyVisionStillReshaping = "DolbyVisionStillReshaping"
        /// A Profile 7 FEL source's enhancement layer folded into the Profile 8.1 RPU on the native route: the
        /// stream's mapping kept, its luma curve lifted by the scene's residual (trait `DolbyVisionFelCurves`).
        case dolbyVisionFelCurves = "DolbyVisionFelCurves"

        /// The package trait that compiles the component.
        public var traitName: String { rawValue }

        /// Whether this build carries the component.
        public var isBuiltIn: Bool {
            switch self {
            case .trueHDObjectAudio:
                #if TrueHDObjectAudio
                return true
                #else
                return false
                #endif
            case .dtsxObjectAudio:
                #if DTSXObjectAudio
                return true
                #else
                return false
                #endif
            case .dualLayerDolbyVision:
                #if DualLayerDolbyVision
                return true
                #else
                return false
                #endif
            case .dolbyVisionStillReshaping:
                #if DolbyVisionStillReshaping
                return true
                #else
                return false
                #endif
            case .dolbyVisionFelCurves:
                #if DolbyVisionFelCurves
                return true
                #else
                return false
                #endif
            }
        }

        /// Host switch over a built-in `dolbyVisionStillReshaping` (reDiffusion fork). Off, the engine
        /// treats a Dolby Vision Profile 5 / 10.0 source the way a build without the trait does: no
        /// reshaped stills, scrub previews and the held picture through the system compositor. On by
        /// default. A session reads it when it opens, so set it before `load`.
        public static var dolbyVisionStillReshapingEnabled: Bool {
            get { stillReshapingSwitch.withLock { $0 } }
            set { stillReshapingSwitch.withLock { $0 = newValue } }
        }

        private static let stillReshapingSwitch = OSAllocatedUnfairLock(initialState: true)

        /// Whether Dolby Vision Profile 5 / 10.0 frames become reshaped stills: built in and not
        /// switched off by the host.
        static var reshapesDolbyVisionStills: Bool {
            dolbyVisionStillReshaping.isBuiltIn && dolbyVisionStillReshapingEnabled
        }
    }
}
