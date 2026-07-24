//
//  QuickFolderService.swift
//  boringNotch
//

import AppKit
import Foundation

enum QuickFolderIconResolver {
    static func symbol(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        let fileManager = FileManager.default
        let knownFolders: [(FileManager.SearchPathDirectory, String)] = [
            (.downloadsDirectory, "arrow.down.circle"),
            (.desktopDirectory, "desktopcomputer"),
            (.documentDirectory, "doc"),
            (.applicationDirectory, "a.app"),
            (.musicDirectory, "music.note"),
            (.moviesDirectory, "film"),
            (.picturesDirectory, "photo"),
            (.userDirectory, "house"),
        ]

        for (directory, symbol) in knownFolders {
            guard let knownURL = fileManager.urls(
                for: directory,
                in: .userDomainMask
            ).first else {
                continue
            }

            if standardizedURL == knownURL.standardizedFileURL {
                return symbol
            }
        }

        let path = standardizedURL.path.lowercased()
        let name = standardizedURL.lastPathComponent.lowercased()

        if path.contains("mobile documents")
            || path.contains("icloud")
            || path.contains("onedrive")
            || path.contains("dropbox")
        {
            return "icloud"
        }

        if name.contains("download") {
            return "arrow.down.circle"
        }
        if name.contains("document") {
            return "doc"
        }
        if name.contains("application") {
            return "a.app"
        }
        if name.contains("music") {
            return "music.note"
        }
        if name.contains("movie") || name.contains("video") {
            return "film"
        }
        if name.contains("picture") || name.contains("photo") {
            return "photo"
        }
        if name.contains("code") || name.contains("project") || name.contains("developer") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("course") || name.contains("school") || name.contains("study") {
            return "graduationcap"
        }

        return "folder"
    }

    static func symbol(for shortcut: QuickFolderShortcut) -> String {
        guard shortcut.isUsingAutomaticIcon,
              let url = Bookmark(data: shortcut.bookmarkData).resolvedURL
        else {
            return shortcut.systemImage
        }

        return symbol(for: url)
    }
}

@MainActor
enum QuickFolderService {
    static func chooseFolder(
        for slot: Int,
        replacing existingShortcut: QuickFolderShortcut?
    ) throws -> QuickFolderShortcut? {
        let panel = NSOpenPanel()
        panel.title = "Choose Quick Folder"
        panel.message = "Choose the folder assigned to slot \(slot + 1)."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let bookmark = try Bookmark(url: url)
        let usesAutomaticIcon = existingShortcut?.isUsingAutomaticIcon ?? true
        let systemImage = usesAutomaticIcon
            ? QuickFolderIconResolver.symbol(for: url)
            : (existingShortcut?.systemImage ?? "folder")

        return QuickFolderShortcut(
            slot: slot,
            name: url.lastPathComponent,
            systemImage: systemImage,
            usesAutomaticIcon: usesAutomaticIcon,
            bookmarkData: bookmark.data
        )
    }

    static func open(_ shortcut: QuickFolderShortcut) {
        _ = Bookmark(data: shortcut.bookmarkData).withAccess { url in
            NSWorkspace.shared.open(url)
        }
    }
}
