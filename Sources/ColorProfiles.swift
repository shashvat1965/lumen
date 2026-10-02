import Foundation
import ColorSync
import CoreGraphics

struct ColorProfile: Identifiable, Hashable {
    let url: URL
    let name: String
    let group: Group
    var id: String { url.path }

    enum Group: Int, CaseIterable {
        case factory, display, user, system
        var title: String {
            switch self {
            case .factory: "Factory"
            case .display: "Display profiles"
            case .user: "Your profiles"
            case .system: "Standard"
            }
        }
    }
}

/// ICC display profiles through ColorSync — the same per-display assignment
/// System Settings › Displays › Color profile makes.
enum ColorProfiles {
    private static var displayClass: CFString { kColorSyncDisplayDeviceClass.takeUnretainedValue() }

    static func uuid(_ id: CGDirectDisplayID) -> CFUUID? { CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() }

    /// The profile ColorSync is applying right now.
    static func current(_ id: CGDirectDisplayID) -> URL? {
        guard let p = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileGetURL(p, nil)?.takeUnretainedValue() as URL?
    }

    static func hasCustom(_ id: CGDirectDisplayID) -> Bool {
        guard let info = deviceInfo(id), let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] else { return false }
        return custom[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] is URL
            || custom.values.contains { $0 is URL }
    }

    private static func deviceInfo(_ id: CGDirectDisplayID) -> [String: Any]? {
        guard let u = uuid(id) else { return nil }
        return ColorSyncDeviceCopyDeviceInfo(displayClass, u)?.takeRetainedValue() as? [String: Any]
    }

    static func factoryURLs(_ id: CGDirectDisplayID) -> [URL] {
        guard let factory = deviceInfo(id)?[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any] else { return [] }
        return factory.values.compactMap { ($0 as? [String: Any])?[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL }
    }

    /// RGB profiles usable on a display, grouped by where they live.
    static func available(for id: CGDirectDisplayID, name displayName: String) -> [ColorProfile] {
        var seen = Set<String>()
        var out: [ColorProfile] = []
        func add(_ url: URL, _ group: ColorProfile.Group) {
            let key = url.resolvingSymlinksInPath().path
            guard !seen.contains(key), let p = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(), isRGBDisplay(p) else { return }
            seen.insert(key)
            let name = (ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?) ?? url.deletingPathExtension().lastPathComponent
            // macOS keeps an auto-generated profile for every monitor ever connected; only show this display's own.
            if group == .display && name != displayName { return }
            out.append(ColorProfile(url: url, name: name, group: group))
        }
        factoryURLs(id).forEach { add($0, .factory) }
        let fm = FileManager.default
        let dirs: [(String, ColorProfile.Group)] = [
            ("/Library/ColorSync/Profiles/Displays", .display),
            (NSHomeDirectory() + "/Library/ColorSync/Profiles", .user),
            ("/Library/ColorSync/Profiles", .user),
            ("/System/Library/ColorSync/Profiles", .system),
        ]
        for (dir, group) in dirs {
            guard let items = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in items where ["icc", "icm"].contains(url.pathExtension.lowercased()) { add(url, group) }
        }
        if let cur = current(id), !seen.contains(cur.resolvingSymlinksInPath().path) {
            if let p = ColorSyncProfileCreateWithURL(cur as CFURL, nil)?.takeRetainedValue() {
                let n = (ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?) ?? cur.lastPathComponent
                out.append(ColorProfile(url: cur, name: n, group: .display))
            }
        }
        return out.sorted { ($0.group.rawValue, $0.name.lowercased()) < ($1.group.rawValue, $1.name.lowercased()) }
    }

    /// Only RGB *display* (\"mntr\") profiles. Named-color profiles such as
    /// Web Safe Colors can technically be assigned to a screen and wreck it.
    private static func isRGBDisplay(_ p: ColorSyncProfile) -> Bool {
        guard let h = ColorSyncProfileCopyHeader(p)?.takeRetainedValue() as Data?, h.count >= 20 else { return false }
        // ColorSync returns the header in host byte order, so 4-byte tags may be swapped.
        func tag(_ r: Range<Int>, _ v: String) -> Bool { h[r] == Data(v.utf8) || h[r] == Data(v.utf8.reversed()) }
        return tag(12..<16, "mntr") && tag(16..<20, "RGB ")
    }

    /// Assigns `url` to every profile slot of the display (macOS switches slots
    /// with the link color mode, e.g. "HDMI HD" for YCbCr). nil clears every
    /// custom slot, restoring the factory profiles.
    @discardableResult
    static func set(_ id: CGDirectDisplayID, _ url: URL?) -> Bool {
        guard let u = uuid(id) else { return false }
        let info = deviceInfo(id)
        let defaultKey = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        var slots = Set([defaultKey])
        if let factory = info?[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any] {
            slots.formUnion(factory.keys.filter { $0 != defaultKey })
        }
        if let custom = info?[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] {
            slots.formUnion(custom.keys)
        }
        var dict: [String: Any] = [kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser]
        for slot in slots { dict[slot] = (url as Any?) ?? kCFNull! }
        return ColorSyncDeviceSetCustomProfiles(displayClass, u, dict as CFDictionary)
    }
}
