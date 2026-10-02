import SwiftUI

// MARK: - Display card

struct DisplayCard: View {
    @ObservedObject var display: Display
    @EnvironmentObject var manager: DisplayManager
    @State private var openRow: String? = CommandLine.arguments.first { $0.hasPrefix("--open=") }.map { String($0.dropFirst(7)) }
    @State private var resIndex: Double?

    private func row(_ k: String) -> Binding<Bool> { Binding(get: { openRow == k }, set: { openRow = $0 ? k : nil }) }

    var body: some View {
        Card {
            header
            if display.isActive {
                if !display.isMirroring { brightness.padding(.top, 2) }
                VStack(spacing: 0) {
                    resolution
                    if !display.colorModes.isEmpty { colorModes }
                    if !display.profiles.isEmpty { colorProfile }
                    hdr
                    if display.ddc != nil { monitor }
                    tools
                    diagnostics
                }
            }
        }
    }

    // Header

    private var ddcStatus: (Color, String)? {
        guard !display.isBuiltin, !display.isVirtual else { return nil }
        if display.ddc == nil { return (T.text3, "No DDC") }
        return display.ddcResponds ? (T.ok, "DDC") : (T.warn, "DDC off")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : display.isVirtual ? "rectangle.dashed" : "display")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(display.isActive ? T.text : T.text3)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.well))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.hairline))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.name).font(T.f(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                    if display.isMain && manager.displays.count > 1 {
                        Text("Main").font(T.f(10, .medium)).foregroundStyle(T.ion)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(T.ion.opacity(0.14)))
                    }
                }
                HStack(spacing: 5) {
                    if let (c, t) = ddcStatus, display.isActive {
                        Dot(color: c).help(t)
                    }
                    Text(display.isActive ? display.chips.joined(separator: " · ") : "Disabled")
                        .font(T.f(11)).monospacedDigit().foregroundStyle(T.text3).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if manager.displays.count > 1 && !display.isVirtual {
                LSwitch(isOn: Binding(get: { display.isActive }, set: { manager.setEnabled(display, $0) }),
                        disabled: display.isActive && manager.displays.filter(\.isActive).count <= 1)
                    .help(display.isActive ? "Disable until re-enabled or Lumen quits" : "Enable")
            }
        }
    }

    // Brightness

    private var brightnessLabel: String {
        if display.boost > 1.001 { return String(format: "XDR %.2f×", display.boost) }
        if display.softDim < 0.999 && display.hasHardwareBrightness { return "Dim \(Int(display.softDim * 100))%" }
        return "\(Int(((display.hasHardwareBrightness ? display.brightness : display.softDim) * 100).rounded()))%"
    }

    private var brightness: some View {
        VStack(alignment: .leading, spacing: 5) {
            LevelBar(value: display.sliderValue, zones: display.zones,
                     icon: display.sliderValue < 0.25 ? "sun.min.fill" : "sun.max.fill",
                     label: brightnessLabel) { display.setSlider($0) }
            if display.xdrCapable || !display.hasHardwareBrightness {
                HStack {
                    Caption(display.hasHardwareBrightness ? "Hardware" : "Software dimming")
                    Spacer()
                    if display.xdrCapable {
                        HStack(spacing: 4) {
                            Circle().fill(T.xdr).frame(width: 5, height: 5)
                            Caption("XDR above 100%")
                        }
                    }
                }
            }
        }
    }

    // Rows

    private var resolution: some View {
        let steps = display.resolutionSteps
        let currentIdx = Double(steps.firstIndex { $0.width == display.current?.width && $0.height == display.current?.height } ?? 0)
        let shown = Int(resIndex ?? currentIdx)
        let size = steps.indices.contains(shown) ? "\(steps[shown].width)×\(steps[shown].height)" : "—"
        let hz = (display.current?.refresh ?? 0) > 0 ? " · \(Int(display.current!.refresh.rounded())) Hz" : ""
        return DrillRow(icon: "rectangle.expand.vertical", title: "Resolution", value: size + hz, open: row("res")) {
            VStack(alignment: .leading, spacing: 10) {
                if steps.count > 1 {
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size.larger").font(.system(size: 10)).foregroundStyle(T.text3)
                        MiniSlider(value: Binding(get: { resIndex ?? currentIdx }, set: { resIndex = $0 }),
                                   range: 0...Double(steps.count - 1), step: 1) {
                            guard let i = resIndex.map(Int.init) else { return }
                            resIndex = nil
                            if Double(i) != currentIdx { display.apply(steps[i]) }
                        }
                        Image(systemName: "textformat.size.smaller").font(.system(size: 10)).foregroundStyle(T.text3)
                    }
                }
                HStack(spacing: 6) {
                    if display.refreshRates.count > 1 {
                        Menu {
                            ForEach(display.refreshRates) { m in
                                Toggle(m.refreshLabel, isOn: Binding(get: { m == display.current }, set: { _ in display.apply(m) }))
                            }
                        } label: { PillMenuLabel(text: display.current?.refreshLabel ?? "Refresh") }.pill()
                    }
                    Menu {
                        ForEach([true, false], id: \.self) { hi in
                            let group = Array(display.modes.filter { $0.hiDPI == hi }.reversed())
                            if !group.isEmpty {
                                Section(hi ? "HiDPI" : "Native pixels") {
                                    ForEach(group) { m in
                                        Toggle("\(m.sizeLabel)   \(m.refreshLabel)", isOn: Binding(get: { m == display.current }, set: { _ in display.apply(m) }))
                                    }
                                }
                            }
                        }
                    } label: { PillMenuLabel(text: "All modes") }.pill()
                    Spacer()
                    if display.current?.hiDPI == true { Caption("HiDPI") }
                }
            }
        }
    }

    private var colorModes: some View {
        DrillRow(icon: "square.stack.3d.up", title: "Color mode",
                 value: display.currentColor.map { "\($0.depthLabel) \($0.eotfLabel)" },
                 valueTint: display.currentColor?.isHDR == true ? T.hdr : T.text2, open: row("color")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["SDR", "HDR10", "HLG"], id: \.self) { group in
                    let modes = display.colorModes.filter { $0.eotfLabel == group }
                    if !modes.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group).font(T.f(11, .medium)).foregroundStyle(group == "SDR" ? T.text3 : T.hdr).padding(.bottom, 2)
                            ForEach(modes) { m in ColorModeRow(mode: m, selected: m == display.currentColor) { display.applyColor(m) } }
                        }
                    }
                }
                Caption((display.otherTimingModes > 0 ? "\(display.otherTimingModes) more at other refresh rates · " : "") + "reverts in 15 s unless kept")
            }
        }
    }

    private var colorProfile: some View {
        DrillRow(icon: "paintpalette", title: "Color profile", value: display.profileName, open: row("profile")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ColorProfile.Group.allCases, id: \.self) { group in
                    let items = display.profiles.filter { $0.group == group }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.title).font(T.f(11, .medium)).foregroundStyle(T.text3).padding(.bottom, 2)
                            ForEach(items) { p in
                                ProfileRow(profile: p, selected: p.url.resolvingSymlinksInPath() == display.profileURL?.resolvingSymlinksInPath()) {
                                    display.applyProfile(p.url)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    if display.customProfile {
                        Button("Reset to factory") { display.applyProfile(nil) }.buttonStyle(PillStyle())
                    }
                    Button("Open ColorSync Utility") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/ColorSync Utility.app"))
                    }.buttonStyle(PillStyle())
                }
            }
        }
    }

    private var hdr: some View {
        Group {
            if display.hdrSupported {
                SwitchRow(icon: "sparkles.tv", title: "High dynamic range",
                          isOn: Binding(get: { display.hdrEnabled }, set: { manager.setHDR(display, $0) }))
            } else if !display.isBuiltin && !display.isVirtual && display.colorModes.contains(where: \.isHDR) {
                SwitchRow(icon: "sparkles.tv", title: "Force HDR", detail: "Not advertised by the display",
                          isOn: Binding(get: { display.forcedHDR || display.currentColor?.isHDR == true }, set: { display.setForcedHDR($0) }))
            }
        }
    }

    private var monitor: some View {
        DrillRow(icon: "dial.medium", title: "Monitor controls", value: display.ddcResponds ? nil : "Unverified",
                 valueTint: display.ddcResponds ? T.text2 : T.warn, open: row("ddc")) {
            VStack(alignment: .leading, spacing: 10) {
                if !display.ddcResponds {
                    Text("The monitor rejects DDC reads. Turn on DDC/CI in its on-screen menu.")
                        .font(T.f(11)).foregroundStyle(T.warn).fixedSize(horizontal: false, vertical: true)
                }
                labeledSlider("circle.lefthalf.filled", Binding(get: { display.contrast ?? 0.5 }, set: { display.setDDC(.contrast, $0) }))
                HStack(spacing: 8) {
                    Button { display.setMute(!display.muted) } label: {
                        Image(systemName: display.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(T.text2).frame(width: 14)
                    }.buttonStyle(.plain)
                    MiniSlider(value: Binding(get: { display.volume ?? 0.5 }, set: { display.setDDC(.volume, $0) }))
                }
                Menu {
                    ForEach(InputSource.common) { src in
                        Toggle(src.name, isOn: Binding(get: { display.input == src.id }, set: { _ in display.setInput(src.id) }))
                    }
                } label: { PillMenuLabel(text: "Input · " + (InputSource.common.first { $0.id == display.input }?.name ?? "Unknown")) }.pill()
            }
        }
    }

    private func labeledSlider(_ icon: String, _ v: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(T.text2).frame(width: 14)
            MiniSlider(value: v)
        }
    }

    private var tools: some View {
        DrillRow(icon: "slider.horizontal.3", title: "Tools", open: row("tools")) {
            VStack(alignment: .leading, spacing: 4) {
                SwitchRow(icon: "circle.righthalf.filled.inverse", title: "Invert colors",
                          isOn: Binding(get: { display.inverted }, set: { manager.setInverted(display, $0) }))
                if !display.isMain && manager.displays.filter(\.isActive).count > 1 {
                    SwitchRow(icon: "rectangle.on.rectangle", title: "Mirror main display",
                              isOn: Binding(get: { display.isMirroring }, set: { manager.setMirroring(display, $0) }))
                }
                HStack(spacing: 6) {
                    Button { ScreenViewers.shared.show(display.id, name: display.name) } label: { Label("Viewer", systemImage: "pip") }
                    if !display.isMain && manager.displays.filter(\.isActive).count > 1 {
                        Button { manager.makeMain(display) } label: { Label("Make main", systemImage: "menubar.rectangle") }
                    }
                }
                .buttonStyle(PillStyle()).padding(.top, 4)
            }
        }
    }

    private var diagnostics: some View {
        DrillRow(icon: "waveform.path.ecg", title: "Diagnostics", open: row("diag")) {
            VStack(spacing: 0) {
                ForEach(Array(display.specs.enumerated()), id: \.offset) { i, kv in
                    HStack(alignment: .firstTextBaseline) {
                        Text(kv.0).font(T.f(11)).foregroundStyle(T.text3)
                        Spacer(minLength: 8)
                        Text(kv.1).font(T.f(11, .medium)).monospacedDigit().foregroundStyle(T.text2)
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    if i < display.specs.count - 1 { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                }
            }
        }
    }
}

struct ProfileRow: View {
    let profile: ColorProfile
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark" : "circle")
                .font(.system(size: selected ? 10 : 6, weight: .bold))
                .foregroundStyle(selected ? T.ion : T.text3)
                .frame(width: 12)
            Text(profile.name).font(T.f(12, selected ? .medium : .regular))
                .foregroundStyle(selected ? T.text : T.text2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? T.ion.opacity(0.10) : Color.white.opacity(hover ? 0.05 : 0)))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(profile.url.path)
    }
}

