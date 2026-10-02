import Foundation
import IOKit

enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case input = 0x60
    case volume = 0x62
    case mute = 0x8D
    case power = 0xD6
}

/// One DDC/CI channel to an external monitor. All I/O happens on a private
/// serial queue; writes are coalesced so dragging a slider never floods the bus.
final class DDCChannel: @unchecked Sendable {
    let service: CFTypeRef
    let vendor: UInt32?
    let product: UInt32?
    let serial: UInt32?
    let name: String?

    private let queue = DispatchQueue(label: "lumen.ddc")
    private var pending: [UInt8: UInt16] = [:]
    private var scheduled = false
    private let lock = NSLock()

    init(service: CFTypeRef, attrs: [String: Any]) {
        self.service = service
        vendor = (attrs["LegacyManufacturerID"] as? NSNumber)?.uint32Value
        product = (attrs["ProductID"] as? NSNumber)?.uint32Value
        serial = (attrs["SerialNumber"] as? NSNumber)?.uint32Value
        name = attrs["ProductName"] as? String
    }

    func set(_ code: VCP, _ value: UInt16) {
        lock.lock()
        pending[code.rawValue] = value
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let (c, v) = pending.first else { scheduled = false; lock.unlock(); return }
                pending.removeValue(forKey: c)
                lock.unlock()
                _ = writeNow(c, v)
                usleep(20_000)
            }
        }
    }

    func read(_ code: VCP, completion: @escaping @Sendable ((current: UInt16, max: UInt16)?) -> Void) {
        queue.async { [self] in completion(readNow(code.rawValue)) }
    }

    /// Synchronous read for the CLI.
    func readBlocking(_ code: VCP) -> (current: UInt16, max: UInt16)? { queue.sync { readNow(code.rawValue) } }
    /// Waits for queued writes to hit the bus.
    func flush() {
        for _ in 0..<50 {
            lock.lock(); let busy = scheduled; lock.unlock()
            if !busy { break }
            usleep(20_000)
        }
        queue.sync {}
    }

    private func i2cWrite(_ bytes: [UInt8]) -> Bool {
        guard let write = Private.avWrite else { return false }
        var buf = bytes
        return buf.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) } == KERN_SUCCESS
    }

    private func writeNow(_ code: UInt8, _ value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(packet.reduce(0x6E ^ 0x51, ^))
        var ok = false
        for _ in 0..<2 {
            usleep(10_000)
            if i2cWrite(packet) { ok = true }
        }
        return ok
    }

    private func readNow(_ code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let read = Private.avRead else { return nil }
        var request: [UInt8] = [0x82, 0x01, code]
        request.append(request.reduce(0x6E ^ 0x51, ^))
        for _ in 0..<4 {
            usleep(10_000)
            guard i2cWrite(request) else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let r = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            guard r == KERN_SUCCESS else { continue }
            // Locate the "VCP feature reply" opcode rather than trusting a fixed offset.
            for i in 0..<(reply.count - 7) where reply[i] == 0x02 && reply[i + 1] == 0x00 && reply[i + 2] == code {
                let max = UInt16(reply[i + 4]) << 8 | UInt16(reply[i + 5])
                let cur = UInt16(reply[i + 6]) << 8 | UInt16(reply[i + 7])
                if max > 0 { return (cur, max) }
            }
        }
        return nil
    }

    /// Walks the IORegistry pairing each external DCPAVServiceProxy with the
    /// framebuffer (and its EDID-derived attributes) that precedes it.
    static func discover() -> [DDCChannel] {
        guard let create = Private.avCreate else { return [] }
        var iter = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        var channels: [DDCChannel] = []
        var attrs: [String: Any]?
        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            let name = String(cString: nameBuf)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                attrs = (prop(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
            } else if name == "DCPAVServiceProxy" {
                guard prop(entry, "Location") as? String == "External", let a = attrs,
                      let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                channels.append(DDCChannel(service: svc, attrs: a))
                attrs = nil
            }
        }
        return channels
    }
}
