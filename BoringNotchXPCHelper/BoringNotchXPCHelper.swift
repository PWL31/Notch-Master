//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import AppKit
import ApplicationServices
import IOKit

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {

    private weak var connection: NSXPCConnection?

    private let lunarStateQueue = DispatchQueue(label: "BoringNotchXPCHelper.lunar.state")
    private let lunarExecutableURL = URL(fileURLWithPath: "/Applications/Lunar.app/Contents/MacOS/Lunar")
    private var lunarProcess: Process?
    private var lunarPipeHandler: JSONLinesPipeHandler?
    private var lunarStreamTask: Task<Void, Never>?
    private var lunarListener: BoringNotchXPCHelperLunarListener?
    private let codexQueue = DispatchQueue(label: "BoringNotchXPCHelper.codex")
    private let oneDriveQueue = DispatchQueue(label: "BoringNotchXPCHelper.onedrive")
    private let thermalService = ThermalSMCService()
    private let fanInstallerService = FanControlInstallerService()

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    override init() {
        super.init()
    }

    deinit {
        var processToTerminate: Process?
        var taskToCancel: Task<Void, Never>?
        var pipeHandlerToClose: JSONLinesPipeHandler?

        lunarStateQueue.sync {
            processToTerminate = self.lunarProcess
            self.lunarProcess = nil

            taskToCancel = self.lunarStreamTask
            self.lunarStreamTask = nil

            pipeHandlerToClose = self.lunarPipeHandler
            self.lunarPipeHandler = nil

            self.lunarListener = nil
        }

        taskToCancel?.cancel()
        if let p = processToTerminate, p.isRunning { p.terminate() }
        if let ph = pipeHandlerToClose {
            Task { await ph.close() }
        }
    }
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }

    // MARK: - OneDrive

    @objc func fetchOneDriveStatus(with reply: @escaping (NSData?, NSString?) -> Void) {
        oneDriveQueue.async {
            let installed = self.oneDriveApplicationURL() != nil
            let runningApplication = self.runningOneDriveApplication()
            let isRunning = runningApplication != nil
            let isAuthorized = AXIsProcessTrusted()

            var accountName: String?
            var statusText: String?

            if isAuthorized,
               let runningApplication,
               let statusItem = self.oneDriveStatusItem(for: runningApplication) {
                let title = self.axString(statusItem, attribute: kAXTitleAttribute)
                let lines = (title ?? "")
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if let first = lines.first {
                    accountName = self.oneDriveAccountName(from: first)
                }
                if lines.count > 1 {
                    statusText = lines.dropFirst().joined(separator: " ")
                }
            }

            let payload: [String: Any] = [
                "installed": installed,
                "running": isRunning,
                "accessibilityAuthorized": isAuthorized,
                "accountName": accountName ?? NSNull(),
                "statusText": statusText ?? NSNull()
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                reply(data as NSData, nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    @objc func performOneDriveAction(
        _ action: NSString,
        with reply: @escaping (Bool, NSString?) -> Void
    ) {
        oneDriveQueue.async {
            guard let runningApplication = self.runningOneDriveApplication() else {
                if let applicationURL = self.oneDriveApplicationURL() {
                    let configuration = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.openApplication(
                        at: applicationURL,
                        configuration: configuration
                    ) { _, error in
                        if let error {
                            reply(false, error.localizedDescription as NSString)
                        } else {
                            reply(
                                false,
                                "OneDrive was started. Try the action again when it finishes launching."
                                    as NSString
                            )
                        }
                    }
                } else {
                    reply(false, "OneDrive is not installed." as NSString)
                }
                return
            }

            guard AXIsProcessTrusted() else {
                let options = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                reply(
                    false,
                    "Accessibility access is required. Grant it, then try again." as NSString
                )
                return
            }

            guard let statusItem = self.oneDriveStatusItem(for: runningApplication) else {
                reply(false, "The OneDrive status control could not be found." as NSString)
                return
            }

            let requestedAction = (action as String).lowercased()
            guard ["activity", "folder", "preferences"].contains(requestedAction) else {
                reply(false, "Unsupported OneDrive action." as NSString)
                return
            }

            guard let window = self.ensureOneDrivePopoverOpen(
                for: runningApplication,
                statusItem: statusItem
            ) else {
                reply(false, "The OneDrive activity center did not open." as NSString)
                return
            }

            if requestedAction == "activity" {
                reply(true, nil)
                return
            }

            let buttons = self.axDescendants(of: window).filter {
                self.axString($0, attribute: kAXRoleAttribute) == (kAXButtonRole as String)
            }

            if requestedAction == "folder" {
                let openFolderButton = buttons.first {
                    self.axString($0, attribute: kAXHelpAttribute)?
                        .localizedCaseInsensitiveContains("Open Folder") == true
                } ?? buttons.dropFirst().first

                guard let openFolderButton,
                      AXUIElementPerformAction(
                        openFolderButton,
                        kAXPressAction as CFString
                      ) == .success
                else {
                    reply(false, "The OneDrive folder button could not be used." as NSString)
                    return
                }

                reply(true, nil)
                return
            }

            let moreButton = buttons.first {
                self.axString($0, attribute: kAXHelpAttribute)?
                    .localizedCaseInsensitiveContains("More") == true
            } ?? buttons.last

            guard let moreButton,
                  AXUIElementPerformAction(
                    moreButton,
                    kAXPressAction as CFString
                  ) == .success
            else {
                reply(false, "The OneDrive settings menu could not be opened." as NSString)
                return
            }

            Thread.sleep(forTimeInterval: 0.25)
            self.postKeyPress(keyCode: 36) // Return selects Preferences, the first menu item.
            reply(true, nil)
        }
    }

    private let oneDriveBundleIdentifiers = [
        "com.microsoft.OneDrive-mac",
        "com.microsoft.OneDrive"
    ]

    private func oneDriveApplicationURL() -> URL? {
        oneDriveBundleIdentifiers.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    }

    private func runningOneDriveApplication() -> NSRunningApplication? {
        oneDriveBundleIdentifiers.lazy.compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }.first
    }

    private func oneDriveStatusItem(
        for application: NSRunningApplication
    ) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let menuBarAttributes = [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute]

        for attribute in menuBarAttributes {
            guard let menuBar: AXUIElement = axValue(
                applicationElement,
                attribute: attribute
            ) else { continue }

            let children: [AXUIElement] = axValue(
                menuBar,
                attribute: kAXChildrenAttribute
            ) ?? []

            if let item = children.first(where: { element in
                let title = axString(element, attribute: kAXTitleAttribute) ?? ""
                let description = axString(element, attribute: kAXDescriptionAttribute) ?? ""
                return title.localizedCaseInsensitiveContains("OneDrive")
                    || description.localizedCaseInsensitiveContains("status menu")
            }) {
                return item
            }
        }

        return nil
    }

    private func oneDriveWindows(
        for application: NSRunningApplication
    ) -> [AXUIElement] {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        return axValue(applicationElement, attribute: kAXWindowsAttribute) ?? []
    }

    private func ensureOneDrivePopoverOpen(
        for application: NSRunningApplication,
        statusItem: AXUIElement
    ) -> AXUIElement? {
        if let activityWindow = oneDriveActivityWindow(for: application) {
            return activityWindow
        }

        guard AXUIElementPerformAction(
            statusItem,
            kAXPressAction as CFString
        ) == .success else {
            return nil
        }
        Thread.sleep(forTimeInterval: 0.45)
        return oneDriveActivityWindow(for: application)
    }

    private func oneDriveActivityWindow(
        for application: NSRunningApplication
    ) -> AXUIElement? {
        oneDriveWindows(for: application).first { window in
            axDescendants(of: window).contains { element in
                guard axString(element, attribute: kAXRoleAttribute)
                    == (kAXButtonRole as String),
                      let help = axString(element, attribute: kAXHelpAttribute)
                else { return false }

                return help.localizedCaseInsensitiveContains("Open Folder")
                    || help.localizedCaseInsensitiveContains("More")
            }
        }
    }

    private func oneDriveAccountName(from title: String) -> String {
        let separators = ["OneDrive — ", "OneDrive – ", "OneDrive - "]
        for separator in separators where title.hasPrefix(separator) {
            return String(title.dropFirst(separator.count))
        }
        return title == "OneDrive" ? "OneDrive" : title
    }

    private func axDescendants(
        of root: AXUIElement,
        maxDepth: Int = 8,
        maxElements: Int = 200
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < maxDepth, result.count < maxElements else { return }
            let children: [AXUIElement] = axValue(
                element,
                attribute: kAXChildrenAttribute
            ) ?? []
            for child in children where result.count < maxElements {
                result.append(child)
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return result
    }

    private func axString(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        axValue(element, attribute: attribute)
    }

    private func axValue<T>(
        _ element: AXUIElement,
        attribute: String
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value
        else { return nil }
        return value as? T
    }

    private func postKeyPress(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        )
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    private func brightnessDisplayID() -> CGDirectDisplayID {
        let mainDisplayID = CGMainDisplayID()
        var tmp: Float = 0

        if displayServicesGetBrightness(displayID: mainDisplayID, out: &tmp) || ioServiceFor(displayID: mainDisplayID) != nil {
            return mainDisplayID
        }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        let allocated = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: allocated)
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids {
            if CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }

        return mainDisplayID
    }

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        let displayID = brightnessDisplayID()
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: displayID, out: &b) || ioServiceFor(displayID: displayID) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        var b: Float = 0
        if displayServicesGetBrightness(displayID: displayID, out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightness(displayID: displayID, value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }
    
    @objc func adjustScreenBrightness(by value: Float, with reply: @escaping (Bool) -> Void) {
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightnessSmooth(displayID: displayID, value: value) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var ioCurrent: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &ioCurrent) == kIOReturnSuccess {
                let target = max(0, min(1, ioCurrent + value))
                let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, target) == kIOReturnSuccess
                IOObjectRelease(io)
                reply(ok)
                return
            }
            IOObjectRelease(io)
        }
        reply(false)
    }

    // MARK: - Codex Usage

    @objc func fetchCodexRateLimits(with reply: @escaping (NSData?, NSString?) -> Void) {
        codexQueue.async {
            guard let executableURL = self.codexExecutableURL() else {
                reply(nil, "Codex is not installed." as NSString)
                return
            }

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["app-server"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            let stateQueue = DispatchQueue(label: "BoringNotchXPCHelper.codex.request")
            var buffer = Data()
            var finished = false

            func finish(_ data: Data?, _ error: String?) {
                stateQueue.async {
                    guard !finished else { return }
                    finished = true
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    try? inputPipe.fileHandleForWriting.close()
                    if process.isRunning {
                        process.terminate()
                    }
                    reply(data as NSData?, error as NSString?)
                }
            }

            func send(_ object: [String: Any]) throws {
                let data = try JSONSerialization.data(withJSONObject: object)
                inputPipe.fileHandleForWriting.write(data)
                inputPipe.fileHandleForWriting.write(Data([0x0A]))
            }

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    finish(nil, "Codex closed the local connection.")
                    return
                }

                stateQueue.async {
                    guard !finished else { return }
                    buffer.append(chunk)

                    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newlineIndex])
                        buffer.removeSubrange(...newlineIndex)
                        guard
                            !line.isEmpty,
                            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                            let id = object["id"] as? NSNumber
                        else { continue }

                        if id.intValue == 0 {
                            do {
                                try send(["method": "initialized", "params": [:]])
                                try send(["method": "account/rateLimits/read", "id": 1])
                            } catch {
                                finish(nil, error.localizedDescription)
                            }
                        } else if id.intValue == 1 {
                            finish(line, nil)
                        }
                    }
                }
            }

            do {
                try process.run()
                try send([
                    "method": "initialize",
                    "id": 0,
                    "params": [
                        "clientInfo": [
                            "name": "notch_master",
                            "title": "Notch Master",
                            "version": "0.2.0"
                        ]
                    ]
                ])
            } catch {
                finish(nil, error.localizedDescription)
                return
            }

            stateQueue.asyncAfter(deadline: .now() + 10) {
                guard !finished else { return }
                finish(nil, "Timed out while reading Codex usage.")
            }
        }
    }

    private func codexExecutableURL() -> URL? {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    // MARK: - Thermal Monitoring and Guarded Fan Control

    @objc func fetchThermalSnapshot(
        with reply: @escaping (NSData?, NSString?) -> Void
    ) {
        thermalService.fetchSnapshot { data, error in
            reply(data as NSData?, error as NSString?)
        }
    }

    @objc func setFanControlMode(
        _ mode: NSString,
        rpm: NSNumber?,
        with reply: @escaping (Bool, NSString?) -> Void
    ) {
        thermalService.setFanControl(
            mode: mode as String,
            rpm: rpm?.intValue
        ) { success, message in
            reply(success, message as NSString?)
        }
    }

    @objc func fanControllerStatus(
        with reply: @escaping (Bool, NSString) -> Void
    ) {
        let status = fanInstallerService.status()
        reply(status.installed, status.detail as NSString)
    }

    @objc func installFanController(
        with reply: @escaping (Bool, NSString?) -> Void
    ) {
        fanInstallerService.install { success, message in
            reply(success, message as NSString?)
        }
    }

    @objc func uninstallFanController(
        with reply: @escaping (Bool, NSString?) -> Void
    ) {
        fanInstallerService.uninstall { success, message in
            reply(success, message as NSString?)
        }
    }

    // MARK: - Lunar Events

    @objc func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let id = brightnessDisplayID()
        reply(NSNumber(value: id))
    }

    @objc func isLunarAvailable(with reply: @escaping (Bool) -> Void) {
        reply(FileManager.default.isExecutableFile(atPath: lunarExecutableURL.path))
    }

    @objc func startLunarEventStream(with reply: @escaping (Bool) -> Void) {
        lunarStateQueue.async { [weak self] in
            guard let self else {
                reply(false)
                return
            }

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                reply(true)
                return
            }

            guard FileManager.default.isExecutableFile(atPath: self.lunarExecutableURL.path) else {
                reply(false)
                return
            }

            guard let connection = self.connection else {
                reply(false)
                return
            }

            let listenerProxy = connection.remoteObjectProxyWithErrorHandler { _ in
                self.stopLunarEventStream()
            } as? BoringNotchXPCHelperLunarListener

            guard let listenerProxy else {
                reply(false)
                return
            }

            let process = Process()
            process.executableURL = self.lunarExecutableURL
            process.arguments = ["@", "listen", "--only-user-adjustments", "-j"]

            let pipeHandler = JSONLinesPipeHandler(decoder: JSONDecoder())
            process.standardOutput = pipeHandler.getPipe()
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { [weak self] _ in
                self?.stopLunarEventStream(reason: "Lunar stream ended")
            }

            do {
                try process.run()
            } catch {
                reply(false)
                return
            }

            self.lunarProcess = process
            self.lunarPipeHandler = pipeHandler
            self.lunarListener = listenerProxy

            let currentPipeHandler = pipeHandler
            self.lunarStreamTask = Task { [weak self] in
                await self?.readLunarEvents(pipeHandler: currentPipeHandler)
            }

            reply(true)
        }
    }

    @objc func stopLunarEventStream() {
        stopLunarEventStream(reason: nil)
    }

    private func stopLunarEventStream(reason: String?) {
        lunarStateQueue.async { [weak self] in
            guard let self else { return }

            self.lunarStreamTask?.cancel()
            self.lunarStreamTask = nil

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                lunarProcess.terminate()
            }

            self.lunarProcess = nil

            if let pipeHandler = self.lunarPipeHandler {
                Task { await pipeHandler.close() }
            }

            self.lunarPipeHandler = nil

            if let reason {
                self.lunarListener?.lunarStreamDidStop(reason)
            }

            self.lunarListener = nil
        }
    }

    private func readLunarEvents(pipeHandler: JSONLinesPipeHandler) async {
        await pipeHandler.readJSONLines(as: LunarBrightnessEvent.self) { [weak self] event in
            self?.emitLunarEvent(event)
        }
    }

    private func emitLunarEvent(_ event: LunarBrightnessEvent) {
        let payload = BNLunarBrightnessEvent(
            brightness: event.brightness,
            display: event.display
        )
        lunarStateQueue.async { [weak self] in
            self?.lunarListener?.lunarEventDidUpdate(payload)
        }
    }

    // MARK: - Lunar OSD preference (hideOSD)

    private static let lunarBundleID = "fyi.lunar.Lunar"
    private static let lunarHideOSDKey = "hideOSD"

    @objc func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void) {
        let appID = Self.lunarBundleID as CFString
        let key = Self.lunarHideOSDKey as CFString
        let value = hide as CFBoolean
        NSLog("Hide OSD in Lunar: \(hide)")
        CFPreferencesSetValue(key, value, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let ok = CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reply(ok)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }
    
    private func displayServicesSetBrightnessSmooth(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightnessSmooth") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

// MARK: - Lunar Parsing

private struct LunarBrightnessEvent: Decodable {
    let brightness: Double
    let display: Int

    init(from decoder: NSCoder) {
        display = decoder.decodeInteger(forKey: "display")
        brightness = decoder.decodeDouble(forKey: "brightness")
    }
}

private actor JSONLinesPipeHandler {
    nonisolated let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = ""
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        let pipe = Pipe()
        self.pipe = pipe
        self.fileHandle = pipe.fileHandleForReading
        self.decoder = decoder
    }

    nonisolated func getPipe() -> Pipe {
        return pipe
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) -> Void) async {
        do {
            try await processLines(as: type) { decodedObject in
                onLine(decodedObject)
            }
        } catch {
            // Ignore stream errors to keep the helper lightweight.
        }
    }

    private func processLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) -> Void) async throws {
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }

            if let chunk = String(data: data, encoding: .utf8) {
                buffer.append(chunk)

                while let range = buffer.range(of: "\n") {
                    let line = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])

                    if !line.isEmpty {
                        processJSONLine(line, as: type, onLine: onLine)
                    }
                }
            }
        }
    }

    private func processJSONLine<T: Decodable>(_ line: String, as type: T.Type, onLine: @escaping (T) -> Void) {
        guard let data = line.data(using: .utf8) else { return }
        if let decodedObject = try? decoder.decode(T.self, from: data) {
            onLine(decodedObject)
        }
    }

    private func readData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }

    func close() async {
        do {
            fileHandle.readabilityHandler = nil

            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            // Ignore close errors.
        }
    }
}
