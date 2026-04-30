//
//  SettingsDetailScreens.swift
//  Экраны «Оформление», «Другое», «Кастомизация» из настроек.
//

import SwiftUI
import UIKit

// MARK: - Оформление

struct SettingsAppearanceScreen: View {
    let accent: Color
    let isEnglish: Bool
    let resolvedColorSchemeFromMainApp: ColorScheme
    @AppStorage("playerStyleIndex") private var playerStyleIndex: Int = 0
    @AppStorage("enableCoverPaging") private var enableCoverPaging: Bool = true
    @AppStorage("enableRoundPlayerCover") private var enableRoundPlayerCover: Bool = false
    @AppStorage("enableCoverSeekAnimation") private var enableCoverSeekAnimation: Bool = false
    @AppStorage("coverSeekShakeDotIndex") private var coverSeekShakeDotIndex: Int = 0
    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: String = ""

    private var appliedColorScheme: ColorScheme {
        switch preferredColorSchemeRaw {
        case "dark": return .dark
        case "light": return .light
        default: return resolvedColorSchemeFromMainApp
        }
    }

    private var isDark: Bool { appliedColorScheme == .dark }
    private var screenBg: Color { isDark ? .black : Color(.systemBackground) }

    private var playerStyleTitle: String { isEnglish ? "Player style \(playerStyleIndex + 1)" : "Стиль плеера \(playerStyleIndex + 1)" }
    private var coverPagingTitle: String { isEnglish ? "Cover paging" : "Перелистывание обложки" }
    private var roundCoverTitle: String { isEnglish ? "Round cover" : "Круглая обложка" }
    private var coverSeekAnimationTitle: String { isEnglish ? "Cover animation on seek" : "Анимация обложки при перемотке" }

    private var themeButtonIcon: String {
        switch preferredColorSchemeRaw {
        case "": return "moon.fill"
        case "dark": return "sun.max.fill"
        case "light": return "circle.lefthalf.filled"
        default: return "moon.fill"
        }
    }

    private var themeButtonTitle: String {
        switch preferredColorSchemeRaw {
        case "": return isEnglish ? "Dark" : "Тёмная"
        case "dark": return isEnglish ? "Light" : "Светлая"
        case "light": return isEnglish ? "System" : "Системная"
        default: return isEnglish ? "Dark" : "Тёмная"
        }
    }

