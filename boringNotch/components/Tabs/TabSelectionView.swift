//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

struct TabSelectionView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    @State private var pageGestureTriggered = false
    @State private var pageSwitchHaptic = false

    private var tabs: [TabModel] {
        var result = [
            TabModel(label: "Home", icon: "house.fill", view: .home),
        ]
        if Defaults[.boringShelf] {
            result.append(
                TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
            )
        }
        result.append(
            TabModel(
                label: "Activity Monitor",
                icon: "waveform.path.ecg",
                view: .activity
            )
        )
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        // Scope page navigation to the tab strip, not the entire notch window.
        .conditionalModifier(Defaults[.enableGestures]) { view in
            view
                .trackpadPanGesture(direction: .left) { translation, phase in
                    handlePageGesture(direction: 1, translation: translation, phase: phase)
                }
                .trackpadPanGesture(direction: .right) { translation, phase in
                    handlePageGesture(direction: -1, translation: translation, phase: phase)
                }
        }
        .sensoryFeedback(.alignment, trigger: pageSwitchHaptic)
    }

    private func handlePageGesture(
        direction: Int,
        translation: CGFloat,
        phase: NSEvent.Phase
    ) {
        guard phase != .ended else {
            pageGestureTriggered = false
            return
        }
        guard vm.notchState == .open,
              !vm.isBatteryPopoverActive,
              !pageGestureTriggered,
              translation >= pageSwipeThreshold
        else { return }

        let views = tabs.map(\.view)
        guard let currentIndex = views.firstIndex(of: coordinator.currentView) else {
            return
        }

        pageGestureTriggered = true
        let destinationIndex = currentIndex + direction
        guard views.indices.contains(destinationIndex) else { return }

        withAnimation(.smooth(duration: 0.28)) {
            coordinator.currentView = views[destinationIndex]
        }
        if Defaults[.enableHaptics] {
            pageSwitchHaptic.toggle()
        }
    }

    private var pageSwipeThreshold: CGFloat {
        min(max(Defaults[.gestureSensitivity] * 0.45, 55), 120)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