struct ColorModeRow: View {
    let mode: ColorMode
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark" : "circle")
                .font(.system(size: selected ? 10 : 6, weight: .bold))
                .foregroundStyle(selected ? T.ion : T.text3)
                .frame(width: 12)
            Text(mode.depthLabel).font(T.f(12, selected ? .medium : .regular)).monospacedDigit()
                .foregroundStyle(selected ? T.text : T.text2).frame(width: 44, alignment: .leading)
            Text(mode.encodingLabel).font(T.f(12)).foregroundStyle(selected ? T.text : T.text2).frame(width: 84, alignment: .leading)
            Text(mode.rangeLabel).font(T.f(12)).foregroundStyle(selected ? T.text : T.text2)
            Spacer(minLength: 4)
            Text("\(mode.id)").font(T.f(10.5)).monospacedDigit().foregroundStyle(T.text3)
        }
        .lineLimit(1)
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? T.ion.opacity(0.10) : Color.white.opacity(hover ? 0.05 : 0)))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("Color element \(mode.id) · colorimetry \(mode.colorimetry) · encoding \(mode.encoding)")
    }
}

// MARK: - Virtual screens

struct VirtualCard: View {
    @ObservedObject var screens = VirtualScreens.shared
    @EnvironmentObject var manager: DisplayManager
    @State private var hiDPI = true
    @State private var customW = "3440"
    @State private var customH = "1440"
    @State private var open = false

