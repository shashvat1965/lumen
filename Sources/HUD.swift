import AppKit
import SwiftUI

@MainActor
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    private let model = HUDModel()

    func show(for d: Display) {
        model.value = d.sliderValue
        model.zones = d.zones
        model.label = d.boost > 1.001 ? String(format: "XDR %.1f×", d.boost) : d.softDim < 0.999 && d.hasHardwareBrightness ? "Dimmed" : "\(Int((d.hasHardwareBrightness ? d.brightness : d.softDim) * 100))%"
        model.name = d.name

        let p = panel ?? makePanel()
        panel = p
        if let screen = d.screen ?? NSScreen.main {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 110))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()

        hide?.cancel()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; p?.animator().alphaValue = 0 }) { p?.orderOut(nil) }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        return p
    }
}

final class HUDModel: ObservableObject {
    @Published var value: Double = 0
    @Published var zones = Display.Zones(dim: 0, xdr: 1)
    @Published var label = ""
    @Published var name = ""
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.name).font(T.f(12, .medium)).foregroundStyle(T.text)
                Spacer()
                Text(model.label).font(T.f(12, .medium)).monospacedDigit().foregroundStyle(model.value > model.zones.xdr ? T.xdr : T.text2)
            }
            LevelBar(value: model.value, zones: model.zones, icon: "sun.max.fill", height: 22, interactive: false)
        }
        .padding(14)
        .frame(width: 300, height: 76)
        .panel(radius: 18)
    }
}
