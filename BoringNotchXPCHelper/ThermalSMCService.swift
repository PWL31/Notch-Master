//
//  ThermalSMCService.swift
//  BoringNotchXPCHelper
//
//  Read-only AppleSMC access for Notch Master.
//  The SMC data layout follows the MIT-licensed macos-smc-fan and MacMonitor
//  implementations documented in THIRD_PARTY_LICENSES.
//

import Foundation
import IOKit

private enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

private struct SMCParamStruct {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

struct SMCValue {
    let type: String
    let bytes: [UInt8]

    var doubleValue: Double? {
        guard !bytes.isEmpty else { return nil }

        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: bytes.prefix(4))
            }
            return value.isFinite ? Double(value) : nil
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                UInt32(bytes[0]) << 24
                    | UInt32(bytes[1]) << 16
                    | UInt32(bytes[2]) << 8
                    | UInt32(bytes[3])
            )
        case "si8 ":
            return Double(Int8(bitPattern: bytes[0]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        default:
            return nil
        }
    }

    var integerValue: Int? {
        doubleValue.map { Int($0.rounded()) }
    }
}

final class SMCReader {
    private let connection: io_connect_t

    init() throws {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        ) == kIOReturnSuccess else {
            throw ThermalServiceError.smcUnavailable
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            throw ThermalServiceError.smcUnavailable
        }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(
            service,
            mach_task_self_,
            0,
            &openedConnection
        ) == kIOReturnSuccess else {
            throw ThermalServiceError.smcUnavailable
        }

        connection = openedConnection
    }

    deinit {
        IOServiceClose(connection)
    }

    func read(_ key: String) throws -> SMCValue {
        var keyInfoInput = SMCParamStruct()
        keyInfoInput.key = try fourCharacterCode(key)
        keyInfoInput.data8 = SMCCommand.readKeyInfo.rawValue

        let keyInfoOutput = try call(keyInfoInput)
        guard keyInfoOutput.result == 0 else {
            throw ThermalServiceError.keyUnavailable(key)
        }

        var readInput = keyInfoInput
        readInput.keyInfo.dataSize = keyInfoOutput.keyInfo.dataSize
        readInput.data8 = SMCCommand.readBytes.rawValue
        let readOutput = try call(readInput)
        guard readOutput.result == 0 else {
            throw ThermalServiceError.keyUnavailable(key)
        }

        let bytes = withUnsafeBytes(of: readOutput.bytes) {
            Array($0.prefix(Int(keyInfoOutput.keyInfo.dataSize)))
        }
        return SMCValue(
            type: fourCharacterString(keyInfoOutput.keyInfo.dataType),
            bytes: bytes
        )
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        var keyInfoInput = SMCParamStruct()
        keyInfoInput.key = try fourCharacterCode(key)
        keyInfoInput.data8 = SMCCommand.readKeyInfo.rawValue

        let keyInfoOutput = try call(keyInfoInput)
        guard keyInfoOutput.result == 0 else {
            throw ThermalServiceError.keyUnavailable(key)
        }

        let expectedSize = Int(keyInfoOutput.keyInfo.dataSize)
        guard expectedSize > 0, expectedSize <= 32, bytes.count == expectedSize else {
            throw ThermalServiceError.controllerFailed(
                "SMC key \(key) expects \(expectedSize) bytes, received \(bytes.count)."
            )
        }

        var writeInput = keyInfoInput
        writeInput.keyInfo.dataSize = keyInfoOutput.keyInfo.dataSize
        writeInput.data8 = SMCCommand.writeBytes.rawValue
        withUnsafeMutableBytes(of: &writeInput.bytes) { destination in
            destination.copyBytes(from: bytes)
        }

        let writeOutput = try call(writeInput)
        guard writeOutput.result == 0 else {
            throw ThermalServiceError.controllerFailed(
                "SMC rejected \(key) (firmware 0x\(String(writeOutput.result, radix: 16)))."
            )
        }
    }

    func enumerateKeys(limit: Int = 4_096) -> [String] {
        guard
            let countValue = try? read("#KEY"),
            let count = countValue.integerValue,
            count > 0
        else {
            return []
        }

        return (0..<min(count, limit)).compactMap { index in
            var input = SMCParamStruct()
            input.data8 = SMCCommand.readIndex.rawValue
            input.data32 = UInt32(index)
            guard let output = try? call(input), output.result == 0 else {
                return nil
            }
            return fourCharacterString(output.key)
        }
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCCommand.kernelIndex.rawValue),
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else {
            throw ThermalServiceError.ioKit(result)
        }
        return output
    }

    private func fourCharacterCode(_ string: String) throws -> UInt32 {
        guard string.utf8.count == 4 else {
            throw ThermalServiceError.invalidKey(string)
        }
        return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCharacterString(_ value: UInt32) -> String {
        String(
            bytes: [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff),
            ],
            encoding: .ascii
        ) ?? ""
    }
}

