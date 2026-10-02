import Foundation
import CoreGraphics
import IOKit

/// Thin dlsym layer over the private frameworks Lumen relies on. Every symbol
/// is optional so a missing one degrades a feature instead of crashing.
enum Private {
    private static let loaded: Void = {
        for path in [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess",
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            "/System/Library/Frameworks/IOKit.framework/IOKit",
        ] { dlopen(path, RTLD_LAZY) }
    }()

    static func sym<T>(_ name: String, as type: T.Type) -> T? {
        _ = loaded
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    // DisplayServices — built-in panel brightness
    static let getBrightness = sym("DisplayServicesGetBrightness",
        as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    static let setBrightness = sym("DisplayServicesSetBrightness",
        as: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
    static let canChangeBrightness = sym("DisplayServicesCanChangeBrightness",
        as: (@convention(c) (CGDirectDisplayID) -> Bool).self)

    // SkyLight — HDR and display enable/disable
    static let supportsHDR = sym("SLSDisplaySupportsHDRMode",
        as: (@convention(c) (CGDirectDisplayID) -> Bool).self)
    static let isHDREnabled = sym("SLSDisplayIsHDRModeEnabled",
        as: (@convention(c) (CGDirectDisplayID) -> Bool).self)
    static let setHDREnabled = sym("SLSDisplaySetHDRModeEnabled",
        as: (@convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> Int32).self)
    static let configureDisplayEnabled = sym("SLSConfigureDisplayEnabled",
        as: (@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError).self)

    // UniversalAccess — system-wide grayscale / invert
    static let grayscaleSet = sym("UAGrayscaleSetEnabled", as: (@convention(c) (Bool) -> Void).self)
    static let grayscaleGet = sym("UAGrayscaleIsEnabled", as: (@convention(c) () -> Bool).self)

    // IOKit IOAVService — DDC/CI over the DCP on Apple Silicon
    static let avCreate = sym("IOAVServiceCreateWithService",
        as: (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?).self)
    static let avWrite = sym("IOAVServiceWriteI2C",
        as: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn).self)
    static let avRead = sym("IOAVServiceReadI2C",
        as: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn).self)
}

// IOMobileFramebuffer — link color mode / timing selection (Apple Silicon DCP)
extension Private {
    static let fbLoaded: Void = { dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY) }()
    static var fbOpen: (@convention(c) (io_service_t, mach_port_t, UInt32, UnsafeMutablePointer<OpaquePointer?>) -> Int32)? {
        _ = fbLoaded; return sym("IOMobileFramebufferOpen", as: (@convention(c) (io_service_t, mach_port_t, UInt32, UnsafeMutablePointer<OpaquePointer?>) -> Int32).self)
    }
    static var fbGetMode: (@convention(c) (OpaquePointer, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32)? {
        _ = fbLoaded; return sym("IOMobileFramebufferGetDigitalOutMode", as: (@convention(c) (OpaquePointer, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32).self)
    }
    static var fbSetMode: (@convention(c) (OpaquePointer, UInt32, UInt32) -> Int32)? {
        _ = fbLoaded; return sym("IOMobileFramebufferSetDigitalOutMode", as: (@convention(c) (OpaquePointer, UInt32, UInt32) -> Int32).self)
    }
}
