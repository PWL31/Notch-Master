//
//  QuickFolderShortcut.swift
//  boringNotch
//

import Defaults
import Foundation

struct QuickFolderShortcut: Codable, Equatable, Identifiable, Defaults.Serializable {
    let id: UUID
    let slot: Int
    let name: String
    var systemImage: String
    var usesAutomaticIcon: Bool?
    let bookmarkData: Data

    var isUsingAutomaticIcon: Bool {
        usesAutomaticIcon != false
    }

    init(
        id: UUID = UUID(),
        slot: Int,
        name: String,
        systemImage: String,
        usesAutomaticIcon: Bool = true,
        bookmarkData: Data
    ) {
        self.id = id
        self.slot = slot
        self.name = name
        self.systemImage = systemImage
        self.usesAutomaticIcon = usesAutomaticIcon
        self.bookmarkData = bookmarkData
    }
}
