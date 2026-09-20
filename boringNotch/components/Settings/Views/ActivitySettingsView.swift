//
//  ActivitySettingsView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct ActivitySettingsView: View {
    @StateObject private var thermalModel = ThermalMonitorViewModel()
    @Default(.activityTemperatureKey) private var selectedTemperatureKey
    @Default(.activityLeftMetric) private var leftMetric
    @Default(.activityMiddleMetric) private var middleMetric
    @Default(.fanPresetCount) private var fanPresetCount
    @Default(.fanPreset1RPM) private var fanPreset1RPM
    @Default(.fanPreset2RPM) private var fanPreset2RPM
    @Default(.fanPreset3RPM) private var fanPreset3RPM
    @State private var controllerInstalled = false
    @State private var controllerDetail = "Checking…"
    @State private var controllerWorking = false
    @State private var controllerError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Monitoring") {
                    Text("AppleSMC · local only")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Fan control backend") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(controllerInstalled ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(controllerInstalled ? "Ready" : controllerDetail)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button(controllerInstalled ? "Repair Controller…" : "Install Controller…") {
                        installController()
                    }
                    .disabled(controllerWorking)

                    if controllerInstalled {
                        Button("Remove…", role: .destructive) {
                            uninstallController()
                        }
                        .disabled(controllerWorking)
                    }

                    if controllerWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let controllerError {
                    Text(controllerError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Activity Monitor")
            } footer: {
                Text(
                    "Fan control requires a one-time administrator approval. The local helper accepts commands only from this macOS user and never connects to the network."
                )
            }

            Section {
                Picker("Left card", selection: $leftMetric) {
                    metricChoices
                }
                Picker("Middle card", selection: $middleMetric) {
                    metricChoices
                }
            } header: {
                Text("Dashboard metrics")
            } footer: {
                Text(
                    "CPU and memory use Mach kernel counters. Network I/O uses local interface byte counters. Nothing is uploaded."
                )
            }

            Section {
                if availableTemperatures.isEmpty {
                    LabeledContent("Displayed sensor") {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Reading AppleSMC…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Picker("Displayed sensor", selection: $selectedTemperatureKey) {
                        ForEach(temperatureGroups, id: \.self) { group in
                            Section(group) {
                                ForEach(
                                    availableTemperatures.filter { $0.group == group }
                                ) { sensor in
                                    Text(sensor.name)
                                        .tag(sensor.key)
                                }
                            }
                        }
                    }

                    if let selectedTemperature {
                        LabeledContent("Current reading") {
                            Text(formatTemperature(selectedTemperature.celsius))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Temperature")
            } footer: {
                Text(
                    "The selected sensor is shown to the right of fan speed in the Activity page. CPU Die Hotspot is the recommended default."
                )
            }

            Section {
                Picker("Visible custom presets", selection: $fanPresetCount) {
                    ForEach(1...3, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)

                presetRow("P1", value: $fanPreset1RPM)
                if fanPresetCount >= 2 {
                    presetRow("P2", value: $fanPreset2RPM)
                }
                if fanPresetCount >= 3 {
                    presetRow("P3", value: $fanPreset3RPM)
                }
            } header: {
                Text("Custom fan speeds")
            } footer: {
                Text(
                    "Each preset is checked against the Mac’s detected minimum and maximum RPM before it can run. Invalid presets stay disabled."
                )
            }

            Section {
                Text(
                    "Automatic always returns control to Apple. Full requests the controller’s maximum profile. If the controller or sensor data is unavailable, Notch Master refuses the command."
                )
                .foregroundStyle(.secondary)
            } header: {
                Text("Safety")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Activity")
        .task {
            await refreshControllerStatus()
            await thermalModel.refresh()
            normalizeTemperatureSelection()
        }
    }

    private var availableTemperatures: [ThermalTemperature] {
        thermalModel.snapshot?.temperatures ?? []
    }

    private var temperatureGroups: [String] {
        Array(Set(availableTemperatures.map(\.group))).sorted()
    }

    private var selectedTemperature: ThermalTemperature? {
        availableTemperatures.first { $0.key == selectedTemperatureKey }
    }

    private var metricChoices: some View {
        ForEach(ActivityMetric.allCases) { metric in
            Label(metric.title, systemImage: metric.systemImage)
                .tag(metric)
        }
    }

    private func presetRow(
        _ name: String,
        value: Binding<Int>
    ) -> some View {
        Stepper(value: value, in: 1_000...8_000, step: 100) {
            HStack {
                Text(name)
                Spacer()
                Text("\(value.wrappedValue) RPM")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func installController() {
        controllerWorking = true
        controllerError = nil
        Task {
            do {
                controllerDetail = try await XPCHelperClient.shared
                    .installFanController()
                controllerInstalled = true
            } catch {
                controllerInstalled = false
                controllerError = error.localizedDescription
            }
            controllerWorking = false
        }
    }

    private func uninstallController() {
        controllerWorking = true
        controllerError = nil
        Task {
            do {
                controllerDetail = try await XPCHelperClient.shared
                    .uninstallFanController()
                controllerInstalled = false
            } catch {
                controllerError = error.localizedDescription
            }
            controllerWorking = false
        }
    }

    private func refreshControllerStatus() async {
        let status = await XPCHelperClient.shared.fanControllerStatus()
        controllerInstalled = status.0
        controllerDetail = status.1
    }

    private func normalizeTemperatureSelection() {
        guard !availableTemperatures.isEmpty,
              selectedTemperature == nil else {
            return
        }
        selectedTemperatureKey = availableTemperatures.first {
            $0.key == "TCMz"
        }?.key ?? availableTemperatures.max {
            $0.celsius < $1.celsius
        }?.key ?? selectedTemperatureKey
    }

    private func formatTemperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°C"
    }
}