enum ThermalServiceError: LocalizedError {
    case smcUnavailable
    case keyUnavailable(String)
    case invalidKey(String)
    case ioKit(kern_return_t)
    case controllerUnavailable
    case invalidRPM(String)
    case controllerFailed(String)
    case controllerTimedOut

    var errorDescription: String? {
        switch self {
        case .smcUnavailable:
            "AppleSMC is unavailable on this Mac."
        case .keyUnavailable(let key):
            "SMC key \(key) is unavailable."
        case .invalidKey(let key):
            "Invalid SMC key \(key)."
        case .ioKit(let code):
            "AppleSMC I/O failed (0x\(String(code, radix: 16)))."
        case .controllerUnavailable:
            "The SMCFanKit helper is not installed. Monitoring remains available."
        case .invalidRPM(let message):
            message
        case .controllerFailed(let message):
            message
        case .controllerTimedOut:
            "The fan controller did not respond within five seconds."
        }
    }
}

private struct ThermalTemperaturePayload: Codable {
    let key: String
    let name: String
    let group: String
    let celsius: Double
}

private struct ThermalFanPayload: Codable {
    let id: Int
    let name: String
    let currentRPM: Int
    let minimumRPM: Int?
    let maximumRPM: Int?
    let targetRPM: Int?
    let manualMode: Bool?
}

private struct ThermalControllerPayload: Codable {
    let available: Bool
    let backend: String?
    let detail: String
}

private struct ThermalSnapshotPayload: Codable {
    let timestamp: Date
    let model: String
    let thermalState: String
    let temperatures: [ThermalTemperaturePayload]
    let fans: [ThermalFanPayload]
    let controller: ThermalControllerPayload
}

final class ThermalSMCService {
    private let queue = DispatchQueue(label: "NotchMaster.thermal.smc")
    private var reader: SMCReader?
    private var cachedTemperatureKeys: [String]?

    func fetchSnapshot(
        completion: @escaping (Data?, String?) -> Void
    ) {
        queue.async {
            do {
                let snapshot = try self.makeSnapshot()
                completion(try JSONEncoder().encode(snapshot), nil)
            } catch {
                completion(nil, error.localizedDescription)
            }
        }
    }

