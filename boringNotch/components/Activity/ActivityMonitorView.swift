//
//  ActivityMonitorView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct ActivityMonitorView: View {
    @StateObject private var thermalModel = ThermalMonitorViewModel()
    @StateObject private var performanceModel = SystemPerformanceMonitor()
    @Default(.activityTemperatureKey) private var selectedTemperatureKey
    @Default(.activityLeftMetric) private var leftMetric
    @Default(.activityMiddleMetric) private var middleMetric
    @Default(.fanPresetCount) private var fanPresetCount
    @Default(.fanPreset1RPM) private var fanPreset1RPM
    @Default(.fanPreset2RPM) private var fanPreset2RPM
    @Default(.fanPreset3RPM) private var fanPreset3RPM
    @State private var fanSliderRPM = 0.0
    @State private var isAdjustingFanSlider = false
    @State private var fanSliderHaptic = false
    @State private var lastFanSliderDetent: Int?

    private var selectedTemperature: ThermalTemperature? {
        guard let temperatures = thermalModel.snapshot?.temperatures else {
            return nil
        }
        return temperatures.first(where: { $0.key == selectedTemperatureKey })
            ?? temperatures.first(where: { $0.key == "TCMz" })
            ?? temperatures.max(by: { $0.celsius < $1.celsius })
    }

    private var presets: [Int] {
        Array([fanPreset1RPM, fanPreset2RPM, fanPreset3RPM]
            .prefix(min(max(fanPresetCount, 1), 3)))
    }

    private var fanSliderRange: ClosedRange<Double>? {
        guard let safeRange = thermalModel.safeCustomRange else { return nil }
        let lower = Int(ceil(Double(safeRange.lowerBound) / 100.0)) * 100
        let upper = Int(floor(Double(safeRange.upperBound) / 100.0)) * 100
        guard lower < upper else { return nil }
        return Double(lower)...Double(upper)
    }

    var body: some View {
        HStack(spacing: 8) {
            performanceCard(leftMetric)
                .frame(width: 158)

            performanceCard(middleMetric)
                .frame(width: 158)

            thermalControlCard
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, minHeight: 116, maxHeight: 120)
        .onAppear {
            thermalModel.start()
            performanceModel.start()
        }
        .onDisappear {
            thermalModel.stop()
            performanceModel.stop()
        }
        .onChange(of: thermalModel.snapshot) {
            synchronizeFanSlider()
        }
        .onChange(of: fanSliderRPM) {
            handleFanSliderDetentChange()
        }
        .sensoryFeedback(.alignment, trigger: fanSliderHaptic)
    }

    private func performanceCard(_ metric: ActivityMetric) -> some View {
        let presentation = metricPresentation(metric)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: metric.systemImage)
                Text(metric.title.uppercased())
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(presentation.primaryText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cyan)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 1)
                if let secondaryText = presentation.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            MetricSparkline(
                primary: presentation.primaryValues,
                secondary: presentation.secondaryValues,
                fixedMaximum: presentation.fixedMaximum
            )
            .frame(height: 49)

            HStack(spacing: 7) {
                metricLegend(
                    color: .cyan,
                    text: presentation.primaryLabel
                )
                if let secondaryLabel = presentation.secondaryLabel {
                    metricLegend(color: .red, text: secondaryLabel)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var thermalControlCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                fanSummary

                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .frame(height: 31)

                temperatureSummary

                Spacer(minLength: 0)

                if thermalModel.isApplyingControl {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: controllerStatusIcon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(controllerStatusColor)
                        .help(controllerStatusDetail)
                }
            }

            HStack(spacing: 5) {
                controlButton("Auto", icon: "a.circle.fill", mode: .automatic)
                controlButton("Full", icon: "bolt.fill", mode: .full)
            }

            HStack(spacing: 5) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, rpm in
                    presetButton(index: index, rpm: rpm)
                }
            }

            fanSpeedSlider
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    @ViewBuilder
    private var fanSpeedSlider: some View {
        if let range = fanSliderRange {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)

                Slider(
                    value: $fanSliderRPM,
                    in: range,
                    step: 100
                ) { isEditing in
                    handleFanSliderEditing(isEditing, range: range)
                }
                .controlSize(.mini)
                .tint(.effectiveAccent)

                Text("\(Int(fanSliderRPM.rounded()))")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 31, alignment: .trailing)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .disabled(
                thermalModel.snapshot?.controller.available != true
                    || thermalModel.isApplyingControl
            )
            .opacity(
                thermalModel.snapshot?.controller.available == true ? 1 : 0.45
            )
            .animation(
                .interactiveSpring(
                    response: 0.18,
                    dampingFraction: 0.62,
                    blendDuration: 0
                ),
                value: fanSliderRPM
            )
            .help(
                "Drag in 100 RPM detents. The selected speed is applied when you release."
            )
        } else {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 3)
                Text("—")
                    .frame(width: 31, alignment: .trailing)
            }
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(height: 14)
            .help("Fan limits are unavailable.")
        }
    }

    private var temperatureSummary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(
                selectedTemperature?.name ?? "Temperature",
                systemImage: "thermometer.medium"
            )
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text(selectedTemperature.map {
                formatTemperature($0.celsius)
            } ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    temperatureColor(selectedTemperature?.celsius)
                )
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Choose the displayed sensor in Settings → Activity.")
    }

    private var fanSummary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(
                thermalModel.snapshot?.fans.count == 1 ? "Fan speed" : "Fans",
                systemImage: "fan"
            )
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.secondary)

            if let fan = thermalModel.snapshot?.fans.first {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(fan.currentRPM)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("RPM")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("— RPM")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlButton(
        _ title: String,
        icon: String,
        mode: FanControlMode
    ) -> some View {
        Button {
            thermalModel.apply(mode)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(
                    thermalModel.selectedMode == mode
                        ? Color.effectiveAccent.opacity(0.30)
                        : Color.white.opacity(0.07)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(
            thermalModel.snapshot?.controller.available != true
                || thermalModel.isApplyingControl
        )
        .help(controllerStatusDetail)
    }

    private func presetButton(index: Int, rpm: Int) -> some View {
        let isInRange = thermalModel.safeCustomRange?.contains(rpm) == true
        let isSelected = thermalModel.selectedMode == .custom
            && thermalModel.selectedCustomRPM == rpm

        return Button {
            thermalModel.apply(.custom, rpm: rpm)
        } label: {
            HStack(spacing: 3) {
                Text("P\(index + 1)")
                    .fontWeight(.bold)
                Text("\(rpm)")
                    .monospacedDigit()
            }
            .font(.system(size: 8, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(
                isSelected
                    ? Color.effectiveAccent.opacity(0.30)
                    : Color.white.opacity(0.07)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(
            thermalModel.snapshot?.controller.available != true
                || !isInRange
                || thermalModel.isApplyingControl
        )
        .help(
            isInRange
                ? "Set all fans to \(rpm) RPM"
                : "Outside the detected safe fan range."
        )
    }

    private func handleFanSliderEditing(
        _ isEditing: Bool,
        range: ClosedRange<Double>
    ) {
        if isEditing {
            isAdjustingFanSlider = true
            lastFanSliderDetent = Int(fanSliderRPM.rounded())
            return
        }

        guard isAdjustingFanSlider else { return }
        isAdjustingFanSlider = false
        let rpm = snappedFanRPM(fanSliderRPM, in: range)
        fanSliderRPM = Double(rpm)
        lastFanSliderDetent = rpm
        thermalModel.apply(.custom, rpm: rpm)
    }

    private func handleFanSliderDetentChange() {
        guard isAdjustingFanSlider else { return }
        let detent = Int(fanSliderRPM.rounded())
        guard detent != lastFanSliderDetent else { return }
        lastFanSliderDetent = detent
        if Defaults[.enableHaptics] {
            fanSliderHaptic.toggle()
        }
    }

    private func synchronizeFanSlider() {
        guard !isAdjustingFanSlider, let range = fanSliderRange else { return }
        let firstFan = thermalModel.snapshot?.fans.first
        let customRPM = thermalModel.selectedMode == .custom
            ? thermalModel.selectedCustomRPM
            : nil
        let preferredRPM = customRPM ?? firstFan?.currentRPM
        guard let preferredRPM else { return }
        fanSliderRPM = Double(
            snappedFanRPM(Double(preferredRPM), in: range)
        )
        lastFanSliderDetent = Int(fanSliderRPM.rounded())
    }

    private func snappedFanRPM(
        _ value: Double,
        in range: ClosedRange<Double>
    ) -> Int {
        let detent = (value / 100.0).rounded() * 100.0
        return Int(min(max(detent, range.lowerBound), range.upperBound))
    }

    private func metricLegend(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func metricPresentation(
        _ metric: ActivityMetric
    ) -> MetricPresentation {
        let samples = performanceModel.samples
        let latest = samples.last
        switch metric {
        case .cpuLoad:
            let total = samples.map {
                min($0.cpuUserPercent + $0.cpuSystemPercent, 100)
            }
            return MetricPresentation(
                primaryText: formatPercent(total.last ?? 0),
                secondaryText: "sys \(formatPercent(latest?.cpuSystemPercent ?? 0))",
                primaryLabel: "Total",
                secondaryLabel: "System",
                primaryValues: total,
                secondaryValues: samples.map(\.cpuSystemPercent),
                fixedMaximum: 100
            )
        case .memoryPressure:
            return MetricPresentation(
                primaryText: formatPercent(latest?.memoryUsedPercent ?? 0),
                secondaryText: "cmp \(formatPercent(latest?.memoryCompressedPercent ?? 0))",
                primaryLabel: "Used",
                secondaryLabel: "Compressed",
                primaryValues: samples.map(\.memoryUsedPercent),
                secondaryValues: samples.map(\.memoryCompressedPercent),
                fixedMaximum: 100
            )
        case .networkIO:
            return MetricPresentation(
                primaryText: formatRate(
                    latest?.networkDownloadBytesPerSecond ?? 0
                ),
                secondaryText: "↑ \(formatRate(latest?.networkUploadBytesPerSecond ?? 0))",
                primaryLabel: "Download",
                secondaryLabel: "Upload",
                primaryValues: samples.map(\.networkDownloadBytesPerSecond),
                secondaryValues: samples.map(\.networkUploadBytesPerSecond),
                fixedMaximum: nil
            )
        case .loadAverage:
            return MetricPresentation(
                primaryText: String(format: "%.2f", latest?.loadOneMinute ?? 0),
                secondaryText: "5m \(String(format: "%.2f", latest?.loadFiveMinutes ?? 0))",
                primaryLabel: "1 minute",
                secondaryLabel: "5 minutes",
                primaryValues: samples.map(\.loadOneMinute),
                secondaryValues: samples.map(\.loadFiveMinutes),
                fixedMaximum: Double(ProcessInfo.processInfo.activeProcessorCount)
            )
        case .thermalPressure:
            return MetricPresentation(
                primaryText: latest?.thermalState ?? "Unknown",
                secondaryText: nil,
                primaryLabel: "System pressure",
                secondaryLabel: nil,
                primaryValues: samples.map(\.thermalPressurePercent),
                secondaryValues: [],
                fixedMaximum: 100
            )
        }
    }

    private var controllerStatusIcon: String {
        if thermalModel.errorMessage != nil {
            return "exclamationmark.triangle.fill"
        }
        return thermalModel.snapshot?.controller.available == true
            ? "checkmark.circle.fill"
            : "lock.fill"
    }

    private var controllerStatusColor: Color {
        if thermalModel.errorMessage != nil { return .red }
        return thermalModel.snapshot?.controller.available == true
            ? .green
            : .secondary
    }

    private var controllerStatusDetail: String {
        thermalModel.errorMessage
            ?? thermalModel.snapshot?.controller.detail
            ?? "Reading local AppleSMC sensors…"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(Color.white.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    private func formatTemperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°C"
    }

    private func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))) + "/s"
    }

    private func temperatureColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 90 { return .red }
        if value >= 75 { return .yellow }
        return .green
    }
}

private struct MetricPresentation {
    let primaryText: String
    let secondaryText: String?
    let primaryLabel: String
    let secondaryLabel: String?
    let primaryValues: [Double]
    let secondaryValues: [Double]
    let fixedMaximum: Double?
}

private struct MetricSparkline: View {
    let primary: [Double]
    let secondary: [Double]
    let fixedMaximum: Double?

    var body: some View {
        GeometryReader { geometry in
            let ceiling = max(
                fixedMaximum
                    ?? max(primary.max() ?? 0, secondary.max() ?? 0) * 1.12,
                1
            )
            ZStack {
                grid(in: geometry.size)
                    .stroke(
                        Color.white.opacity(0.08),
                        style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
                    )

                area(
                    values: primary,
                    size: geometry.size,
                    ceiling: ceiling
                )
                .fill(Color.cyan.opacity(0.14))

                area(
                    values: secondary,
                    size: geometry.size,
                    ceiling: ceiling
                )
                .fill(Color.red.opacity(0.12))

                line(
                    values: primary,
                    size: geometry.size,
                    ceiling: ceiling
                )
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))

                line(
                    values: secondary,
                    size: geometry.size,
                    ceiling: ceiling
                )
                .stroke(Color.red, style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func grid(in size: CGSize) -> Path {
        Path { path in
            for fraction in [0.33, 0.66] {
                let y = size.height * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
    }

    private func line(
        values: [Double],
        size: CGSize,
        ceiling: Double
    ) -> Path {
        Path { path in
            for (index, point) in points(
                values: values,
                size: size,
                ceiling: ceiling
            ).enumerated() {
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }

    private func area(
        values: [Double],
        size: CGSize,
        ceiling: Double
    ) -> Path {
        let plottedPoints = points(
            values: values,
            size: size,
            ceiling: ceiling
        )
        return Path { path in
            guard let first = plottedPoints.first,
                  let last = plottedPoints.last else {
                return
            }
            path.move(to: CGPoint(x: first.x, y: size.height))
            path.addLine(to: first)
            for point in plottedPoints.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }

    private func points(
        values: [Double],
        size: CGSize,
        ceiling: Double
    ) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let divisor = max(values.count - 1, 1)
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(divisor)
            let normalized = min(max(value / ceiling, 0), 1)
            return CGPoint(
                x: x,
                y: size.height * CGFloat(1 - normalized)
            )
        }
    }
}
