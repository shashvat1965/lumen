import AppKit
import Combine

struct ModeOption: Identifiable, Hashable {
    let mode: CGDisplayMode
    let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
    let refresh: Double

    init(_ m: CGDisplayMode) {
        mode = m
        width = m.width; height = m.height
        pixelWidth = m.pixelWidth; pixelHeight = m.pixelHeight
        refresh = m.refreshRate
    }

    var hiDPI: Bool { pixelWidth > width }
    var sizeKey: String { "\(width)x\(height)\(hiDPI ? "h" : "")" }
    var id: String { "\(sizeKey)@\(refresh)" }
    var sizeLabel: String { "\(width) × \(height)" }
    var refreshLabel: String { refresh == 0 ? "Default" : refresh.rounded() == refresh ? "\(Int(refresh)) Hz" : String(format: "%.2f Hz", refresh) }

    static func == (a: ModeOption, b: ModeOption) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct InputSource: Identifiable, Hashable {
    let id: UInt16
    let name: String
    static let common: [InputSource] = [
        .init(id: 0x0F, name: "DisplayPort 1"), .init(id: 0x10, name: "DisplayPort 2"),
        .init(id: 0x11, name: "HDMI 1"), .init(id: 0x12, name: "HDMI 2"),
        .init(id: 0x1B, name: "USB-C"), .init(id: 0x03, name: "DVI"), .init(id: 0x01, name: "VGA"),
    ]
}

enum Settings {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: ["xdrMax": 1.6, "extendDimming": true, "mediaKeys": true, "keysFollowCursor": true, "blur": true, "panelTint": 0.55, "cardFill": 0.045])
    }
    static var xdrMax: Double { d.double(forKey: "xdrMax") }
    static var extendDimming: Bool { d.bool(forKey: "extendDimming") }
    static var mediaKeys: Bool { d.bool(forKey: "mediaKeys") }
    static var keysFollowCursor: Bool { d.bool(forKey: "keysFollowCursor") }
}

@MainActor
final class Display: ObservableObject, Identifiable {
    let id: CGDirectDisplayID
    let isBuiltin: Bool
    @Published var name: String
    @Published var isActive = true
    @Published var isMain = false
    @Published var isMirroring = false

    @Published var brightness: Double = 0.5   // hardware 0…1
    @Published var softDim: Double = 1        // gamma 0.08…1
    @Published var boost: Double = 1          // XDR multiplier 1…maxBoost
    @Published var inverted = false

    @Published var ddc: DDCChannel?
    @Published var ddcResponds = false
    @Published var contrast: Double?
    @Published var volume: Double?
    @Published var muted = false
    @Published var input: UInt16?
    private var ddcMax: [VCP: UInt16] = [:]

    @Published var modes: [ModeOption] = []
    @Published var current: ModeOption?
    @Published var hdrSupported = false
    @Published var hdrEnabled = false

    var gammaTouched = false

    init(id: CGDirectDisplayID) {
        self.id = id
        isBuiltin = CGDisplayIsBuiltin(id) != 0
        name = isBuiltin ? "Built-in Display" : "Display"
        let s = UserDefaults.standard
        softDim = s.object(forKey: key("softDim")) as? Double ?? 1
        inverted = s.bool(forKey: key("inverted"))
        boost = s.object(forKey: key("boost")) as? Double ?? 1
    }

    var persistKey: String { "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))" }
    private func key(_ k: String) -> String { "d.\(persistKey).\(k)" }

    // MARK: Color modes (link color element)

    @Published var colorModes: [ColorMode] = []
    @Published var currentColor: ColorMode?
    @Published var otherTimingModes = 0
    var framebuffer: Framebuffer?
    var isVirtual: Bool { VirtualScreens.shared.isVirtual(id) }

    func refreshColorModes() {
        if framebuffer == nil { framebuffer = Framebuffer.find(for: id) }
        guard let fb = framebuffer else { colorModes = []; currentColor = nil; return }
        colorModes = fb.modesForCurrentTiming()
        let cur = fb.current?.color
        currentColor = colorModes.first { $0.id == cur }
        otherTimingModes = fb.otherTimingModeCount()
    }

