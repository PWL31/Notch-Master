//
//  ThermalModels.swift
//  boringNotch
//

import Foundation

struct ThermalTemperature: Codable, Identifiable, Equatable {
    let key: String
    let name: String
    let group: String
    let celsius: Double

    var id: String { key }
}

struct ThermalFan: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let currentRPM: Int
    let minimumRPM: Int?
    let maximumRPM: Int?
    let targetRPM: Int?
    let manualMode: Bool?
}

struct ThermalControllerStatus: Codable, Equatable {
    let available: Bool
    let backend: String?
    let detail: String
}

struct ThermalSnapshot: Codable, Equatable {
    let timestamp: Date
    let model: String
    let thermalState: String
    let temperatures: [ThermalTemperature]
    let fans: [ThermalFan]
    let controller: ThermalControllerStatus
}

enum FanControlMode: String, CaseIterable, Identifiable {
    case automatic
    case full
    case custom

    var id: Self { self }
}

@MainActor
final class ThermalMonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: ThermalSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplyingControl = false
    @Published var errorMessage: String?
    @Published var selectedMode: FanControlMode = .automatic
    @Published var selectedCustomRPM: Int?

    private var refreshTask: Task<Void, Never>?

    var safeCustomRange: ClosedRange<Int>? {
        guard let fans = snapshot?.fans, !fans.isEmpty else { return nil }
        guard
            let minimum = fans.compactMap(\.minimumRPM).max(),
            let maximum = fans.compactMap(\.maximumRPM).min(),
            minimum <= maximum
        else {
            return nil
        }
        return minimum...maximum
    }

    func start() {
        stop()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
                await refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await XPCHelperClient.shared.fetchThermalSnapshot()
            let updated = try JSONDecoder().decode(ThermalSnapshot.self, from: data)
            snapshot = updated
            synchronizeSelectedMode(with: updated.fans)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ mode: FanControlMode, rpm: Int? = nil) {
        guard !isApplyingControl else { return }
        isApplyingControl = true
        errorMessage = nil

        Task {
            do {
                try await XPCHelperClient.shared.setFanControl(
                    mode: mode.rawValue,
                    rpm: rpm
                )
                selectedMode = mode
                selectedCustomRPM = mode == .custom ? rpm : nil
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplyingControl = false
        }
    }

    private func synchronizeSelectedMode(with fans: [ThermalFan]) {
        guard !fans.isEmpty else { return }
        let manualFans = fans.filter { $0.manualMode == true }
        guard !manualFans.isEmpty else {
            selectedMode = .automatic
            selectedCustomRPM = nil
            return
        }

        let allAtMaximum = manualFans.allSatisfy { fan in
            guard let target = fan.targetRPM, let maximum = fan.maximumRPM else {
                return false
            }
            return abs(target - maximum) <= 10
        }
        if allAtMaximum {
            selectedMode = .full
            selectedCustomRPM = nil
            return
        }

        let targets = Set(manualFans.compactMap(\.targetRPM))
        selectedMode = .custom
        selectedCustomRPM = targets.count == 1 ? targets.first : nil
    }

    deinit {
        refreshTask?.cancel()
    }
}