    private func toggleTheme() {
        withAnimation(.easeInOut(duration: 0.35)) {
            switch preferredColorSchemeRaw {
            case "": preferredColorSchemeRaw = "dark"
            case "dark": preferredColorSchemeRaw = "light"
            case "light": preferredColorSchemeRaw = ""
            default: preferredColorSchemeRaw = ""
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if #available(iOS 26.0, *) {
                    VStack(alignment: .leading, spacing: 12) {
                        DeveloperMenuPlayerStyleRowIOS26(
                            playerStyleIndex: $playerStyleIndex,
                            title: playerStyleTitle,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12
                        )
                        DeveloperMenuCoverPagingRowIOS26(
                            enableCoverPaging: $enableCoverPaging,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12,
                            title: coverPagingTitle
                        )
                        DeveloperMenuCoverSeekAnimationRowIOS26(
                            enableCoverSeekAnimation: $enableCoverSeekAnimation,
                            coverSeekShakeDotIndex: $coverSeekShakeDotIndex,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12,
                            title: coverSeekAnimationTitle,
                            isEnglish: isEnglish
                        )
                        DeveloperMenuRoundCoverRowIOS26(
                            enableRoundPlayerCover: $enableRoundPlayerCover,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12,
                            title: roundCoverTitle
                        )
                        InitialScreenStyleCapsuleIconButtonIOS26(
                            systemDark: isDark,
                            accent: accent,
                            systemImage: themeButtonIcon,
                            title: themeButtonTitle,
                            action: toggleTheme
                        )
                        .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(isDark ? Color(white: 0.12) : Color(white: 0.92))
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        DeveloperMenuPlayerStyleRowLegacy(
                            playerStyleIndex: $playerStyleIndex,
                            title: playerStyleTitle,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12
                        )
                        DeveloperMenuCoverPagingRowLegacy(
                            enableCoverPaging: $enableCoverPaging,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12,
                            title: coverPagingTitle
                        )
                        DeveloperMenuCoverSeekAnimationRowLegacy(
                            enableCoverSeekAnimation: $enableCoverSeekAnimation,
                            coverSeekShakeDotIndex: $coverSeekShakeDotIndex,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12,
                            title: coverSeekAnimationTitle,
                            isEnglish: isEnglish
                        )
                        DeveloperMenuRoundCoverRowLegacy(
                            enableRoundPlayerCover: $enableRoundPlayerCover,
                            isDark: isDark,
                            accent: accent,
                            horizontalPadding: 12,
                            title: roundCoverTitle
                        )
                        InitialScreenStyleCapsuleIconButtonLegacy(
                            systemDark: isDark,
                            accent: accent,
                            systemImage: themeButtonIcon,
                            title: themeButtonTitle,
                            action: toggleTheme
                        )
                        .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(isDark ? Color(white: 0.12) : Color(white: 0.92))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(screenBg)
        .navigationTitle(isEnglish ? "Appearance" : "Оформление")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(appliedColorScheme)
    }
}

// MARK: - Другое

struct SettingsOtherScreen: View {
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @AppStorage("isEnglish") private var isEnglishStorage: Bool = false
    @AppStorage("sphereStreamLossless") private var streamLossless: Bool = false
    @ObservedObject private var discord = DiscordRPC.shared
    var onAddMusic: () -> Void

    private var languageValue: String { isEnglishStorage ? "English" : "Русский" }
    private var addMusicTitle: String { isEnglish ? "Add music from device" : "Добавить музыку с устройства" }

    private var losslessTitle: String {
        let onWord = isEnglish ? "On" : "Вкл"
        let offWord = isEnglish ? "Off" : "Выкл"
        let label = isEnglish ? "Lossless audio" : "Lossless-аудио"
        return "\(label): \(streamLossless ? onWord : offWord)"
    }

    private var discordButtonTitle: String {
        if let name = discord.discordUsername {
            return "Discord: \(name)"
        }
        return isEnglish ? "Connect Discord" : "Подключить Discord"
    }
    private var discordDisconnectTitle: String { isEnglish ? "Disconnect Discord" : "Отключить Discord" }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if #available(iOS 26.0, *) {
                    Button { isEnglishStorage.toggle() } label: {
                        Text(languageValue)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "globe")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(isDarkMode ? accent : .white).interactive(), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    Button(action: onAddMusic) {
                        Text(addMusicTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(isDarkMode ? accent : .white).interactive(), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { streamLossless.toggle() }
                    } label: {
                        Text(losslessTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: streamLossless ? "waveform.badge.plus" : "waveform")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(isDarkMode ? accent : .white).interactive(), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    // Discord
                    Button {
                        if discord.discordUsername != nil {
                            discord.disconnect()
                        } else {
                            discord.authorize()
                        }
                    } label: {
                        Text(discordButtonTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(isDarkMode ? accent : .white).interactive(), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    if discord.discordUsername != nil {
                        Button { discord.disconnect() } label: {
                            Text(discordDisconnectTitle)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(Color.red.opacity(0.3)).interactive(), in: Capsule())
                        .foregroundStyle(.red)
                    }

                    if let status = discord.statusText {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button { isEnglishStorage.toggle() } label: {
                        Text(languageValue)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "globe")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .background((isDarkMode ? accent : .white), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    Button(action: onAddMusic) {
                        Text(addMusicTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .background((isDarkMode ? accent : .white), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { streamLossless.toggle() }
                    } label: {
                        Text(losslessTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: streamLossless ? "waveform.badge.plus" : "waveform")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .background((isDarkMode ? accent : .white), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    // Discord
                    Button {
                        if discord.discordUsername != nil {
                            discord.disconnect()
                        } else {
                            discord.authorize()
                        }
                    } label: {
                        Text(discordButtonTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .background((isDarkMode ? accent : .white), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    if discord.discordUsername != nil {
                        Button { discord.disconnect() } label: {
                            Text(discordDisconnectTitle)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                    }

                    if let status = discord.statusText {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
        .background(isDarkMode ? Color.black : Color(.systemBackground))
        .navigationTitle(isEnglish ? "Other" : "Другое")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Кастомизация (цвет приложения)

struct SettingsCustomizationScreen: View {
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @AppStorage("sphereUseCustomAccent") private var useCustomAccent: Bool = false
    @AppStorage("sphereAccentR") private var accentR: Double = 217.0 / 255.0
    @AppStorage("sphereAccentG") private var accentG: Double = 252.0 / 255.0
    @AppStorage("sphereAccentB") private var accentB: Double = 1.0
    @State private var pickerUIColor: UIColor = .systemPurple
    @State private var showColorPicker = false

    private var title: String { isEnglish ? "Customization" : "Кастомизация" }
    private var pickTitle: String { isEnglish ? "App accent color" : "Цвет акцента приложения" }
    private var resetTitle: String { isEnglish ? "Reset to default" : "Сбросить к стандартному" }
    private var pickerSheetTitle: String { isEnglish ? "Accent color" : "Цвет акцента" }
    private var doneTitle: String { isEnglish ? "Done" : "Готово" }
    private var cancelTitle: String { isEnglish ? "Cancel" : "Отмена" }

    /// Превью: при открытом пикере показываем выбранный цвет в реальном времени.
    private var accentPreviewFill: Color {
        if showColorPicker {
            return Color(uiColor: pickerUIColor)
        }
        if useCustomAccent {
            return Color(red: accentR, green: accentG, blue: accentB)
        }
        return accent
    }

    private func commitSelectedAccent() {
        let c = pickerUIColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if c.getRed(&r, green: &g, blue: &b, alpha: &a) {
            accentR = Double(r)
            accentG = Double(g)
            accentB = Double(b)
        } else if let comp = c.cgColor.components, comp.count >= 3 {
            accentR = Double(comp[0])
            accentG = Double(comp[1])
            accentB = Double(comp[2])
        }
        useCustomAccent = true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if #available(iOS 26.0, *) {
                    Button {
                        pickerUIColor = UIColor(red: accentR, green: accentG, blue: accentB, alpha: 1)
                        showColorPicker = true
                    } label: {
                        Text(pickTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "paintpalette.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(isDarkMode ? accent : .white).interactive(), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .shadow(color: isDarkMode ? .clear : Color.black.opacity(0.20), radius: 18, x: 0, y: 8)

                    Button {
                        useCustomAccent = false
                    } label: {
                        Text(resetTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(isDarkMode ? accent : .white).interactive(), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                } else {
                    Button {
                        pickerUIColor = UIColor(red: accentR, green: accentG, blue: accentB, alpha: 1)
                        showColorPicker = true
                    } label: {
                        Text(pickTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(isDarkMode ? .white : accent)
                                    Image(systemName: "paintpalette.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? accent : .white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .background((isDarkMode ? accent : .white), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)

                    Button { useCustomAccent = false } label: {
                        Text(resetTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .background((isDarkMode ? accent : .white), in: Capsule())
                    .foregroundStyle(isDarkMode ? .white : accent)
                }

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accentPreviewFill)
                    .frame(height: 44)
                    .overlay {
                        Text(isEnglish ? "Preview" : "Превью")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
        .background(isDarkMode ? Color.black : Color(.systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showColorPicker) {
            NavigationStack {
                AppAccentUIColorPickerSheet(
                    isPresented: $showColorPicker,
                    selectedUIColor: $pickerUIColor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(pickerSheetTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelTitle) {
                            showColorPicker = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(doneTitle) {
                            commitSelectedAccent()
                            showColorPicker = false
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }
}
