//
//  DeveloperMenu_SphereExport.swift
//  Экспорт из Sphere (ContentView.swift) — окно «Разработка» (5 тапов по вкладке Настройки).
//  Добавьте файл в таргет приложения. Нужны: AccentColor в ассетах, iOS 16+.
//

import SwiftUI
import UIKit
import QuartzCore
import OSLog

// MARK: - Лог для кнопки «скачать по ссылке» в меню разработчика (родитель передаёт submitAddByLink)
private let sphereAddByLinkLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "AddByLink")

private func sphereAddByLinkLog(_ message: String) {
    NSLog("[AddByLink] %@", message)
    sphereAddByLinkLogger.notice("\(message, privacy: .public)")
}

// MARK: - Tab bar: 5 тапов по правой трети UITabBar (iOS 26+)
/// Находит системный UITabBar у TabView и вешает счётчик тапов по последней вкладке (Настройки). 5 тапов за 1.5 с → callback.
@available(iOS 26.0, *)
struct TabBarDebugTapInjector: UIViewRepresentable {
    var onSettingsFiveTaps: () -> Void
    func makeUIView(context: Context) -> UIView {
        let host = TabBarDebugTapInjectorHost()
        host.onSettingsFiveTaps = onSettingsFiveTaps
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        return host
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? TabBarDebugTapInjectorHost)?.onSettingsFiveTaps = onSettingsFiveTaps
    }
}

@available(iOS 26.0, *)
final class TabBarDebugTapInjectorHost: UIView {
    var onSettingsFiveTaps: (() -> Void)?
    private var tapCount = 0
    private var tapStartTime: CFTimeInterval = 0
    private static let windowInterval: CFTimeInterval = 1.5
    private static let requiredTaps = 5
    private weak var tabBar: UITabBar?
    private var tapRecognizer: UITapGestureRecognizer?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, tabBar == nil else { return }
        findAndAttachToTabBar()
    }
    private func findAndAttachToTabBar() {
        var v: UIView? = self
        while let view = v {
            if let bar = view as? UITabBar, bar.items?.count ?? 0 >= 3 {
                attachToTabBar(bar)
                return
            }
            v = view.superview
        }
        func findTabBarController(_ vc: UIViewController?) -> UITabBarController? {
            guard let vc else { return nil }
            if let tbc = vc as? UITabBarController { return tbc }
            if let tbc = vc.presentedViewController.flatMap({ findTabBarController($0) }) { return tbc }
            for child in vc.children {
                if let tbc = findTabBarController(child) { return tbc }
            }
            return nil
        }
        guard let window else {
            DispatchQueue.main.async { [weak self] in self?.findAndAttachToTabBar() }
            return
        }
        if let tbc = findTabBarController(window.rootViewController), tbc.tabBar.items?.count ?? 0 >= 3 {
            attachToTabBar(tbc.tabBar)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.findAndAttachToTabBar() }
    }
    private func attachToTabBar(_ bar: UITabBar) {
        guard tabBar == nil else { return }
        tabBar = bar
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        bar.addGestureRecognizer(tap)
        tapRecognizer = tap
    }
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let bar = tabBar, recognizer.state == .ended else { return }
        let loc = recognizer.location(in: bar)
        let w = bar.bounds.width
        guard w > 0, loc.x >= w * 2.0 / 3.0 else { return }
        let now = CACurrentMediaTime()
        if tapCount == 0 || now - tapStartTime > Self.windowInterval {
            tapStartTime = now
            tapCount = 0
        }
        tapCount += 1
        if tapCount >= Self.requiredTaps {
            tapCount = 0
            onSettingsFiveTaps?()
        }
    }
}

@available(iOS 26.0, *)
extension TabBarDebugTapInjectorHost: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - Кнопка закрытия (Liquid Glass на iOS 26)
// Стиль кнопки-крестика с Liquid Glass (круглая, большая)
private struct CloseButtonGlassStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        // Всегда фиолетовый круг и белый крестик, независимо от темы.
        let circleColor: Color = accent
        let xColor: Color = .white

        if #available(iOS 26.0, *) {
            configuration.label
                .foregroundStyle(xColor)
                .glassEffect(.regular.tint(circleColor).interactive(), in: Circle())
        } else {
            configuration.label
                .foregroundStyle(xColor)
                .background(circleColor, in: Circle())
        }
    }
}

// MARK: - Меню разработчика и вспомогательные ряды
/// Кнопка «Стиль плеера» на iOS 26: точь-в-точь как капсулы на главном экране (ширина, высота, кружок 32×32, иконка, надпись, тень). Справа три точки — логика переключения 0/1/2 без изменений.
@available(iOS 26.0, *)
struct DeveloperMenuPlayerStyleRowIOS26: View {
    @Binding var playerStyleIndex: Int
    let title: String
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12 + 16 + 10 + 16 + 10 + 16

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .overlay(alignment: .leading) {
                ZStack {
                    Circle().fill(circleFill)
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(circleIconColor)
                }
                .frame(width: 32, height: 32)
                .padding(.leading, 6)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 10) {
                    Button { playerStyleIndex = 0 } label: {
                        Circle()
                            .fill(playerStyleIndex == 0 ? circleFill : Color.primary.opacity(0.2))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    Button { playerStyleIndex = 1 } label: {
                        Circle()
                            .fill(playerStyleIndex == 1 ? circleFill : Color.primary.opacity(0.2))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    Button { playerStyleIndex = 2 } label: {
                        Circle()
                            .fill(playerStyleIndex == 2 ? circleFill : Color.primary.opacity(0.2))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12)
            }
            .glassEffect(.regular.tint(capsuleFill).interactive(), in: Capsule())
            .foregroundStyle(textColor)
            .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
            .padding(.horizontal, horizontalPadding)
    }
}

/// Строка «Перелистывание обложки» на iOS 26: капсула в Liquid Glass, справа переключатель.
@available(iOS 26.0, *)
struct DeveloperMenuCoverPagingRowIOS26: View {
    @Binding var enableCoverPaging: Bool
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat
    let title: String

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    /// В тёмной теме активный переключатель — серый, в светлой — акцент.
    private var toggleTint: Color { isDark ? Color(.systemGray) : accent }
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $enableCoverPaging)
                .labelsHidden()
                .tint(toggleTint)
        }
        .padding(.vertical, 12)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(circleIconColor)
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .glassEffect(.regular.tint(capsuleFill).interactive(), in: Capsule())
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
        .padding(.horizontal, horizontalPadding)
    }
}

