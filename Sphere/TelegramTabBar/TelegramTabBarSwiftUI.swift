import SwiftUI
import UIKit

/// Обёртка таббара из Telegram (UIKit) для SwiftUI — только для iOS 18 и ниже.
struct TelegramTabBarSwiftUI: UIViewRepresentable {
    let homeTitle: String
    let favoritesTitle: String
    let settingsTitle: String
    let accent: Color
    @Binding var selectedTab: MainAppTab

    func makeUIView(context: Context) -> TelegramTabBarView {
        let view = TelegramTabBarView()
        view.configure(
            items: [
                .init(id: MainAppTab.home.rawValue, title: homeTitle, imageName: "Spherelogo"),
                .init(id: MainAppTab.favorites.rawValue, title: favoritesTitle, imageName: "heart.fill"),
                .init(id: MainAppTab.settings.rawValue, title: settingsTitle, imageName: "gearshape.fill"),
            ],
            selectedId: selectedTab.rawValue,
            accentColor: UIColor(accent),
            isDark: UITraitCollection.current.userInterfaceStyle == .dark
        )
        view.onSelect = { id in
            if let tab = MainAppTab(rawValue: id) {
                DispatchQueue.main.async {
                    selectedTab = tab
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: TelegramTabBarView, context: Context) {
        uiView.configure(
            items: [
                .init(id: MainAppTab.home.rawValue, title: homeTitle, imageName: "Spherelogo"),
                .init(id: MainAppTab.favorites.rawValue, title: favoritesTitle, imageName: "heart.fill"),
                .init(id: MainAppTab.settings.rawValue, title: settingsTitle, imageName: "gearshape.fill"),
            ],
            selectedId: selectedTab.rawValue,
            accentColor: UIColor(accent),
            isDark: context.environment.colorScheme == .dark
        )
    }
}
