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

    #if canImport(AppKit)
    /// Owns the hosted layer as its backing layer. AVKit's sample-buffer PiP
    /// replaces the source layer's owning view with a private bridge view
    /// added to that view's SUPERVIEW — backing this view directly parked the
    /// bridge inside NSHostingView, which SwiftUI rejects ("Adding
    /// 'AVPictureInPicturePlayerLayerView' as a subview of
    /// NSHostingController.view is not supported"). With an inner child the
    /// bridge lands in this plain NSView instead.
    private let layerHostView = NSView()
    #endif

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
        layerHostView.wantsLayer = true
        layerHostView.layer?.backgroundColor = CGColor.black
        layerHostView.frame = bounds
        layerHostView.autoresizingMask = [.width, .height]
        addSubview(layerHostView)
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

    #if canImport(AppKit)
    /// macOS AVKit PiP MIRRORS the sample-buffer layer without reparenting or
    /// resizing it (probe 2026-08-29: the layer stays this view's subtree at
    /// app-window bounds through the whole session, so the window showed an
    /// unscaled crop). The sizing contract is the render-size delegate
    /// callback: while set, the layer renders at AVKit's requested size and
    /// the mirror shows the whole frame.
    private var pipOverrideSize: CGSize?

    /// Engine-internal: AVKit's PiP render size (nil = PiP over, back to the
    /// view's own bounds).
    func setPiPOverrideSize(_ size: CGSize?) {
        pipOverrideSize = size
        applyLayerFrame()
    }
    #endif

    private func applyLayerFrame() {
        guard let hosted = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if canImport(AppKit)
        let target = pipOverrideSize.map { CGRect(origin: .zero, size: $0) } ?? bounds
        layerHostView.frame = target
        // Only size the layer while it lives in our tree — once AVKit adopts
        // it into its PiP DisplayLayerView, geometry belongs to AVKit.
        if hosted.superlayer === layerHostView.layer || hosted.superlayer == nil {
            hosted.frame = layerHostView.bounds
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
        layer.frame = bounds
        #elseif canImport(AppKit)
        // Plain SUBLAYER of layerHostView, deliberately NOT its backing
        // layer: AVKit's PiP adopts the source layer into its own
        // DisplayLayerView (that is what scales it for the window), and a
        // view-BACKING layer is AppKit-owned — the adoption failed silently
        // and the PiP window mirrored the unmoved, unscaled layer as a crop
        // (probe 2026-08-29: superlayer never changed through a session).
        // layerHostView still keeps AVKit's bridge insertion below the
        // SwiftUI hosting view (the cffb3204 arrangement).
        layerHostView.frame = bounds
        layerHostView.wantsLayer = true
        layerHostView.layer?.addSublayer(layer)
        layer.frame = layerHostView.bounds
        #endif
        hostedLayer = layer
        CATransaction.commit()
    }

    /// Engine-internal. Remove the current hosted layer without
    /// replacement (used on unbind / teardown).
    func detach() {
        guard let hosted = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.removeFromSuperlayer()
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

    public func makeNSView(context: Context) -> NSView {
        // Plain container between AetherPlayerView and SwiftUI: macOS PiP
        // inserts its stand-in views (AVPictureInPicturePlayerLayerView /
        // AVPictureInPictureSampleBufferDisplayLayerView) into superviews of
        // the video hosting chain, and SwiftUI mounts a representable's view
        // DIRECTLY inside NSHostingView — so the player view's own superview
        // was the hosting view and startPictureInPicture tripped SwiftUI's
        // "not supported as a subview of NSHostingController.view" runtime
        // issue (field report 2026-08-28). With this level plus the inner
        // layerHostView, every AVKit insertion point is a plain NSView.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor.black
        let view = AetherPlayerView()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        engine.bind(view: view)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        // #188: rebind on update so an engine swap at the same structural position
        // takes over the reused view. Idempotent for the steady-state case.
        guard let view = nsView.subviews.compactMap({ $0 as? AetherPlayerView }).first else { return }
        engine.bind(view: view)
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        let view = nsView.subviews.compactMap({ $0 as? AetherPlayerView }).first
        Task { @MainActor in
            view?.detach()
        }
    }
}
#endif
