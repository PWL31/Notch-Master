import Defaults
import SwiftUI

private struct CodexRateLimitResponse: Decodable {
    struct ResponseResult: Decodable {
        let rateLimits: RateLimitSnapshot?
        let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    }

    struct ResponseError: Decodable {
        let message: String
    }

    let result: ResponseResult?
    let error: ResponseError?
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitWindow: Decodable, Equatable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?
}

@MainActor
final class CodexUsageViewModel: ObservableObject {
    static let shared = CodexUsageViewModel()

    @Published private(set) var weeklyWindow: RateLimitWindow?
    @Published private(set) var shortWindow: RateLimitWindow?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private var refreshTimer: Timer?
    private var hasStarted = false

    private init() {}

    var weeklyRemainingPercent: Int? {
        remainingPercent(for: weeklyWindow)
    }

    func weeklyPercentageText(for mode: CodexUsageDisplayMode) -> String {
        percentageText(for: weeklyWindow, mode: mode)
    }

    func percentageText(
        for window: RateLimitWindow?,
        mode: CodexUsageDisplayMode
    ) -> String {
        guard let window else { return "—" }
        let percentage = mode == .used
            ? max(0, min(100, window.usedPercent))
            : remainingPercent(for: window) ?? 0
        return "\(percentage)%"
    }

    func resetCountdownText(at date: Date = Date()) -> String? {
        resetCountdownText(for: weeklyWindow, at: date)
    }

    func resetCountdownText(
        for window: RateLimitWindow?,
        at date: Date = Date()
    ) -> String? {
        guard let timestamp = window?.resetsAt else { return nil }
        let remainingSeconds = TimeInterval(timestamp) - date.timeIntervalSince1970
        guard remainingSeconds > 0 else { return "now" }

        if remainingSeconds < 60 * 60 {
            return "\(max(1, Int(ceil(remainingSeconds / 60))))m"
        }
        if remainingSeconds < 24 * 60 * 60 {
            return "\(Int(ceil(remainingSeconds / (60 * 60))))h"
        }
        return "\(Int(ceil(remainingSeconds / (24 * 60 * 60))))d"
    }

    func remainingPercent(for window: RateLimitWindow?) -> Int? {
        window.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    var resetText: String? {
        guard let timestamp = weeklyWindow?.resetsAt else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Resets \(formatter.localizedString(for: resetDate, relativeTo: Date()))"
    }

    var settingsDescription: String {
        if let weeklyWindow {
            let remaining = max(0, min(100, 100 - weeklyWindow.usedPercent))
            let shortDescription = shortWindow.map {
                "5h \($0.usedPercent)% used · "
            } ?? ""
            return "\(shortDescription)weekly \(weeklyWindow.usedPercent)% used · \(remaining)% remaining · \(resetText ?? "reset time unavailable")"
        }
        if let errorMessage {
            return errorMessage
        }
        return isRefreshing ? "Reading local Codex account…" : "Local only · no API key required"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                CodexUsageViewModel.shared.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            do {
                let data = try await XPCHelperClient.shared.fetchCodexRateLimits()
                let response = try JSONDecoder().decode(CodexRateLimitResponse.self, from: data)
                if let protocolError = response.error?.message {
                    throw NSError(
                        domain: "BoringNotch.CodexUsage",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: protocolError]
                    )
                }

                let directSnapshot = response.result?.rateLimits
                let snapshotsById = response.result?.rateLimitsByLimitId ?? [:]
                let preferredSnapshots = [
                    directSnapshot,
                    snapshotsById["codex"]
                ].compactMap { $0 }
                let snapshots = preferredSnapshots.isEmpty
                    ? Array(snapshotsById.values)
                    : preferredSnapshots

                guard !snapshots.isEmpty else {
                    throw NSError(
                        domain: "BoringNotch.CodexUsage",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Codex returned no rate-limit window."]
                    )
                }

                let windows = snapshots
                    .flatMap { [$0.primary, $0.secondary].compactMap { $0 } }
                    .reduce(into: [RateLimitWindow]()) { result, window in
                        if !result.contains(window) {
                            result.append(window)
                        }
                    }
                weeklyWindow = Self.weeklyWindow(in: windows)
                shortWindow = windows.first {
                    $0.windowDurationMins == 5 * 60
                }
                errorMessage = nil
                lastUpdated = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    private static func weeklyWindow(
        in windows: [RateLimitWindow]
    ) -> RateLimitWindow? {
        if let exactWeeklyWindow = windows.first(where: {
            $0.windowDurationMins == 7 * 24 * 60
        }) {
            return exactWeeklyWindow
        }

        return windows
            .filter { ($0.windowDurationMins ?? 0) >= 24 * 60 }
            .min {
                abs(($0.windowDurationMins ?? 0) - 7 * 24 * 60)
                    < abs(($1.windowDurationMins ?? 0) - 7 * 24 * 60)
            }
    }
}

struct CodexWeekUsageBadge: View {
    @ObservedObject private var usage = CodexUsageViewModel.shared
    @Default(.codexUsageDisplayMode) private var displayMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Group {
                if let shortWindow = usage.shortWindow,
                   let weeklyWindow = usage.weeklyWindow {
                    VStack(spacing: 0) {
                        usageRow(
                            window: shortWindow,
                            date: context.date,
                            compact: true
                        )
                        usageRow(
                            window: weeklyWindow,
                            date: context.date,
                            compact: true
                        )
                    }
                } else {
                    usageRow(
                        window: usage.weeklyWindow ?? usage.shortWindow,
                        date: context.date,
                        compact: false
                    )
                }
            }
        }
        .padding(.horizontal, usage.shortWindow == nil ? 9 : 8)
        .frame(height: 30)
        .background(.white.opacity(0.08), in: Capsule())
        .help(badgeHelpText)
        .onAppear { usage.start() }
        .onTapGesture { usage.refresh() }
    }

