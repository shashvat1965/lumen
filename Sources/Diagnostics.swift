import AppKit
import SwiftUI

/// `Lumen --diagnose` prints what Lumen can see and control, then exits.
@MainActor
enum Diagnostics {
    static func run() {
        let m = DisplayManager.shared
        print("DDC channels:", DDCChannel.discover().map { "\($0.name ?? "?") v\($0.vendor ?? 0) p\($0.product ?? 0)" })
        for d in m.displays {
            print("• \(d.name) id=\(d.id) builtin=\(d.isBuiltin) active=\(d.isActive) main=\(d.isMain)")
            print("  mode=\(d.subtitle) modes=\(d.modes.count) steps=\(d.resolutionSteps.map(\.sizeLabel))")
            print("  brightness=\(d.brightness) xdr=\(d.xdrCapable) maxBoost=\(d.maxBoost) hdrSupported=\(d.hdrSupported) hdr=\(d.hdrEnabled)")
            print("  ddc=\(d.ddc?.name ?? "none")")
            if let ddc = d.ddc {
                let sem = DispatchSemaphore(value: 0)
                for code in [VCP.brightness, .contrast, .volume, .input] {
                    ddc.read(code) { r in print("  DDC \(code): \(r.map { "\($0.current)/\($0.max)" } ?? "no reply")"); sem.signal() }
                    sem.wait()
                }
            }
        }
        for d in m.displays where d.isActive {
            print("  [\(d.name)] color modes (\(d.colorModes.count), +\(d.otherTimingModes) at other timings), current=\(d.currentColor?.summary ?? "?")")
            for c in d.colorModes.prefix(20) { print("     #\(c.id) \(c.summary) colorimetry=\(c.colorimetry)") }
        }
        if CommandLine.arguments.contains("--vtest") {
            let before = m.displays.count
            let v = VirtualConfig(name: "Lumen Test", width: 2560, height: 1440, hiDPI: true)
            VirtualScreens.shared.add(v)
            m.refresh()
            let vid = VirtualScreens.shared.displayID(for: v)
            print("virtual id=\(vid.map(String.init) ?? "nil") displays \(before) -> \(m.displays.count)")
            if let vid { let d = Display(id: vid); d.refreshState(); print("  virtual modes:", d.resolutionSteps.map { $0.sizeLabel + ($0.hiDPI ? "h" : "") }) }
            VirtualScreens.shared.remove(v)
        }
        print("NightShift available=\(NightShift.shared.available) on=\(NightShift.shared.isOn) strength=\(NightShift.shared.strength)")
        print("Grayscale=\(m.grayscale) Accessibility=\(MediaKeys.shared.isTrusted)")
        if CommandLine.arguments.contains("--window") {
            let host = NSHostingView(rootView: RootView().environmentObject(m))
            let w = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 340, height: 600), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            // Synthetic wallpaper so translucency can be judged without capturing the real screen.
            let wall = NSHostingView(rootView: LinearGradient(colors: [Color(red: 0.18, green: 0.32, blue: 0.62), Color(red: 0.55, green: 0.25, blue: 0.45), Color(red: 0.95, green: 0.6, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Text("Lorem ipsum dolor sit amet").font(.system(size: 46, weight: .black)).foregroundStyle(.white.opacity(0.8)).rotationEffect(.degrees(-20))))
            let container = NSView()
            wall.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(wall)
            NSLayoutConstraint.activate([wall.leadingAnchor.constraint(equalTo: container.leadingAnchor), wall.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                         wall.topAnchor.constraint(equalTo: container.topAnchor), wall.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
            w.contentView = container
            host.translatesAutoresizingMaskIntoConstraints = false
            w.contentView!.addSubview(host)
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 30),
                                         host.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -30),
                                         host.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 40),
                                         host.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -30)])
            w.setContentSize(NSSize(width: host.fittingSize.width + 60, height: host.fittingSize.height + 70))
            w.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            print("WINDOW \(w.windowNumber)"); fflush(stdout)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            for scheme in [ColorScheme.dark, .light] {
                let view = RootView().environmentObject(m).environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.94))
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1] + "-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
        exit(0)
    }
}
