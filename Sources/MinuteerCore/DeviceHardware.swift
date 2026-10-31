import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum HardwareTier: String, Sendable, CaseIterable {
    case m1Base = "Apple M1"
    case m2Base = "Apple M2"
    case modernBase = "Apple M3/M4"
    case proMaxUltra = "Apple Silicon Pro/Max/Ultra"
    case intelOrOther = "Standard Mac"
}

public struct DeviceHardware: Sendable {
    nonisolated(unsafe) public static var chipNameOverride: String?
    nonisolated(unsafe) public static var memoryGBOverride: Int?

    public static var chipName: String {
        if let override = chipNameOverride {
            return override
        }
        #if canImport(Darwin)
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
        let name = machine.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Apple Silicon" : name
        #else
        return "Generic Mac"
        #endif
    }

    public static var modelIdentifier: String {
        #if canImport(Darwin)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &machine, &size, nil, 0)
        let model = machine.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Mac" : model
        #else
        return "Mac"
        #endif
    }

    public static var physicalMemoryGB: Int {
        if let override = memoryGBOverride {
            return override
        }
        #if canImport(Darwin)
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        return max(1, Int(memSize / (1024 * 1024 * 1024)))
        #else
        return 16
        #endif
    }

    public static var currentTier: HardwareTier {
        hardwareTier(for: chipName)
    }

    public static func hardwareTier(for name: String) -> HardwareTier {
        let lower = name.lowercased()
        if lower.contains("pro") || lower.contains("max") || lower.contains("ultra") {
            return .proMaxUltra
        }
        if lower.contains("m4") || lower.contains("m3") {
            return .modernBase
        }
        if lower.contains("m2") {
            return .m2Base
        }
        if lower.contains("m1") {
            return .m1Base
        }
        return .intelOrOther
    }
}
