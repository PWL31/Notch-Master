//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit
import Defaults

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @Default(.showOneDriveInShelf) private var showOneDriveInShelf
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            if showOneDriveInShelf {
                OneDriveShelfView()
                    .frame(width: 132)
            }
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: spacing) {
                        ForEach(Defaults[.reverseShelfOrdering] ? tvm.items.reversed() : tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}

private struct OneDriveStatusPayload: Decodable {
    let installed: Bool
    let running: Bool
    let accessibilityAuthorized: Bool
    let accountName: String?
    let statusText: String?
}

private enum OneDriveShelfState {
    case synced
    case syncing
    case paused
    case needsAttention
    case running
    case notRunning
    case notInstalled
    case unavailable

    var label: String {
        switch self {
        case .synced: "Up to date"
        case .syncing: "Syncing"
        case .paused: "Paused"
        case .needsAttention: "Needs attention"
        case .running: "Running"
        case .notRunning: "Not running"
        case .notInstalled: "Not installed"
        case .unavailable: "Unavailable"
        }
    }

    var color: Color {
        switch self {
        case .synced: .green
        case .syncing: .blue
        case .paused: .yellow
        case .needsAttention: .red
        case .running: .blue
        case .notRunning, .notInstalled, .unavailable: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .synced: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .needsAttention: "exclamationmark.circle.fill"
        case .running: "circle.fill"
        case .notRunning, .notInstalled, .unavailable: "circle"
        }
    }
}

private enum OneDriveShelfAction: String {
    case activity
}

@MainActor
private final class OneDriveShelfViewModel: ObservableObject {
    @Published private(set) var accountName = "OneDrive"
    @Published private(set) var detail = "Checking status…"
    @Published private(set) var state: OneDriveShelfState = .unavailable
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    let appIcon: NSImage? = {
        let workspace = NSWorkspace.shared
        let identifiers = ["com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"]
        guard let url = identifiers.lazy.compactMap({
            workspace.urlForApplication(withBundleIdentifier: $0)
        }).first else { return nil }
        return workspace.icon(forFile: url.path)
    }()

    func refresh() async {
        do {
            let data = try await XPCHelperClient.shared.fetchOneDriveStatus()
            let payload = try JSONDecoder().decode(OneDriveStatusPayload.self, from: data)
            apply(payload)
        } catch {
            state = .unavailable
            detail = "Status unavailable"
        }
    }

    func perform(_ action: OneDriveShelfAction) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil

        Task {
            defer { isWorking = false }
            do {
                try await XPCHelperClient.shared.performOneDriveAction(action.rawValue)
                try? await Task.sleep(for: .milliseconds(500))
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        }
    }

    private func apply(_ payload: OneDriveStatusPayload) {
        accountName = payload.accountName?.isEmpty == false
            ? payload.accountName!
            : "OneDrive"

        guard payload.installed else {
            state = .notInstalled
            detail = state.label
            return
        }
        guard payload.running else {
            state = .notRunning
            detail = state.label
            return
        }

        let statusText = payload.statusText?.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = statusText?.isEmpty == false ? statusText! : "Running"
        state = Self.classify(statusText)

        if !payload.accessibilityAuthorized, statusText == nil {
            detail = "Running"
        }
    }

    private static func classify(_ statusText: String?) -> OneDriveShelfState {
        guard let normalized = statusText?.lowercased(), !normalized.isEmpty else {
            return .running
        }

        if normalized.contains("backed up and synced")
            || normalized.contains("up to date")
            || normalized.contains("synced") {
            return .synced
        }
        if normalized.contains("syncing")
            || normalized.contains("processing changes")
            || normalized.contains("uploading")
            || normalized.contains("downloading") {
            return .syncing
        }
        if normalized.contains("paused") {
            return .paused
        }
        if normalized.contains("error")
            || normalized.contains("attention")
            || normalized.contains("can't sync")
            || normalized.contains("cannot sync")
            || normalized.contains("not signed in") {
            return .needsAttention
        }
        return .running
    }
}

private struct OneDriveShelfView: View {
    @StateObject private var model = OneDriveShelfViewModel()
    @Default(.oneDriveWebURL) private var oneDriveWebURL
    @Default(.oneDriveRecycleBinURL) private var oneDriveRecycleBinURL

    var body: some View {
        VStack(spacing: 8) {
            Button {
                model.perform(.activity)
            } label: {
                VStack(spacing: 6) {
                    Group {
                        if let appIcon = model.appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "externaldrive.connected.to.line.below")
                                .resizable()
                                .scaledToFit()
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                    .frame(width: 31, height: 31)

                    Text(model.accountName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: model.state.symbol)
                            .foregroundStyle(model.state.color)
                        Text(model.detail)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open OneDrive activity center")

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                webButton(
                    icon: "globe",
                    help: "Open OneDrive on the web",
                    destination: configuredURL(oneDriveWebURL)
                )
                webButton(
                    icon: "trash",
                    help: "Open OneDrive recycle bin",
                    destination: configuredURL(oneDriveRecycleBinURL)
                )
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if model.isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .padding(8)
            }
        }
        .help(model.errorMessage ?? model.detail)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
            }
        }
    }

    private func webButton(
        icon: String,
        help: String,
        destination: URL?
    ) -> some View {
        Group {
            if let destination {
                Link(destination: destination) {
                    webButtonIcon(icon)
                }
            } else {
                Button(action: {}) {
                    webButtonIcon(icon)
                }
                .disabled(true)
            }
        }
        .buttonStyle(.plain)
        .help(destination == nil ? "Set this URL in Settings → Shelf" : help)
    }

    private func webButtonIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
    }

    private func configuredURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}
