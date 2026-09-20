//
//  FanControlDaemon.swift
//  BoringNotchXPCHelper
//
//  Root-only AppleSMC writer used by Notch Master. The control sequence is
//  based on the MIT-licensed macos-smc-fan research credited in
//  THIRD_PARTY_LICENSES.
//

import Darwin
import Foundation

enum FanControlDaemonConstants {
    static let label = "com.trent.notchmaster.fancontrol"
    static let socketPath = "/var/run/com.trent.notchmaster.fancontrol.sock"
    static let installedExecutable =
        "/Library/PrivilegedHelperTools/com.trent.notchmaster.fancontrol"
    static let installedPlist =
        "/Library/LaunchDaemons/com.trent.notchmaster.fancontrol.plist"
}

enum FanControlSocketError: LocalizedError {
    case invalidPath
    case unavailable(String)
    case rejected(String)
    case invalidCommand
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            "The fan-controller socket path is invalid."
        case .unavailable(let message):
            message
        case .rejected(let message):
            message
        case .invalidCommand:
            "The fan controller received an invalid command."
        case .unauthorized:
            "The fan controller rejected this user."
        }
    }
}

final class FanControlDaemonClient {
    static func status() -> (available: Bool, detail: String) {
        do {
            let response = try request("PING")
            return (true, response)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    static func set(fan: Int, rpm: Int) throws -> String {
        try request("SET \(fan) \(rpm)")
    }

    static func automatic(fan: Int) throws -> String {
        try request("AUTO \(fan)")
    }

    static func automaticAll() throws -> String {
        try request("AUTOALL")
    }

    private static func request(_ command: String) throws -> String {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw FanControlSocketError.unavailable("Could not create the controller socket.")
        }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var address = try socketAddress()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            throw FanControlSocketError.unavailable(
                "Fan controller is not installed or running."
            )
        }

        let requestData = Data((command + "\n").utf8)
        let bytesWritten = requestData.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard bytesWritten == requestData.count else {
            throw FanControlSocketError.unavailable(
                "Could not send the fan command."
            )
        }

        var buffer = [UInt8](repeating: 0, count: 1_024)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else {
            throw FanControlSocketError.unavailable(
                "Fan controller did not respond."
            )
        }
        let response = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if response == "OK" { return "Ready" }
        if response.hasPrefix("OK ") {
            return String(response.dropFirst(3))
        }
        if response.hasPrefix("ERR ") {
            throw FanControlSocketError.rejected(
                String(response.dropFirst(4))
            )
        }
        throw FanControlSocketError.rejected(response)
    }

    fileprivate static func socketAddress() throws -> sockaddr_un {
        let pathBytes = Array(FanControlDaemonConstants.socketPath.utf8) + [0]
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw FanControlSocketError.invalidPath
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        return address
    }
}

final class FanControlDaemon {
    private let allowedUID: uid_t
    private let reader: SMCReader

    init(allowedUID: uid_t) throws {
        guard geteuid() == 0 else {
            throw FanControlSocketError.unavailable(
                "Fan controller must run as root."
            )
        }
        self.allowedUID = allowedUID
        reader = try SMCReader()
    }

    func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        unlink(FanControlDaemonConstants.socketPath)

        let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else {
            throw FanControlSocketError.unavailable("Could not create fan-controller socket.")
        }

