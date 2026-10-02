import AppKit
import ServiceManagement

/// Night Shift through CoreBrightness' CBBlueLightClient.
@MainActor
final class NightShift {
    static let shared = NightShift()
    private let client: NSObject? = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()

    var available: Bool { client != nil }

    var isOn: Bool {
        guard let c = client else { return false }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard c.responds(to: sel) else { return false }
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, buf)
        return buf.load(as: Bool.self) // first field: active
    }

    func set(_ on: Bool) {
        guard let c = client else { return }
        let sel = NSSelectorFromString("setEnabled:")
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, on)
    }

    var strength: Double {
        get {
            guard let c = client else { return 0.5 }
            let sel = NSSelectorFromString("getStrength:")
            typealias F = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
            var v: Float = 0.5
            _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, &v)
            return Double(v)
        }
        set {
            guard let c = client else { return }
            let sel = NSSelectorFromString("setStrength:commit:")
            typealias F = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
            _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, Float(newValue), true)
        }
    }
}

enum Appearance {
    static var isDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    static func setDark(_ on: Bool) {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")?.executeAndReturnError(&err)
    }

    static func toggleDark() {
        let src = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
        }
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}