    func setFanControl(
        mode: String,
        rpm: Int?,
        completion: @escaping (Bool, String?) -> Void
    ) {
        queue.async {
            do {
                let fans = try self.readFans()
                guard !fans.isEmpty else {
                    throw ThermalServiceError.controllerFailed(
                        "No controllable fan was detected."
                    )
                }
                let messages: [String]

                switch mode {
                case "automatic":
                    messages = try fans.map {
                        try FanControlDaemonClient.automatic(fan: $0.id)
                    }
                case "full":
                    messages = try fans.map { fan in
                        guard let maximum = fan.maximumRPM else {
                            throw ThermalServiceError.invalidRPM(
                                "The maximum RPM for \(fan.name) is unavailable."
                            )
                        }
                        return try FanControlDaemonClient.set(
                            fan: fan.id,
                            rpm: maximum
                        )
                    }
                case "custom":
                    guard let rpm else {
                        throw ThermalServiceError.invalidRPM("Choose a custom RPM first.")
                    }
                    let minimum = fans.compactMap(\.minimumRPM).max()
                    let maximum = fans.compactMap(\.maximumRPM).min()
                    guard let minimum, let maximum, minimum <= maximum else {
                        throw ThermalServiceError.invalidRPM(
                            "Fan limits are unavailable, so a custom speed cannot be applied safely."
                        )
                    }
                    guard (minimum...maximum).contains(rpm) else {
                        throw ThermalServiceError.invalidRPM(
                            "\(rpm) RPM is outside this Mac’s safe detected range (\(minimum)–\(maximum) RPM)."
                        )
                    }
                    messages = try fans.map {
                        try FanControlDaemonClient.set(fan: $0.id, rpm: rpm)
                    }
                default:
                    throw ThermalServiceError.controllerFailed("Unsupported fan mode.")
                }

                let output = messages.filter { !$0.isEmpty }.joined(separator: "\n")
                completion(true, output.isEmpty ? nil : output)
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }

    private func makeSnapshot() throws -> ThermalSnapshotPayload {
        _ = try smcReader()
        return ThermalSnapshotPayload(
            timestamp: Date(),
            model: Self.hardwareModel(),
            thermalState: Self.thermalStateName,
            temperatures: readTemperatures(),
            fans: try readFans(),
            controller: controllerStatus()
        )
    }

    private func smcReader() throws -> SMCReader {
        if let reader {
            return reader
        }
        let newReader = try SMCReader()
        reader = newReader
        return newReader
    }

    private func readTemperatures() -> [ThermalTemperaturePayload] {
        guard let reader = try? smcReader() else { return [] }

        let keys: [String]
        if let cachedTemperatureKeys {
            keys = cachedTemperatureKeys
        } else {
            let enumerated = reader.enumerateKeys()
                .filter { $0.count == 4 && $0.first == "T" }
            let fallbacks = [
                "TCMz", "TCMb", "TCHP",
                "TRDX", "Tg0e",
                "TB0T", "TB1T", "TB2T",
                "T5SP", "TH0T", "Ts1P", "Ts0P",
                "TPMP", "TPSP", "TAOL", "TW0P", "TIOP",
                "TVm0", "Tm0B", "TMVR", "TVD0", "TVM0", "TVMC",
            ]
            keys = Array(Set(enumerated + fallbacks)).sorted()
            cachedTemperatureKeys = keys
        }

        var values = keys.compactMap { key -> ThermalTemperaturePayload? in
            guard
                let value = try? reader.read(key).doubleValue,
                value.isFinite,
                (5...130).contains(value)
            else {
                return nil
            }
            let metadata = Self.temperatureMetadata(for: key)
            guard metadata.group != "Other" else {
                return nil
            }
            return ThermalTemperaturePayload(
                key: key,
                name: metadata.name,
                group: metadata.group,
                celsius: value
            )
        }

        // Apple Silicon exposes multiple cluster sensors rather than the
        // user-facing averages found in older utilities. Derive stable,
        // selectable summaries while preserving the original raw sensors.
        Self.appendAverage(
            key: "CPUA",
            name: "CPU Core Average",
            group: "CPU",
            matching: { $0.key.hasPrefix("Tp0") || $0.key.hasPrefix("Te0") },
            to: &values
        )
        Self.appendAverage(
            key: "PAVG",
            name: "CPU Performance Core Average",
            group: "CPU",
            matching: { $0.key.hasPrefix("Tp0") },
            to: &values
        )
        Self.appendAverage(
            key: "EAVG",
            name: "CPU Efficiency Core Average",
            group: "CPU",
            matching: { $0.key.hasPrefix("Te0") },
            to: &values
        )
        Self.appendAverage(
            key: "BAVG",
            name: "Battery Average",
            group: "Battery",
            matching: { ["TB0T", "TB1T", "TB2T"].contains($0.key) },
            to: &values
        )

        let ordered = values.sorted {
            let leftPriority = Self.temperaturePriority($0)
            let rightPriority = Self.temperaturePriority($1)
            return leftPriority == rightPriority
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : leftPriority < rightPriority
        }

        // Keep the picker readable while still exposing representative
        // per-cluster sensors beneath the synthetic averages.
        var perGroup: [String: Int] = [:]
        return ordered.filter { sensor in
            let current = perGroup[sensor.group, default: 0]
            guard current < 10 else { return false }
            perGroup[sensor.group] = current + 1
            return true
        }
    }

    private func readFans() throws -> [ThermalFanPayload] {
        let reader = try smcReader()
        let reportedCount = (try? reader.read("FNum").integerValue) ?? 0
        let candidateCount = min(max(reportedCount, 2), 4)

        var fans: [ThermalFanPayload] = []
        for index in 0..<candidateCount {
            guard
                let current = try? reader.read("F\(index)Ac").doubleValue,
                current.isFinite,
                current >= 0
            else {
                continue
            }

            fans.append(
                ThermalFanPayload(
                    id: index,
                    name: reportedCount > 1 ? "Fan \(index + 1)" : "Fan",
                    currentRPM: Int(current.rounded()),
                    minimumRPM: Self.validRPM(
                        try? reader.read("F\(index)Mn").doubleValue
                    ),
                    maximumRPM: Self.validRPM(
                        try? reader.read("F\(index)Mx").doubleValue
                    ),
                    targetRPM: Self.validRPM(
                        try? reader.read("F\(index)Tg").doubleValue
                    ),
                    manualMode: Self.manualMode(reader: reader, fan: index)
                )
            )
        }
        return fans
    }

    private func controllerStatus() -> ThermalControllerPayload {
        let status = FanControlDaemonClient.status()
        if status.available {
            return ThermalControllerPayload(
                available: true,
                backend: "Notch Master Fan Helper",
                detail: status.detail
            )
        }
        return ThermalControllerPayload(
            available: false,
            backend: nil,
            detail: "Monitoring only · install Fan Controller in Activity settings"
        )
    }

    private static func validRPM(_ value: Double?) -> Int? {
        guard let value else { return nil }
        guard value.isFinite, (0...20_000).contains(value) else { return nil }
        return Int(value.rounded())
    }

    private static func manualMode(reader: SMCReader, fan: Int) -> Bool? {
        for key in ["F\(fan)md", "F\(fan)Md"] {
            if let bytes = try? reader.read(key).bytes,
               let value = bytes.first {
                return value == 1
            }
        }
        return nil
    }

    private static func temperatureMetadata(
        for key: String
    ) -> (name: String, group: String) {
        switch key {
        case "TCMz": return ("CPU Die Hotspot", "CPU")
        case "TCMb": return ("CPU Core Maximum", "CPU")
        case "TCHP": return ("CPU / Charger Proximity", "CPU")
        case "TRDX": return ("GPU Die Hotspot", "GPU")
        case "TB0T": return ("Battery Pack 1", "Battery")
        case "TB1T": return ("Battery Pack 2", "Battery")
        case "TB2T": return ("Battery Pack 3", "Battery")
        case "T5SP": return ("SSD Controller", "Storage")
        case "TH0T": return ("NAND Flash", "Storage")
        case "Ts1P", "TsOP": return ("SSD Proximity", "Storage")
        case "TPMP": return ("SoC Package", "System")
        case "TPSP": return ("SoC Surface", "System")
        case "TAOL": return ("Ambient Airflow", "System")
        case "TW0P": return ("Wi-Fi / Airport Proximity", "System")
        case "TIOP": return ("Thunderbolt Controller", "System")
        case "TDBP": return ("Display Backlight", "System")
        case "TDeL": return ("Display Panel", "System")
        case "TVm0", "Tm0B": return ("Unified Memory", "Memory")
        case "TMVR": return ("Memory VRM", "Memory")
        case "TVD0", "TVM0", "TVMC": return ("Power / Memory Regulator", "Memory")
        default:
            if key.hasPrefix("Tp0") || key.hasPrefix("Te0") {
                return ("CPU Cluster (\(key))", "CPU")
            }
            if key.hasPrefix("Tg0") {
                return ("GPU Cluster (\(key))", "GPU")
            }
            if key.hasPrefix("TB") {
                return ("Battery Sensor (\(key))", "Battery")
            }
            if key.hasPrefix("TPD") {
                return ("SoC Package (\(key))", "System")
            }
            if key.hasPrefix("TV") || key.hasPrefix("Tm") {
                return ("Memory / VRM Sensor (\(key))", "Memory")
            }
            return ("Other Sensor (\(key))", "Other")
        }
    }

    private static func appendAverage(
        key: String,
        name: String,
        group: String,
        matching predicate: (ThermalTemperaturePayload) -> Bool,
        to values: inout [ThermalTemperaturePayload]
    ) {
        let matched = values.filter(predicate)
        guard !matched.isEmpty else { return }
        values.append(
            ThermalTemperaturePayload(
                key: key,
                name: name,
                group: group,
                celsius: matched.map(\.celsius).reduce(0, +)
                    / Double(matched.count)
            )
        )
    }

    private static func temperaturePriority(
        _ sensor: ThermalTemperaturePayload
    ) -> Int {
        let preferred = [
            "TCMz", "CPUA", "PAVG", "EAVG", "TCMb",
            "TRDX", "BAVG", "TB0T", "T5SP", "TPMP",
        ]
        if let index = preferred.firstIndex(of: sensor.key) {
            return index
        }
        let groupOrder = ["CPU", "GPU", "Battery", "Storage", "System", "Other"]
        return 20 + (groupOrder.firstIndex(of: sensor.group) ?? groupOrder.count)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static var thermalStateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
