import AzaharCore
import QuartzCore
import SwiftUI
import UIKit

/// UIView backed by a CAMetalLayer. MoltenVK creates the Vulkan swapchain on this layer.
/// Touches on the emulated bottom screen are forwarded to the core in drawable pixels.
final class EmulatorSurfaceUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private weak var activeTouch: UITouch?
    private var lastReported: (CGSize, Bool) = (.zero, false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        metalLayer.pixelFormat = .bgra8Unorm
        for l in [topLayer, bottomLayer] {
            l.magnificationFilter = .linear
            l.backgroundColor = UIColor(white: 0.07, alpha: 1).cgColor // visible screen bounds before the first frame
            l.contentsGravity = .resize
            l.isHidden = true
            layer.addSublayer(l)
        }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Avoids a retain cycle between the view and its display link.
    private final class DisplayLinkProxy: NSObject {
        weak var view: EmulatorSurfaceUIView?
        init(_ v: EmulatorSurfaceUIView) { view = v }
        @objc func tick() { view?.drawSoftwareFrame() }
    }

    override func removeFromSuperview() {
        displayLink?.invalidate()
        displayLink = nil
        super.removeFromSuperview()
    }

    private var lastDiag = Date.distantPast

    fileprivate func drawSoftwareFrame() {
        #if DEBUG
        if Date().timeIntervalSince(lastDiag) > 2 {
            lastDiag = Date()
            var t = AZScreenRect(), b = AZScreenRect(), w: Int32 = 0, h: Int32 = 0
            let ok = az_get_screen_rects(&t, &b)
            let n = az_get_software_frame(0, nil, 0, &w, &h)
            NSLog("BifoldDiag sw=%d running=%d rects=%d top=(%.0f,%.0f %.0fx%.0f en=%d) frame=%llu %dx%d hidden=%d",
                  az_is_software_renderer() ? 1 : 0, az_is_running() ? 1 : 0, ok ? 1 : 0,
                  t.x, t.y, t.width, t.height, t.enabled ? 1 : 0, n, w, h, topLayer.isHidden ? 1 : 0)
        }
        #endif
        guard az_is_software_renderer() else {
            if !topLayer.isHidden { topLayer.isHidden = true; bottomLayer.isHidden = true }
            return
        }
        var top = AZScreenRect(), bottom = AZScreenRect()
        guard az_get_screen_rects(&top, &bottom) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = contentScaleFactor
        for (i, (l, r)) in [(topLayer, top), (bottomLayer, bottom)].enumerated() {
            l.isHidden = !r.enabled
            l.frame = CGRect(x: CGFloat(r.x) / scale, y: CGFloat(r.y) / scale,
                             width: CGFloat(r.width) / scale, height: CGFloat(r.height) / scale)
            var w: Int32 = 0, h: Int32 = 0
            let counter = az_get_software_frame(Int32(i), nil, 0, &w, &h)
            guard counter != 0, counter != lastFrame || l.contents == nil, w > 0, h > 0 else { continue }
            let size = Int(w) * Int(h) * 4
            if buffers[i].count != size { buffers[i] = [UInt8](repeating: 0, count: size) }
            buffers[i].withUnsafeMutableBufferPointer { ptr in
                _ = az_get_software_frame(Int32(i), ptr.baseAddress, Int32(size), &w, &h)
            }
            if let image = Self.makeImage(buffers[i], width: Int(w), height: Int(h)) {
                l.contents = image
            }
            if i == 1 { lastFrame = counter }
        }
        CATransaction.commit()
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Software renderer output (simulator / compatibility mode), drawn on top of the Metal layer.
    private let topLayer = CALayer()
    private let bottomLayer = CALayer()
    private var displayLink: CADisplayLink?
    private var lastFrame: UInt64 = 0
    private var buffers: [[UInt8]] = [[], []]

    /// Called once the layer has a real size and was handed to the core.
    var onReady: (() -> Void)?
    private var didSignalReady = false

    deinit {
        // The core keeps an unretained pointer to the layer. EmulationScreen stops the session
        // before this view goes away; never leave a dangling pointer behind.
        if !az_is_running() {
            az_set_surface(nil, 0, 0, false)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.windowScene?.screen {
            contentScaleFactor = screen.nativeScale
            metalLayer.contentsScale = screen.nativeScale
        }
        reportSurface(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportSurface(force: false)
    }

    private var pixelSize: CGSize {
        CGSize(width: (bounds.width * contentScaleFactor).rounded(),
               height: (bounds.height * contentScaleFactor).rounded())
    }

    func reportSurface(force: Bool) {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let size = pixelSize
        let portrait = bounds.height > bounds.width
        if !force, lastReported.0 == size, lastReported.1 == portrait { return }
        lastReported = (size, portrait)
        metalLayer.drawableSize = size
        let ptr = Unmanaged.passUnretained(metalLayer).toOpaque()
        az_set_surface(ptr, Int32(size.width), Int32(size.height), portrait)
        if !didSignalReady {
            didSignalReady = true
            onReady?()
        }
    }

    // MARK: Touch screen

    private func pixelPoint(_ touch: UITouch) -> CGPoint {
        let p = touch.location(in: self)
        return CGPoint(x: p.x * contentScaleFactor, y: p.y * contentScaleFactor)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let t = touches.first else { return }
        let p = pixelPoint(t)
        if az_touch_begin(Float(p.x), Float(p.y)) {
            activeTouch = t
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        let p = pixelPoint(t)
        az_touch_move(Float(p.x), Float(p.y))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        activeTouch = nil
        az_touch_end()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

/// Lays out the game surface and the controller. Portrait: the surface gets the space above a
/// control area at the bottom (the core scales both screens to fit it); landscape or with a
/// physical controller: the surface fills the view and the controls float over its edges.
final class EmulatorContainerView: UIView {
    let surface = EmulatorSurfaceUIView()
    let pad = VirtualControllerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addSubview(surface)
        addSubview(pad)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let portrait = bounds.height > bounds.width
        if portrait && !pad.isHidden {
            let controls = min(max(bounds.height * 0.36, 260), 360)
            let surfaceHeight = max(bounds.height - controls - safeAreaInsets.bottom * 0.3, bounds.height * 0.45)
            surface.frame = CGRect(x: 0, y: 0, width: bounds.width, height: surfaceHeight)
            pad.portraitControlsTop = surfaceHeight
        } else {
            surface.frame = bounds
            pad.portraitControlsTop = nil
        }
        pad.frame = bounds
    }
}

/// Surface + virtual controller stacked in one UIKit hierarchy so multi-touch works naturally:
/// touches that miss the on-screen buttons fall through to the surface (3DS touch screen).
struct EmulatorSurface: UIViewRepresentable {
    @ObservedObject var settings = AppSettings.shared
    var showController: Bool
    var onReady: () -> Void

    func makeUIView(context: Context) -> EmulatorContainerView {
        let container = EmulatorContainerView()
        container.surface.onReady = onReady
        context.coordinator.pad = container.pad
        return container
    }

    func updateUIView(_ uiView: EmulatorContainerView, context: Context) {
        let pad = uiView.pad
        let wasHidden = pad.isHidden
        pad.isHidden = !showController
        pad.alpha = CGFloat(settings.controllerOpacity)
        pad.hapticsEnabled = settings.haptics
        if wasHidden != pad.isHidden { uiView.setNeedsLayout() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { weak var pad: VirtualControllerView? }
}
