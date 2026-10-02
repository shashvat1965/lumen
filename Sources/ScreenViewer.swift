import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreImage
import Combine

/// A live window onto any display (physical or virtual), with filters —
/// Lumen's take on BetterDisplay's video filter window / PiP.
@MainActor
final class ScreenViewers {
    static let shared = ScreenViewers()
    private var open: [ViewerWindow] = []

    func show(_ id: CGDirectDisplayID, name: String) {
        if let w = open.first(where: { $0.displayID == id }) { w.window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = ViewerWindow(displayID: id, name: name)
        open.append(w)
        w.onClose = { [weak self, weak w] in self?.open.removeAll { $0 === w } }
    }
}

final class ViewerModel: ObservableObject {
    @Published var invert = false
    @Published var grayscale = false
    @Published var flipH = false
    @Published var flipV = false
    @Published var rotation = 0
    @Published var opacity = 1.0
    @Published var pinned = false
    @Published var error: String?
}

@MainActor
final class ViewerWindow: NSObject, NSWindowDelegate, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let window: NSWindow
    var onClose: (() -> Void)?
    private let model = ViewerModel()
    private let surfaceView = NSView()
    private var stream: SCStream?
    private var observers: [Any] = []

    init(displayID: CGDirectDisplayID, name: String) {
        self.displayID = displayID
        let bounds = CGDisplayBounds(displayID)
        let aspect = bounds.width / max(bounds.height, 1)
        let w: CGFloat = 640
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: w / aspect),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        window.backgroundColor = .black
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]

        surfaceView.wantsLayer = true
        surfaceView.layerUsesCoreImageFilters = true
        surfaceView.layer?.contentsGravity = .resizeAspect
        surfaceView.layer?.backgroundColor = NSColor.black.cgColor

        let host = NSHostingView(rootView: ViewerChrome(model: model))
        let root = NSView()
        for v in [surfaceView, host] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: root.topAnchor), v.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        }
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        observers.append(model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.applyFilters() } })
        Task { await start() }
    }

    private func applyFilters() {
        guard let layer = surfaceView.layer else { return }
        var filters: [CIFilter] = []
        if model.invert, let f = CIFilter(name: "CIColorInvert") { filters.append(f) }
        if model.grayscale, let f = CIFilter(name: "CIColorControls") { f.setValue(0, forKey: kCIInputSaturationKey); filters.append(f) }
        layer.filters = filters
        var t = CATransform3DIdentity
        t = CATransform3DRotate(t, CGFloat(model.rotation) * .pi / 180, 0, 0, 1)
        t = CATransform3DScale(t, model.flipH ? -1 : 1, model.flipV ? -1 : 1, 1)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: surfaceView.bounds.midX, y: surfaceView.bounds.midY)
        layer.transform = t
        window.alphaValue = model.opacity
        window.level = model.pinned ? .floating : .normal
        window.collectionBehavior = model.pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
    }

    private func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { model.error = "Display not capturable"; return }
            let mine = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = true
            cfg.queueDepth = 4
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await s.startCapture()
            stream = s
        } catch {
            model.error = "Screen Recording permission is required. Enable Lumen in System Settings › Privacy & Security."
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        MainActor.assumeIsolated { surfaceView.layer?.contents = surface }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        MainActor.assumeIsolated { model.error = error.localizedDescription }
    }

    func windowWillClose(_ notification: Notification) {
        Task { try? await stream?.stopCapture() }
        onClose?()
    }

    func windowDidResize(_ notification: Notification) { applyFilters() }
}

struct ViewerChrome: View {
    @ObservedObject var model: ViewerModel
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.contentShape(Rectangle())
            if let e = model.error {
                Text(e).font(T.f(12)).foregroundStyle(T.text).multilineTextAlignment(.center).padding(14)
                    .panel(radius: 14).padding(30)
                    .frame(maxHeight: .infinity)
            }
            if hover {
                Group {
                    HStack(spacing: 6) {
                        toggle("Invert", "circle.righthalf.filled.inverse", $model.invert)
                        toggle("Grayscale", "camera.filters", $model.grayscale)
                        toggle("Flip horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", $model.flipH)
                        toggle("Flip vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down", $model.flipV)
                        Button { model.rotation = (model.rotation + 90) % 360 } label: { Image(systemName: "rotate.right") }
                            .buttonStyle(PillStyle()).help("Rotate 90°")
                        MiniSlider(value: $model.opacity, range: 0.2...1).frame(width: 90).help("Window opacity")
                        toggle("Keep on top", "pin", $model.pinned)
                    }
                    .padding(6)
                    .panel(radius: 12)
                }
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.snappy) { hover = h } }
    }

    private func toggle(_ title: String, _ icon: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Image(systemName: icon).foregroundStyle(on.wrappedValue ? T.ion : T.text)
        }
        .buttonStyle(PillStyle())
        .help(title)
    }
}
