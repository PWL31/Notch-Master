//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)

        // Configure the interface for callbacks from the helper to the app.
        let listenerInterface = NSXPCInterface(with: (any BoringNotchXPCHelperLunarListener).self)
        listenerInterface.setClasses(
            NSSet(array: [BNLunarBrightnessEvent.self]) as! Set<AnyHashable>,
            for: #selector(BoringNotchXPCHelperLunarListener.lunarEventDidUpdate(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.remoteObjectInterface = listenerInterface
        
        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = BoringNotchXPCHelper(connection: newConnection)
        newConnection.exportedObject = exportedObject
        
        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

if CommandLine.arguments.contains("--fan-controller-status") {
    let status = FanControlDaemonClient.status()
    print(status.detail)
    exit(status.available ? 0 : 1)
} else if CommandLine.arguments.contains("--install-fan-controller") {
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false
    FanControlInstallerService().install { success, detail in
        succeeded = success
        print(detail ?? (success ? "Installed" : "Installation failed"))
        semaphore.signal()
    }
    semaphore.wait()
    exit(succeeded ? 0 : 1)
} else if CommandLine.arguments.contains("--uninstall-fan-controller") {
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false
    FanControlInstallerService().uninstall { success, detail in
        succeeded = success
        print(detail ?? (success ? "Removed" : "Removal failed"))
        semaphore.signal()
    }
    semaphore.wait()
    exit(succeeded ? 0 : 1)
} else if CommandLine.arguments.contains("--fan-daemon") {
    guard let uidIndex = CommandLine.arguments.firstIndex(of: "--allowed-uid"),
          CommandLine.arguments.indices.contains(uidIndex + 1),
          let uidValue = UInt32(CommandLine.arguments[uidIndex + 1]) else {
        fputs("Missing --allowed-uid.\n", stderr)
        exit(64)
    }
    do {
        try FanControlDaemon(allowedUID: uid_t(uidValue)).run()
    } catch {
        fputs("Fan controller failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    // Create the delegate for the service.
    let delegate = ServiceDelegate()

    // Set up the XPC listener for the embedded user-level helper.
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    listener.resume()
}
