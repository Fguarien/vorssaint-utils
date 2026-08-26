// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation

enum CPUTemperaturePlatform: Equatable {
    case appleM1Family
    case appleM2Family
    case appleM3Family
    case appleM4Family
    case appleM5Family
    case intel
    case generic
}

struct CachedSensorReading {
    var value: Double
    var updatedAt: TimeInterval
    var missedSamples: Int
}

enum TemperatureSensorSelector {
    static let minimumChipTemperature = 10.0

    private static let appleM1CPUCoreKeys: Set<String> = [
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H",
        "Tp0L", "Tp0P", "Tp0X", "Tp0b",
    ]

    private static let appleM2CPUCoreKeys: Set<String> = [
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0X", "Tp0b", "Tp0f", "Tp0j",
    ]

    private static let appleM3CPUCoreKeys: Set<String> = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B",
        "Tf0D", "Tf0E", "Tf44", "Tf49",
        "Tf4A", "Tf4B", "Tf4D", "Tf4E",
    ]

    private static let appleM4CPUCoreKeys: Set<String> = [
        "Te05", "Te0S", "Te09", "Te0H",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
    ]

    private static let appleM5CPUCoreKeys: Set<String> = [
        "Tp00", "Tp04", "Tp08", "Tp0C",
        "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X",
        "Tp0a", "Tp0d", "Tp0g", "Tp0j",
        "Tp0m", "Tp0p", "Tp0u", "Tp0y",
    ]

    static func platform(brandString: String?) -> CPUTemperaturePlatform {
        let brand = brandString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch appleSiliconGeneration(in: brand) {
        case 1: return .appleM1Family
        case 2: return .appleM2Family
        case 3: return .appleM3Family
        case 4: return .appleM4Family
        case 5: return .appleM5Family
        default:
            // Intel Macs name their CPU in the same sysctl. They expose a
            // completely different SMC namespace (TC…/TG… instead of Tp…/Tg…),
            // so they need their own platform rather than the generic fallback,
            // which finds no CPU sensor at all on them.
            return brand.contains("Intel") ? .intel : .generic
        }
    }

    static func currentPlatform() -> CPUTemperaturePlatform {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return .generic
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return .generic
        }
        return platform(brandString: String(cString: buffer))
    }

    static func displayedCPUTemperature(readings: [(key: String, value: Double)],
                                        platform: CPUTemperaturePlatform) -> Double? {
        let valid = readings.filter { isPlausibleTemperature($0.value) }
        guard !valid.isEmpty else { return nil }

        let core = valid.filter { isCPUCoreKey($0.key, platform: platform) }
        if let value = core.map({ $0.value }).max() {
            return value
        }
        return valid.map { $0.value }.max()
    }

    static func hasCPUCoreSet(platform: CPUTemperaturePlatform) -> Bool {
        switch platform {
        case .appleM1Family, .appleM2Family, .appleM3Family, .appleM4Family, .appleM5Family:
            return true
        case .intel: return true
        case .generic: return false
        }
    }

    static func isCPUCoreKey(_ key: String, platform: CPUTemperaturePlatform) -> Bool {
        switch platform {
        case .appleM1Family:
            return appleM1CPUCoreKeys.contains(key)
        case .appleM2Family:
            return appleM2CPUCoreKeys.contains(key)
        case .appleM3Family:
            return appleM3CPUCoreKeys.contains(key)
        case .appleM4Family:
            return appleM4CPUCoreKeys.contains(key)
        case .appleM5Family:
            return appleM5CPUCoreKeys.contains(key)
        case .intel:
            return isIntelCPUCoreKey(key)
        case .generic:
            return false
        }
    }

    /// Intel die sensors, the ones that actually track the cores: TC0c…TC9c per
    /// core, TCXc/TCXC for the package (PECI), TC0D/TCXD for the die on the
    /// notebooks. Deliberately excludes TC0P and TC0H — proximity and heatsink
    /// sensors that lag the die by ten degrees or more.
    static func isIntelCPUCoreKey(_ key: String) -> Bool {
        let characters = Array(key)
        guard characters.count == 4, characters[0] == "T", characters[1] == "C" else { return false }
        guard characters[2].isNumber || characters[2] == "X" else { return false }
        return characters[3] == "c" || characters[3] == "C"
            || characters[3] == "d" || characters[3] == "D"
    }

    static func isCPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        // Intel keeps its CPU sensors under TC…; Tp/Te on those machines are
        // power-supply and enclosure probes, so matching them there would
        // display a case temperature as the CPU temperature.
        if platform == .intel { return key.hasPrefix("TC") }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return true }
        return platform == .appleM3Family && key.hasPrefix("Tf")
    }

    /// GPU sensors: Tg… on Apple Silicon, TG… on Intel (one block per discrete
    /// GPU, so a dual-GPU Mac Pro reports both).
    static func isGPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        platform == .intel ? key.hasPrefix("TG") : key.hasPrefix("Tg")
    }

    static func stabilizedTemperature(_ reading: Double?,
                                      cache: inout CachedSensorReading?,
                                      now: TimeInterval,
                                      maxAge: TimeInterval,
                                      minimum: Double = 1) -> Double? {
        if let reading, reading > 1, reading >= minimum, reading < 125 {
            cache = CachedSensorReading(value: reading, updatedAt: now, missedSamples: 0)
            return reading
        }
        guard var cached = cache else { return nil }
        cached.missedSamples += 1
        if cached.missedSamples <= 4, now - cached.updatedAt <= maxAge {
            cache = cached
            return cached.value
        }
        cache = nil
        return nil
    }

    private static func appleSiliconGeneration(in brand: String) -> Int? {
        guard brand.hasPrefix("Apple M") else { return nil }
        let remainder = brand.dropFirst("Apple M".count)
        guard let first = remainder.first, let generation = Int(String(first)) else { return nil }
        guard generation >= 1, generation <= 5 else { return nil }
        let afterGeneration = remainder.dropFirst()
        guard afterGeneration.isEmpty || afterGeneration.first == " " else { return nil }
        return generation
    }

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value >= minimumChipTemperature && value < 125
    }
}
