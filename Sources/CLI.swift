import AppKit

/// `lumen` command-line interface. Runs inside Lumen.app when it is open (so
/// the menu stays in sync and session-only features like XDR, dimming and
/// virtual screens work), and falls back to running directly otherwise.
@MainActor
enum CLI {
    static let requestName = Notification.Name("io.lumen.cli.request")
    static let replyName = Notification.Name("io.lumen.cli.reply")
    static let commands: Set<String> = ["help", "-h", "--help", "version", "list", "ls", "info", "brightness", "b", "dim", "xdr",
        "resolution", "res", "modes", "colormodes", "colormode", "hdr", "ddc", "enable", "disable", "main", "mirror", "invert",
        "nightshift", "grayscale", "dark", "virtual", "viewer"]
    /// Need the app's process (state lives there).
    static let appOnly: Set<String> = ["dim", "xdr", "invert", "virtual", "viewer"]

    static func isCommand(_ s: String) -> Bool { commands.contains(s) }

    // MARK: Entry from the terminal

    static func main(_ args: [String]) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let cmd = args[0]
        let tty = isatty(1) != 0
        let appRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "io.lumen.app")
            .contains { $0.processIdentifier != getpid() }

        if ["help", "-h", "--help"].contains(cmd) { print(help(Style(color: tty))); return 0 }
        if cmd == "colormode" || !appRunning {
            if appOnly.contains(cmd) {
                FileHandle.standardError.write("lumen: '\(cmd)' needs Lumen.app running (open -a Lumen)\n".data(using: .utf8)!)
                return 2
            }
            DisplayManager.shared.prepareForCLI()
            let (out, code) = execute(args, style: Style(color: tty), interactive: true)
            if !out.isEmpty { print(out) }
            DisplayManager.shared.displays.forEach { $0.ddc?.flush() }
            return code
        }
        return forward(args, tty: tty)
    }

    private static func forward(_ args: [String], tty: Bool) -> Int32 {
        let id = UUID().uuidString
        var result: (String, Int32)?
        let center = DistributedNotificationCenter.default()
        let obs = center.addObserver(forName: replyName, object: id, queue: .main) { note in
            let out = note.userInfo?["out"] as? String ?? ""
            let code = (note.userInfo?["code"] as? NSNumber)?.int32Value ?? 1
            result = (out, code)
        }
        center.postNotificationName(requestName, object: id, userInfo: ["args": args, "tty": tty], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(8)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        center.removeObserver(obs)
        guard let (out, code) = result else {
            FileHandle.standardError.write("lumen: Lumen.app did not respond\n".data(using: .utf8)!)
            return 1
        }
        if !out.isEmpty { print(out) }
        return code
    }

    // MARK: Server side (inside Lumen.app)

    static func startServer() {
        DistributedNotificationCenter.default().addObserver(forName: requestName, object: nil, queue: .main) { note in
            guard let id = note.object as? String, let args = note.userInfo?["args"] as? [String], !args.isEmpty else { return }
            let tty = note.userInfo?["tty"] as? Bool ?? false
            MainActor.assumeIsolated {
                let (out, code) = execute(args, style: Style(color: tty), interactive: false)
                DistributedNotificationCenter.default().postNotificationName(replyName, object: id,
                    userInfo: ["out": out, "code": NSNumber(value: code)], deliverImmediately: true)
            }
        }
    }

    // MARK: Commands

    struct Style {
        let color: Bool
        func c(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
        func bold(_ s: String) -> String { c("1", s) }
        func dim(_ s: String) -> String { c("2", s) }
        func accent(_ s: String) -> String { c("38;5;111", s) }
        func warm(_ s: String) -> String { c("38;5;215", s) }
        func ok(_ s: String) -> String { c("38;5;114", s) }
        func warn(_ s: String) -> String { c("38;5;214", s) }
        func err(_ s: String) -> String { c("38;5;203", s) }
    }

    struct Failure: Error { let message: String; var code: Int32 = 1 }

    static func execute(_ args: [String], style st: Style, interactive: Bool) -> (String, Int32) {
        do { return (try run(args, st, interactive), 0) }
        catch let f as Failure { return (st.err("error: ") + f.message, f.code) }
        catch { return (st.err("error: ") + error.localizedDescription, 1) }
    }

    private static var mgr: DisplayManager { DisplayManager.shared }

    private static func display(_ sel: String?) throws -> Display {
        guard let sel else { throw Failure(message: "missing display (try: builtin, main, external, an index from `lumen list`, an ID, or part of a name)", code: 2) }
        let ds = mgr.displays
        let s = sel.lowercased()
        let found: Display? = switch s {
        case "builtin", "internal", "laptop": ds.first { $0.isBuiltin }
        case "main", "primary": ds.first { $0.isMain }
        case "external", "ext", "monitor": ds.first { !$0.isBuiltin && !$0.isVirtual }
        default:
            if let n = Int(s) { n >= 1 && n <= ds.count ? ds[n - 1] : ds.first { $0.id == CGDirectDisplayID(n) } }
            else { ds.first { $0.name.lowercased().contains(s) } }
        }
        guard let d = found else { throw Failure(message: "no display matches '\(sel)'", code: 2) }
        return d
    }

    private static func onOff(_ s: String?, current: Bool) throws -> Bool {
        switch s?.lowercased() {
        case nil, "toggle": return !current
        case "on", "1", "true", "yes": return true
        case "off", "0", "false", "no": return false
        default: throw Failure(message: "expected on, off or toggle", code: 2)
        }
    }

    private static func pct(_ s: String) throws -> Double {
        guard let v = Double(s.replacingOccurrences(of: "%", with: "")) else { throw Failure(message: "'\(s)' is not a number", code: 2) }
        return v
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        let visible = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
        return s + String(repeating: " ", count: max(0, n - visible))
    }

    private static func run(_ a: [String], _ st: Style, _ interactive: Bool) throws -> String {
        let cmd = a[0]
        let arg = { (i: Int) -> String? in a.count > i ? a[i] : nil }
        switch cmd {
        case "version":
            return "lumen " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")

        case "list", "ls":
            var lines = [st.dim(pad("#", 3) + pad("ID", 6) + pad("NAME", 26) + pad("RESOLUTION", 18) + pad("BRIGHT", 9) + "FLAGS")]
            for (i, d) in mgr.displays.enumerated() {
                var flags: [String] = []
                if d.isMain { flags.append(st.accent("main")) }
                if d.isBuiltin { flags.append("builtin") }
                if d.isVirtual { flags.append("virtual") }
                if !d.isActive { flags.append(st.err("disabled")) }
                if d.isMirroring { flags.append("mirroring") }
                if d.xdrCapable { flags.append(st.warm("xdr")) }
                if d.hdrEnabled || d.currentColor?.isHDR == true { flags.append("hdr") }
                if !d.isBuiltin && !d.isVirtual { flags.append(d.ddc == nil ? st.dim("no-ddc") : d.ddcResponds ? st.ok("ddc") : st.warn("ddc-off")) }
                let res = d.current.map { "\($0.width)×\($0.height)" + ($0.refresh > 0 ? "@\(Int($0.refresh.rounded()))" : "") + ($0.hiDPI ? "*" : "") } ?? "—"
                lines.append(pad("\(i + 1)", 3) + pad("\(d.id)", 6) + pad(st.bold(String(d.name.prefix(24))), 26) + pad(res, 18)
                             + pad(brightnessText(d), 9) + flags.joined(separator: " "))
            }
            return lines.joined(separator: "\n") + "\n" + st.dim("* = HiDPI")

        case "info":
            let d = try display(arg(1))
            var out = [st.bold(d.name) + "  " + st.dim(d.chips.joined(separator: " · "))]
            let w = (d.specs.map(\.0.count).max() ?? 10) + 2
            out += d.specs.map { pad(st.dim($0.0), w) + $0.1 }
            out.append(pad(st.dim("Brightness"), w) + brightnessText(d))
            return out.joined(separator: "\n")

        case "brightness", "b":
            let d = try display(arg(1))
            guard let v = arg(2) else { return brightnessText(d) }
            let p = try pct(v)
            if p > 100 {
                guard !interactive || d.isBuiltin else { throw Failure(message: "XDR boost needs Lumen.app running") }
                guard d.xdrCapable else { throw Failure(message: "\(d.name) has no XDR headroom") }
                if interactive { throw Failure(message: "XDR boost needs Lumen.app running") }
                d.softDim = 1; d.setHardware(1); d.boost = min(p / 100, d.maxBoost)
                XDRBoost.shared.update(for: d); d.applyGamma(); d.persist()
            } else if d.hasHardwareBrightness {
                d.boost = 1; d.softDim = 1
                d.setHardware(max(p, 0) / 100)
                if !interactive { XDRBoost.shared.update(for: d); d.applyGamma(); d.persist() }
            } else {
                if interactive { throw Failure(message: "\(d.name) has no hardware brightness; software dimming needs Lumen.app running") }
                d.softDim = max(0.08, p / 100); d.applyGamma(); d.persist()
            }
            return "\(d.name): " + brightnessText(d)

        case "dim":
            let d = try display(arg(1))
            guard let v = arg(2) else { return "\(d.name): software level \(Int(d.softDim * 100))%" }
            d.softDim = v == "off" ? 1 : max(0.08, min(try pct(v) / 100, 1))
            d.applyGamma(); d.persist()
            return "\(d.name): software level \(Int(d.softDim * 100))%"

        case "xdr":
            let d = try display(arg(1))
            guard d.xdrCapable else { throw Failure(message: "\(d.name) has no XDR headroom") }
            guard let v = arg(2) else { return String(format: "%@: XDR %.2f× (max %.2f×)", d.name, d.boost, d.maxBoost) }
            if v == "off" { d.boost = 1 } else {
                guard let f = Double(v.replacingOccurrences(of: "x", with: "")) else { throw Failure(message: "expected a factor like 1.5 or off", code: 2) }
                d.setHardware(1); d.boost = min(max(f, 1), d.maxBoost)
            }
            XDRBoost.shared.update(for: d); d.persist()
            return String(format: "%@: XDR %.2f×", d.name, d.boost)

        case "resolution", "res":
            let d = try display(arg(1))
            guard let v = arg(2) else { return d.subtitle }
            let parts = v.lowercased().split(separator: "@")
            let wh = parts[0].split(separator: "x").compactMap { Int($0) }
            guard wh.count == 2 else { throw Failure(message: "expected WIDTHxHEIGHT[@HZ], e.g. 2560x1440@60", code: 2) }
            let hz = parts.count > 1 ? Double(parts[1]) : nil
            let wantLo = a.contains("--lodpi")
            let candidates = d.modes.filter { $0.width == wh[0] && $0.height == wh[1] && (wantLo ? !$0.hiDPI : true) }
                .sorted { a, b in
                    let ah = a.hiDPI && !wantLo, bh = b.hiDPI && !wantLo
                    if ah != bh { return ah }
                    let r = hz ?? d.current?.refresh ?? 60
                    return abs(a.refresh - r) < abs(b.refresh - r)
                }
            guard let m = candidates.first else { throw Failure(message: "\(d.name) has no \(wh[0])×\(wh[1]) mode; see `lumen modes \(arg(1)!)`") }
            d.apply(m)
            return "\(d.name): \(m.sizeLabel) \(m.refreshLabel)\(m.hiDPI ? " HiDPI" : "")"

        case "modes":
            let d = try display(arg(1))
            return d.modes.reversed().map { m in
                let cur = m == d.current
                return (cur ? st.accent("● ") : "  ") + pad(m.sizeLabel, 14) + pad(m.refreshLabel, 10) + (m.hiDPI ? "HiDPI" : st.dim("native"))
            }.joined(separator: "\n")

        case "colormodes":
            let d = try display(arg(1))
            guard !d.colorModes.isEmpty else { throw Failure(message: "\(d.name) exposes no color modes") }
            var out: [String] = []
            for g in ["SDR", "HDR10", "HLG"] {
                let ms = d.colorModes.filter { $0.eotfLabel == g }
                guard !ms.isEmpty else { continue }
                out.append(st.bold(g))
                out += ms.map { m in
                    (m == d.currentColor ? st.accent("● ") : "  ") + pad("#\(m.id)", 6) + pad(m.depthLabel, 8) + pad(m.encodingLabel, 13) + m.rangeLabel
                }
            }
            if d.otherTimingModes > 0 { out.append(st.dim("\(d.otherTimingModes) more at other refresh rates")) }
            return out.joined(separator: "\n")

        case "colormode":
            let d = try display(arg(1))
            guard let v = arg(2), let id = UInt32(v.replacingOccurrences(of: "#", with: "")),
                  let m = d.colorModes.first(where: { $0.id == id }) else { throw Failure(message: "usage: lumen colormode <display> <id>  (ids from `lumen colormodes`)", code: 2) }
            guard let previous = d.currentColor else { throw Failure(message: "can't read the current color mode") }
            if m == previous { return "\(d.name): already \(m.summary)" }
            guard d.framebuffer?.setColor(m.id) == true else { throw Failure(message: "the display rejected color mode #\(m.id)") }
            if a.contains("--yes") || a.contains("-y") || !interactive { return "\(d.name): \(m.summary)" }
            print("\(d.name): switched to \(m.summary). Keep it? [y/N] (reverting in 15 s) ", terminator: "")
            fflush(stdout)
            if waitForYes(seconds: 15) { return "Kept." }
            d.framebuffer?.setColor(previous.id)
            return "\nReverted to \(previous.summary)."

        case "hdr":
            let d = try display(arg(1))
            if arg(2) == "force" { d.setForcedHDR(true); return "\(d.name): forcing HDR" }
            let on = try onOff(arg(2), current: d.hdrEnabled)
            if d.hdrSupported { mgr.setHDR(d, on) } else if interactive { throw Failure(message: "\(d.name) doesn't advertise HDR; use `lumen hdr \(arg(1)!) force` with Lumen.app running") } else { d.setForcedHDR(on) }
            return "\(d.name): HDR \(on ? "on" : "off")"

        case "ddc":
            let d = try display(arg(1))
            guard let ddc = d.ddc else { throw Failure(message: "\(d.name) has no DDC channel") }
            let feature: [String: VCP] = ["brightness": .brightness, "contrast": .contrast, "volume": .volume, "input": .input, "mute": .mute]
            guard let name = arg(2), let code = feature[name] else { throw Failure(message: "usage: lumen ddc <display> brightness|contrast|volume|input|mute [value]", code: 2) }
            guard let v = arg(3) else {
                guard let r = ddc.readBlocking(code) else { throw Failure(message: "no reply — enable DDC/CI in the monitor's on-screen menu") }
                return "\(name): \(r.current) / \(r.max)"
            }
            let value: UInt16
            if code == .input, let src = InputSource.common.first(where: { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == v.lowercased() }) { value = src.id }
            else if code == .mute { value = try onOff(v, current: false) ? 1 : 2 }
            else if let n = UInt16(v.hasPrefix("0x") ? String(v.dropFirst(2)) : v, radix: v.hasPrefix("0x") ? 16 : 10) { value = n }
            else { throw Failure(message: "bad value '\(v)'", code: 2) }
            ddc.set(code, value)
            ddc.flush()
            return "\(d.name): \(name) ← \(value)"

        case "enable", "disable":
            let d = try display(arg(1))
            mgr.setEnabled(d, cmd == "enable")
            return "\(d.name): \(cmd)d" + (cmd == "disable" ? st.dim(" (until `lumen enable`, logout, or Lumen quits)") : "")

        case "main":
            let d = try display(arg(1))
            mgr.makeMain(d)
            return "\(d.name) is now the main display"

        case "mirror":
            let d = try display(arg(1))
            if arg(2) == "off" { mgr.setMirroring(d, false); return "\(d.name): mirroring off" }
            mgr.setMirroring(d, true)
            return "\(d.name): mirroring the main display"

        case "invert":
            let d = try display(arg(1))
            let on = try onOff(arg(2), current: d.inverted)
            mgr.setInverted(d, on)
            return "\(d.name): invert \(on ? "on" : "off")"

        case "nightshift":
            let ns = NightShift.shared
            if let v = arg(1), let n = Double(v.replacingOccurrences(of: "%", with: "")) {
                ns.strength = min(max(n / 100, 0), 1); ns.set(true)
                return "Night Shift on, warmth \(Int(n))%"
            }
            let on = try onOff(arg(1), current: ns.isOn)
            ns.set(on)
            return "Night Shift \(on ? "on" : "off")"

        case "grayscale":
            let on = try onOff(arg(1), current: mgr.grayscale)
            mgr.setGrayscale(on)
            return "Grayscale \(on ? "on" : "off")"

        case "dark":
            let on = try onOff(arg(1), current: Appearance.isDark)
            Appearance.setDark(on)
            return "Dark Mode \(on ? "on" : "off")"

        case "virtual":
            let vs = VirtualScreens.shared
            switch arg(1) ?? "list" {
            case "list":
                if vs.configs.isEmpty { return st.dim("No virtual screens. Create one: lumen virtual add 2560x1440") }
                return vs.configs.enumerated().map { i, c in
                    "\(i + 1)  " + pad(st.bold(c.name), 22) + pad(c.label, 22) + (vs.displayID(for: c).map { "id \($0)" } ?? st.err("offline"))
                        + (c.mirrorKey != nil ? st.dim("  shown on a physical display") : "")
                }.joined(separator: "\n")
            case "add":
                guard let size = arg(2) else { throw Failure(message: "usage: lumen virtual add WIDTHxHEIGHT [--lodpi] [--name NAME]", code: 2) }
                let wh = size.lowercased().split(separator: "x").compactMap { Int($0) }
                guard wh.count == 2, wh[0] >= 640, wh[1] >= 480 else { throw Failure(message: "size must look like 2560x1440", code: 2) }
                let name = a.firstIndex(of: "--name").flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil } ?? "Virtual \(wh[0])×\(wh[1])"
                let c = VirtualConfig(name: name, width: wh[0], height: wh[1], hiDPI: !a.contains("--lodpi"))
                vs.add(c)
                return "Created \(name) (\(c.label))"
            case "remove", "rm":
                let c = try virtual(arg(2))
                vs.remove(c)
                return "Removed \(c.name)"
            case "show":
                let c = try virtual(arg(2))
                if arg(3) == "off" || arg(3) == nil { vs.setMirror(c, to: nil); return "\(c.name) is no longer shown on a physical display" }
                let d = try display(arg(3))
                vs.setMirror(c, to: d.persistKey)
                return "\(d.name) now shows \(c.name)"
            default:
                throw Failure(message: "usage: lumen virtual [list | add WxH | remove <name|#> | show <name|#> <display|off>]", code: 2)
            }

        case "viewer":
            let d = try display(arg(1))
            ScreenViewers.shared.show(d.id, name: d.name)
            return "Opened a viewer for \(d.name)"

        default:
            throw Failure(message: "unknown command '\(cmd)'. Run `lumen help`.", code: 2)
        }
    }

    private static func virtual(_ sel: String?) throws -> VirtualConfig {
        let vs = VirtualScreens.shared.configs
        guard let sel else { throw Failure(message: "missing virtual screen", code: 2) }
        if let n = Int(sel), n >= 1, n <= vs.count { return vs[n - 1] }
        guard let c = vs.first(where: { $0.name.lowercased().contains(sel.lowercased()) }) else { throw Failure(message: "no virtual screen matches '\(sel)'", code: 2) }
        return c
    }

    private static func brightnessText(_ d: Display) -> String {
        if d.boost > 1.001 { return String(format: "XDR %.2f×", d.boost) }
        if !d.hasHardwareBrightness { return "\(Int(d.softDim * 100))% sw" }
        let hw = "\(Int((d.brightness * 100).rounded()))%"
        return d.softDim < 0.999 ? "\(hw) dim \(Int(d.softDim * 100))%" : hw
    }

    private static func waitForYes(seconds: Int) -> Bool {
        var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&fds, 1, Int32(seconds * 1000)) > 0, let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func help(_ st: Style) -> String {
        let rows: [(String, String)] = [
            ("list", "Displays with resolution, brightness and capabilities"),
            ("info <d>", "Full diagnostics for a display"),
            ("brightness <d> [0-100|101-250]", "Get/set brightness; >100 is XDR boost (built-in)"),
            ("dim <d> [pct|off]", "Software dimming below the panel minimum"),
            ("xdr <d> [factor|off]", "XDR boost factor, e.g. 1.6"),
            ("resolution <d> [WxH[@Hz]] [--lodpi]", "Get/set resolution (HiDPI preferred)"),
            ("modes <d>", "All resolution modes"),
            ("colormodes <d>", "Link color modes (bit depth, RGB/YCbCr, range, HDR)"),
            ("colormode <d> <id> [-y]", "Switch color mode; reverts in 15 s unless confirmed"),
            ("hdr <d> [on|off|force]", "HDR, or force it on displays that don't advertise it"),
            ("ddc <d> <feature> [value]", "brightness, contrast, volume, input (e.g. hdmi1), mute"),
            ("enable|disable <d>", "Turn a display on/off (session only)"),
            ("main <d>", "Make the main display"),
            ("mirror <d> [off]", "Mirror the main display onto <d>"),
            ("invert <d> [on|off]", "Invert colors on one display"),
            ("nightshift [on|off|0-100]", "Night Shift and warmth"),
            ("grayscale [on|off]", "System grayscale"),
            ("dark [on|off]", "Dark Mode"),
            ("virtual [list|add WxH|remove|show]", "Virtual screens and flexible scaling"),
            ("viewer <d>", "Open a live viewer window for a display"),
        ]
        let w = rows.map(\.0.count).max()! + 2
        return [st.bold("lumen") + " — control your displays from the terminal", "",
                st.dim("USAGE") + "  lumen <command> [args]", "",
                st.dim("DISPLAYS") + "  builtin · main · external · index from `lumen list` · display ID · part of the name", ""]
            .joined(separator: "\n") + "\n" + rows.map { "  " + pad(st.accent($0.0), w) + st.dim($0.1) }.joined(separator: "\n")
            + "\n\n" + st.dim("XDR, dimming, invert, virtual screens and viewers need Lumen.app running; everything else works either way.")
    }
}