    @ViewBuilder
    private func usageRow(
        window: RateLimitWindow?,
        date: Date,
        compact: Bool
    ) -> some View {
        HStack(spacing: compact ? 3 : 4) {
            statusIndicator(for: window, compact: compact)
            Text(usage.percentageText(for: window, mode: displayMode))
            if let countdown = usage.resetCountdownText(for: window, at: date) {
                Text("·")
                Image(systemName: "arrow.clockwise")
                    .font(.system(
                        size: compact ? 7 : 9,
                        weight: .bold
                    ))
                Text(countdown)
            }
        }
        .font(.system(
            size: compact ? 8.5 : 11,
            weight: .semibold,
            design: .rounded
        ))
        .monospacedDigit()
        .foregroundStyle(statusColor(for: window))
        .frame(height: compact ? 12 : 30)
    }

    @ViewBuilder
    private func statusIndicator(
        for window: RateLimitWindow?,
        compact: Bool
    ) -> some View {
        if usage.errorMessage != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: compact ? 7 : 10, weight: .bold))
                .foregroundStyle(.orange)
        } else if isCritical(window) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: compact ? 8 : 11, weight: .bold))
                .foregroundStyle(.red)
                .shadow(color: .red.opacity(0.9), radius: 4)
        } else {
            Circle()
                .fill(statusColor(for: window))
                .frame(
                    width: compact ? 5 : 8,
                    height: compact ? 5 : 8
                )
                .shadow(
                    color: statusColor(for: window).opacity(0.9),
                    radius: compact ? 2 : 4
                )
        }
    }

    private func isCritical(_ window: RateLimitWindow?) -> Bool {
        guard let remaining = usage.remainingPercent(for: window) else {
            return false
        }
        return remaining < 10
    }

    private func statusColor(for window: RateLimitWindow?) -> Color {
        guard usage.errorMessage == nil else { return .orange }
        guard let remaining = usage.remainingPercent(for: window) else {
            return .gray
        }
        if remaining < 20 {
            return .red
        }
        if remaining < 30 {
            return .yellow
        }
        return .green
    }

    private var badgeHelpText: String {
        if let shortWindow = usage.shortWindow,
           let weeklyWindow = usage.weeklyWindow {
            return "5h: \(usage.percentageText(for: shortWindow, mode: displayMode)) · Weekly: \(usage.percentageText(for: weeklyWindow, mode: displayMode)) · Click to refresh"
        }
        return usage.resetText
            ?? usage.errorMessage
            ?? "Codex weekly usage"
    }
}