    var body: some View {
        Card {
            DrillRow(icon: "rectangle.dashed", title: "Virtual screens", value: screens.configs.isEmpty ? "None" : "\(screens.configs.count)", open: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(screens.configs) { c in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(T.f(12.5)).foregroundStyle(T.text)
                                Text(c.label + (c.mirrorKey != nil ? " · on a physical display" : "")).font(T.f(11)).monospacedDigit().foregroundStyle(T.text3)
                            }
                            Spacer()
                            Menu {
                                Button("Open viewer") { if let id = screens.displayID(for: c) { ScreenViewers.shared.show(id, name: c.name) } }
                                Section("Show on physical display") {
                                    Toggle("None", isOn: Binding(get: { c.mirrorKey == nil }, set: { _ in screens.setMirror(c, to: nil) }))
                                    ForEach(manager.displays.filter { !$0.isVirtual }) { d in
                                        Toggle(d.name, isOn: Binding(get: { c.mirrorKey == d.persistKey }, set: { _ in screens.setMirror(c, to: d.persistKey) }))
                                    }
                                }
                                Divider()
                                Button("Remove", role: .destructive) { screens.remove(c) }
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(T.text2)
                                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                            }.pill()
                        }
                    }
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(VirtualScreens.presets, id: \.0) { p in Button("\(p.0) · \(p.1)×\(p.2)") { add(p.1, p.2, p.0) } }
                        } label: { PillMenuLabel(text: "Preset") }.pill()
                        field($customW)
                        Text("×").font(T.f(11)).foregroundStyle(T.text3)
                        field($customH)
                        Button("Add") { if let w = Int(customW), let h = Int(customH), w >= 640, h >= 480 { add(w, h, "\(w)×\(h)") } }
                            .buttonStyle(PillStyle(prominent: true))
                    }
                    SwitchRow(icon: "sparkle.magnifyingglass", title: "HiDPI", detail: "Render at 2× for sharp scaling", isOn: $hiDPI)
                    Caption("Virtual screens live while Lumen runs. Show one on a real display to get any scaled resolution.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func field(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain).font(T.f(11.5, .medium)).monospacedDigit().foregroundStyle(T.text)
            .multilineTextAlignment(.center)
            .frame(width: 46, height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.well))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(T.hairline))
    }

    private func add(_ w: Int, _ h: Int, _ label: String) {
        screens.add(VirtualConfig(name: "Virtual \(label)", width: w, height: h, hiDPI: hiDPI))
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var manager: DisplayManager
    @State private var showSettings = CommandLine.arguments.contains("--settings")
    @State private var nightShift = NightShift.shared.isOn
    @State private var nightStrength = NightShift.shared.strength
    @State private var dark = Appearance.isDark
    @State private var contentHeight: CGFloat = 300
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var maxContent: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 220 }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                Text(showSettings ? "Settings" : "Lumen").font(T.f(15, .semibold)).tracking(-0.2).foregroundStyle(T.text)
                if !showSettings {
                    Text("\(manager.displays.filter(\.isActive).count) of \(manager.displays.count) active")
                        .font(T.f(11)).monospacedDigit().foregroundStyle(T.text3)
                }
                Spacer()
                IconButton(icon: showSettings ? "xmark" : "gearshape") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSettings.toggle() }
                }
            }
            if showSettings { SettingsPage().transition(.opacity) } else { mainPage.transition(.opacity) }
        }
        .padding(12)
        .frame(width: 352)
        .panel()
        .background(ClearWindow())
        .onAppear(perform: sync)
        .onReceive(tick) { _ in
            for d in manager.displays where d.isBuiltin {
                var b: Float = 0
                if Private.getBrightness?(d.id, &b) == 0, abs(Double(b) - d.brightness) > 0.005 { d.brightness = Double(b) }
            }
            nightShift = NightShift.shared.isOn
            dark = Appearance.isDark
        }
    }

    private func sync() {
        manager.refresh()
        nightShift = NightShift.shared.isOn
        nightStrength = NightShift.shared.strength
        dark = Appearance.isDark
    }

    private var mainPage: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(manager.displays) { DisplayCard(display: $0) }
                    VirtualCard()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxContent))
            .modifier(EdgeFade(active: contentHeight > maxContent))

            HStack(spacing: 8) {
                if NightShift.shared.available {
                    Tile(icon: "moon.fill", title: "Night Shift", isOn: nightShift, tint: T.warm) { nightShift.toggle(); NightShift.shared.set(nightShift) }
                }
                Tile(icon: "circle.lefthalf.filled", title: "Dark Mode", isOn: dark) { dark.toggle(); Appearance.toggleDark() }
                Tile(icon: "camera.filters", title: "Grayscale", isOn: manager.grayscale, tint: T.text) { manager.setGrayscale(!manager.grayscale) }
            }
            if nightShift {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(T.warm).frame(width: 14)
                    MiniSlider(value: Binding(get: { nightStrength }, set: { nightStrength = $0; NightShift.shared.strength = $0 }), tint: T.warm)
                }
                .padding(.horizontal, 4)
            }
            HStack {
                FooterButton(title: "Display Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
                Spacer()
                FooterButton(title: "Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .padding(.horizontal, 4).padding(.top, 2)
        }
    }
}

