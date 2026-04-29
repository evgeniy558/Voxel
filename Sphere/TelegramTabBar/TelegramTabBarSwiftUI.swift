import SwiftUI
import UIKit

struct TabBarSwiftUI: UIViewRepresentable {
    let homeTitle: String
    let favoritesTitle: String
    let profileTitle: String
    let searchTitle: String
    let accent: Color
    let avatarImage: UIImage?
    @Binding var selectedTab: MainAppTab
    var onSettingsFiveTaps: (() -> Void)?

    private func tabItems() -> [SphereTabBarView.Item] {
        [
            .init(id: MainAppTab.home.rawValue, title: homeTitle, imageName: "Spherelogo"),
            .init(id: MainAppTab.favorites.rawValue, title: favoritesTitle, imageName: "heart.fill"),
            .init(id: MainAppTab.profile.rawValue, title: profileTitle, imageName: "person.fill", avatarImage: avatarImage),
            .init(id: MainAppTab.search.rawValue, title: searchTitle, imageName: "magnifyingglass"),
        ]
    }

    func makeUIView(context: Context) -> SphereTabBarView {
        let view = SphereTabBarView()
        view.configure(
            items: tabItems(),
            selectedId: selectedTab.rawValue,
            accentColor: UIColor(accent),
            isDark: UITraitCollection.current.userInterfaceStyle == .dark
        )
        view.onSelect = { id in
            if let tab = MainAppTab(rawValue: id) {
                DispatchQueue.main.async { selectedTab = tab }
            }
        }
        view.onSettingsFiveTaps = onSettingsFiveTaps
        return view
    }

    func updateUIView(_ uiView: SphereTabBarView, context: Context) {
        uiView.onSettingsFiveTaps = onSettingsFiveTaps
        uiView.configure(
            items: tabItems(),
            selectedId: selectedTab.rawValue,
            accentColor: UIColor(accent),
            isDark: context.environment.colorScheme == .dark
        )
    }
}