/// Строка «Перелистывание обложки» на iOS 16–18: капсула без Liquid Glass.
struct DeveloperMenuCoverPagingRowLegacy: View {
    @Binding var enableCoverPaging: Bool
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat
    let title: String

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    /// В тёмной теме активный переключатель — серый, в светлой — акцент.
    private var toggleTint: Color { isDark ? Color(.systemGray) : accent }
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $enableCoverPaging)
                .labelsHidden()
                .tint(toggleTint)
        }
        .padding(.vertical, 12)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .background(Capsule().fill(capsuleFill))
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(circleIconColor)
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
        .padding(.horizontal, horizontalPadding)
    }
}

/// Строка «Круглая обложка» на iOS 26: как «Перелистывание обложки» — переключатель справа.
@available(iOS 26.0, *)
struct DeveloperMenuRoundCoverRowIOS26: View {
    @Binding var enableRoundPlayerCover: Bool
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat
    let title: String

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    private var toggleTint: Color { isDark ? Color(.systemGray) : accent }
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $enableRoundPlayerCover)
                .labelsHidden()
                .tint(toggleTint)
        }
        .padding(.vertical, 12)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(circleIconColor)
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .glassEffect(.regular.tint(capsuleFill).interactive(), in: Capsule())
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
        .padding(.horizontal, horizontalPadding)
    }
}

/// Строка «Круглая обложка» на iOS 16–18.
struct DeveloperMenuRoundCoverRowLegacy: View {
    @Binding var enableRoundPlayerCover: Bool
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat
    let title: String

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    private var toggleTint: Color { isDark ? Color(.systemGray) : accent }
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $enableRoundPlayerCover)
                .labelsHidden()
                .tint(toggleTint)
        }
        .padding(.vertical, 12)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .background(Capsule().fill(capsuleFill))
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(circleIconColor)
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
        .padding(.horizontal, horizontalPadding)
    }
}

/// Строка «Анимация обложки при перемотке» на iOS 26: заголовок слева от иконки; подстрока «Дрожание» / «Вращение» по центру с точками справа.
@available(iOS 26.0, *)
struct DeveloperMenuCoverSeekAnimationRowIOS26: View {
    @Binding var enableCoverSeekAnimation: Bool
    @Binding var coverSeekShakeDotIndex: Int
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat
    let title: String
    let isEnglish: Bool

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    private var toggleTint: Color { isDark ? Color(.systemGray) : accent }
    /// Как у остальных капсул: 6 pt до круга + 32 + 10 до текста (`overlay` `.padding(.leading, 6)`).
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12
    private let rowCornerRadius: CGFloat = 24

    private var activeDot: Int { min(max(coverSeekShakeDotIndex, 0), 1) }

    private var modeSubrowTitle: String {
        if activeDot == 0 {
            return isEnglish ? "Shake" : "Дрожание"
        }
        return isEnglish ? "Rotation" : "Вращение"
    }

