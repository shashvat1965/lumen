import Foundation
import IOKit
import CoreGraphics

/// One "ColorElement" the DCP can drive the link with.
struct ColorMode: Identifiable, Hashable {
    let id: UInt32
    let depth: Int
    let encoding: Int      // 0 RGB, 1 YCbCr 4:2:2, 2 YCbCr 4:2:0, 3 YCbCr 4:4:4
    let range: Int         // 0 full, 1 limited
    let eotf: Int          // 0 SDR (gamma), 1 PQ / HDR10, 2 HLG
    let colorimetry: Int
    let score: Int

    init?(_ d: [String: Any]) {
        guard let id = (d["ID"] as? NSNumber)?.uint32Value else { return nil }
        self.id = id
        depth = d["Depth"] as? Int ?? 8
        encoding = d["PixelEncoding"] as? Int ?? 0
        range = d["DynamicRange"] as? Int ?? 0
        eotf = d["EOTF"] as? Int ?? 0
        colorimetry = d["Colorimetry"] as? Int ?? 0
        score = d["Score"] as? Int ?? 0
    }

    var depthLabel: String { "\(depth)-bit" }
    var eotfLabel: String { ["SDR", "HDR10", "HLG"].indices.contains(eotf) ? ["SDR", "HDR10", "HLG"][eotf] : "EOTF \(eotf)" }
    var encodingLabel: String {
        switch encoding { case 0: "RGB"; case 3: "YCbCr 4:4:4"; default: "YCbCr" }
    }
    var rangeLabel: String { range == 0 ? "Full" : "Limited" }
    var isHDR: Bool { eotf != 0 }
    var summary: String { "\(depthLabel) \(eotfLabel) \(encodingLabel) \(rangeLabel)" }
}

/// The DCP framebuffer backing a CGDisplay. Lets us read and switch the link's
/// color element (bit depth / encoding / range / transfer function).
final class Framebuffer {
    let service: io_service_t
    private var ref: OpaquePointer?

    private init(service: io_service_t) {
        self.service = service
        IOObjectRetain(service)
    }
    deinit { IOObjectRelease(service) }

    static func find(for id: CGDirectDisplayID) -> Framebuffer? {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        let builtin = CGDisplayIsBuiltin(id) != 0
        let v = CGDisplayVendorNumber(id), p = CGDisplayModelNumber(id), s = CGDisplaySerialNumber(id)
        var fallback: Framebuffer?
        while true {
            let svc = IOIteratorNext(iter)
            if svc == 0 { break }
            defer { IOObjectRelease(svc) }
            guard let attrs = (IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "DisplayAttributes" as CFString, nil,
                    IOOptionBits(kIORegistryIterateRecursively)) as? [String: Any])?["ProductAttributes"] as? [String: Any] else { continue }
            let fv = (attrs["LegacyManufacturerID"] as? NSNumber)?.uint32Value
            let fp = (attrs["ProductID"] as? NSNumber)?.uint32Value
            let fs = (attrs["SerialNumber"] as? NSNumber)?.uint32Value
            if builtin {
                if fv == 1552 && fs == nil { return Framebuffer(service: svc) }
            } else if fv == v && fp == p {
                if fs == s || s == 0 { return Framebuffer(service: svc) }
                fallback = Framebuffer(service: svc)
            }
        }
        return fallback
    }

    private func handle() -> OpaquePointer? {
        if let ref { return ref }
        guard let open = Private.fbOpen else { return nil }
        var r: OpaquePointer?
        guard open(service, mach_task_self_, 0, &r) == 0 else { return nil }
        ref = r
        return r
    }

    private func prop<T>(_ key: String) -> T? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
    }

    var current: (color: UInt32, timing: UInt32)? {
        guard let h = handle(), let get = Private.fbGetMode else { return nil }
        var c: UInt32 = 0, t: UInt32 = 0
        return get(h, &c, &t) == 0 ? (c, t) : nil
    }

    /// Color modes valid for the timing currently on the wire, best first.
    func modesForCurrentTiming() -> [ColorMode] {
        guard let cur = current, let timings: [[String: Any]] = prop("TimingElements") else { return [] }
        let timing = timings.first { ($0["ID"] as? NSNumber)?.uint32Value == cur.timing }
        let list = (timing?["ColorModes"] as? [[String: Any]]) ?? (prop("ColorElements") ?? [])
        var seen = Set<UInt32>()
        return list.compactMap(ColorMode.init).filter { seen.insert($0.id).inserted }
            .sorted { ($0.eotf, -$0.depth, $0.encoding, $0.range) < ($1.eotf, -$1.depth, $1.encoding, $1.range) }
    }

    /// Number of extra color modes that only exist at other refresh rates/timings.
    func otherTimingModeCount() -> Int {
        let all: [[String: Any]] = prop("ColorElements") ?? []
        return max(0, Set(all.compactMap { ($0["ID"] as? NSNumber)?.uint32Value }).count - modesForCurrentTiming().count)
    }

    @discardableResult
    func setColor(_ color: UInt32) -> Bool {
        guard let h = handle(), let set = Private.fbSetMode, let cur = current else { return false }
        return set(h, color, cur.timing) == 0
    }
}