        var address = try FanControlDaemonClient.socketAddress()
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    server,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            Darwin.close(server)
            throw FanControlSocketError.unavailable(
                "Could not bind fan-controller socket (errno \(errno))."
            )
        }

        guard chown(FanControlDaemonConstants.socketPath, allowedUID, gid_t.max) == 0,
              chmod(FanControlDaemonConstants.socketPath, S_IRUSR | S_IWUSR) == 0,
              Darwin.listen(server, 4) == 0 else {
            Darwin.close(server)
            unlink(FanControlDaemonConstants.socketPath)
            throw FanControlSocketError.unavailable(
                "Could not secure fan-controller socket."
            )
        }

        while true {
            let client = Darwin.accept(server, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                continue
            }
            autoreleasepool {
                handle(client)
                Darwin.close(client)
            }
        }
    }

    private func handle(_ descriptor: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == allowedUID else {
            respond("ERR unauthorized", to: descriptor)
            return
        }

        var buffer = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else {
            respond("ERR empty command", to: descriptor)
            return
        }
        let command = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let detail = try execute(command)
            respond("OK \(detail)", to: descriptor)
        } catch {
            respond("ERR \(error.localizedDescription)", to: descriptor)
        }
    }

    private func execute(_ command: String) throws -> String {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first else {
            throw FanControlSocketError.invalidCommand
        }

        switch verb {
        case "PING":
            let count = try fanCount()
            return "Ready · \(count) fan\(count == 1 ? "" : "s")"
        case "SET":
            guard parts.count == 3,
                  let fan = Int(parts[1]),
                  let rpm = Int(parts[2]) else {
                throw FanControlSocketError.invalidCommand
            }
            try setFan(fan, rpm: rpm)
            return "Fan \(fan + 1) target \(rpm) RPM"
        case "AUTO":
            guard parts.count == 2, let fan = Int(parts[1]) else {
                throw FanControlSocketError.invalidCommand
            }
            try setAutomatic(fan)
            return "Fan \(fan + 1) returned to Apple automatic control"
        case "AUTOALL":
            let count = try fanCount()
            for fan in 0..<count {
                try setAutomatic(fan)
            }
            return "All fans returned to Apple automatic control"
        default:
            throw FanControlSocketError.invalidCommand
        }
    }

    private func fanCount() throws -> Int {
        let count = try reader.read("FNum").integerValue ?? 0
        guard (1...4).contains(count) else {
            throw FanControlSocketError.rejected("No controllable fan was detected.")
        }
        return count
    }

    private func setFan(_ fan: Int, rpm: Int) throws {
        let count = try fanCount()
        guard (0..<count).contains(fan) else {
            throw FanControlSocketError.rejected("Fan index is out of range.")
        }
        let minimum = try rpmValue("F\(fan)Mn")
        let maximum = try rpmValue("F\(fan)Mx")
        guard minimum <= maximum, (minimum...maximum).contains(rpm) else {
            throw FanControlSocketError.rejected(
                "\(rpm) RPM is outside this fan's detected range (\(minimum)–\(maximum))."
            )
        }

        try enableManualMode(fan)
        let targetKey = "F\(fan)Tg"
        let targetValue = try reader.read(targetKey)
        try reader.write(
            targetKey,
            bytes: Self.rpmBytes(rpm, size: targetValue.bytes.count)
        )
    }

    private func setAutomatic(_ fan: Int) throws {
        let count = try fanCount()
        guard (0..<count).contains(fan) else {
            throw FanControlSocketError.rejected("Fan index is out of range.")
        }
        let fanModeKey = try modeKey(for: fan)
        try? reader.write(fanModeKey, bytes: [0])

        let targetKey = "F\(fan)Tg"
        if let target = try? reader.read(targetKey) {
            try? reader.write(
                targetKey,
                bytes: Self.rpmBytes(0, size: target.bytes.count)
            )
        }

        var hasOtherManualFan = false
        for other in 0..<count where other != fan {
            guard let key = try? modeKey(for: other),
                  let value = try? reader.read(key),
                  value.bytes.first == 1 else {
                continue
            }
            hasOtherManualFan = true
        }
        if !hasOtherManualFan, (try? reader.read("Ftst")) != nil {
            try? reader.write("Ftst", bytes: [0])
        }
    }

    private func enableManualMode(_ fan: Int) throws {
        let key = try modeKey(for: fan)
        if (try? reader.write(key, bytes: [1])) != nil {
            return
        }
        guard (try? reader.read("Ftst")) != nil else {
            throw FanControlSocketError.rejected(
                "This Mac rejected manual fan mode and has no Ftst unlock key."
            )
        }
        try reader.write("Ftst", bytes: [1])
        Thread.sleep(forTimeInterval: 0.5)

        let deadline = Date().addingTimeInterval(10)
        repeat {
            if (try? reader.write(key, bytes: [1])) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        try? reader.write("Ftst", bytes: [0])
        throw FanControlSocketError.rejected(
            "Timed out while enabling manual fan mode."
        )
    }

    private func modeKey(for fan: Int) throws -> String {
        for key in ["F\(fan)md", "F\(fan)Md"] {
            if (try? reader.read(key)) != nil { return key }
        }
        throw FanControlSocketError.rejected(
            "The fan mode key is unavailable on this Mac."
        )
    }

    private func rpmValue(_ key: String) throws -> Int {
        guard let value = try reader.read(key).doubleValue,
              value.isFinite,
              (0...20_000).contains(value) else {
            throw FanControlSocketError.rejected(
                "Fan limits are unavailable."
            )
        }
        return Int(value.rounded())
    }

    private static func rpmBytes(_ rpm: Int, size: Int) -> [UInt8] {
        if size == 4 {
            var value = Float(rpm)
            return withUnsafeBytes(of: &value) { Array($0) }
        }
        let raw = UInt16(clamping: rpm * 4)
        return [UInt8(raw >> 8), UInt8(raw & 0xff)]
    }

    private func respond(_ response: String, to descriptor: Int32) {
        let data = Data((response + "\n").utf8)
        data.withUnsafeBytes { buffer in
            _ = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
    }
}