struct IconButton: View {
    let icon: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(hover ? T.text : T.text2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.10 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) { Text(title).font(T.f(11.5)).foregroundStyle(hover ? T.text2 : T.text3) }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @EnvironmentObject var manager: DisplayManager
    @AppStorage("mediaKeys") private var mediaKeys = true
    @AppStorage("keysFollowCursor") private var followCursor = true
    @AppStorage("extendDimming") private var extendDimming = true
    @AppStorage("xdrMax") private var xdrMax = 1.6
    @AppStorage("blur") private var blur = true
    @AppStorage("panelTint") private var panelTint = 0.55
    @AppStorage("cardFill") private var cardFill = 0.045
    @State private var login = LoginItem.enabled
    @State private var trusted = MediaKeys.shared.isTrusted
    @State private var cliInstalled = CLIInstall.isInstalled

    var body: some View {
        VStack(spacing: 8) {
            Card {
                Text("Appearance").font(T.f(13, .medium)).foregroundStyle(T.text)
                HStack {
                    Text("Background").font(T.f(12.5)).foregroundStyle(T.text)
                    Spacer()
                    Segmented(options: [("Blur", true), ("Clear", false)], selection: $blur)
                }
                .frame(height: 28)
                valueSlider("Panel tint", $panelTint, 0...0.95) { "\(Int($0 * 100))%" }
                valueSlider("Card opacity", $cardFill, 0...0.2) { "\(Int(($0 * 500).rounded()))%" }
                HStack {
                    Spacer()
                    Button("Reset") { withAnimation { blur = true; panelTint = 0.55; cardFill = 0.045 } }.buttonStyle(PillStyle())
                }
            }
            Card {
                Text("General").font(T.f(13, .medium)).foregroundStyle(T.text)
                SwitchRow(icon: "power", title: "Launch at login", isOn: Binding(get: { login }, set: { LoginItem.set($0); login = LoginItem.enabled }))
                HStack(spacing: 9) {
                    Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(T.text2).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Command-line tool").font(T.f(12.5)).foregroundStyle(T.text)
                        Text(cliInstalled ? "lumen is on your PATH" : "Adds lumen to \(CLIInstall.dir)").font(T.f(11)).foregroundStyle(T.text3)
                    }
                    Spacer()
                    if cliInstalled { Dot(color: T.ok) } else {
                        Button("Install") { CLIInstall.install(); cliInstalled = CLIInstall.isInstalled }.buttonStyle(PillStyle(prominent: true))
                    }
                }
            }
            Card {
                Text("Brightness keys").font(T.f(13, .medium)).foregroundStyle(T.text)
                SwitchRow(icon: "keyboard", title: "Control external and XDR", detail: "DDC monitors, boost above 100%",
                          isOn: Binding(get: { mediaKeys }, set: {
                              mediaKeys = $0
                              if $0 { MediaKeys.shared.start() } else { MediaKeys.shared.stop() }
                          }))
                SwitchRow(icon: "cursorarrow", title: "Follow pointer", detail: "Adjust the display under the cursor", isOn: $followCursor)
                if !trusted {
                    Button { MediaKeys.shared.requestAccess() } label: { Label("Grant Accessibility access", systemImage: "lock.open").frame(maxWidth: .infinity) }
                        .buttonStyle(PillStyle(prominent: true))
                }
            }
            Card {
                Text("Brightness range").font(T.f(13, .medium)).foregroundStyle(T.text)
                SwitchRow(icon: "sun.min", title: "Dim below minimum", detail: "Software dimming at the low end", isOn: $extendDimming)
                if manager.displays.contains(where: \.xdrCapable) {
                    valueSlider("XDR boost limit", $xdrMax, 1...2.5, step: 0.1, tint: T.xdr) { String(format: "%.1f×", $0) }
                }
            }
            HStack {
                FooterButton(title: "Rescan displays") { manager.scheduleRefresh() }
                Spacer()
                FooterButton(title: "Re-enable all displays") { manager.reenableAll(); manager.scheduleRefresh() }
            }
            .padding(.horizontal, 4).padding(.top, 2)
        }
        .onAppear { trusted = MediaKeys.shared.isTrusted; login = LoginItem.enabled; cliInstalled = CLIInstall.isInstalled }
        .onChange(of: extendDimming) { manager.displays.forEach { $0.objectWillChange.send() } }
    }

    private func valueSlider(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, step: Double? = nil,
                             tint: Color = T.ion, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(T.f(12.5)).foregroundStyle(T.text)
                Spacer()
                Text(format(v.wrappedValue)).font(T.f(12.5, .medium)).monospacedDigit().foregroundStyle(T.text2)
            }
            MiniSlider(value: v, range: range, step: step, tint: tint)
        }
    }
}

enum CLIInstall {
    static var dir: String { FileManager.default.isWritableFile(atPath: "/opt/homebrew/bin") ? "/opt/homebrew/bin" : "/usr/local/bin" }
    static var path: String { dir + "/lumen" }
    static var isInstalled: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == Bundle.main.executablePath }
    static func install() {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: Bundle.main.executablePath ?? "")
    }
}

/// Strips the MenuBarExtra panel's own material so only our panel shows.
struct ClearWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            func hideMaterials(_ v: NSView) {
                if let fx = v as? NSVisualEffectView, !(fx is LumenBlurView) { fx.state = .inactive; fx.alphaValue = 0 }
                v.subviews.forEach(hideMaterials)
            }
            if let root = w.contentView?.superview ?? w.contentView { hideMaterials(root) }
        }
    }
}
