import AppKit
import MetalKit

/// Pushes an XDR panel past its SDR brightness ceiling. A 1×1 EDR window in the
/// screen's corner keeps macOS's EDR headroom open, which raises the backlight;
/// the boost itself is a gamma table scaled past 1 (`DisplayManager.applyGamma`).
///
/// This replaced a fullscreen overlay with a multiply compositing filter: during
/// a Space transition WindowServer drew that overlay without the filter, so the
/// whole screen flashed white.
@MainActor
final class XDRBoost {
    static let shared = XDRBoost()
    private var triggers: [CGDirectDisplayID: (window: NSWindow, view: BoostView)] = [:]

    func update(for d: Display) {
        guard d.gammaGain > 1, let screen = d.screen,
              let device = MTLCreateSystemDefaultDevice() else { remove(d.id); return }
        let frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1)
        if let t = triggers[d.id] {
            t.window.setFrame(frame, display: false)
            t.view.factor = d.boost
            return
        }
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.animationBehavior = .none
        w.sharingType = .none
        w.isReleasedWhenClosed = false
        let v = BoostView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), device: device)
        v.factor = d.boost
        w.contentView = v
        w.orderFrontRegardless()
        triggers[d.id] = (w, v)
    }

    func remove(_ id: CGDirectDisplayID) {
        triggers.removeValue(forKey: id)?.window.close()
    }

    func removeAll() { triggers.keys.forEach(remove) }
}

/// One EDR pixel. Its only job is to exist, so macOS keeps the headroom open.
final class BoostView: MTKView, MTKViewDelegate {
    var factor: Double = 1
    private var queue: MTLCommandQueue?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        queue = device?.makeCommandQueue()
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        framebufferOnly = true
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        preferredFramesPerSecond = 5
        if let l = layer as? CAMetalLayer {
            l.wantsExtendedDynamicRangeContent = true
            l.isOpaque = false
        }
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
