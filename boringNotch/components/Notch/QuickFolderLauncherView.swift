//
//  QuickFolderLauncherView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct QuickFolderLauncherView: View {
    @Default(.quickFolders) private var quickFolders
    @Default(.visibleQuickFolderCount) private var visibleQuickFolderCount

    private var clampedVisibleCount: Int {
        min(max(visibleQuickFolderCount, 1), 4)
    }

    private var configuredFolders: [QuickFolderShortcut] {
        quickFolders
            .filter { (0..<clampedVisibleCount).contains($0.slot) }
            .sorted { $0.slot < $1.slot }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ForEach(configuredFolders) { shortcut in
                HoverButton(
                    icon: QuickFolderIconResolver.symbol(for: shortcut),
                    iconColor: .secondary,
                    scale: .medium
                ) {
                    QuickFolderService.open(shortcut)
                }
                .help(shortcut.name)
                .accessibilityLabel("Open \(shortcut.name)")

                Spacer(minLength: 0)
            }
        }
        .frame(width: 30, height: 150)
    }
}
