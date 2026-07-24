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
        weeklyWindow.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    func weeklyPercentageText(for mode: CodexUsageDisplayMode) -> String {
        guard let weeklyWindow else { return "—" }
        let percentage = mode == .used
            ? weeklyWindow.usedPercent
            : max(0, min(100, 100 - weeklyWindow.usedPercent))
        return "\(percentage)%"
    }

    func resetCountdownText(at date: Date = Date()) -> String? {
        guard let timestamp = weeklyWindow?.resetsAt else { return nil }
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
            return "\(weeklyWindow.usedPercent)% used · \(remaining)% remaining · \(resetText ?? "reset time unavailable")"
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

                guard let snapshot = response.result?.rateLimits
                    ?? response.result?.rateLimitsByLimitId?.values.first
                else {
                    throw NSError(
                        domain: "BoringNotch.CodexUsage",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Codex returned no rate-limit window."]
                    )
                }

                let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
                weeklyWindow = windows.max {
                    ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
                }
                shortWindow = windows
                    .filter { ($0.windowDurationMins ?? .max) < 24 * 60 }
                    .min { ($0.windowDurationMins ?? .max) < ($1.windowDurationMins ?? .max) }
                errorMessage = nil
                lastUpdated = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }
}

struct CodexWeekUsageBadge: View {
    @ObservedObject private var usage = CodexUsageViewModel.shared
    @Default(.codexUsageDisplayMode) private var displayMode

    var body: some View {
        HStack(spacing: 6) {
            statusIndicator
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 4) {
                    Text(usage.weeklyPercentageText(for: displayMode))
                    if let countdown = usage.resetCountdownText(at: context.date) {
                        Text("·")
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                        Text(countdown)
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(statusColor)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.white.opacity(0.08), in: Capsule())
        .help(usage.resetText ?? usage.errorMessage ?? "Codex weekly usage")
        .onAppear { usage.start() }
        .onTapGesture { usage.refresh() }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if usage.errorMessage != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
        } else if isCritical {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.red)
                .shadow(color: .red.opacity(0.9), radius: 4)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.9), radius: 4)
        }
    }

    private var isCritical: Bool {
        guard let remaining = usage.weeklyRemainingPercent else { return false }
        return remaining < 10
    }

    private var statusColor: Color {
        guard usage.errorMessage == nil else { return .orange }
        guard let remaining = usage.weeklyRemainingPercent else { return .gray }
        if remaining < 20 {
            return .red
        }
        if remaining < 30 {
            return .yellow
        }
        return .green
    }
}
