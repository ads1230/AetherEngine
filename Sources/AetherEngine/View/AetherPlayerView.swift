import Foundation
import QuartzCore
import AVFoundation

#if canImport(UIKit)
import UIKit
import SwiftUI
#elseif canImport(AppKit)
import AppKit
import SwiftUI
#endif

/// A single render surface owned by AetherEngine.
///
/// The host embeds one instance (UIKit on iOS/tvOS, AppKit on macOS) and
/// hands it to `engine.bind(view:)`. The engine then attaches whichever
/// `CALayer` is active for the current source:
///
/// - `AVPlayerLayer` for the native AVPlayer path (HEVC, H.264, plus AV1
///   on devices with hardware AV1 decode).
/// - `AVSampleBufferDisplayLayer` for the software path driven by
///   `SoftwarePlaybackHost` (AV1 without hardware decode, VP9, MPEG-4
///   Part 2, MPEG-2, VC-1).
///
/// The view swaps the hosted layer internally on dispatch changes, so the
/// host never needs to know which backend is rendering. The active layer
/// can also change across sessions when consecutive sources dispatch to
/// different paths.
@MainActor
public final class AetherPlayerView: PlatformBaseView {

    private var hostedLayer: CALayer?

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    #endif

    private func commonInit() {
        #if canImport(UIKit)
        backgroundColor = .black
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = CGColor.black
        #endif
    }

    // MARK: - Layout

    #if canImport(UIKit)
    public override func layoutSubviews() {
        super.layoutSubviews()
        applyLayerFrame()
    }
    #elseif canImport(AppKit)
    public override func layout() {
        super.layout()
        applyLayerFrame()
    }
    #endif

    private func applyLayerFrame() {
        guard let hosted = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if canImport(AppKit)
        if hosted === layer {
            hosted.bounds = bounds
        } else {
            hosted.frame = bounds
        }
        #else
        hosted.frame = bounds
        #endif
        CATransaction.commit()
    }

    // MARK: - Engine-only attachment

    /// Engine-internal. Replace whichever layer is currently hosted with
    /// `layer`. Synchronous, runs on the main actor, no implicit
    /// animations so swaps don't flash. Idempotent if the same layer is
    /// already attached.
    func attach(_ layer: CALayer) {
        if hostedLayer === layer { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.removeFromSuperlayer()
        #if canImport(UIKit)
        self.layer.addSublayer(layer)
        #elseif canImport(AppKit)
        // macOS PiP's sample-buffer path expects the source layer to be owned
        // by a real NSView. Hosting it only as a sublayer lets AVKit attach its
        // private PiP bridge view to NSHostingController.view, which SwiftUI
        // warns is an unsupported hierarchy.
        self.layer = layer
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        #endif
        if layer === self.layer {
            layer.bounds = bounds
        } else {
            layer.frame = bounds
        }
        hostedLayer = layer
        CATransaction.commit()
    }

    /// Engine-internal. Remove the current hosted layer without
    /// replacement (used on unbind / teardown).
    func detach() {
        guard let hosted = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if canImport(AppKit)
        if hosted === layer {
            let blankLayer = CALayer()
            blankLayer.backgroundColor = CGColor.black
            layer = blankLayer
        } else {
            hosted.removeFromSuperlayer()
        }
        #else
        hosted.removeFromSuperlayer()
        #endif
        hostedLayer = nil
        CATransaction.commit()
    }
}

// MARK: - Platform base view alias

#if canImport(UIKit)
public typealias PlatformBaseView = UIView
#elseif canImport(AppKit)
public typealias PlatformBaseView = NSView
#endif

// MARK: - SwiftUI wrapper

#if canImport(UIKit)
/// SwiftUI surface for embedding AetherEngine playback.
///
/// ```swift
/// AetherPlayerSurface(engine: engine)
///     .ignoresSafeArea()
/// ```
public struct AetherPlayerSurface: UIViewRepresentable {
    private let engine: AetherEngine

    public init(engine: AetherEngine) {
        self.engine = engine
    }

    public func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    public func updateUIView(_ uiView: AetherPlayerView, context: Context) {
        // #188: when a host swaps its AetherEngine instance at the same structural
        // position, SwiftUI reuses this platform view and only calls updateUIView,
        // so the new engine's bind(view:) never runs from makeUIView. Rebinding here
        // points the new engine at the reused view and re-attaches its layer; bind is
        // idempotent for the steady-state existing === view case, so this is cheap.
        engine.bind(view: uiView)
    }

    public static func dismantleUIView(_ uiView: AetherPlayerView, coordinator: ()) {
        // The engine releases its weak ref when the view deinits, but
        // explicit unbind keeps the layer removed promptly on teardown.
        Task { @MainActor in
            uiView.detach()
        }
    }
}
#elseif canImport(AppKit)
public struct AetherPlayerSurface: NSViewRepresentable {
    private let engine: AetherEngine

    public init(engine: AetherEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    public func updateNSView(_ nsView: AetherPlayerView, context: Context) {
        // #188: rebind on update so an engine swap at the same structural position
        // takes over the reused view. Idempotent for the steady-state case.
        engine.bind(view: nsView)
    }

    public static func dismantleNSView(_ nsView: AetherPlayerView, coordinator: ()) {
        Task { @MainActor in
            nsView.detach()
        }
    }
}
#endif