    private var playIconCircle: some View {
        ZStack {
            Circle().fill(circleFill)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(circleIconColor)
        }
        .frame(width: 32, height: 32)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                playIconCircle
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $enableCoverSeekAnimation)
                    .labelsHidden()
                    .tint(toggleTint)
            }
            .padding(.vertical, 10)
            .padding(.leading, 6)
            .padding(.trailing, trailingInset)

            if enableCoverSeekAnimation {
                Rectangle()
                    .fill(textColor.opacity(0.18))
                    .frame(height: 1)
                    .padding(.leading, leadingInset - 4)
                    .padding(.trailing, 12)
                ZStack {
                    Text(modeSubrowTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                    HStack(spacing: 10) {
                        Button {
                            coverSeekShakeDotIndex = 0
                        } label: {
                            Circle()
                                .fill(activeDot == 0 ? circleFill : Color.primary.opacity(0.2))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        Button {
                            coverSeekShakeDotIndex = 1
                        } label: {
                            Circle()
                                .fill(activeDot == 1 ? circleFill : Color.primary.opacity(0.2))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, trailingInset)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, trailingInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: enableCoverSeekAnimation)
        .glassEffect(.regular.tint(capsuleFill).interactive(), in: RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
        .padding(.horizontal, horizontalPadding)
    }
}

/// Строка «Анимация обложки при перемотке» на iOS 16–18: заголовок слева; подстрока по центру с точками справа.
struct DeveloperMenuCoverSeekAnimationRowLegacy: View {
    @Binding var enableCoverSeekAnimation: Bool
    @Binding var coverSeekShakeDotIndex: Int
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat
    let title: String
    let isEnglish: Bool

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    private var toggleTint: Color { isDark ? Color(.systemGray) : accent }
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12
    private let rowCornerRadius: CGFloat = 24

    private var activeDot: Int { min(max(coverSeekShakeDotIndex, 0), 1) }

    private var modeSubrowTitle: String {
        if activeDot == 0 {
            return isEnglish ? "Shake" : "Дрожание"
        }
        return isEnglish ? "Rotation" : "Вращение"
    }

    private var playIconCircle: some View {
        ZStack {
            Circle().fill(circleFill)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(circleIconColor)
        }
        .frame(width: 32, height: 32)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                playIconCircle
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $enableCoverSeekAnimation)
                    .labelsHidden()
                    .tint(toggleTint)
            }
            .padding(.vertical, 10)
            .padding(.leading, 6)
            .padding(.trailing, trailingInset)

            if enableCoverSeekAnimation {
                Rectangle()
                    .fill(textColor.opacity(0.18))
                    .frame(height: 1)
                    .padding(.leading, leadingInset - 4)
                    .padding(.trailing, 12)
                ZStack {
                    Text(modeSubrowTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                    HStack(spacing: 10) {
                        Button {
                            coverSeekShakeDotIndex = 0
                        } label: {
                            Circle()
                                .fill(activeDot == 0 ? circleFill : Color.primary.opacity(0.2))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        Button {
                            coverSeekShakeDotIndex = 1
                        } label: {
                            Circle()
                                .fill(activeDot == 1 ? circleFill : Color.primary.opacity(0.2))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, trailingInset)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, trailingInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous).fill(capsuleFill))
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: enableCoverSeekAnimation)
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
        .padding(.horizontal, horizontalPadding)
    }
}

/// Кнопка «Стиль плеера» на iOS 16–18: капсула с заливкой без Liquid Glass.
struct DeveloperMenuPlayerStyleRowLegacy: View {
    @Binding var playerStyleIndex: Int
    let title: String
    let isDark: Bool
    let accent: Color
    let horizontalPadding: CGFloat

    private var capsuleFill: Color { isDark ? accent : .white }
    private var textColor: Color { isDark ? .white : accent }
    private var circleFill: Color { isDark ? .white : accent }
    private var circleIconColor: Color { isDark ? accent : .white }
    private let leadingInset: CGFloat = 6 + 32 + 10
    private let trailingInset: CGFloat = 12 + 16 + 10 + 16 + 10 + 16

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .background(Capsule().fill(capsuleFill))
            .overlay(alignment: .leading) {
                ZStack {
                    Circle().fill(circleFill)
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(circleIconColor)
                }
                .frame(width: 32, height: 32)
                .padding(.leading, 6)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 10) {
                    Button { playerStyleIndex = 0 } label: {
                        Circle()
                            .fill(playerStyleIndex == 0 ? circleFill : Color.primary.opacity(0.2))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    Button { playerStyleIndex = 1 } label: {
                        Circle()
                            .fill(playerStyleIndex == 1 ? circleFill : Color.primary.opacity(0.2))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    Button { playerStyleIndex = 2 } label: {
                        Circle()
                            .fill(playerStyleIndex == 2 ? circleFill : Color.primary.opacity(0.2))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12)
            }
            .foregroundStyle(textColor)
            .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
            .padding(.horizontal, horizontalPadding)
    }
}

// MARK: - Капсула с иконкой слева (как на начальном экране: тема, язык)

@available(iOS 26.0, *)
struct InitialScreenStyleCapsuleIconButtonIOS26: View {
    let systemDark: Bool
    let accent: Color
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(alignment: .leading) {
                    ZStack {
                        Circle()
                            .fill(systemDark ? .white : accent)
                        Image(systemName: systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(systemDark ? accent : .white)
                    }
                    .frame(width: 32, height: 32)
                    .padding(.leading, 6)
                }
        }
        .glassEffect(
            .regular.tint(systemDark ? accent : .white).interactive(),
            in: Capsule()
        )
        .foregroundStyle(systemDark ? .white : accent)
        .shadow(color: systemDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
    }
}

struct InitialScreenStyleCapsuleIconButtonLegacy: View {
    let systemDark: Bool
    let accent: Color
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(alignment: .leading) {
                    ZStack {
                        Circle()
                            .fill(systemDark ? .white : accent)
                        Image(systemName: systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(systemDark ? accent : .white)
                    }
                    .frame(width: 32, height: 32)
                    .padding(.leading, 6)
                }
        }
        .background((systemDark ? accent : .white), in: Capsule())
        .foregroundStyle(systemDark ? .white : accent)
        .shadow(color: systemDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
    }
}

/// Имена imageset в `Assets.xcassets` для кнопок «Подключить сервисы».
private enum DeveloperMenuStreamingServiceAsset {
    static let vkMusic = "vk music icon"
    static let yandexMusic = "yandex music icon"
    static let soundcloud = "soundcloud icon"
    static let spotify = "spotify icon"
    static let appleMusic = "apple music icon"
}

/// Один размер иконки в круге 32×32: ассеты (template) и SF Symbol в блоках «Подключить сервисы» и «Скачать по ссылке».
private let kDeveloperMenuCircleAssetIconSide: CGFloat = 23
private let kDeveloperMenuCircleSFSymbolPointSize: CGFloat = 19

/// Капсула с ассет-иконкой слева: тёмная тема — иконка фиолетовая (`accent`), светлая — белая; круг как у языка/темы.
@available(iOS 26.0, *)
private struct DeveloperMenuServiceAssetCapsuleIOS26: View {
    let systemDark: Bool
    let accent: Color
    let assetName: String
    let title: String
    let action: () -> Void

    private var iconTint: Color { systemDark ? accent : .white }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(alignment: .leading) {
                    ZStack {
                        Circle()
                            .fill(systemDark ? .white : accent)
                        Image(assetName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: kDeveloperMenuCircleAssetIconSide, height: kDeveloperMenuCircleAssetIconSide)
                            .foregroundStyle(iconTint)
                    }
                    .frame(width: 32, height: 32)
                    .padding(.leading, 6)
                }
        }
        .glassEffect(
            .regular.tint(systemDark ? accent : .white).interactive(),
            in: Capsule()
        )
        .foregroundStyle(systemDark ? .white : accent)
        .shadow(color: systemDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
    }
}

private struct DeveloperMenuServiceAssetCapsuleLegacy: View {
    let systemDark: Bool
    let accent: Color
    let assetName: String
    let title: String
    let action: () -> Void

    private var iconTint: Color { systemDark ? accent : .white }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(alignment: .leading) {
                    ZStack {
                        Circle()
                            .fill(systemDark ? .white : accent)
                        Image(assetName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: kDeveloperMenuCircleAssetIconSide, height: kDeveloperMenuCircleAssetIconSide)
                            .foregroundStyle(iconTint)
                    }
                    .frame(width: 32, height: 32)
                    .padding(.leading, 6)
                }
        }
        .background((systemDark ? accent : .white), in: Capsule())
        .foregroundStyle(systemDark ? .white : accent)
        .shadow(color: systemDark ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
    }
}

/// Реальный `UIScrollView.contentOffset` — SwiftUI `GeometryReader` + `PreferenceKey` часто не обновляется при скролле.
struct DevMenuScrollOffsetUIKitReader: UIViewRepresentable {
    @Binding var offsetY: CGFloat
    /// Если `true` — только `y ≥ 0` (нормализованный скролл). Если `false` (главная): нормализованный `y`, отрицательный при резинке вверху — поле едет вместе с контентом.
    var clampsVerticalOffsetToNonNegative: Bool = true
    /// Главная: KVO не всегда совпадает с частотой кадра ProMotion — подписываемся на `CADisplayLink` на время жеста/инерции, чтобы капсула ехала в такт с `UIScrollView`.
    var prefersDisplayLinkWhileScrolling: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(offsetY: $offsetY) }

    func makeUIView(context: Context) -> DetectorView {
        let v = DetectorView()
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: DetectorView, context: Context) {
        context.coordinator.offsetY = $offsetY
        context.coordinator.clampsVerticalOffsetToNonNegative = clampsVerticalOffsetToNonNegative
        context.coordinator.prefersDisplayLinkWhileScrolling = prefersDisplayLinkWhileScrolling
        context.coordinator.attachIfPossible(from: uiView)
    }

    final class Coordinator: NSObject {
        var offsetY: Binding<CGFloat>
        var clampsVerticalOffsetToNonNegative = true
        var prefersDisplayLinkWhileScrolling = false
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var insetObservation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?

        init(offsetY: Binding<CGFloat>) {
            self.offsetY = offsetY
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// Снимаем линк, если `DetectorView` ушёл из окна — иначе тикаем впустую.
        func cancelDisplayLinkForHostRemoval() {
            stopDisplayLink()
        }

        private func startDisplayLinkIfNeeded() {
            guard prefersDisplayLinkWhileScrolling else { return }
            guard displayLink == nil, observedScrollView != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(stepDisplayLink(_:)))
            if #available(iOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func stepDisplayLink(_ link: CADisplayLink) {
            guard let sv = observedScrollView else {
                stopDisplayLink()
                return
            }
            pushScrollOffset(from: sv, fromDisplayLink: true)
            if !sv.isDragging, !sv.isDecelerating {
                stopDisplayLink()
            }
        }

        private func pushScrollOffset(from sv: UIScrollView, fromDisplayLink: Bool = false) {
            let raw = sv.contentOffset.y
            // Без нормализации на новых iOS в покое часто `contentOffset.y ≈ -adjustedContentInset.top`,
            // тогда latch − offset завышает ведущий спейсер и поле поиска «съезжает» на блок библиотеки.
            let scrollFromVisualTop = raw + sv.adjustedContentInset.top
            let y = clampsVerticalOffsetToNonNegative ? max(0, scrollFromVisualTop) : scrollFromVisualTop
            // Без `async`: иначе на новых iOS / ProMotion оверлей поиска отстаёт на кадр и «плавает» относительно скролла.
            let scale = max(sv.traitCollection.displayScale, 1)
            let aligned = (y * scale).rounded(.toNearestOrAwayFromZero) / scale
            let apply = { self.offsetY.wrappedValue = aligned }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
            if !fromDisplayLink, prefersDisplayLinkWhileScrolling, sv.isDragging || sv.isDecelerating {
                startDisplayLinkIfNeeded()
            }
        }

        func attachIfPossible(from view: UIView) {
            var v: UIView? = view.superview
            while let current = v {
                if let sv = current as? UIScrollView {
                    /// `SystemPagedScrollView`: paging + `isScrollEnabled = false`. Если цепочка superview когда‑то даёт его раньше вертикального `ScrollView`, `contentOffset.y` ≈ 0 — «липкая» панель не закрепляется и едет с контентом.
                    if sv.isPagingEnabled, !sv.isScrollEnabled {
                        v = current.superview
                        continue
                    }
                    if sv !== observedScrollView {
                        stopDisplayLink()
                        observation?.invalidate()
                        observation = nil
                        insetObservation?.invalidate()
                        insetObservation = nil
                        observedScrollView = sv
                        observation = sv.observe(\.contentOffset, options: [.new, .initial]) { [weak self] sv, _ in
                            self?.pushScrollOffset(from: sv, fromDisplayLink: false)
                        }
                        insetObservation = sv.observe(\.contentInset, options: [.new, .initial]) { [weak self] sv, _ in
                            self?.pushScrollOffset(from: sv, fromDisplayLink: false)
                        }
                    }
                    return
                }
                v = current.superview
            }
        }

        deinit {
            stopDisplayLink()
            observation?.invalidate()
            insetObservation?.invalidate()
        }
    }

    final class DetectorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attachIfPossible(from: self)
            } else {
                coordinator?.cancelDisplayLinkForHostRemoval()
            }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attachIfPossible(from: self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.attachIfPossible(from: self)
        }
    }
}

