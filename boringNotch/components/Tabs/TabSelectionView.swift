//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let label: String
    let icon: String
    let view: NotchViews

    // Stable across renders so ForEach and matchedGeometryEffect keep identity.
    var id: NotchViews { view }

    /// One gate per tab. The bar shows only when more than one tab is visible, which
    /// keeps the pre-CodeBurn behaviour when the CodeBurn tab is off.
    static func visible(shelfEnabled: Bool, shelfEmpty: Bool, alwaysShowTabs: Bool, codeBurnEnabled: Bool, currentView: NotchViews) -> [TabModel] {
        var tabs = [TabModel(label: "Home", icon: "house.fill", view: .home)]
        if shelfEnabled && (!shelfEmpty || alwaysShowTabs || (codeBurnEnabled && currentView == .shelf)) {
            tabs.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
        }
        if codeBurnEnabled {
            tabs.append(TabModel(label: "CodeBurn", icon: "flame.fill", view: .codeburn))
        }
        return tabs
    }
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var tvm = ShelfStateViewModel.shared
    @Default(.boringShelf) var boringShelf
    @Default(.showCodeBurnTab) var showCodeBurnTab
    @Namespace var animation

    private var tabs: [TabModel] {
        TabModel.visible(shelfEnabled: boringShelf, shelfEmpty: tvm.isEmpty,
                         alwaysShowTabs: coordinator.alwaysShowTabs, codeBurnEnabled: showCodeBurnTab, currentView: coordinator.currentView)
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
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
