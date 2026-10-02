import AppKit

struct VirtualConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var width: Int
    var height: Int
    var hiDPI: Bool
    var refresh: Double = 60
    var serial: UInt32 = UInt32.random(in: 1000...999_999)
    /// Physical display (vendor-model-serial key) that mirrors this screen, i.e. "flexible scaling".
    var mirrorKey: String?

    var label: String { "\(width) × \(height)\(hiDPI ? " HiDPI" : "")" }
}

/// Virtual screens live only as long as Lumen does, so configs are persisted
/// and recreated on launch.
@MainActor
final class VirtualScreens: ObservableObject {
    static let shared = VirtualScreens()
    @Published private(set) var configs: [VirtualConfig] = []
    private var live: [UUID: CGVirtualDisplay] = [:]

    static let presets: [(String, Int, Int)] = [
        ("1080p", 1920, 1080), ("1440p", 2560, 1440), ("4K", 3840, 2160),
        ("Ultrawide 1440", 3440, 1440), ("5K2K", 5120, 2160), ("16:10", 2560, 1600),
    ]

    func start() {
        if let data = UserDefaults.standard.data(forKey: "virtualScreens"),
           let saved = try? JSONDecoder().decode([VirtualConfig].self, from: data) {
            configs = saved
            saved.forEach(spawn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in configs.forEach(applyMirror) }
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(configs), forKey: "virtualScreens")
    }

    func displayID(for c: VirtualConfig) -> CGDirectDisplayID? { live[c.id]?.displayID }
    func isVirtual(_ id: CGDirectDisplayID) -> Bool { live.values.contains { $0.displayID == id } }

    func add(_ c: VirtualConfig) {
        configs.append(c)
        save()
        spawn(c)
        DisplayManager.shared.scheduleRefresh()
    }

    func remove(_ c: VirtualConfig) {
        if c.mirrorKey != nil { var cc = c; cc.mirrorKey = nil; applyMirror(cc) }
        live.removeValue(forKey: c.id)  // releasing the object tears the display down
        configs.removeAll { $0.id == c.id }
        save()
        DisplayManager.shared.scheduleRefresh()
    }

    func setMirror(_ c: VirtualConfig, to key: String?) {
        guard let i = configs.firstIndex(of: c) else { return }
        let old = configs[i]
        if old.mirrorKey != nil { applyMirror(old, enable: false) }
        configs[i].mirrorKey = key
        save()
        applyMirror(configs[i])
    }

    private func spawn(_ c: VirtualConfig) {
        let scale = c.hiDPI ? 2 : 1
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = c.name
        desc.maxPixelsWide = UInt32(c.width * scale)
        desc.maxPixelsHigh = UInt32(c.height * scale)
        // ~110 logical ppi keeps macOS' default scaling sensible.
        desc.sizeInMillimeters = CGSize(width: Double(c.width) / 110 * 25.4, height: Double(c.height) / 110 * 25.4)
        desc.vendorID = 0x4C4D  // "LM"
        desc.productID = 0x5653
        desc.serialNum = c.serial
        desc.terminationHandler = { _, _ in }

        guard let display = CGVirtualDisplay(descriptor: desc) else { return }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = c.hiDPI ? 1 : 0
        // Offer a ladder of sizes so the resolution slider has room to move.
        var modes: [CGVirtualDisplayMode] = []
        for f in [1.0, 0.875, 0.75, 0.625, 0.5] {
            let w = UInt32((Double(c.width) * f).rounded()) & ~1, h = UInt32((Double(c.height) * f).rounded()) & ~1
            modes.append(CGVirtualDisplayMode(width: w * UInt32(scale), height: h * UInt32(scale), refreshRate: c.refresh))
            if c.hiDPI { modes.append(CGVirtualDisplayMode(width: w, height: h, refreshRate: c.refresh)) }
        }
        settings.modes = modes
        guard display.apply(settings) else { return }
        live[c.id] = display
    }

    private func applyMirror(_ c: VirtualConfig) { applyMirror(c, enable: c.mirrorKey != nil) }

    private func applyMirror(_ c: VirtualConfig, enable: Bool) {
        guard let key = c.mirrorKey ?? (enable ? nil : c.mirrorKey),
              let physical = DisplayManager.shared.displays.first(where: { $0.persistKey == key }) else {
            // Turning off: un-mirror whichever physical display mirrors us.
            if !enable, let vid = displayID(for: c) {
                for d in DisplayManager.shared.displays where CGDisplayMirrorsDisplay(d.id) == vid { unmirror(d.id) }
            }
            return
        }
        guard let vid = displayID(for: c) else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        CGConfigureDisplayMirrorOfDisplay(cfg, physical.id, enable ? vid : kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    private func unmirror(_ id: CGDirectDisplayID) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }
}
