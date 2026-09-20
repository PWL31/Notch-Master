//
//  SystemPerformanceMonitor.swift
//  boringNotch
//
//  Local, low-overhead system sampling for the Activity dashboard.
//

import Darwin
import Foundation

struct SystemPerformanceSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cpuUserPercent: Double
    let cpuSystemPercent: Double
    let memoryUsedPercent: Double
    let memoryCompressedPercent: Double
    let networkDownloadBytesPerSecond: Double
    let networkUploadBytesPerSecond: Double
    let loadOneMinute: Double
    let loadFiveMinutes: Double
    let thermalPressurePercent: Double
    let thermalState: String
}

@MainActor
final class SystemPerformanceMonitor: ObservableObject {
    @Published private(set) var samples: [SystemPerformanceSample] = []

    private var samplingTask: Task<Void, Never>?
    private var previousCPUTicks: [UInt32]?
    private var previousNetworkBytes: (received: UInt64, sent: UInt64)?
    private var previousSampleTime: Date?
    private let historyLimit = 42

    var latest: SystemPerformanceSample? { samples.last }

    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                sample()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    private func sample() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(previousSampleTime ?? now), 0.001)
        let cpu = sampleCPU()
        let memory = sampleMemory()
        let network = sampleNetwork(elapsed: elapsed)
        let load = sampleLoadAverage()
        let thermal = Self.thermalPressure

        let sample = SystemPerformanceSample(
            timestamp: now,
            cpuUserPercent: cpu.user,
            cpuSystemPercent: cpu.system,
            memoryUsedPercent: memory.used,
            memoryCompressedPercent: memory.compressed,
            networkDownloadBytesPerSecond: network.received,
            networkUploadBytesPerSecond: network.sent,
            loadOneMinute: load.one,
            loadFiveMinutes: load.five,
            thermalPressurePercent: thermal.percent,
            thermalState: thermal.name
        )
        samples.append(sample)
        if samples.count > historyLimit {
            samples.removeFirst(samples.count - historyLimit)
        }
        previousSampleTime = now
    }

    private func sampleCPU() -> (user: Double, system: Double) {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        ) == KERN_SUCCESS, let processorInfo else {
            return (0, 0)
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: processorInfo),
                vm_size_t(processorInfoCount)
                    * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let ticks = (0..<Int(processorInfoCount)).map {
            UInt32(bitPattern: processorInfo[$0])
        }
        guard let previousCPUTicks, previousCPUTicks.count == ticks.count else {
            self.previousCPUTicks = ticks
            return (0, 0)
        }

        var userTicks = 0.0
        var systemTicks = 0.0
        var totalTicks = 0.0
        for cpu in 0..<Int(processorCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = Double(ticks[base + Int(CPU_STATE_USER)]
                &- previousCPUTicks[base + Int(CPU_STATE_USER)])
            let system = Double(ticks[base + Int(CPU_STATE_SYSTEM)]
                &- previousCPUTicks[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(ticks[base + Int(CPU_STATE_IDLE)]
                &- previousCPUTicks[base + Int(CPU_STATE_IDLE)])
            let nice = Double(ticks[base + Int(CPU_STATE_NICE)]
                &- previousCPUTicks[base + Int(CPU_STATE_NICE)])
            userTicks += user + nice
            systemTicks += system
            totalTicks += user + system + idle + nice
        }
        self.previousCPUTicks = ticks
        guard totalTicks > 0 else { return (0, 0) }
        return (
            min(max(userTicks / totalTicks * 100, 0), 100),
            min(max(systemTicks / totalTicks * 100, 0), 100)
        )
    }

    private func sampleMemory() -> (used: Double, compressed: Double) {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    $0,
                    &count
                )
            }
        }
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS, totalBytes > 0 else { return (0, 0) }

        let pageBytes = Double(vm_kernel_page_size)
        let compressedBytes = Double(statistics.compressor_page_count) * pageBytes
        let usedBytes = (
            Double(statistics.active_count)
                + Double(statistics.wire_count)
                + Double(statistics.compressor_page_count)
        ) * pageBytes
        return (
            min(max(usedBytes / totalBytes * 100, 0), 100),
            min(max(compressedBytes / totalBytes * 100, 0), 100)
        )
    }

    private func sampleNetwork(
        elapsed: TimeInterval
    ) -> (received: Double, sent: Double) {
        let current = cumulativeNetworkBytes()
        guard let previousNetworkBytes else {
            self.previousNetworkBytes = current
            return (0, 0)
        }
        self.previousNetworkBytes = current
        return (
            Double(current.received &- previousNetworkBytes.received) / elapsed,
            Double(current.sent &- previousNetworkBytes.sent) / elapsed
        )
    }

    private func cumulativeNetworkBytes() -> (received: UInt64, sent: UInt64) {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return (0, 0)
        }
        defer { freeifaddrs(firstAddress) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var address: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = address {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            let isLinkLayer = interface.ifa_addr?.pointee.sa_family
                == UInt8(AF_LINK)
            let isPhysicalInterface = name.hasPrefix("en")
            let isUp = (interface.ifa_flags & UInt32(IFF_UP)) != 0

            if isLinkLayer, isPhysicalInterface, isUp,
               let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                received += UInt64(data.pointee.ifi_ibytes)
                sent += UInt64(data.pointee.ifi_obytes)
            }
            address = interface.ifa_next
        }
        return (received, sent)
    }

    private func sampleLoadAverage() -> (one: Double, five: Double) {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) >= 2 else { return (0, 0) }
        return (max(values[0], 0), max(values[1], 0))
    }

    private static var thermalPressure: (percent: Double, name: String) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: (8, "Nominal")
        case .fair: (40, "Fair")
        case .serious: (72, "Serious")
        case .critical: (100, "Critical")
        @unknown default: (0, "Unknown")
        }
    }

    deinit {
        samplingTask?.cancel()
    }
}