    /// Switches the link color mode, then asks the user to confirm within 15 s
    /// or it reverts — a bad mode can leave the panel blank.
    func applyColor(_ m: ColorMode) {
        guard let fb = framebuffer, let previous = currentColor, m != previous else { return }
        guard fb.setColor(m.id) else { return }
        currentColor = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshColorModes(); DisplayManager.shared.scheduleRefresh() }
        ConfirmPanel.shared.ask("Keep color mode \(m.summary)?") { [weak self] in
            guard let self else { return }
            self.framebuffer?.setColor(previous.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshColorModes() }
        }
    }

    /// Forced HDR: first try the WindowServer HDR switch even if the display
    /// doesn't advertise support; otherwise drive the link with a PQ color mode.
    @Published var forcedHDR = false
    private var sdrColorBeforeForce: ColorMode?

    func setForcedHDR(_ on: Bool) {
        if on {
            sdrColorBeforeForce = currentColor
            _ = Private.setHDREnabled?(id, true, 0, 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                if Private.isHDREnabled?(id) == true {
                    forcedHDR = true; hdrEnabled = true
                    ConfirmPanel.shared.ask("Keep forced HDR?") { [weak self] in self?.setForcedHDR(false) }
                    return
                }
                let pq = colorModes.filter { $0.eotf == 1 }
                    .sorted { ($0.encoding == 0 ? 0 : 1, -$0.depth, $0.range) < ($1.encoding == 0 ? 0 : 1, -$1.depth, $1.range) }.first
                guard let pq else { return }
                forcedHDR = true
                applyColor(pq)
            }
        } else {
            forcedHDR = false
            _ = Private.setHDREnabled?(id, false, 0, 0)
            if let sdr = sdrColorBeforeForce ?? colorModes.first(where: { $0.eotf == 0 }), currentColor?.isHDR == true {
                framebuffer?.setColor(sdr.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshColorModes() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refreshState() }
        }
    }

    func persist() {
        let s = UserDefaults.standard
        s.set(softDim, forKey: key("softDim"))
        s.set(inverted, forKey: key("inverted"))
        s.set(boost, forKey: key("boost"))
    }

    var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    var hasHardwareBrightness: Bool {
        isBuiltin ? Private.setBrightness != nil : ddc != nil
    }

    var xdrCapable: Bool {
        isBuiltin && (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.05
    }

    var maxBoost: Double {
        min(Settings.xdrMax, Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1))
    }

    var subtitle: String {
        guard isActive else { return "Disabled" }
        if isMirroring { return "Mirroring" }
        guard let c = current else { return "" }
        var parts = [c.sizeLabel]
        if c.refresh > 0 { parts.append(c.refreshLabel) }
        if c.hiDPI { parts.append("HiDPI") }
        return parts.joined(separator: " · ")
    }

    // MARK: Technical readouts

    var bitDepth: Int? { screen.map { $0.depth.bitsPerSample } }
    var colorSpaceName: String? { screen?.colorSpace?.localizedName }
    var scale: Double? { current.map { Double($0.pixelWidth) / Double(max($0.width, 1)) } }
    var edrNow: Double { Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1) }
    var edrPotential: Double { Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) }

    var physicalSize: CGSize { CGDisplayScreenSize(id) }  // millimetres
    var diagonalInches: Double {
        let s = physicalSize
        return (s.width * s.width + s.height * s.height).squareRoot() / 25.4
    }
    var ppi: Double? {
        guard let c = current, physicalSize.width > 0 else { return nil }
        return Double(c.pixelWidth) / (physicalSize.width / 25.4)
    }

    var chips: [String] {
        var c: [String] = []
        if let m = current { c.append("\(m.pixelWidth)×\(m.pixelHeight)") }
        if let s = scale { c.append(String(format: "@%gx", (s * 100).rounded() / 100)) }
        if let cm = currentColor { c.append(cm.depthLabel); c.append(cm.isHDR ? cm.eotfLabel : edrPotential > 1.05 ? "EDR" : "SDR") }
        else { c.append(hdrEnabled ? "HDR" : edrPotential > 1.05 ? "EDR" : "SDR") }
        return c
    }

    var specs: [(String, String)] {
        var r: [(String, String)] = [
            ("ID", String(format: "%u  (0x%08X)", id, id)),
            ("Vendor / Model", String(format: "0x%04X / 0x%04X", CGDisplayVendorNumber(id), CGDisplayModelNumber(id))),
            ("Serial", "\(CGDisplaySerialNumber(id))"),
            ("Connection", isBuiltin ? "Internal" : isVirtual ? "Virtual" : "External"),
        ]
        if physicalSize.width > 0 {
            r.append(("Panel", String(format: "%.0f×%.0f mm  %.1f\"", physicalSize.width, physicalSize.height, diagonalInches)))
        }
        if let ppi { r.append(("Density", String(format: "%.0f ppi", ppi))) }
        if let c = current {
            r.append(("Framebuffer", "\(c.pixelWidth)×\(c.pixelHeight)"))
            r.append(("Logical", "\(c.width)×\(c.height)"))
            r.append(("Refresh", c.refresh > 0 ? String(format: "%.2f Hz", c.refresh) : "Variable"))
        }
        r.append(("Modes", "\(modes.count) (\(modes.filter(\.hiDPI).count) HiDPI)"))
        r.append(("Rotation", "\(Int(CGDisplayRotation(id)))°"))
        r.append(("EDR headroom", String(format: "%.2f / %.2f", edrNow, edrPotential)))
        if let cm = currentColor {
            r.append(("Link color", "#\(cm.id) \(cm.summary)"))
            r.append(("Colorimetry", "\(cm.colorimetry)"))
        }
        if let t = framebuffer?.current?.timing { r.append(("Link timing", "#\(t)")) }
        r.append(("HDR mode", hdrSupported ? (hdrEnabled ? "On" : "Off") : "Unsupported"))
        if !isBuiltin { r.append(("DDC/CI", ddc == nil ? "Not found" : ddcResponds ? "Read/Write" : "Write-only")) }
        r.append(("Gamma", gammaTouched ? String(format: "Custom (%.2f%@)", softDim, inverted ? ", inv" : "") : "ColorSync"))
        return r
    }

    // MARK: Combined slider
    // The single slider is split into zones: software dimming below the panel's
    // minimum, the hardware range, and (on XDR panels) extra EDR headroom.

    struct Zones { let dim: Double; let xdr: Double }
    var zones: Zones {
        guard hasHardwareBrightness else { return Zones(dim: 1, xdr: 1) }
        return Zones(dim: Settings.extendDimming ? 0.12 : 0, xdr: xdrCapable ? 0.8 : 1)
    }

    var sliderValue: Double {
        let z = zones
        if !hasHardwareBrightness { return (softDim - 0.08) / 0.92 }
        if softDim < 0.999 && z.dim > 0 { return z.dim * (softDim - 0.08) / 0.92 }
        if boost > 1.001 && z.xdr < 1 { return z.xdr + (1 - z.xdr) * (boost - 1) / max(maxBoost - 1, 0.01) }
        return z.dim + (z.xdr - z.dim) * brightness
    }

    func setSlider(_ v: Double) {
        let v = min(max(v, 0), 1)
        let z = zones
        if !hasHardwareBrightness {
            softDim = 0.08 + 0.92 * v
            applyGamma(); persist(); return
        }
        if v < z.dim {
            softDim = 0.08 + 0.92 * (v / z.dim)
            setHardware(0); boost = 1
        } else if v <= z.xdr {
            softDim = 1; boost = 1
            setHardware((v - z.dim) / (z.xdr - z.dim))
        } else {
            softDim = 1
            setHardware(1)
            boost = 1 + (maxBoost - 1) * (v - z.xdr) / (1 - z.xdr)
        }
        applyGamma()
        XDRBoost.shared.update(for: self)
        persist()
    }

    /// Step used by the brightness keys: 1/16 of the slider, like macOS.
    func step(_ dir: Double) { setSlider(sliderValue + dir / 16) }

    func setHardware(_ v: Double) {
        brightness = min(max(v, 0), 1)
        if isBuiltin {
            _ = Private.setBrightness?(id, Float(brightness))
        } else if let ddc {
            ddc.set(.brightness, UInt16((brightness * Double(ddcMax[.brightness] ?? 100)).rounded()))
        }
    }

    func setDDC(_ code: VCP, _ v: Double) {
        guard let ddc else { return }
        ddc.set(code, UInt16((v * Double(ddcMax[code] ?? 100)).rounded()))
        switch code {
        case .contrast: contrast = v
        case .volume: volume = v
        default: break
        }
    }

    func setMute(_ on: Bool) { muted = on; ddc?.set(.mute, on ? 1 : 2) }
    func setInput(_ src: UInt16) { input = src; ddc?.set(.input, src) }

    func applyGamma() {
        DisplayManager.shared.applyGamma(self)
    }

    // MARK: Refresh from the system

    func refreshState() {
        isActive = CGDisplayIsActive(id) != 0
        isMain = CGDisplayIsMain(id) != 0
        isMirroring = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
        if let s = screen { name = s.localizedName }
        else if let n = DisplayManager.shared.disabledNames[String(id)] { name = n }

        if isBuiltin, let get = Private.getBrightness {
            var b: Float = 0
            if get(id, &b) == 0 { brightness = Double(b) }
        }

        hdrSupported = Private.supportsHDR?(id) ?? false
        hdrEnabled = hdrSupported && (Private.isHDREnabled?(id) ?? false)

        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() }
            .map(ModeOption.init)
        var seen = Set<String>()
        modes = all.filter { seen.insert($0.id).inserted }
            .sorted { ($0.width, $0.height, $0.refresh) < ($1.width, $1.height, $1.refresh) }
        if let m = CGDisplayCopyDisplayMode(id) { current = ModeOption(m) }
        if isActive { refreshColorModes() }
    }

    func refreshDDC() {
        guard let ddc else { return }
        for code in [VCP.brightness, .contrast, .volume, .input] {
            ddc.read(code) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, let r = result else { return }
                    self.ddcResponds = true
                    if code != .input { self.ddcMax[code] = r.max }
                    let v = Double(r.current) / Double(max(r.max, 1))
                    switch code {
                    case .brightness: self.brightness = min(v, 1)
                    case .contrast: self.contrast = min(v, 1)
                    case .volume: self.volume = min(v, 1)
                    case .input: self.input = r.current & 0xFF
                    default: break
                    }
                }
            }
        }
    }

    // MARK: Resolution helpers

    /// One entry per distinct logical size, preferring HiDPI variants.
    var resolutionSteps: [ModeOption] {
        var best: [String: ModeOption] = [:]
        let refresh = current?.refresh ?? 0
        for m in modes {
            let k = "\(m.width)x\(m.height)"
            if let b = best[k] {
                let better = (m.hiDPI && !b.hiDPI) ||
                    (m.hiDPI == b.hiDPI && abs(m.refresh - refresh) < abs(b.refresh - refresh))
                if better { best[k] = m }
            } else { best[k] = m }
        }
        if let c = current { best["\(c.width)x\(c.height)"] = c }
        return best.values.sorted { ($0.width * $0.height) < ($1.width * $1.height) }
    }

    var refreshRates: [ModeOption] {
        guard let c = current else { return [] }
        return modes.filter { $0.width == c.width && $0.height == c.height && $0.hiDPI == c.hiDPI }
            .sorted { $0.refresh > $1.refresh }
    }

    func apply(_ option: ModeOption) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        CGConfigureDisplayWithDisplayMode(cfg, id, option.mode, nil)
        if CGCompleteDisplayConfiguration(cfg, .permanently) == .success { current = option }
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()
    @Published var displays: [Display] = []
    @Published var grayscale = false
    /// Displays Lumen disabled. They vanish from the online list, so we must
    /// remember them to offer re-enabling — and we re-enable them on quit/launch.
    @Published var disabledNames: [String: String] = UserDefaults.standard.dictionary(forKey: "disabledDisplays") as? [String: String] ?? [:]
    private var channels: [DDCChannel] = []
    private var pendingRefresh = false

    func start() {
        // Safety net: anything left disabled by a previous run comes back on.
        reenableAll()
        channels = DDCChannel.discover()
        refresh()
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayManager.shared.scheduleRefresh() }
        }, nil)
        for d in displays { applyGamma(d); XDRBoost.shared.update(for: d) }
    }

    /// Lightweight bring-up for one-shot CLI use (no callbacks, no gamma).
    func prepareForCLI() {
        channels = DDCChannel.discover()
        refresh()
    }

    func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            pendingRefresh = false
            let previous = Set(displays.map(\.id))
            channels = DDCChannel.discover()
            refresh()
            // Gamma tables reset on reconfiguration, so reapply ours.
            for d in displays where d.gammaTouched || d.softDim < 0.999 || d.inverted { d.gammaTouched = false; applyGamma(d) }
            for d in displays { XDRBoost.shared.update(for: d) }
            for d in displays where !previous.contains(d.id) { d.refreshDDC() }
        }
    }

    func refresh() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for k in disabledNames.keys { if let i = CGDirectDisplayID(k), !ids.contains(i) { ids.append(i) } }

        let existing = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        var result: [Display] = []
        var unclaimed = channels
        for id in ids {
            let d = existing[id] ?? Display(id: id)
            if !d.isBuiltin && d.ddc == nil {
                d.ddc = match(id, in: &unclaimed)
                if existing[id] == nil { d.refreshDDC() }
            }
            d.refreshState()
            result.append(d)
        }
        // A single unmatched external + single channel is almost certainly a pair.
        let bare = result.filter { !$0.isBuiltin && $0.ddc == nil }
        if bare.count == 1, unclaimed.count == 1 { bare[0].ddc = unclaimed[0]; bare[0].refreshDDC() }

        displays = result.sorted { ($0.isBuiltin ? 0 : 1, $0.id) < ($1.isBuiltin ? 0 : 1, $1.id) }
        grayscale = Private.grayscaleGet?() ?? false
    }

    private func match(_ id: CGDirectDisplayID, in pool: inout [DDCChannel]) -> DDCChannel? {
        let v = CGDisplayVendorNumber(id), p = CGDisplayModelNumber(id), s = CGDisplaySerialNumber(id)
        let scored = pool.enumerated().map { i, c -> (Int, Int) in
            var score = 0
            if c.vendor == v { score += 1 }
            if c.product == p { score += 2 }
            if c.serial == s, s != 0 { score += 4 }
            return (i, score)
        }.filter { $0.1 >= 3 }.max { $0.1 < $1.1 }
        guard let (i, _) = scored else { return nil }
        return pool.remove(at: i)
    }

    func applyGamma(_ d: Display) {
        if d.softDim >= 0.999 && !d.inverted {
            guard d.gammaTouched else { return }
            d.gammaTouched = false
            CGDisplayRestoreColorSyncSettings()
            for other in displays where other.id != d.id && (other.softDim < 0.999 || other.inverted) {
                other.gammaTouched = false
                applyGamma(other)
            }
            return
        }
        let s = Float(d.softDim)
        let (lo, hi): (Float, Float) = d.inverted ? (s, 0) : (0, s)
        CGSetDisplayTransferByFormula(d.id, lo, hi, 1, lo, hi, 1, lo, hi, 1)
        d.gammaTouched = true
    }

    func setInverted(_ d: Display, _ on: Bool) {
        d.inverted = on
        applyGamma(d)
        d.persist()
    }

    func setGrayscale(_ on: Bool) {
        Private.grayscaleSet?(on)
        grayscale = on
    }

    func setEnabled(_ d: Display, _ on: Bool) {
        guard let fn = Private.configureDisplayEnabled else { return }
        if !on && displays.filter(\.isActive).count <= 1 { return }  // never black out the last screen
        if !on { disabledNames[String(d.id)] = d.name }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        _ = fn(cfg, d.id, on)
        // Session-only: a logout or reboot always brings the display back.
        if CGCompleteDisplayConfiguration(cfg, .forSession) == .success, on { disabledNames.removeValue(forKey: String(d.id)) }
        UserDefaults.standard.set(disabledNames, forKey: "disabledDisplays")
        scheduleRefresh()
    }

    func reenableAll() {
        guard let fn = Private.configureDisplayEnabled else { return }
        for k in disabledNames.keys {
            guard let id = CGDirectDisplayID(k) else { continue }
            var cfg: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { continue }
            _ = fn(cfg, id, true)
            CGCompleteDisplayConfiguration(cfg, .forSession)
        }
        disabledNames = [:]
        UserDefaults.standard.set(disabledNames, forKey: "disabledDisplays")
    }

    func setHDR(_ d: Display, _ on: Bool) {
        _ = Private.setHDREnabled?(d.id, on, 0, 0)
        d.hdrEnabled = on
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { d.refreshState() }
    }

    func makeMain(_ d: Display) {
        let origin = CGDisplayBounds(d.id).origin
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        for other in displays where other.isActive {
            let b = CGDisplayBounds(other.id).origin
            CGConfigureDisplayOrigin(cfg, other.id, Int32(b.x - origin.x), Int32(b.y - origin.y))
        }
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    func setMirroring(_ d: Display, _ on: Bool) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        let master = displays.first { $0.isMain && $0.id != d.id }?.id ?? CGMainDisplayID()
        CGConfigureDisplayMirrorOfDisplay(cfg, d.id, on ? master : kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    /// Display currently under the mouse pointer (used by brightness keys).
    var displayUnderCursor: Display? {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return displays.first { $0.id == id }
    }

    func restoreOnQuit() {
        reenableAll()
        CGDisplayRestoreColorSyncSettings()
        XDRBoost.shared.removeAll()
    }
}