/// Живой скролл iOS 18+: `contentOffset.y` во время жеста.
struct DeveloperMenuLiveScrollModifier: ViewModifier {
    @Binding var scrollY: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y)
            } action: { _, newY in
                scrollY = newY
            }
        } else {
            content
        }
    }
}

/// По 5 тапам по «Настройки» — пустой fullscreen с кнопкой-крестиком справа сверху, как на экране входа (56×56, Liquid Glass на iOS 26).
struct DeveloperMenuView: View {
    /// Схема с `MainAppView` (уже с учётом `preferredColorScheme` у корня). Внутри `fullScreenCover` свой `Environment.colorScheme` часто .light — его нельзя использовать для режима «системная».
    let resolvedColorSchemeFromMainApp: ColorScheme
    let accent: Color
    let onDismiss: () -> Void
    @Binding var addByLinkInput: String
    var submitAddByLink: () -> Void
    var isAddingFromLink: Bool
    @State private var devMenuScrollOffset: CGFloat = 0
    @AppStorage("spotifyToMp3APIBaseURLOverride") private var spotifyToMp3APIBaseURLOverride: String = ""
    @AppStorage("isEnglish") private var isEnglish: Bool = false
    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: String = ""

    /// Явная схема для поддерева меню: при «системной» — как на главном экране, не `nil` (у модалки `nil` даёт светлую среду).
    private var appliedColorSchemeForMenu: ColorScheme {
        switch preferredColorSchemeRaw {
        case "dark": return .dark
        case "light": return .light
        default: return resolvedColorSchemeFromMainApp
        }
    }

    private var isDark: Bool { appliedColorSchemeForMenu == .dark }
    /// Фон скролла под панелью — как у корня экрана (без серого дефолта `ScrollView`).
    private var devMenuScreenBackgroundColor: Color { isDark ? .black : Color(.systemBackground) }
    private var textColor: Color { isDark ? .white : accent }
    private let horizontalPadding: CGFloat = 27
    /// Зазор между нижним краем блюра и кнопкой закрытия (блюр чуть ниже крестика).
    private let devMenuBlurBottomGutter: CGFloat = 10
    /// Сторона квадрата под круглую кнопку закрытия (как на экране входа).
    private let devMenuCloseButtonSide: CGFloat = 56
    private let devMenuCloseButtonTrailingPadding: CGFloat = 12
    /// Нижние **оба** угла одинаковые: R = радиус кнопки + trailing (как зазор от круга кнопки до дуги); честная окружность — `style: .circular`.
    private var devMenuBlurBottomCornerRadius: CGFloat {
        devMenuCloseButtonSide / 2 + devMenuCloseButtonTrailingPadding
    }
    /// Запас в `Spacer` над первым блоком; при `contentOffset.y ≥` этого значения под панелью уже не пустой отступ, а контент — только тогда показываем блюр.
    private let devMenuScrollRevealInset: CGFloat = 4
    /// Блюр панели только после прокрутки вниз (iOS 18+ — `onScrollGeometryChange`, 16–17 — `PreferenceKey` + `coordinateSpace` на `ScrollView`).
    private var devMenuTopBlurMaterialVisible: Bool {
        devMenuScrollOffset >= devMenuScrollRevealInset
    }
    /// Заголовок по центру верхней панели меню разработчика.
    private var developerMenuBarCenterTitle: String { isEnglish ? "Development" : "Разработка" }
    private var addSongFromSpotifyByLinkTitle: String { isEnglish ? "Download by link" : "Скачать по ссылке" }
    private var connectServicesTitle: String { isEnglish ? "Connect services" : "Подключить сервисы" }
    /// Чуть правее прежнего края (12) + меньший шрифт, чем у заголовка панели.
    private let devMenuSectionHeaderLeading: CGFloat = 18

