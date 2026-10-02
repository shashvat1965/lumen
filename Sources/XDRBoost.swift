import AppKit
import MetalKit

/// Pushes an XDR panel past its SDR brightness ceiling by laying a fullscreen
/// EDR surface over the screen and multiplying everything beneath it by a
/// value > 1. macOS raises the backlight to make room for the EDR headroom.
@MainActor
final class XDRBoost {
    static let shared = XDRBoost()
    private var overlays: [CGDirectDisplayID: (window: NSWindow, view: BoostView)] = [:]

    func update(for d: Display) {
        guard d.isBuiltin, d.isActive, d.boost > 1.001, let screen = d.screen,
              let device = MTLCreateSystemDefaultDevice() else { remove(d.id); return }
        if let o = overlays[d.id] {
            o.window.setFrame(screen.frame, display: false)
            o.view.factor = d.boost
            return
        }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.sharingType = .none
        w.isReleasedWhenClosed = false
        let v = BoostView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        v.factor = d.boost
        w.contentView = v
        w.orderFrontRegardless()
        overlays[d.id] = (w, v)
    }

    func remove(_ id: CGDirectDisplayID) {
        overlays.removeValue(forKey: id)?.window.close()
    }

    func removeAll() { overlays.keys.forEach(remove) }
}

final class BoostView: MTKView, MTKViewDelegate {
    var factor: Double = 1
    private var queue: MTLCommandQueue?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        queue = device?.makeCommandQueue()
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        framebufferOnly = true
        preferredFramesPerSecond = 10
        if let l = layer as? CAMetalLayer {
            l.wantsExtendedDynamicRangeContent = true
            l.isOpaque = false
        }
        layer?.compositingFilter = "multiplyBlendMode"
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue?.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: factor, green: factor, blue: factor, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
