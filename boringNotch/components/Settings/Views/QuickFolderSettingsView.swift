//
//  QuickFolderSettingsView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct QuickFolderSettings: View {
    @Default(.showQuickFolders) private var showQuickFolders
    @Default(.visibleQuickFolderCount) private var visibleQuickFolderCount
    @Default(.quickFolders) private var quickFolders
    @State private var errorMessage: String?

    private let customIcons = [
        ("Folder", "folder"),
        ("Downloads", "arrow.down.circle"),
        ("Documents", "doc"),
        ("Cloud", "icloud"),
        ("Home", "house"),
        ("Applications", "a.app"),
        ("Code", "chevron.left.forwardslash.chevron.right"),
        ("Courses", "graduationcap"),
        ("Books", "book.closed"),
        ("Projects", "hammer"),
        ("Archive", "shippingbox"),
        ("Music", "music.note"),
        ("Movies", "film"),
        ("Pictures", "photo"),
    ]

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showQuickFolders) {
                    Text("Show quick folders in Notch")
                }
                Picker("Visible shortcuts", selection: $visibleQuickFolderCount) {
                    ForEach(1...4, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("General")
            } footer: {
                Text("Quick folders appear between Music and Calendar without changing the Notch width.")
            }

            Section {
                ForEach(0..<4, id: \.self) { slot in
                    folderRow(for: slot)
                }
            } header: {
                Text("Folder slots")
            } footer: {
                Text("Folder access is stored locally using macOS security-scoped bookmarks.")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Quick Folders")
        .alert(
            "Couldn’t Save Folder",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func folderRow(for slot: Int) -> some View {
        let shortcut = shortcut(for: slot)

        return HStack(spacing: 12) {
            Image(
                systemName: shortcut.map(QuickFolderIconResolver.symbol(for:))
                    ?? "folder"
            )
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Slot \(slot + 1)")
                Text(shortcut?.name ?? "Not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let shortcut {
                iconMenu(for: shortcut)
            }

            Button(shortcut == nil ? "Choose…" : "Change…") {
                chooseFolder(for: slot)
            }

            if shortcut != nil {
                Button(role: .destructive) {
                    quickFolders.removeAll { $0.slot == slot }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove folder")
            }
        }
    }

    private func iconMenu(for shortcut: QuickFolderShortcut) -> some View {
        Menu {
            Button {
                setAutomaticIcon(for: shortcut.slot)
            } label: {
                Label("Automatic (Finder-style)", systemImage: "wand.and.stars")
            }

            Divider()

            ForEach(customIcons, id: \.1) { title, symbol in
                Button {
                    setCustomIcon(symbol, for: shortcut.slot)
                } label: {
                    Label(title, systemImage: symbol)
                }
            }
        } label: {
            Label(
                shortcut.isUsingAutomaticIcon ? "Auto" : "Custom",
                systemImage: QuickFolderIconResolver.symbol(for: shortcut)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func shortcut(for slot: Int) -> QuickFolderShortcut? {
        quickFolders.first { $0.slot == slot }
    }

    private func chooseFolder(for slot: Int) {
        do {
            guard let selected = try QuickFolderService.chooseFolder(
                for: slot,
                replacing: shortcut(for: slot)
            ) else {
                return
            }

            quickFolders.removeAll { $0.slot == slot }
            quickFolders.append(selected)
            quickFolders.sort { $0.slot < $1.slot }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setAutomaticIcon(for slot: Int) {
        guard let index = quickFolders.firstIndex(where: { $0.slot == slot }) else {
            return
        }

        quickFolders[index].usesAutomaticIcon = true
        quickFolders[index].systemImage =
            QuickFolderIconResolver.symbol(for: quickFolders[index])
    }

    private func setCustomIcon(_ symbol: String, for slot: Int) {
        guard let index = quickFolders.firstIndex(where: { $0.slot == slot }) else {
            return
        }

        quickFolders[index].usesAutomaticIcon = false
        quickFolders[index].systemImage = symbol
    }
}