    /// Надпись над карточкой.
    private func devMenuSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isDark ? .white : accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, devMenuSectionHeaderLeading)
            .padding(.trailing, 12)
    }

    var body: some View {
        (isDark ? Color.black : Color(.systemBackground))
            .ignoresSafeArea()
            .preferredColorScheme(appliedColorSchemeForMenu)
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    // Полоса до физического верха; safe area + крестик + небольшой зазор до нижней грани блюра.
                    let devMenuBarTotalHeight = geo.safeAreaInsets.top + devMenuCloseButtonSide + devMenuBlurBottomGutter
                    ZStack(alignment: .top) {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 12) {
                                // iOS 16–17: KVO на `UIScrollView` внутри SwiftUI `ScrollView`. iOS 18+ — `onScrollGeometryChange`.
                                Group {
                                    if #available(iOS 18.0, *) {
                                        Color.clear.frame(height: 0)
                                    } else {
                                        DevMenuScrollOffsetUIKitReader(offsetY: $devMenuScrollOffset)
                                            .frame(width: 1, height: 1)
                                            .allowsHitTesting(false)
                                    }
                                }
                                Spacer().frame(height: devMenuBarTotalHeight + devMenuScrollRevealInset)
                                connectServicesBlock()
                                VStack(alignment: .leading, spacing: 8) {
                                    devMenuSectionHeader(addSongFromSpotifyByLinkTitle)
                                    devMenuDownloadByLinkBlock()
                                }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.bottom, 36)
                }
                .scrollContentBackground(.hidden)
                .background(devMenuScreenBackgroundColor)
                .modifier(DeveloperMenuLiveScrollModifier(scrollY: $devMenuScrollOffset))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                developerMenuTopBlurBar(
                    safeAreaTop: geo.safeAreaInsets.top,
                    totalHeight: devMenuBarTotalHeight,
                    bottomGutter: devMenuBlurBottomGutter,
                    showTopBlurStrip: devMenuTopBlurMaterialVisible
                )
                    .zIndex(1)
            }
            .ignoresSafeArea(edges: .top)
            }
        }
    }

    /// Верх прямой; снизу слева и справа — **одинаковые** круговые четверти (один радиус, `.circular`).
    private func devMenuTopBlurBarShape() -> UnevenRoundedRectangle {
        let r = devMenuBlurBottomCornerRadius
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: r,
                bottomTrailing: r,
                topTrailing: 0
            ),
            style: .circular
        )
    }

    /// Верхняя панель: блюр только после прокрутки вниз; вверху экрана полоса невидима, крестик всегда на месте.
    @ViewBuilder
    private func developerMenuTopBlurBar(safeAreaTop: CGFloat, totalHeight: CGFloat, bottomGutter: CGFloat, showTopBlurStrip: Bool) -> some View {
        ZStack(alignment: .top) {
            devMenuTopBlurBarShape()
                .fill(.ultraThinMaterial)
                .frame(height: totalHeight)
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(showTopBlurStrip ? 1 : 0)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Color.clear.frame(height: safeAreaTop)
                // Текст по геометрическому центру всей ширины панели; отступ только у крестика (не сдвигает центр надписи).
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: devMenuCloseButtonSide)
                    .overlay {
                        Text(developerMenuBarCenterTitle)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(isDark ? .white : accent)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .trailing) {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: devMenuCloseButtonSide, height: devMenuCloseButtonSide)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CloseButtonGlassStyle(accent: accent))
                        .padding(.trailing, devMenuCloseButtonTrailingPadding)
                    }
                Color.clear.frame(height: bottomGutter)
            }
            .frame(height: totalHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: showTopBlurStrip)
        .clipShape(devMenuTopBlurBarShape())
        .shadow(color: Color.black.opacity(showTopBlurStrip ? 0.06 : 0), radius: 2, x: 0, y: 1)
        // Панель до самого верха корпуса (под вырез / статус-бар).
        .ignoresSafeArea(edges: .top)
    }

    /// Пять кнопок подключения стримингов — пока заглушки (действие пустое), стиль как у «Язык» / «Добавить музыку».
    @ViewBuilder
    private func connectServicesBlock() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            devMenuSectionHeader(connectServicesTitle)
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 12) {
                    developerMenuServiceConnectButton(
                        title: isEnglish ? "VK Music" : "VK Музыка",
                        assetName: DeveloperMenuStreamingServiceAsset.vkMusic
                    )
                    developerMenuServiceConnectButton(
                        title: isEnglish ? "Yandex Music" : "Yandex Музыка",
                        assetName: DeveloperMenuStreamingServiceAsset.yandexMusic
                    )
                    developerMenuServiceConnectButton(
                        title: "SoundCloud",
                        assetName: DeveloperMenuStreamingServiceAsset.soundcloud
                    )
                    developerMenuServiceConnectButton(
                        title: "Spotify",
                        assetName: DeveloperMenuStreamingServiceAsset.spotify
                    )
                    developerMenuServiceConnectButton(
                        title: "Apple Music",
                        assetName: DeveloperMenuStreamingServiceAsset.appleMusic
                    )
                }
                .padding(.top, 18)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(isDark ? Color(white: 0.12) : Color(white: 0.92))
            )
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func developerMenuServiceConnectButton(title: String, assetName: String, action: @escaping () -> Void = {}) -> some View {
        if #available(iOS 26.0, *) {
            DeveloperMenuServiceAssetCapsuleIOS26(
                systemDark: isDark,
                accent: accent,
                assetName: assetName,
                title: title,
                action: action
            )
            .padding(.horizontal, 12)
        } else {
            DeveloperMenuServiceAssetCapsuleLegacy(
                systemDark: isDark,
                accent: accent,
                assetName: assetName,
                title: title,
                action: action
            )
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func devMenuDownloadByLinkBlock() -> some View {
        let capsuleColor = isDark ? accent : Color.white
        let textColor = isDark ? Color.white : accent
        let circleFill = isDark ? Color.white : accent
        let iconColor = isDark ? accent : Color.white
        let cursorColor = isDark ? Color.white : accent

        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 14) {
                devMenuCapsuleField(placeholder: isEnglish ? "Spotify API URL (spotisaver)" : "URL API Spotify (spotisaver)", text: $spotifyToMp3APIBaseURLOverride, systemImage: "link", showReset: !spotifyToMp3APIBaseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onReset: { spotifyToMp3APIBaseURLOverride = "" }, isDark: isDark, capsuleColor: capsuleColor, textColor: textColor, circleFill: circleFill, iconColor: iconColor, cursorColor: cursorColor)
                devMenuCapsuleField(placeholder: isEnglish ? "Spotify track link" : "Ссылка на песню Spotify", text: $addByLinkInput, systemImage: "music.note", leadingAssetName: DeveloperMenuStreamingServiceAsset.spotify, trailingSystemImage: "arrow.down.circle.fill", onTrailingTap: {
                    sphereAddByLinkLog("тап по кнопке скачивания в меню разработчика")
                    submitAddByLink()
                }, isTrailingDisabled: addByLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingFromLink, isDark: isDark, capsuleColor: capsuleColor, textColor: textColor, circleFill: circleFill, iconColor: iconColor, cursorColor: cursorColor)
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 18)
            if isAddingFromLink {
                ProgressView()
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(isDark ? Color(white: 0.12) : Color(white: 0.92)))
        .padding(.horizontal, 12)
    }

    private func devMenuCapsuleField(placeholder: String, text: Binding<String>, systemImage: String, leadingAssetName: String? = nil, showReset: Bool = false, onReset: (() -> Void)? = nil, trailingSystemImage: String? = nil, onTrailingTap: (() -> Void)? = nil, isTrailingDisabled: Bool = false, isDark: Bool = false, capsuleColor: Color, textColor: Color, circleFill: Color, iconColor: Color, cursorColor: Color) -> some View {
        let hasTrailingIcon = trailingSystemImage != nil && onTrailingTap != nil
        let hasTrailingReset = showReset && onReset != nil
        let hasTrailing = hasTrailingIcon || hasTrailingReset
        let trailingPadding: CGFloat = hasTrailing ? (hasTrailingIcon ? 52 : 56) : 20
        let field = TextField("", text: text)
            .textContentType(.URL)
            .keyboardType(.URL)
            .autocapitalization(.none)
            .tint(cursorColor)
            .padding(.leading, 52)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        return Group {
            if #available(iOS 26.0, *) {
                field
                    .glassEffect(.regular.tint(capsuleColor).interactive(), in: Capsule())
                    .foregroundStyle(textColor)
            } else {
                field
                    .background(capsuleColor, in: Capsule())
                    .foregroundStyle(textColor)
            }
        }
        .tint(cursorColor)
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                if let asset = leadingAssetName {
                    Image(asset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: kDeveloperMenuCircleAssetIconSide, height: kDeveloperMenuCircleAssetIconSide)
                        .foregroundStyle(iconColor)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: kDeveloperMenuCircleSFSymbolPointSize, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .overlay(alignment: .leading) {
            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(textColor)
                    .padding(.leading, 52)
                    .padding(.trailing, trailingPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if let img = trailingSystemImage, let action = onTrailingTap {
                Button(action: action) {
                    ZStack {
                        Circle().fill(circleFill)
                        Image(systemName: img)
                            .font(.system(size: kDeveloperMenuCircleSFSymbolPointSize, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .opacity(isTrailingDisabled ? 0.5 : 1)
                .disabled(isTrailingDisabled)
            } else if hasTrailingReset, let action = onReset {
                Button(action: action) {
                    Text(isEnglish ? "Reset" : "Сброс")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
        }
    }
}

// MARK: - Поля «Редактирование профиля» (капсулы как блок «Скачать по ссылке»)
private enum EditProfileCapsuleFieldMode {
    case username
    case displayName
    case bio
    case socialLink
}

@ViewBuilder
private func editProfileCapsuleField(
    placeholder: String,
    text: Binding<String>,
    systemImage: String,
    isDark: Bool,
    accent: Color,
    mode: EditProfileCapsuleFieldMode
) -> some View {
    let capsuleColor = isDark ? accent : Color.white
    let textColor = isDark ? Color.white : accent
    let circleFill = isDark ? Color.white : accent
    let iconColor = isDark ? accent : Color.white
    let cursorColor = isDark ? Color.white : accent
    let trailingPadding: CGFloat = 20
    let verticalPad: CGFloat = 14

    let styledCore = Group {
        switch mode {
        case .username:
            TextField("", text: text)
                .textContentType(.username)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .displayName:
            TextField("", text: text)
                .textContentType(.name)
        case .bio:
            TextField("", text: text)
        case .socialLink:
            TextField("", text: text)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
    .font(.system(size: 17, weight: .semibold))
    .tint(cursorColor)
    .padding(.leading, 52)
    .padding(.trailing, trailingPadding)
    .padding(.vertical, verticalPad)
    .frame(maxWidth: .infinity, alignment: .leading)

    Group {
        if #available(iOS 26.0, *) {
            styledCore
                .glassEffect(.regular.tint(capsuleColor).interactive(), in: Capsule())
                .foregroundStyle(textColor)
        } else {
            styledCore
                .background(capsuleColor, in: Capsule())
                .foregroundStyle(textColor)
        }
    }
    .tint(cursorColor)
    .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
    .overlay(alignment: .leading) {
        ZStack {
            Circle().fill(circleFill)
            Image(systemName: systemImage)
                .font(.system(size: kDeveloperMenuCircleSFSymbolPointSize, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: 32, height: 32)
        .padding(.leading, 6)
    }
    .overlay(alignment: .leading) {
        if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(placeholder)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.leading, 52)
                .padding(.trailing, trailingPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        }
    }
}

/// Ключ UserDefaults для ссылки на соцсеть (экран редактирования → экран профиля).
let sphereEditProfileSocialLinkDefaultsKey = "sphere_edit_profile_social_link"

// MARK: - Редактирование профиля (хром как у меню разработчика)
struct EditProfileMenuView: View {
    let resolvedColorSchemeFromMainApp: ColorScheme
    let isEnglish: Bool
    let onDismiss: () -> Void

    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: String = ""
    @StateObject private var authService = AuthService.shared
    @State private var scrollOffset: CGFloat = 0
    @State private var editUsername: String = ""
    @State private var editNickname: String = ""
    @State private var editBio: String = ""
    @State private var editSocialLink: String = ""
    @State private var showAvatarPicker = false
    @State private var avatarColorIndex = 0
    @State private var customAvatarImage: UIImage?
    @State private var showGalleryPicker = false
    @State private var triggerAvatarPickerDismiss = false

    private var accent: Color { Color("AccentColor") }

    private var appliedColorSchemeForMenu: ColorScheme {
        switch preferredColorSchemeRaw {
        case "dark": return .dark
        case "light": return .light
        default: return resolvedColorSchemeFromMainApp
        }
    }

    private var isDark: Bool { appliedColorSchemeForMenu == .dark }
    private var screenBackground: Color { isDark ? .black : Color(.systemBackground) }
    private let blurBottomGutter: CGFloat = 10
    private let closeButtonSide: CGFloat = 56
    private let closeButtonTrailingPadding: CGFloat = 12
    private var blurBottomCornerRadius: CGFloat { closeButtonSide / 2 + closeButtonTrailingPadding }
    private let scrollRevealInset: CGFloat = 4
    private var topBlurVisible: Bool { scrollOffset >= scrollRevealInset }
    private var barTitle: String { isEnglish ? "Edit profile" : "Редактирование профиля" }

    private let avatarSide: CGFloat = 104

    private var editProfileAvatarPickerPalette: [Color] {
        [
            accent,
            Color(red: 0.2, green: 0.5, blue: 1),
            Color(red: 0.2, green: 0.75, blue: 0.4),
            Color(red: 1, green: 0.5, blue: 0.2),
            Color(red: 0.95, green: 0.3, blue: 0.35),
            Color(red: 0.95, green: 0.4, blue: 0.7),
            Color(red: 0.2, green: 0.7, blue: 0.75),
            .black
        ]
    }

    private var useSheetForAvatarPicker: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private var profileDataSectionTitle: String { isEnglish ? "Profile data" : "Данные профиля" }
    private var bioSectionTitle: String { isEnglish ? "About" : "О себе" }
    private var customizationSectionTitle: String { isEnglish ? "Customization" : "Кастомизация" }
    private var phUsername: String { isEnglish ? "Username" : "Никнейм" }
    private var phDisplayName: String { isEnglish ? "Display name" : "Отображаемое имя" }
    private var phBio: String { isEnglish ? "Tell about yourself" : "Несколько слов о себе" }
    private var phSocial: String { isEnglish ? "Link to social network" : "Ссылка на социальную сеть" }
    private var profileBackgroundButtonTitle: String { isEnglish ? "Profile background" : "Фон профиля" }
    private var videoBackgroundButtonTitle: String { isEnglish ? "Video background" : "Видео фон" }

    var body: some View {
        screenBackground
            .ignoresSafeArea()
            .preferredColorScheme(appliedColorSchemeForMenu)
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    let barTotalHeight = geo.safeAreaInsets.top + closeButtonSide + blurBottomGutter
                    ZStack(alignment: .top) {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 12) {
                                Group {
                                    if #available(iOS 18.0, *) {
                                        Color.clear.frame(height: 0)
                                    } else {
                                        DevMenuScrollOffsetUIKitReader(offsetY: $scrollOffset)
                                            .frame(width: 1, height: 1)
                                            .allowsHitTesting(false)
                                    }
                                }
                                Spacer().frame(height: barTotalHeight + scrollRevealInset)

                                VStack(spacing: 20) {
                                    Button {
                                        syncAvatarPickerFromProfile()
                                        showAvatarPicker = true
                                    } label: {
                                        ProfileAvatarCoreView(profile: authService.currentProfile, side: avatarSide, accent: accent)
                                            .clipShape(Circle())
                                            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
                                            .frame(width: avatarSide, height: avatarSide)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity)

                                    editProfileSectionHeader(profileDataSectionTitle)
                                    editProfileFieldsCard(isDark: isDark) {
                                        VStack(spacing: 14) {
                                            editProfileCapsuleField(
                                                placeholder: phDisplayName,
                                                text: $editNickname,
                                                systemImage: "person.fill",
                                                isDark: isDark,
                                                accent: accent,
                                                mode: .displayName
                                            )
                                            editProfileCapsuleField(
                                                placeholder: phUsername,
                                                text: $editUsername,
                                                systemImage: "at",
                                                isDark: isDark,
                                                accent: accent,
                                                mode: .username
                                            )
                                        }
                                    }

                                    editProfileSectionHeader(bioSectionTitle)
                                    editProfileFieldsCard(isDark: isDark) {
                                        VStack(spacing: 14) {
                                            editProfileCapsuleField(
                                                placeholder: phBio,
                                                text: $editBio,
                                                systemImage: "text.alignleft",
                                                isDark: isDark,
                                                accent: accent,
                                                mode: .bio
                                            )
                                            editProfileCapsuleField(
                                                placeholder: phSocial,
                                                text: $editSocialLink,
                                                systemImage: "link",
                                                isDark: isDark,
                                                accent: accent,
                                                mode: .socialLink
                                            )
                                        }
                                    }

                                    editProfileSectionHeader(customizationSectionTitle)
                                    editProfileFieldsCard(isDark: isDark) {
                                        VStack(spacing: 14) {
                                            editProfileStubCapsuleButton(
                                                title: profileBackgroundButtonTitle,
                                                systemImage: "photo.on.rectangle.angled"
                                            )
                                            editProfileStubCapsuleButton(
                                                title: videoBackgroundButtonTitle,
                                                systemImage: "play.rectangle.fill"
                                            )
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)

                                Color.clear
                                    .frame(minHeight: max(geo.size.height * 0.35, 120))
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(.bottom, 36)
                        }
                        .scrollContentBackground(.hidden)
                        .background(screenBackground)
                        .modifier(DeveloperMenuLiveScrollModifier(scrollY: $scrollOffset))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        editProfileTopBlurBar(
                            safeAreaTop: geo.safeAreaInsets.top,
                            totalHeight: barTotalHeight,
                            bottomGutter: blurBottomGutter,
                            showTopBlurStrip: topBlurVisible
                        )
                        .zIndex(1)
                    }
                    .ignoresSafeArea(edges: .top)
                }
            }
            .overlay {
                if showAvatarPicker && !useSheetForAvatarPicker {
                    AvatarPickerCardView(
                        avatarColorIndex: $avatarColorIndex,
                        isPresented: $showAvatarPicker,
                        customAvatarImage: $customAvatarImage,
                        pickerColors: editProfileAvatarPickerPalette,
                        accent: accent,
                        isEnglish: isEnglish,
                        showGalleryPicker: $showGalleryPicker,
                        triggerDismiss: $triggerAvatarPickerDismiss,
                        onDismissCompleted: { triggerAvatarPickerDismiss = false }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                }
            }
            .sheet(isPresented: Binding(
                get: { showAvatarPicker && useSheetForAvatarPicker },
                set: { showAvatarPicker = $0 }
            )) {
                if #available(iOS 26.0, *) {
                    AvatarPickerSheet(
                        avatarColorIndex: $avatarColorIndex,
                        isPresented: $showAvatarPicker,
                        customAvatarImage: $customAvatarImage,
                        pickerColors: editProfileAvatarPickerPalette,
                        accent: accent,
                        isEnglish: isEnglish
                    )
                }
            }
            .fullScreenCover(isPresented: $showGalleryPicker) {
                PhotoLibraryPicker { image in
                    showGalleryPicker = false
                    if let image {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let cropped = AvatarPickerSheet.cropImageToSquare(image)
                            DispatchQueue.main.async {
                                customAvatarImage = cropped
                                avatarColorIndex = 7
                                triggerAvatarPickerDismiss = true
                            }
                        }
                    }
                }
            }
            .onAppear {
                syncFieldsFromProfile()
                syncAvatarPickerFromProfile()
            }
            .onChange(of: showAvatarPicker) { isOpen in
                guard !isOpen else { return }
                Task { await commitAvatarSelection() }
            }
    }

    private func editProfileSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isDark ? .white : accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .padding(.trailing, 12)
    }

    private func editProfileFieldsCard<Content: View>(isDark: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(isDark ? Color(white: 0.12) : Color(white: 0.92))
        )
        .padding(.horizontal, 12)
    }

    private func syncFieldsFromProfile() {
        if let p = authService.currentProfile {
            editNickname = p.nickname
            editUsername = p.username
            editBio = p.bio ?? ""
        }
        editSocialLink = UserDefaults.standard.string(forKey: sphereEditProfileSocialLinkDefaultsKey) ?? ""
    }

    private func syncAvatarPickerFromProfile() {
        guard let url = authService.currentProfile?.avatarUrl else {
            avatarColorIndex = 0
            customAvatarImage = nil
            return
        }
        if let idx = SphereProfileAvatarPalette.presetIndex(from: url) {
            avatarColorIndex = idx
            customAvatarImage = nil
        } else {
            avatarColorIndex = 7
            customAvatarImage = nil
        }
    }

    private func commitAvatarSelection() async {
        guard authService.isSignedIn else { return }
        if avatarColorIndex < 7 {
            let newUrl = SphereProfileAvatarPalette.presetURL(for: avatarColorIndex)
            if authService.currentProfile?.avatarUrl != newUrl {
                await authService.updateProfile(nickname: nil, username: nil, bio: nil, avatarUrl: newUrl, updateBio: false)
            }
            customAvatarImage = nil
        } else if let img = customAvatarImage {
            await authService.updateProfileAvatar(image: img)
            customAvatarImage = nil
        }
    }

    private func commitTextFields() async {
        let u = editUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = editNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = editBio.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(editSocialLink, forKey: sphereEditProfileSocialLinkDefaultsKey)
        await authService.updateProfile(
            nickname: n,
            username: u,
            bio: b.isEmpty ? nil : b,
            avatarUrl: nil,
            updateBio: true
        )
    }

    @ViewBuilder
    private func editProfileStubCapsuleButton(title: String, systemImage: String, action: @escaping () -> Void = {}) -> some View {
        let capsuleColor = isDark ? accent : Color.white
        let textColor = isDark ? Color.white : accent
        let circleFill = isDark ? Color.white : accent
        let iconColor = isDark ? accent : Color.white

        /// Высота и ширина как у `editProfileCapsuleField` (`vertical` 14); текст по центру капсулы, иконка поверх слева.
        let label = Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                HStack(spacing: 0) {
                    ZStack {
                        Circle().fill(circleFill)
                        Image(systemName: systemImage)
                            .font(.system(size: kDeveloperMenuCircleSFSymbolPointSize, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                    .frame(width: 32, height: 32)
                    .padding(.leading, 6)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)

        Group {
            if #available(iOS 26.0, *) {
                label
                    .glassEffect(.regular.tint(capsuleColor).interactive(), in: Capsule())
                    .foregroundStyle(textColor)
            } else {
                label
                    .background(capsuleColor, in: Capsule())
                    .foregroundStyle(textColor)
            }
        }
        .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
    }

    private func saveEditsAndDismiss() async {
        await commitTextFields()
        onDismiss()
    }

    private func editProfileTopBlurBarShape() -> UnevenRoundedRectangle {
        let r = blurBottomCornerRadius
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: r,
                bottomTrailing: r,
                topTrailing: 0
            ),
            style: .circular
        )
    }

    @ViewBuilder
    private func editProfileTopBlurBar(safeAreaTop: CGFloat, totalHeight: CGFloat, bottomGutter: CGFloat, showTopBlurStrip: Bool) -> some View {
        ZStack(alignment: .top) {
            editProfileTopBlurBarShape()
                .fill(.ultraThinMaterial)
                .frame(height: totalHeight)
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(showTopBlurStrip ? 1 : 0)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Color.clear.frame(height: safeAreaTop)
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: closeButtonSide)
                    .overlay {
                        Text(barTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isDark ? .white : accent)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .trailing) {
                        Button {
                            Task { await saveEditsAndDismiss() }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: closeButtonSide, height: closeButtonSide)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CloseButtonGlassStyle(accent: accent))
                        .padding(.trailing, closeButtonTrailingPadding)
                    }
                Color.clear.frame(height: bottomGutter)
            }
            .frame(height: totalHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: showTopBlurStrip)
        .clipShape(editProfileTopBlurBarShape())
        .shadow(color: Color.black.opacity(showTopBlurStrip ? 0.06 : 0), radius: 2, x: 0, y: 1)
        .ignoresSafeArea(edges: .top)
    }
}
