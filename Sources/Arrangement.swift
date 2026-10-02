import CoreGraphics
import Foundation

/// Display arrangement in global (top-left origin, points) coordinates.
@MainActor
enum Arrangement {
    enum Side: String, CaseIterable { case left, right, above, below }
    enum Align: String { case start, center, end }

    /// Displays that occupy their own space on the desktop.
    static func participants(_ ds: [Display]) -> [Display] {
        ds.filter { $0.isActive && CGDisplayMirrorsDisplay($0.id) == kCGNullDirectDisplay }
    }

    static func bounds(_ ds: [Display]) -> [CGDirectDisplayID: CGRect] {
        Dictionary(uniqueKeysWithValues: participants(ds).map { ($0.id, CGDisplayBounds($0.id)) })
    }

    /// Nearest valid position for `id` touching another display's edge,
    /// snapping to edge/center alignment when close.
    static func snap(_ id: CGDirectDisplayID, proposed p: CGRect, in frames: [CGDirectDisplayID: CGRect]) -> CGRect {
        let others = frames.filter { $0.key != id }.map(\.value)
        guard !others.isEmpty else { return p }
        let w = p.width, h = p.height
        let snapDist = max(w, h) * 0.08
        var candidates: [CGRect] = []

        func alignAxis(_ v: CGFloat, size: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
            let v = min(max(v, lo - size + 1), hi - 1)  // keep at least a sliver of shared edge
            for target in [lo, hi - size, (lo + hi - size) / 2] where abs(v - target) < snapDist { return target }
            return v
        }

        for o in others {
            let y = alignAxis(p.minY, size: h, lo: o.minY, hi: o.maxY)
            let x = alignAxis(p.minX, size: w, lo: o.minX, hi: o.maxX)
            candidates.append(CGRect(x: o.minX - w, y: y, width: w, height: h))   // left of o
            candidates.append(CGRect(x: o.maxX, y: y, width: w, height: h))       // right of o
            candidates.append(CGRect(x: x, y: o.minY - h, width: w, height: h))   // above o
            candidates.append(CGRect(x: x, y: o.maxY, width: w, height: h))       // below o
        }
        let valid = candidates.filter { c in !others.contains { $0.intersection(c).width > 0.5 && $0.intersection(c).height > 0.5 } }
        func dist(_ r: CGRect) -> CGFloat { hypot(r.minX - p.minX, r.minY - p.minY) }
        return (valid.min { dist($0) < dist($1) } ?? candidates.min { dist($0) < dist($1) } ?? p).integral
    }

    static func place(_ id: CGDirectDisplayID, _ side: Side, of other: CGDirectDisplayID, align: Align,
                      in frames: [CGDirectDisplayID: CGRect]) -> CGRect? {
        guard let r = frames[id], let o = frames[other] else { return nil }
        let w = r.width, h = r.height
        func along(_ lo: CGFloat, _ hi: CGFloat, _ size: CGFloat) -> CGFloat {
            switch align { case .start: lo; case .center: (lo + hi - size) / 2; case .end: hi - size }
        }
        let rect: CGRect = switch side {
        case .left: CGRect(x: o.minX - w, y: along(o.minY, o.maxY, h), width: w, height: h)
        case .right: CGRect(x: o.maxX, y: along(o.minY, o.maxY, h), width: w, height: h)
        case .above: CGRect(x: along(o.minX, o.maxX, w), y: o.minY - h, width: w, height: h)
        case .below: CGRect(x: along(o.minX, o.maxX, w), y: o.maxY, width: w, height: h)
        }
        return rect.integral
    }

    /// Writes new origins, keeping the main display at (0, 0) as macOS requires.
    @discardableResult
    static func apply(_ frames: [CGDirectDisplayID: CGRect]) -> Bool {
        let main = CGMainDisplayID()
        let shift = frames[main]?.origin ?? .zero
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        for (id, r) in frames {
            CGConfigureDisplayOrigin(cfg, id, Int32((r.minX - shift.x).rounded()), Int32((r.minY - shift.y).rounded()))
        }
        let ok = CGCompleteDisplayConfiguration(cfg, .permanently) == .success
        DisplayManager.shared.scheduleRefresh()
        return ok
    }
}
