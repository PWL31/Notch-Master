//
//  FanControlInstallerService.swift
//  BoringNotchXPCHelper
//

import AppKit
import Foundation

final class FanControlInstallerService {
    private let queue = DispatchQueue(
        label: "NotchMaster.fan-controller.installer",
        qos: .userInitiated
    )

    func status() -> (installed: Bool, detail: String) {
        let status = FanControlDaemonClient.status()
        if status.available { return (true, status.detail) }

        let executableExists = FileManager.default.fileExists(
            atPath: FanControlDaemonConstants.installedExecutable
        )
        if executableExists {
            return (
                false,
                "Fan controller is installed but not responding. Choose Repair."
            )
        }
        return (false, "Not installed")
    }

    func install(completion: @escaping (Bool, String?) -> Void) {
        queue.async {
            do {
                let source = try self.sourceExecutable()
                let plistURL = try self.makeLaunchDaemonPlist()
                defer { try? FileManager.default.removeItem(at: plistURL) }

                let command = [
                    "/bin/launchctl bootout system/\(FanControlDaemonConstants.label) >/dev/null 2>&1 || true",
                    "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
                    "/usr/bin/install -o root -g wheel -m 755 \(Self.shellQuote(source.path)) \(Self.shellQuote(FanControlDaemonConstants.installedExecutable))",
                    "/usr/bin/install -o root -g wheel -m 644 \(Self.shellQuote(plistURL.path)) \(Self.shellQuote(FanControlDaemonConstants.installedPlist))",
                    "/bin/launchctl bootstrap system \(Self.shellQuote(FanControlDaemonConstants.installedPlist))",
                    "/bin/launchctl enable system/\(FanControlDaemonConstants.label)",
                    "/bin/launchctl kickstart -k system/\(FanControlDaemonConstants.label)",
                ].joined(separator: "; ")

                try Self.runWithAdministratorPrivileges(command)

                let deadline = Date().addingTimeInterval(12)
                repeat {
                    let status = FanControlDaemonClient.status()
                    if status.available {
                        completion(true, status.detail)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                } while Date() < deadline

                completion(
                    false,
                    "The helper was installed, but it did not start. Choose Repair or check the system log."
                )
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }

    func uninstall(completion: @escaping (Bool, String?) -> Void) {
        queue.async {
            _ = try? FanControlDaemonClient.automaticAll()
            do {
                let command = [
                    "/bin/launchctl bootout system/\(FanControlDaemonConstants.label) >/dev/null 2>&1 || true",
                    "/bin/rm -f \(Self.shellQuote(FanControlDaemonConstants.installedExecutable))",
                    "/bin/rm -f \(Self.shellQuote(FanControlDaemonConstants.installedPlist))",
                    "/bin/rm -f \(Self.shellQuote(FanControlDaemonConstants.socketPath))",
                ].joined(separator: "; ")
                try Self.runWithAdministratorPrivileges(command)
                completion(true, "Removed")
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }

    private func sourceExecutable() throws -> URL {
        guard let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw FanControlSocketError.unavailable(
                "The embedded fan-controller executable is missing."
            )
        }
        return executable
    }

    private func makeLaunchDaemonPlist() throws -> URL {
        let uid = getuid()
        let plist: [String: Any] = [
            "Label": FanControlDaemonConstants.label,
            "ProgramArguments": [
                FanControlDaemonConstants.installedExecutable,
                "--fan-daemon",
                "--allowed-uid",
                String(uid),
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 5,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(FanControlDaemonConstants.label)-\(UUID().uuidString).plist"
            )
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func runWithAdministratorPrivileges(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(
            source: "do shell script \"\(escaped)\" with administrator privileges"
        ) else {
            throw FanControlSocketError.unavailable(
                "Could not create the administrator installer."
            )
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "Administrator authorization was cancelled or failed."
            throw FanControlSocketError.unavailable(message)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
