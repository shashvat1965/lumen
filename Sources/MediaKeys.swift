import AppKit
import ApplicationServices

/// Intercepts the brightness keys so they drive whichever display the pointer
/// is on: DDC for external monitors, XDR boost / soft dimming at the ends of
/// the built-in panel's range. Everything else passes through untouched.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()
    private var tap: CFMachPort?
    private var retry: Timer?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        guard tap == nil else { return }
        if !install() {
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if MediaKeys.shared.install() { MediaKeys.shared.retry?.invalidate() }
                }
            }
        }
    }

    func stop() {
        retry?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
    }

    @discardableResult
    private func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let t = MediaKeys.shared.tap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { MediaKeys.shared.handle(event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(_ event: CGEvent) -> Bool {
        guard Settings.mediaKeys, let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        guard code == 2 || code == 3 else { return false } // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        let dir: Double = code == 2 ? 1 : -1

        let mgr = DisplayManager.shared
        guard let d = Settings.keysFollowCursor ? (mgr.displayUnderCursor ?? mgr.displays.first { $0.isMain }) : mgr.displays.first(where: { $0.isMain }) else { return false }

        if d.isBuiltin {
            // Let macOS own the normal range; we only take over at either end.
            if let get = Private.getBrightness { var b: Float = 0; if get(d.id, &b) == 0 { d.brightness = Double(b) } }
            let intoXDR = d.xdrCapable && d.maxBoost > 1.01 && ((dir > 0 && d.brightness >= 0.999) || (dir < 0 && d.boost > 1.001))
            let intoDim = Settings.extendDimming && ((dir < 0 && d.brightness <= 0.001) || (dir > 0 && d.softDim < 0.999))
            guard intoXDR || intoDim else { return false }
        }
        if down {
            d.step(dir)
            HUD.shared.show(for: d)
        }
        return true
    }
}
