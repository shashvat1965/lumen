import AppKit
import SwiftUI

/// "Keep these display settings?" with an auto-revert countdown, shown on the
/// built-in panel so it stays visible even if the changed display goes dark.
@MainActor
final class ConfirmPanel: ObservableObject {
    static let shared = ConfirmPanel()
    @Published var message = ""
    @Published var remaining = 15
    private var panel: NSPanel?
    private var timer: Timer?
    private var revert: (() -> Void)?

    func ask(_ message: String, revert: @escaping () -> Void) {
        finish(keep: true)
        self.message = message
        self.revert = revert
        remaining = 15
        let p = panel ?? make()
        panel = p
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false } ?? NSScreen.main
        if let f = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - 170, y: f.midY - 60)) }
        p.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = ConfirmPanel.shared
                c.remaining -= 1
                if c.remaining <= 0 { c.finish(keep: false) }
            }
        }
    }

    func finish(keep: Bool) {
        timer?.invalidate(); timer = nil
        if !keep { revert?() }
        revert = nil
        panel?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ConfirmView(model: self))
        return p
    }
}

struct ConfirmView: View {
    @ObservedObject var model: ConfirmPanel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.warn)
                Text(model.message).font(T.f(13, .medium)).foregroundStyle(T.text).lineLimit(2)
            }
            Text("Reverting in \(model.remaining) s").font(T.f(11.5)).monospacedDigit().foregroundStyle(T.text3)
                .contentTransition(.numericText())
            HStack {
                Button("Revert") { model.finish(keep: false) }.buttonStyle(PillStyle())
                Spacer()
                Button("Keep") { model.finish(keep: true) }.buttonStyle(PillStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 120)
        .panel(radius: 18)
    }
}
