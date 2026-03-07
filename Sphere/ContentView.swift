//
//  ContentView.swift
//  Sphere
//
//  Created by Evgeniy on 01.03.2026.
//

import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import MediaPlayer
import CoreImage
import Combine
import ImageIO

/// Фиолетовый акцент приложения — из Assets (AccentColor), как на иконке
private var sphereAccent: Color { Color("AccentColor") }

/// URL API для конвертации Spotify → MP3. Для всех пользователей: задеплойте api на Render.com (см. api/README.md), подставьте сюда ваш URL, например https://sphere-spotify-api.onrender.com/api?url=
private let spotifyToMp3APIBaseURL: String = "https://sphere-spotify-api.onrender.com/api?url="

/// Ячейка для сброса при перетаскивании: сначала точное попадание, затем расширенная зона, затем ближайшая по центру
private func resolveDropTargetId(for pos: CGPoint, frames: [UUID: CGRect], excluding excludedId: UUID) -> UUID? {
    if let id = frames.first(where: { $0.key != excludedId && $0.value.contains(pos) })?.key { return id }
    let expanded = frames.mapValues { $0.insetBy(dx: -40, dy: -40) }
    if let id = expanded.first(where: { $0.key != excludedId && $0.value.contains(pos) })?.key { return id }
    func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let c = CGPoint(x: r.midX, y: r.midY)
        return hypot(p.x - c.x, p.y - c.y)
    }
    return frames
        .filter { $0.key != excludedId }
        .min(by: { dist(pos, $0.value) < dist(pos, $1.value) })?
        .key
}

/// URL обложки для трека (если был сохранён при импорте): тот же путь, расширение .jpg
private func coverImageURL(for track: AppTrack) -> URL {
    track.url.deletingPathExtension().appendingPathExtension("jpg")
}

/// Максимальный размер стороны обложки в пикселях для UI (мини + герой). Снижает лаги анимации.
private let coverDisplayMaxPixelSize: CGFloat = 640

/// Загружает обложку из папки приложения с даунсемплингом до display size (без полного декода большого JPEG).
private func loadCoverImage(for track: AppTrack) -> UIImage? {
    let url = coverImageURL(for: track)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: coverDisplayMaxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
    }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
}

/// Цвет иконки на кнопке: чёрный на светлом фоне, белый на тёмном.
private func iconColor(onBackground background: Color) -> Color {
    let ui = UIColor(background)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    return luminance > 0.5 ? Color.black : Color.white
}

/// Акцент для кнопок и ползунков с учётом темы: на светлой теме — темнее, на тёмной — светлее, чтобы элементы были хорошо видны.
private func accentForTheme(_ color: Color, isDarkTheme: Bool) -> Color {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    if isDarkTheme {
        if luminance < 0.45 {
            let add = 0.5 - luminance
            return Color(red: Double(min(r + add, 1)), green: Double(min(g + add, 1)), blue: Double(min(b + add, 1)))
        }
        return color
    } else {
        if luminance > 0.55 {
            return Color(red: Double(r * 0.42), green: Double(g * 0.42), blue: Double(b * 0.42))
        }
        return color
    }
}

/// Акцент считается светлым/белым, если яркость высокая — тогда второстепенный цвет на светлой теме делаем чёрным.
private func isAccentLight(_ color: Color) -> Bool {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    return luminance >= 0.82
}

/// Наблюдатель текущего аудио-маршрута: если звук идёт на AirPods/Bluetooth — показываем иконку airpods.
final class AudioRouteObserver: ObservableObject {
    @Published private(set) var isOutputBluetooth: Bool = false

    private var cancellable: AnyCancellable?

    init() {
        updateFromSession()
        cancellable = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFromSession() }
    }

    private func updateFromSession() {
        let session = AVAudioSession.sharedInstance()
        let isBluetooth = session.currentRoute.outputs.contains { desc in
            switch desc.portType {
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return true
            default: return false
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.isOutputBluetooth = isBluetooth
        }
    }
}

/// Системный пикер выбора AirPlay/Bluetooth — по нажатию показывается меню выбора устройства. Кнопка системы скрыта (tint .clear), сверху рисуется своя иконка.
private struct AirPlayRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let picker = AVRoutePickerView()
        picker.backgroundColor = .clear
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? AVRoutePickerView)?.tintColor = .clear
        (uiView as? AVRoutePickerView)?.activeTintColor = .clear
    }
}

/// Базовый цвет фона с оттенком акцента: тёмный для тёмной темы, светлый для светлой.
private func gradientBaseTint(accent: Color, isDarkTheme: Bool) -> Color {
    let ui = UIColor(accent)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    if isDarkTheme {
        let scale: CGFloat = 0.22
        return Color(red: Double(min(r * scale, 1)), green: Double(min(g * scale, 1)), blue: Double(min(b * scale, 1)))
    } else {
        let grayPart: CGFloat = 0.78
        let tintPart: CGFloat = 0.22
        return Color(
            red: Double(min(grayPart + r * tintPart, 1)),
            green: Double(min(grayPart + g * tintPart, 1)),
            blue: Double(min(grayPart + b * tintPart, 1))
        )
    }
}

/// Доминантный цвет изображения (усреднённый) для градиента.
private func dominantColor(from image: UIImage) -> Color? {
    guard let ciImage = CIImage(image: image) else { return nil }
    let extent = ciImage.extent
    guard !extent.isEmpty else { return nil }
    let filter = CIFilter(name: "CIAreaAverage")
    filter?.setValue(ciImage, forKey: kCIInputImageKey)
    filter?.setValue(CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height), forKey: kCIInputExtentKey)
    guard let out = filter?.outputImage else { return nil }
    let ctx = CIContext()
    var pixel: [UInt8] = [0, 0, 0, 0]
    ctx.render(out, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
}

/// Обложка трека: загружается из .jpg рядом с файлом или плейсхолдер.
private struct TrackCoverView: View {
    let track: AppTrack
    let accent: Color
    var cornerRadius: CGFloat = 20
    var placeholderPadding: CGFloat = 10

    @State private var loadedImage: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(accent)
                .aspectRatio(1, contentMode: .fit)

            if let img = loadedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image("Voxmusic")
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .padding(placeholderPadding)
            }
        }
        .onAppear {
            if loadedImage == nil {
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = loadCoverImage(for: track)
                    DispatchQueue.main.async { loadedImage = img }
                }
            }
        }
        .onChange(of: track.id) { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = loadCoverImage(for: track)
                DispatchQueue.main.async { loadedImage = img }
            }
        }
    }
}

/// PreferenceKey для передачи frame мини-обложки в глобальных координатах (для hero-анимации).
private struct MiniCoverFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Позиция большой обложки в overlay. На iOS 26 — выше (24 + safeTop), на 18 — как раньше.
private func heroBigFrame(overlayWidth: CGFloat, safeTop: CGFloat) -> CGRect {
    let bigSize = min(overlayWidth - 48, 320)
    let x = (overlayWidth - bigSize) / 2
    if #available(iOS 26.0, *) {
        return CGRect(x: x, y: 24 + safeTop, width: bigSize, height: bigSize)
    } else {
        return CGRect(x: x, y: 56 + safeTop - 5, width: bigSize, height: bigSize)
    }
}

/// Fallback-прямоугольник для мини-обложки в глобальных координатах (для hero). На iOS 26 — под бар с offset -62.
private func heroMiniFallbackFrame(overlayGlobal: CGRect) -> CGRect {
    let miniSize: CGFloat = 40
    let barLeftInset: CGFloat = 28
    if #available(iOS 26.0, *) {
        let barCenterFromBottomIOS26: CGFloat = 94
        return CGRect(
            x: overlayGlobal.minX + barLeftInset,
            y: overlayGlobal.maxY - barCenterFromBottomIOS26 - miniSize / 2,
            width: miniSize,
            height: miniSize
        )
    } else {
        let barCenterFromBottom: CGFloat = 143
        return CGRect(
            x: overlayGlobal.minX + barLeftInset,
            y: overlayGlobal.maxY - barCenterFromBottom - miniSize / 2,
            width: miniSize,
            height: miniSize
        )
    }
}

/// Одна обложка для hero-анимации. Рисуется в одном размере; снаружи анимируют только scale и position (фиолет и картинка в sync).
private struct HeroCoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    let image: UIImage?
    let accent: Color
    let size: CGSize
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(accent)
            .frame(width: size.width, height: size.height)
            .overlay(
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    } else {
                        Image("Voxmusic")
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                            .padding(size.width > 60 ? 24 : 4)
                    }
                }
            )
            .compositingGroup()
            .drawingGroup(opaque: false)
            .shadow(color: colorScheme == .light ? .black.opacity(0.28) : .clear, radius: 20, x: 0, y: 10)
    }
}

/// Overlay с hero-обложкой (уменьшает сложность type-check в MainAppView.body).
private struct HeroCoverOverlayView: View {
    let isPlayerSheetPresented: Bool
    let isPlayerSheetClosing: Bool
    let playerDragOffset: CGFloat
    let miniCoverFrame: CGRect
    let onCloseAnimationDidEnd: () -> Void
    let currentCoverImage: UIImage?
    let accent: Color
    @ObservedObject var playbackHolder: PlaybackStateHolder
    private static let playerSheetAnimation: Animation = .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.38)

    var body: some View {
        GeometryReader { g in
            let overlayGlobal = g.frame(in: .global)
            let bigSize = min(g.size.width - 48, 320)
            let safeTop = g.safeAreaInsets.top
            let bigFrame = heroBigFrame(overlayWidth: g.size.width, safeTop: safeTop)
            let miniFrame = miniCoverFrame.isEmpty ? heroMiniFallbackFrame(overlayGlobal: overlayGlobal) : miniCoverFrame

            if #available(iOS 26.0, *) {
                if isPlayerSheetPresented || isPlayerSheetClosing {
                    let miniFrameLocal = CGRect(
                        x: miniFrame.minX - overlayGlobal.minX,
                        y: miniFrame.minY - overlayGlobal.minY,
                        width: miniFrame.width,
                        height: miniFrame.height
                    )
                    HeroCoverOverlayContentIOS26(
                        miniFrame: miniFrameLocal,
                        bigFrame: bigFrame,
                        playerDragOffset: playerDragOffset,
                        isClosing: isPlayerSheetClosing,
                        onCloseComplete: onCloseAnimationDidEnd,
                        currentCoverImage: currentCoverImage,
                        accent: accent,
                        playbackHolder: playbackHolder
                    )
                } else {
                    Color.clear
                }
            } else {
                let bigSize = bigFrame.size
                let minScale = min(miniFrame.width / bigSize.width, miniFrame.height / bigSize.height)
                let scale: CGFloat = isPlayerSheetPresented ? (playbackHolder.isPlaying ? 1.06 : 0.92) : minScale
                let posX = isPlayerSheetPresented ? bigFrame.midX : (miniFrame.midX - overlayGlobal.minX)
                let posY = isPlayerSheetPresented ? bigFrame.midY + playerDragOffset : (miniFrame.midY - overlayGlobal.minY)

                HeroCoverView(image: currentCoverImage, accent: accent, size: bigSize, cornerRadius: 36)
                    .scaleEffect(scale)
                    .animation(.spring(response: 0.52, dampingFraction: 0.68), value: playbackHolder.isPlaying)
                    .position(x: posX, y: posY)
            }
        }
        .allowsHitTesting(false)
        .animation(Self.playerSheetAnimation, value: isPlayerSheetPresented)
        .animation(Self.playerSheetAnimation, value: playerDragOffset)
    }
}

/// Герой при открытом sheet на iOS 26: одна обложка в большом размере, анимация только scale + position (фиолет и картинка не рассинхронятся).
@available(iOS 26.0, *)
private struct HeroCoverOverlayContentIOS26: View {
    let miniFrame: CGRect
    let bigFrame: CGRect
    let playerDragOffset: CGFloat
    let isClosing: Bool
    let onCloseComplete: () -> Void
    let currentCoverImage: UIImage?
    let accent: Color
    @ObservedObject var playbackHolder: PlaybackStateHolder
    private static let playerSheetAnimation: Animation = .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.38)
    private static let closeDuration: Double = 0.38

    @State private var openProgress: CGFloat = 0

    var body: some View {
        let minScale = min(miniFrame.width / bigFrame.width, miniFrame.height / bigFrame.height)
        let baseScale = openProgress * (1 - minScale) + minScale
        let scale = baseScale * (openProgress > 0.01 ? (playbackHolder.isPlaying ? 1.06 : 0.92) : 1)
        let posX = miniFrame.midX + (bigFrame.midX - miniFrame.midX) * openProgress
        let posY = miniFrame.midY + (bigFrame.midY - miniFrame.midY) * openProgress + playerDragOffset

        HeroCoverView(image: currentCoverImage, accent: accent, size: bigFrame.size, cornerRadius: 36)
            .scaleEffect(scale)
            .animation(.spring(response: 0.52, dampingFraction: 0.68), value: playbackHolder.isPlaying)
            .position(x: posX, y: posY)
            .onAppear {
                if isClosing {
                    openProgress = 1
                    withAnimation(Self.playerSheetAnimation) { openProgress = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration) {
                        onCloseComplete()
                    }
                } else {
                    openProgress = 0
                    DispatchQueue.main.async {
                        withAnimation(Self.playerSheetAnimation) { openProgress = 1 }
                    }
                }
            }
            .onChange(of: isClosing) { newClosing in
                if newClosing {
                    withAnimation(Self.playerSheetAnimation) { openProgress = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration) {
                        onCloseComplete()
                    }
                } else {
                    openProgress = 0
                    DispatchQueue.main.async {
                        withAnimation(Self.playerSheetAnimation) { openProgress = 1 }
                    }
                }
            }
    }
}

private func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    let x = a.minX + (b.minX - a.minX) * t
    let y = a.minY + (b.minY - a.minY) * t
    let w = a.width + (b.width - a.width) * t
    let h = a.height + (b.height - a.height) * t
    return CGRect(x: x, y: y, width: w, height: h)
}

/// Обложка 40×40 для мини-плеера (только iOS 18 и ниже; на iOS 26 не используется).
private struct MiniPlayerCoverView: View {
    let track: AppTrack
    let accent: Color
    @State private var loadedImage: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(accent)
            .frame(width: 40, height: 40)
            .overlay(
                Group {
                    if let img = loadedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image("Voxmusic")
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(4)
                    }
                }
            )
            .onAppear {
                if loadedImage == nil {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let img = loadCoverImage(for: track)
                        DispatchQueue.main.async { loadedImage = img }
                    }
                }
            }
            .onChange(of: track.id) { _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = loadCoverImage(for: track)
                    DispatchQueue.main.async { loadedImage = img }
                }
            }
    }
}

/// Обложка мини-плеера для iOS 26: RoundedRectangle + overlay + shadow (на 18 и ниже не задействуется).
private struct MiniPlayerCoverViewIOS26: View {
    let track: AppTrack
    let accent: Color
    @State private var loadedImage: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(accent)
            .frame(width: 40, height: 40)
            .overlay(
                Group {
                    if let img = loadedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image("Voxmusic")
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(4)
                    }
                }
            )
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
            .onAppear {
                if loadedImage == nil {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let img = loadCoverImage(for: track)
                        DispatchQueue.main.async { loadedImage = img }
                    }
                }
            }
            .onChange(of: track.id) { _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = loadCoverImage(for: track)
                    DispatchQueue.main.async { loadedImage = img }
                }
            }
    }
}

/// Установка системной громкости через MPVolumeView (работает на устройстве)
private enum SystemVolume {
    /// Количество шагов громкости — слайдер и кнопки устройства двигаются равными делениями
    static let stepCount: Int = 16
    static var step: Double { 1.0 / Double(stepCount) }

    static func setVolume(_ value: Float) {
        let volumeView = MPVolumeView()
        guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            slider.value = value
        }
    }
    static func current() -> Float {
        AVAudioSession.sharedInstance().outputVolume
    }
    /// Округление до ближайшего шага (0, 1/16, 2/16, …, 1)
    static func stepped(_ value: Double) -> Double {
        let n = Double(stepCount)
        return (value * n).rounded() / n
    }
}

/// Режим кнопки повтора: конец (пауза), цикл (повтор трека), следующий трек
enum RepeatMode {
    case pauseAtEnd   // Конец — пауза при окончании
    case repeatOne    // Цикл включён — трек начинается заново
    case playNext     // Цикл выключен — следующий трек, если нет — пауза
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var colorSchemeOverride: ColorScheme? = nil
    @AppStorage("isEnglish") private var isEnglish = false
    @State private var showCreateAccount = false
    @State private var showSignIn = false
    /// После нажатия «Создать» в создании аккаунта — показываем главный экран приложения
    @AppStorage("isInApp") private var isInApp: Bool = false
    /// Фиксированный размер начального экрана (без клавиатуры), чтобы он не смещался при открытой клавиатуре в sheet
    @State private var loginScreenFixedSize: CGSize?

    /// Тема: по системе, если override == nil; иначе принудительно светлая или тёмная
    private var isDarkMode: Bool { (colorSchemeOverride ?? colorScheme) == .dark }

    private func toggleTheme() {
        switch colorSchemeOverride {
        case nil: colorSchemeOverride = .dark
        case .dark?: colorSchemeOverride = .light
        case .light?: colorSchemeOverride = nil
        @unknown default: colorSchemeOverride = nil
        }
    }

    /// Иконка кнопки темы = что будет при следующем нажатии: луна → тёмная, солнце → светлая, полукруг → система
    private var themeButtonIcon: String {
        switch colorSchemeOverride {
        case nil: return "moon.fill"           // сейчас система → след. нажатие: тёмная
        case .dark?: return "sun.max.fill"    // сейчас тёмная → след. нажатие: светлая
        case .light?: return "circle.lefthalf.filled"  // сейчас светлая → след. нажатие: система
        @unknown default: return "moon.fill"
        }
    }

    private var createAccountTitle: String { isEnglish ? "Create account" : "Создать аккаунт" }
    private var signInTitle: String { isEnglish ? "Sign in" : "Войти" }
    /// Надпись Sphere под иконкой — всегда на английском (Spheretextpurple)
    private let textImageName = "Spheretextpurple"
    private var subtitleText: String { isEnglish ? "Container for your music" : "Контейнер для вашей музыки" }

    /// Отступ снизу, чтобы кнопки «Войти»/«Создать аккаунт» не налезали на круглые кнопки
    private var bottomPaddingForMainButtons: CGFloat { 150 }

    @ViewBuilder
    private func roundGlassButton(systemImage: String, action: @escaping () -> Void) -> some View {
        let content = Image(systemName: systemImage)
            .font(.system(size: 22))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)

        if #available(iOS 26.0, *) {
            Button(action: action) {
                content
                    .glassEffect(.regular.tint(sphereAccent).interactive(), in: Circle())
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                content
                    .background(sphereAccent, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var glassButtons: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 14) {
                    Button(createAccountTitle) {
                        showCreateAccount = true
                    }
                        .buttonStyle(.glassProminent)
                        .tint(sphereAccent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                    Button(signInTitle) {
                        showSignIn = true
                    }
                        .buttonStyle(.glass)
                        .tint(sphereAccent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: 14) {
                Button(createAccountTitle) {
                    showCreateAccount = true
                }
                    .buttonStyle(GlassMaterialButtonStyle(accent: sphereAccent, prominent: true))
                    .frame(maxWidth: .infinity)

                Button(signInTitle) {
                    showSignIn = true
                }
                    .buttonStyle(GlassMaterialButtonStyle(accent: sphereAccent, prominent: false))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if isInApp {
                    MainAppView(onLogout: { isInApp = false })
                } else {
                    loginScreen
                        .frame(
                            width: loginScreenFixedSize?.width ?? geo.size.width,
                            height: loginScreenFixedSize?.height ?? geo.size.height
                        )
                }
            }
            .background(
                Group {
                    if !isInApp && !showCreateAccount && !showSignIn {
                        GeometryReader { g in
                            Color.clear
                                .onAppear { if loginScreenFixedSize == nil { loginScreenFixedSize = g.size } }
                        }
                    }
                }
            )
            .frame(
                minWidth: isInApp ? 0 : (loginScreenFixedSize?.width ?? 0),
                minHeight: isInApp ? 0 : (loginScreenFixedSize?.height ?? 0)
            )
        }
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(colorSchemeOverride)
        .fullScreenCover(isPresented: $showCreateAccount) {
            CreateAccountView(
                isPresented: $showCreateAccount,
                isEnglish: isEnglish,
                isDarkMode: isDarkMode,
                onAccountCreated: {
                    showCreateAccount = false
                    isInApp = true
                }
            )
        }
        .fullScreenCover(isPresented: $showSignIn) {
            SignInView(
                isPresented: $showSignIn,
                isEnglish: isEnglish,
                onSignIn: {
                    showSignIn = false
                    isInApp = true
                }
            )
        }
    }

    private var loginScreen: some View {
        ZStack {
            if isDarkMode {
                Color.black
                    .ignoresSafeArea()
            }
            Image(isDarkMode ? "DarkScreen" : "LightScreen")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 60)

                Image("Spherelogopurple")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .foregroundStyle(sphereAccent)

                Image(textImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 56)
                    .padding(.top, 24)

                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(sphereAccent)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                Spacer(minLength: 48)

                glassButtons
                    .padding(.horizontal, 32)
                    .padding(.bottom, bottomPaddingForMainButtons)
            }

            // Круглые кнопки: слева — тема, справа — язык
            VStack {
                Spacer()
                HStack {
                    roundGlassButton(systemImage: themeButtonIcon) {
                        toggleTheme()
                    }

                    Spacer()

                    roundGlassButton(systemImage: "globe") {
                        isEnglish.toggle()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard)
        .ignoresSafeArea(edges: .all)
    }
}

// Главное меню приложения: капсула внизу (как tab bar) с блюром, переключение тапом и свайпом
enum MainAppTab: Int {
    case home = 0
    case favorites = 1
    case settings = 2
}

/// Tab bar в стиле Telegram: капля с блюром (только iOS 18 и ниже; на iOS 26 не показывается).
private struct DropletTabBar: View {
    let homeTitle: String
    let settingsTitle: String
    let accent: Color
    @Binding var selectedTab: MainAppTab

    @State private var dragOffset: CGFloat = 0

    private let barHeight: CGFloat = 58
    private let iconSize: CGFloat = 24
    private let labelFontSize: CGFloat = 12
    private let innerInset: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let segmentWidth = (w - innerInset * 2) / 2
            let dropletWidth = segmentWidth + innerInset * 2
            let half = w / 2
            let homeDropletX = innerInset
            let settingsDropletX = innerInset + segmentWidth
            let baseX: CGFloat = selectedTab == .home ? homeDropletX : settingsDropletX
            let currentDropletX = baseX + dragOffset
            let effectiveDropletX = max(homeDropletX, min(settingsDropletX, currentDropletX))
            let effectiveTab: MainAppTab = (effectiveDropletX + dropletWidth / 2 < half) ? .home : .settings

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h / 2)
                    .fill(Color(UIColor.systemGray5))
                    .overlay(
                        RoundedRectangle(cornerRadius: h / 2)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                HStack(spacing: 0) {
                    tabItemGray(icon: "house.fill", label: homeTitle)
                    tabItemGray(icon: "gearshape.fill", label: settingsTitle)
                }
                .padding(.horizontal, innerInset)
                .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: (h - 6) / 2)
                    .fill(.ultraThinMaterial)
                    .frame(width: dropletWidth, height: h - 6)
                    .offset(x: effectiveDropletX)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation.width
                            }
                            .onEnded { _ in
                                let target: MainAppTab = (effectiveDropletX + dropletWidth / 2 < half) ? .home : .settings
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                    selectedTab = target
                                    dragOffset = 0
                                }
                            }
                    )

                Group {
                    if effectiveTab == .home {
                        dropletContentLabel(icon: "house.fill", label: homeTitle)
                    } else {
                        dropletContentLabel(icon: "gearshape.fill", label: settingsTitle)
                    }
                }
                .frame(width: segmentWidth, height: h - innerInset * 2)
                .offset(x: effectiveDropletX + innerInset)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let target: MainAppTab = location.x < half ? .home : .settings
                if target != selectedTab {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        selectedTab = target
                        dragOffset = 0
                    }
                }
            }
        }
        .frame(height: barHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabItemGray(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
            Text(label)
                .font(.system(size: labelFontSize, weight: .semibold))
        }
        .foregroundStyle(Color.primary.opacity(0.65))
        .frame(maxWidth: .infinity)
    }

    private func dropletContentLabel(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
            Text(label)
                .font(.system(size: labelFontSize, weight: .semibold))
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Элемент для сохранения в UserDefaults: только имя файла, чтобы после обновления приложения путь к контейнеру не ломался.
private struct StoredTrackItem: Codable {
    let id: UUID
    let pathComponent: String
    let title: String?
    let artist: String?
    let addedAt: Date?

    enum CodingKeys: String, CodingKey { case id, pathComponent, title, artist, addedAt }

    init(id: UUID, pathComponent: String, title: String?, artist: String?, addedAt: Date? = nil) {
        self.id = id
        self.pathComponent = pathComponent
        self.title = title
        self.artist = artist
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pathComponent = try c.decode(String.self, forKey: .pathComponent)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pathComponent, forKey: .pathComponent)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(addedAt, forKey: .addedAt)
    }
}

/// Описание трека, добавленного пользователем (название и исполнитель из метаданных при импорте).
private struct AppTrack: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var title: String?
    var artist: String?
    var addedAt: Date?

    enum CodingKeys: String, CodingKey { case id, url, title, artist, addedAt }

    init(id: UUID = UUID(), url: URL, title: String? = nil, artist: String? = nil, addedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(addedAt, forKey: .addedAt)
    }

    /// Название для отображения: из метаданных или имя файла.
    var displayTitle: String {
        let fromFile = url.deletingPathExtension().lastPathComponent
        if let t = title, !t.isEmpty { return t }
        return fromFile
    }

    /// Исполнитель для отображения.
    var displayArtist: String {
        artist ?? ""
    }

    static func == (lhs: AppTrack, rhs: AppTrack) -> Bool {
        lhs.url == rhs.url
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }

    @ViewBuilder
    func presentationCornerRadiusIfAvailable(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCornerRadius(radius)
        } else {
            self
        }
    }
}

/// На iOS 18 и ниже — плавное увеличение круглой кнопки при нажатии; на iOS 26 не применяется.
/// Если задан isDarkTheme — при нажатии кнопка светлеет (тёмная тема) или темнеет (светлая).
/// Масштаб ведётся через отдельное состояние, чтобы при коротком тапе всегда проигрывалась пружина «обратно».
private struct ScaleOnPressRoundButtonStyle: ButtonStyle {
    var isDarkTheme: Bool? = nil

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
            } else {
                ScalePressFeedbackView(isPressed: configuration.isPressed, isDarkTheme: isDarkTheme) {
                    configuration.label
                }
            }
        }
    }

    private func brightnessWhenPressed(_ pressed: Bool) -> Double {
        guard pressed, let dark = isDarkTheme else { return 0 }
        return dark ? 0.12 : -0.12
    }
}

/// Держит масштаб в состоянии; при отпускании всегда запускает пружину к 1, чтобы короткий тап был заметен.
private struct ScalePressFeedbackView<Label: View>: View {
    let isPressed: Bool
    let isDarkTheme: Bool?
    @ViewBuilder let label: () -> Label

    @State private var displayScale: CGFloat = 1

    private let pressScale: CGFloat = 1.26
    private func brightness() -> Double {
        guard isPressed, let dark = isDarkTheme else { return 0 }
        return dark ? 0.12 : -0.12
    }

    var body: some View {
        label()
            .scaleEffect(displayScale)
            .brightness(brightness())
            .onChange(of: isPressed) { newValue in
                if newValue {
                    withAnimation(.easeOut(duration: 0.1)) { displayScale = pressScale }
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { displayScale = 1 }
                }
            }
            .onAppear { displayScale = isPressed ? pressScale : 1 }
    }
}

/// Скругление только верхних углов — как в Apple Music.
private struct TopRoundedShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let tl = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tl, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Состояние воспроизведения вынесено в отдельный объект: обновляется таймером, наблюдается только мини-плеером и окном плеера, чтобы контент с контекстными меню не перерисовывался и не мигал.
private final class PlaybackStateHolder: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var isPlaying: Bool = false
    @Published var duration: TimeInterval = 0
}

private struct MainAppView: View {
    let onLogout: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("isEnglish") private var isEnglish = false

    @AppStorage("storedTracksData") private var storedTracksData: Data = Data()
    @AppStorage("addNewTracksAtStart") private var addNewTracksAtStart: Bool = true
    @AppStorage("spotifyToMp3APIBaseURLOverride") private var spotifyToMp3APIBaseURLOverride: String = ""

    private var effectiveSpotifyToMp3APIBaseURL: String {
        let o = spotifyToMp3APIBaseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? spotifyToMp3APIBaseURL : o
    }

    @State private var selectedTab: MainAppTab = .home
    @State private var tracks: [AppTrack] = []
    @State private var currentTrack: AppTrack?
    @Namespace private var playerCoverNamespace
    @State private var isPlayerSheetPresented = false
    @State private var playerDragOffset: CGFloat = 0
    @State private var isAddingMusic = false
    @State private var addByLinkInput: String = ""
    @State private var isAddingFromLink: Bool = false
    @State private var addByLinkErrorMessage: String?
    @State private var playbackHolder = PlaybackStateHolder()
    @State private var mediaPlayer: AVPlayer?
    @State private var volume: Double = 1.0
    @State private var progressTimer: Timer?
    @State private var repeatMode: RepeatMode = .playNext
    @State private var playbackErrorMessage: String?
    @State private var isMiniPlayerHidden = false
    @State private var currentCoverImage: UIImage?
    @State private var currentCoverAccent: Color?
    @State private var coverImageCache: [UUID: UIImage] = [:]
    @State private var coverAccentCache: [UUID: Color] = [:]
    @State private var volumeSyncTimer: Timer?
    @State private var playReadyCancellable: AnyCancellable?
    @State private var playReadyTimeoutWorkItem: DispatchWorkItem?
    @State private var miniCoverFrame: CGRect = .zero
    @State private var isPlayerSheetClosing = false
    @StateObject private var remotePlaybackObserver = RemotePlaybackObserver()
    @StateObject private var audioRouteObserver = AudioRouteObserver()

    private var hasNextTrack: Bool {
        guard let current = currentTrack, let index = tracks.firstIndex(of: current) else { return false }
        return index < tracks.count - 1
    }

    private var accent: Color { Color("AccentColor") }
    private var homeTitle: String { isEnglish ? "Home" : "Главная" }
    private var favoritesTitle: String { isEnglish ? "Favorites" : "Избранное" }
    private var settingsTitle: String { isEnglish ? "Settings" : "Настройки" }
    private var logoutTitle: String { isEnglish ? "Log out" : "Выйти" }
    private var libraryTitle: String { isEnglish ? "Library" : "Библиотека" }
    private var addMusicTitle: String { isEnglish ? "Add music from device" : "Добавить музыку с устройства" }
    private var libraryEmptyTitle: String { isEnglish ? "Your tracks will appear here" : "Здесь появятся ваши треки" }
    private var noResultsTitle: String { isEnglish ? "No results" : "Ничего не найдено" }
    private var doneTitle: String { isEnglish ? "Done" : "Готово" }
    private var playbackErrorTitle: String { isEnglish ? "Playback error" : "Ошибка воспроизведения" }
    private var deleteTitle: String { isEnglish ? "Delete" : "Удалить" }
    private var moveTitle: String { isEnglish ? "Move" : "Переместить" }
    private var madeByTitle: String { isEnglish ? "made by @evgeniy558" : "сделано @evgeniy558" }
    private var addByLinkLabel: String { isEnglish ? "Add track by link from Spotify or TikTok" : "Добавить трек по ссылке из Spotify или TikTok" }

    private var mainBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    private static let storedTracksUserDefaultsKey = "storedTracksData"
    @State private var saveTracksWorkItem: DispatchWorkItem?

    private func loadTracksFromStorage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let data = UserDefaults.standard.data(forKey: Self.storedTracksUserDefaultsKey) ?? Data()
            guard !data.isEmpty else { return }
            let fileManager = FileManager.default
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

            do {
                var resolved: [AppTrack] = []
                if let stored = try? JSONDecoder().decode([StoredTrackItem].self, from: data) {
                    for item in stored {
                        let fileURL = documents.appendingPathComponent(item.pathComponent)
                        guard fileManager.fileExists(atPath: fileURL.path) else { continue }
                        resolved.append(AppTrack(id: item.id, url: fileURL, title: item.title, artist: item.artist, addedAt: item.addedAt))
                    }
                } else if var legacy = try? JSONDecoder().decode([AppTrack].self, from: data) {
                    for track in legacy {
                        if fileManager.fileExists(atPath: track.url.path) {
                            resolved.append(track)
                        } else {
                            let fallback = documents.appendingPathComponent(track.url.lastPathComponent)
                            if fileManager.fileExists(atPath: fallback.path) {
                                resolved.append(AppTrack(id: track.id, url: fallback, title: track.title, artist: track.artist, addedAt: track.addedAt))
                            }
                        }
                    }
                }
                DispatchQueue.main.async { tracks = resolved }
            } catch {
                print("Failed to decode tracks:", error)
            }
        }
    }

    private func saveTracksToStorage() {
        let currentTracks = tracks
        DispatchQueue.global(qos: .utility).async {
            let items = currentTracks.map { StoredTrackItem(id: $0.id, pathComponent: $0.url.lastPathComponent, title: $0.title, artist: $0.artist, addedAt: $0.addedAt) }
            guard let data = try? JSONEncoder().encode(items) else { return }
            DispatchQueue.main.async { storedTracksData = data }
        }
    }

    private func scheduleSaveTracks() {
        saveTracksWorkItem?.cancel()
        let item = DispatchWorkItem { saveTracksToStorage() }
        saveTracksWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Копирует выбранный файл в папку приложения, извлекает обложку и метаданные (название, исполнитель), затем вызывает completion.
    private func copyImportedFileToAppContainer(source: URL, completion: @escaping (URL?, String?, String?) -> Void) {
        let src = source
        guard src.startAccessingSecurityScopedResource() else {
            DispatchQueue.main.async { completion(nil, nil, nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { src.stopAccessingSecurityScopedResource() }
            let fileManager = FileManager.default
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                DispatchQueue.main.async { completion(nil, nil, nil) }
                return
            }
            let ext = src.pathExtension.isEmpty ? "audio" : src.pathExtension
            let dest = documents.appendingPathComponent("imported_\(UUID().uuidString).\(ext)", isDirectory: false)
            do {
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.copyItem(at: src, to: dest)
                saveArtworkAndMetadataFromAudioFile(at: dest) { title, artist in
                    let resolvedTitle: String? = (title != nil && !title!.isEmpty) ? title : src.deletingPathExtension().lastPathComponent
                    DispatchQueue.main.async { completion(dest, resolvedTitle, artist) }
                }
            } catch {
                DispatchQueue.main.async { completion(nil, nil, nil) }
            }
        }
    }

    private func submitAddByLink() {
        let raw = addByLinkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)") else {
            addByLinkErrorMessage = isEnglish ? "Enter a valid link" : "Введите корректную ссылку"
            return
        }
        let host = url.host?.lowercased() ?? ""
        if host.contains("spotify.com"), url.path.contains("/track/") {
            if effectiveSpotifyToMp3APIBaseURL.isEmpty {
                addByLinkErrorMessage = isEnglish ? "Spotify API URL is not set. Deploy the api (see api/README.md) and set the URL in Settings or in code." : "Не задан URL API Spotify. Задеплойте api (см. api/README.md) и укажите URL в настройках или в коде."
                return
            }
            isAddingFromLink = true
            addByLinkErrorMessage = nil
            fetchViaAPIAndAddToLibrary(linkURL: url)
            return
        }
        if host.contains("tiktok.com") || host.contains("vt.tiktok.com") {
            isAddingFromLink = true
            addByLinkErrorMessage = nil
            fetchTikTokAndAddToLibrary(url: url)
            return
        }
        addByLinkErrorMessage = isEnglish ? "Link must be from Spotify (track) or TikTok" : "Ссылка должна быть на трек Spotify или TikTok"
    }

    private func fetchViaAPIAndAddToLibrary(linkURL: URL) {
        let base = effectiveSpotifyToMp3APIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            DispatchQueue.main.async {
                self.addByLinkErrorMessage = self.isEnglish ? "Invalid conversion API URL" : "Некорректный URL API конвертации"
                self.isAddingFromLink = false
            }
            return
        }
        let baseForAPI = base.replacingOccurrences(of: "?url=", with: "").replacingOccurrences(of: "&url=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pathPart = baseForAPI.hasSuffix("/") ? baseForAPI + "api" : (baseForAPI.contains("/api") ? baseForAPI : baseForAPI + "/api")
        guard var comp = URLComponents(string: pathPart) else {
            DispatchQueue.main.async {
                self.addByLinkErrorMessage = self.isEnglish ? "Invalid conversion API URL" : "Некорректный URL API конвертации"
                self.isAddingFromLink = false
            }
            return
        }
        comp.queryItems = [URLQueryItem(name: "url", value: linkURL.absoluteString)]
        guard let apiURL = comp.url else {
            DispatchQueue.main.async {
                self.addByLinkErrorMessage = self.isEnglish ? "Invalid conversion API URL" : "Некорректный URL API конвертации"
                self.isAddingFromLink = false
            }
            return
        }
        let addNewTracksAtStart = self.addNewTracksAtStart
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 180 // API перебирает форматы и cookies — может занять 1–2 минуты
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            if let data = data, !data.isEmpty, let http = http, (200...299).contains(http.statusCode) {
                // успех — сохраняем MP3 ниже
            } else {
                let message: String = {
                    guard let data = data, !data.isEmpty,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let err = json["error"] as? String, !err.isEmpty else {
                        return self.isEnglish ? "Couldn't get MP3 from conversion API" : "Не удалось получить MP3 от API конвертации"
                    }
                    return err
                }()
                DispatchQueue.main.async {
                    self.addByLinkErrorMessage = message
                    self.isAddingFromLink = false
                }
                return
            }
            guard let data = data, !data.isEmpty else { return }
            let fileManager = FileManager.default
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                DispatchQueue.main.async { self.isAddingFromLink = false }
                return
            }
            let dest = documents.appendingPathComponent("imported_\(UUID().uuidString).mp3", isDirectory: false)
            do {
                try data.write(to: dest)
                self.saveArtworkAndMetadataFromAudioFile(at: dest) { title, artist in
                    let newTrack = AppTrack(url: dest, title: title, artist: artist, addedAt: Date())
                    DispatchQueue.main.async {
                        if !self.tracks.contains(where: { $0.id == newTrack.id }) {
                            if addNewTracksAtStart {
                                self.tracks.insert(newTrack, at: 0)
                            } else {
                                self.tracks.append(newTrack)
                            }
                        }
                        self.addByLinkInput = ""
                        self.currentTrack = newTrack
                        self.isMiniPlayerHidden = false
                        self.loadCoverAndAccent(for: newTrack)
                        self.startPlayback(for: newTrack)
                        self.isAddingFromLink = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.addByLinkErrorMessage = self.isEnglish ? "Couldn't save MP3 file" : "Не удалось сохранить MP3"
                    self.isAddingFromLink = false
                }
            }
        }.resume()
    }

    private func fetchTikTokAndAddToLibrary(url: URL) {
        let addNewTracksAtStart = self.addNewTracksAtStart
        let onDone: () -> Void = {
            DispatchQueue.main.async {
                self.isAddingFromLink = false
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.httpMethod = "GET"
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                guard let data = data, let html = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        self.addByLinkErrorMessage = self.isEnglish ? "Couldn't load the page" : "Не удалось загрузить страницу"
                        self.isAddingFromLink = false
                    }
                    return
                }
                let videoURLString: String? = {
                    if let range = html.range(of: #""downloadAddr":"([^"]+)""#, options: .regularExpression),
                       let sub = html[range].split(separator: "\"").dropFirst(2).first {
                        return String(sub).replacingOccurrences(of: "\\u002F", with: "/")
                    }
                    if let range = html.range(of: #""playAddr":"([^"]+)""#, options: .regularExpression),
                       let sub = html[range].split(separator: "\"").dropFirst(2).first {
                        return String(sub).replacingOccurrences(of: "\\u002F", with: "/")
                    }
                    return nil
                }()
                let cleaned = (videoURLString ?? "").replacingOccurrences(of: "\\/", with: "/")
                let urlStr = cleaned.hasPrefix("http") ? cleaned : (cleaned.hasPrefix("//") ? "https:" + cleaned : "https://\(cleaned)")
                guard let finalURL = URL(string: urlStr) else {
                    DispatchQueue.main.async {
                        self.addByLinkErrorMessage = self.isEnglish ? "Couldn't get video from this link" : "Не удалось получить видео по ссылке"
                        self.isAddingFromLink = false
                    }
                    return
                }
                URLSession.shared.dataTask(with: finalURL) { videoData, _, _ in
                    guard let videoData = videoData, !videoData.isEmpty else {
                        DispatchQueue.main.async {
                            self.addByLinkErrorMessage = self.isEnglish ? "Couldn't download video" : "Не удалось скачать видео"
                            self.isAddingFromLink = false
                        }
                        return
                    }
                    let fileManager = FileManager.default
                    guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                        onDone()
                        return
                    }
                    let tempMP4 = documents.appendingPathComponent("temp_import_\(UUID().uuidString).mp4", isDirectory: false)
                    let destM4A = documents.appendingPathComponent("imported_\(UUID().uuidString).m4a", isDirectory: false)
                    do {
                        try videoData.write(to: tempMP4)
                    } catch {
                        DispatchQueue.main.async {
                            self.addByLinkErrorMessage = self.isEnglish ? "Couldn't save file" : "Не удалось сохранить файл"
                            self.isAddingFromLink = false
                        }
                        return
                    }
                    let asset = AVURLAsset(url: tempMP4)
                    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                        try? fileManager.removeItem(at: tempMP4)
                        DispatchQueue.main.async {
                            self.addByLinkErrorMessage = self.isEnglish ? "Couldn't convert to audio" : "Не удалось конвертировать в аудио"
                            self.isAddingFromLink = false
                        }
                        return
                    }
                    exportSession.outputURL = destM4A
                    exportSession.outputFileType = .m4a
                    exportSession.exportAsynchronously {
                        try? fileManager.removeItem(at: tempMP4)
                        guard exportSession.status == .completed else {
                            DispatchQueue.main.async {
                                self.addByLinkErrorMessage = self.isEnglish ? "Couldn't convert to audio" : "Не удалось конвертировать в аудио"
                                self.isAddingFromLink = false
                            }
                            return
                        }
                        self.saveArtworkAndMetadataFromAudioFile(at: destM4A) { title, artist in
                            let newTrack = AppTrack(url: destM4A, title: title, artist: artist, addedAt: Date())
                            DispatchQueue.main.async {
                                if !self.tracks.contains(where: { $0.id == newTrack.id }) {
                                    if addNewTracksAtStart {
                                        self.tracks.insert(newTrack, at: 0)
                                    } else {
                                        self.tracks.append(newTrack)
                                    }
                                }
                                self.addByLinkInput = ""
                                self.currentTrack = newTrack
                                self.isMiniPlayerHidden = false
                                self.loadCoverAndAccent(for: newTrack)
                                self.startPlayback(for: newTrack)
                                self.isAddingFromLink = false
                            }
                        }
                    }
                }.resume()
            }
            task.resume()
        }
    }

    /// Извлекает обложку и метаданные (название, исполнитель) из аудиофайла; обложка сохраняется рядом как .jpg.
    private func saveArtworkAndMetadataFromAudioFile(at audioURL: URL, completion: @escaping (String?, String?) -> Void) {
        let asset = AVURLAsset(url: audioURL)
        asset.loadValuesAsynchronously(forKeys: ["metadata"]) {
            var err: NSError?
            guard asset.statusOfValue(forKey: "metadata", error: &err) == .loaded else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            let metadata = asset.metadata
            var imageData: Data?
            var title: String?
            var artist: String?
            for item in metadata {
                if item.commonKey == .commonKeyArtwork, let data = item.dataValue {
                    imageData = data
                }
                if item.commonKey == .commonKeyTitle, let str = item.stringValue, !str.isEmpty {
                    title = str
                }
                if item.commonKey == .commonKeyArtist, let str = item.stringValue, !str.isEmpty {
                    artist = str
                }
                if item.identifier == .commonIdentifierArtwork, let data = item.dataValue, imageData == nil {
                    imageData = data
                }
                if item.keySpace == .id3, title == nil, let str = item.stringValue, !str.isEmpty {
                    let keyStr = (item.key as? String) ?? ""
                    if keyStr.contains("title") || keyStr.contains("TIT2") { title = str }
                }
                if item.keySpace == .id3, artist == nil, let str = item.stringValue, !str.isEmpty {
                    let keyStr = (item.key as? String) ?? ""
                    if keyStr.contains("artist") || keyStr.contains("performer") || keyStr.contains("TPE1") { artist = str }
                }
                if item.key as? String == "picture", let data = item.dataValue, imageData == nil {
                    imageData = data
                }
                if item.keySpace == .id3, let dict = item.value as? [AnyHashable: Any], let data = dict["data"] as? Data, imageData == nil {
                    imageData = data
                }
            }
            if let data = imageData, let image = UIImage(data: data),
               let jpg = image.jpegData(compressionQuality: 0.85) {
                let coverURL = audioURL.deletingPathExtension().appendingPathExtension("jpg")
                try? jpg.write(to: coverURL)
            }
            DispatchQueue.main.async { completion(title, artist) }
        }
    }

    private func startPlayback(for track: AppTrack) {
        DispatchQueue.main.async {
            do {
                // Сессия уже настроена в SphereApp; только активируем при необходимости
                try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

                self.stopProgressTimer()
                self.mediaPlayer?.pause()
                self.mediaPlayer?.replaceCurrentItem(with: nil)

                var url = track.url
                if !url.isFileURL || !url.path.hasPrefix(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "") {
                    _ = url.startAccessingSecurityScopedResource()
                }
                let fileURL = url.isFileURL ? URL(fileURLWithPath: url.path) : url

                if fileURL.isFileURL && !FileManager.default.fileExists(atPath: fileURL.path) {
                    self.playbackErrorMessage = "Файл не найден"
                    return
                }

                // AVPlayer поддерживает больше форматов и не даёт OSStatus -50 на устройстве
                let item = AVPlayerItem(url: fileURL)
                let player = AVPlayer(playerItem: item)
                player.volume = Float(self.volume)
                self.mediaPlayer = player
                self.playbackHolder.currentTime = 0
                self.playbackHolder.progress = 0
                self.playbackHolder.duration = 0
                self.playbackErrorMessage = nil

                self.playReadyCancellable?.cancel()
                self.playReadyTimeoutWorkItem?.cancel()

                func tryStartPlayback() {
                    guard self.mediaPlayer?.currentItem === item else { return }
                    let d = CMTimeGetSeconds(item.duration)
                    if d.isFinite && d > 0 { self.playbackHolder.duration = d }
                    player.play()
                    self.playbackHolder.isPlaying = true
                    self.startProgressTimer()
                    self.updateNowPlayingInfo()
                    self.playReadyCancellable?.cancel()
                    self.playReadyCancellable = nil
                    self.playReadyTimeoutWorkItem?.cancel()
                    self.playReadyTimeoutWorkItem = nil
                }

                self.playReadyCancellable = item.publisher(for: \.status)
                    .receive(on: DispatchQueue.main)
                    .sink { status in
                        guard self.mediaPlayer?.currentItem === item else { return }
                        switch status {
                        case .readyToPlay:
                            tryStartPlayback()
                        case .failed:
                            self.playbackErrorMessage = item.error?.localizedDescription ?? "Ошибка воспроизведения"
                            self.playReadyCancellable?.cancel()
                            self.playReadyTimeoutWorkItem?.cancel()
                        default:
                            break
                        }
                    }

                let work = DispatchWorkItem { [weak player] in
                    DispatchQueue.main.async {
                        guard self.mediaPlayer?.currentItem === item, !self.playbackHolder.isPlaying else { return }
                        tryStartPlayback()
                    }
                }
                self.playReadyTimeoutWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            } catch {
                self.playbackErrorMessage = error.localizedDescription
            }
        }
    }

    private func togglePlayPause() {
        guard let player = mediaPlayer else {
            if let track = currentTrack {
                startPlayback(for: track)
            }
            return
        }

        if player.timeControlStatus == .playing {
            player.pause()
            playbackHolder.isPlaying = false
            stopProgressTimer()
        } else {
            let dur = player.currentItem?.duration.seconds ?? 0
            let atEnd = dur > 0 && (player.currentTime().seconds >= dur - 0.01 || playbackHolder.progress >= 0.99)
            if atEnd {
                if repeatMode == .playNext && hasNextTrack {
                    playNextTrack()
                    return
                }
                lastSeekTime = Date()
                player.seek(to: .zero, toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
                playbackHolder.currentTime = 0
                playbackHolder.progress = 0
                if dur.isFinite { playbackHolder.duration = dur }
                player.play()
                playbackHolder.isPlaying = true
                startProgressTimer()
                lastSeekTime = nil
                return
            }
            player.play()
            playbackHolder.isPlaying = true
            startProgressTimer()
        }
    }

    private func playPreviousTrack() {
        guard !tracks.isEmpty else { return }
        guard let current = currentTrack,
              let index = tracks.firstIndex(of: current),
              index > 0 else { return }

        let previous = tracks[index - 1]
        currentTrack = previous
        playbackHolder.progress = 0
        startPlayback(for: previous)
    }

    private func playNextTrack() {
        guard !tracks.isEmpty else { return }
        guard let current = currentTrack,
              let index = tracks.firstIndex(of: current),
              index < tracks.count - 1 else { return }

        let next = tracks[index + 1]
        currentTrack = next
        playbackHolder.progress = 0
        startPlayback(for: next)
    }

    private func removeTrack(id trackId: UUID) {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return }
        removeTrack(track)
    }

    private func removeTrack(_ track: AppTrack) {
        let wasCurrent = currentTrack?.id == track.id
        let indexBefore = tracks.firstIndex(where: { $0.id == track.id })
        withAnimation(.easeOut(duration: 0.28)) {
            tracks.removeAll { $0.id == track.id }
        }
        if wasCurrent {
            mediaPlayer?.pause()
            mediaPlayer?.replaceCurrentItem(with: nil)
            currentTrack = nil
            playbackHolder.isPlaying = false
            stopProgressTimer()
            let idx = indexBefore ?? 0
            if idx < tracks.count {
                currentTrack = tracks[idx]
                startPlayback(for: tracks[idx])
            } else if idx > 0, !tracks.isEmpty {
                currentTrack = tracks[idx - 1]
                startPlayback(for: tracks[idx - 1])
            } else if !tracks.isEmpty {
                currentTrack = tracks[0]
                startPlayback(for: tracks[0])
            }
        }
    }

    @State private var lastSeekTime: Date?

    private static let seekTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)

    private func seek(to progress: Double) {
        guard let player = mediaPlayer, let currentItem = player.currentItem else { return }
        var dur = currentItem.duration.seconds
        if !dur.isFinite || dur <= 0 {
            let assetDur = CMTimeGetSeconds(currentItem.asset.duration)
            if assetDur.isFinite && assetDur > 0 { dur = assetDur }
        }
        if !dur.isFinite || dur <= 0, playbackHolder.duration > 0 {
            dur = playbackHolder.duration
        }
        guard dur.isFinite, dur > 0 else { return }
        let clamped = min(max(progress, 0), 1)
        let isRewindForRepeat = clamped >= 0.98 && repeatMode == .repeatOne
        if !isRewindForRepeat { lastSeekTime = Date() }

        if clamped >= 0.98 {
            if repeatMode == .playNext && hasNextTrack {
                playNextTrack()
                return
            }
            if repeatMode == .repeatOne {
                player.seek(to: .zero, toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
                playbackHolder.currentTime = 0
                playbackHolder.progress = 0
                playbackHolder.duration = dur
                player.play()
                playbackHolder.isPlaying = true
                startProgressTimer()
                lastSeekTime = nil
                return
            }
            playbackHolder.progress = 1
            playbackHolder.currentTime = dur
            playbackHolder.duration = dur
            player.seek(to: CMTime(seconds: dur, preferredTimescale: 600), toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
            player.pause()
            playbackHolder.isPlaying = false
            stopProgressTimer()
            return
        }

        let sec = clamped * dur
        player.seek(to: CMTime(seconds: sec, preferredTimescale: 600), toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
        playbackHolder.progress = clamped
        playbackHolder.currentTime = sec
        playbackHolder.duration = dur
    }

    private func setVolume(_ value: Double) {
        let steppedVal = SystemVolume.stepped(value)
        volume = steppedVal
        mediaPlayer?.volume = 1.0
        SystemVolume.setVolume(Float(steppedVal))
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let interval: TimeInterval = isPlayerSheetPresented ? 0.25 : 1.0
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            if let last = lastSeekTime, Date().timeIntervalSince(last) < 0.5 { return }
            guard let player = mediaPlayer else { return }
            let dur = player.currentItem?.duration.seconds ?? 0
            guard dur.isFinite, dur > 0 else { return }
            DispatchQueue.main.async {
                updateNowPlayingInfo()
                if player.timeControlStatus != .playing {
                    if repeatMode == .playNext && hasNextTrack {
                        playNextTrack()
                        return
                    }
                    if repeatMode == .repeatOne {
                        player.seek(to: .zero, toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
                        playbackHolder.currentTime = 0
                        playbackHolder.progress = 0
                        playbackHolder.duration = dur
                        player.play()
                        playbackHolder.isPlaying = true
                        startProgressTimer()
                        lastSeekTime = nil
                        return
                    }
                    playbackHolder.isPlaying = false
                    stopProgressTimer()
                    playbackHolder.progress = 1
                    playbackHolder.currentTime = dur
                    playbackHolder.duration = dur
                    return
                }
                let newTime = player.currentTime().seconds
                let newDuration = dur
                let newProgress = newDuration > 0 ? newTime / newDuration : 0
                if abs(newProgress - playbackHolder.progress) > 0.002 || abs(newTime - playbackHolder.currentTime) > 0.15 {
                    playbackHolder.currentTime = newTime
                    playbackHolder.duration = newDuration
                    playbackHolder.progress = newProgress
                }
                if newTime >= newDuration - 0.01 {
                    if repeatMode == .playNext && hasNextTrack {
                        playNextTrack()
                        return
                    }
                    if repeatMode == .repeatOne {
                        player.seek(to: .zero, toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
                        playbackHolder.currentTime = 0
                        playbackHolder.progress = 0
                        playbackHolder.duration = dur
                        player.play()
                        playbackHolder.isPlaying = true
                        startProgressTimer()
                        lastSeekTime = nil
                        return
                    }
                    player.pause()
                    playbackHolder.isPlaying = false
                    stopProgressTimer()
                    playbackHolder.progress = 1
                    playbackHolder.currentTime = dur
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func restartProgressTimerIfNeeded() {
        guard progressTimer != nil else { return }
        startProgressTimer()
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Перемотка на позицию в секундах (для Lock Screen / Control Center).
    private func seekToTime(_ position: TimeInterval) {
        let dur = playbackHolder.duration
        guard dur > 0 else { return }
        let progress = min(max(position / dur, 0), 1)
        seek(to: progress)
    }

    /// Обновляет Control Center / Lock Screen / Dynamic Island.
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            NowPlayingManager.shared.clear()
            return
        }
        NowPlayingManager.shared.update(
            title: track.title,
            artist: track.artist,
            duration: playbackHolder.duration,
            currentTime: playbackHolder.currentTime,
            isPlaying: playbackHolder.isPlaying,
            artwork: currentCoverImage
        )
    }

    /// Полная остановка воспроизведения при выходе из аккаунта (трек не должен играть на экране входа).
    private func stopPlaybackOnLogout() {
        isPlayerSheetPresented = false
        stopProgressTimer()
        mediaPlayer?.pause()
        mediaPlayer?.replaceCurrentItem(with: nil)
        currentTrack = nil
        playbackHolder.isPlaying = false
        playbackHolder.progress = 0
        playbackHolder.currentTime = 0
        playbackHolder.duration = 0
        currentCoverImage = nil
        currentCoverAccent = nil
    }

    private func loadCoverAndAccent(for track: AppTrack) {
        currentCoverImage = coverImageCache[track.id]
        currentCoverAccent = coverAccentCache[track.id]
        DispatchQueue.global(qos: .userInitiated).async {
            let img = loadCoverImage(for: track)
            let accentColor = img.flatMap { dominantColor(from: $0) }
            DispatchQueue.main.async {
                if let img { coverImageCache[track.id] = img }
                if let accentColor { coverAccentCache[track.id] = accentColor }
                currentCoverImage = img
                currentCoverAccent = accentColor
            }
        }
    }

    /// Плавная анимация плеера: кривая без рывков, длительность даёт много кадров на 120 Гц
    private static let playerSheetAnimation: Animation = .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.38)

    private func openPlayerSheet() {
        isPlayerSheetClosing = false
        withAnimation(Self.playerSheetAnimation) {
            isPlayerSheetPresented = true
        }
    }

    /// Контент с таббаром: на iOS 26 — нативный TabView (капля + liquid glass), на iOS 18 и ниже — свой таббар с блюром.
    @ViewBuilder
    private var tabContent: some View {
        if #available(iOS 26.0, *) {
            tabViewIOS26
        } else {
            tabViewWithInset
        }
    }

    /// Нативный TabView iOS 26: системный таббар с каплей и liquid glass, каплю можно двигать.
    @available(iOS 26.0, *)
    private var tabViewIOS26: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .tabItem { Label(homeTitle, image: "Spherelogo") }
                .tag(MainAppTab.home)
            favoritesTab
                .tabItem { Label(favoritesTitle, systemImage: "heart.fill") }
                .tag(MainAppTab.favorites)
            settingsTab
                .tabItem { Label(settingsTitle, systemImage: "gearshape.fill") }
                .tag(MainAppTab.settings)
        }
        .background(mainBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let currentTrack, !isPlayerSheetPresented, !isMiniPlayerHidden {
                miniPlayer(for: currentTrack, namespace: playerCoverNamespace, playbackHolder: playbackHolder)
                Spacer().frame(height: 12)
                Spacer().frame(height: 24)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: currentTrack != nil)
    }

    /// Контент + таббар с блюром и каплей (только iOS 18 и ниже).
    private var tabViewWithInset: some View {
        Group {
            switch selectedTab {
            case .home: homeTab
            case .favorites: favoritesTab
            case .settings: settingsTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 44)
                .onEnded { value in
                    let dx = value.translation.width
                    if dx < -60 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            switch selectedTab {
                            case .home: selectedTab = .favorites
                            case .favorites: selectedTab = .settings
                            case .settings: break
                            }
                        }
                    } else if dx > 60 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            switch selectedTab {
                            case .home: break
                            case .favorites: selectedTab = .home
                            case .settings: selectedTab = .favorites
                            }
                        }
                    }
                }
        )
        .background(mainBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let currentTrack, !isPlayerSheetPresented, !isMiniPlayerHidden {
                    miniPlayer(for: currentTrack, namespace: playerCoverNamespace, playbackHolder: playbackHolder)
                    Spacer().frame(height: 12)
                }
                TelegramTabBarSwiftUI(
                    homeTitle: homeTitle,
                    favoritesTitle: favoritesTitle,
                    settingsTitle: settingsTitle,
                    accent: accent,
                    selectedTab: $selectedTab
                )
                .frame(height: 76)
                .padding(.vertical, 8)
            }
            .animation(.easeInOut(duration: 0.25), value: currentTrack != nil)
        }
    }

    @ViewBuilder
    private var playerSheetOverlayContent: some View {
        if isPlayerSheetPresented, let currentTrack {
            PlayerSheetView(
                track: currentTrack,
                accent: accent,
                coverImage: currentCoverImage,
                coverAccent: currentCoverAccent,
                namespace: playerCoverNamespace,
                isEnglish: isEnglish,
                playbackHolder: playbackHolder,
                audioRouteObserver: audioRouteObserver,
                volume: $volume,
                onDismiss: {
                    if #available(iOS 26.0, *) {
                        playerDragOffset = 0
                        isPlayerSheetClosing = true
                    } else {
                        withAnimation(Self.playerSheetAnimation) {
                            isPlayerSheetPresented = false
                        }
                    }
                },
                onTogglePlayPause: { togglePlayPause() },
                onPrevious: { playPreviousTrack() },
                onNext: { playNextTrack() },
                onSeek: { seek(to: $0) },
                onVolumeChange: { setVolume($0) },
                repeatMode: repeatMode,
                onRepeatModeChange: { repeatMode = $0 },
                onRepeatCycle: {
                    switch repeatMode {
                    case .pauseAtEnd: repeatMode = .repeatOne
                    case .repeatOne: repeatMode = .playNext
                    case .playNext: repeatMode = .pauseAtEnd
                    }
                },
                isBottomSheet: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(TopRoundedShape(radius: 24))
            .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: -2)
            .offset(y: playerDragOffset)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        let h = value.translation.height
                        let w = value.translation.width
                        if h > 0, h >= abs(w) {
                            playerDragOffset = h
                        }
                    }
                    .onEnded { value in
                        let dy = value.translation.height
                        let predicted = value.predictedEndTranslation.height
                        let threshold: CGFloat = 120
                        let screenH = UIScreen.main.bounds.height
                        if dy > threshold || predicted > threshold {
                            withAnimation(Self.playerSheetAnimation) {
                                playerDragOffset = screenH
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                                isPlayerSheetPresented = false
                                playerDragOffset = 0
                            }
                        } else {
                            withAnimation(Self.playerSheetAnimation) {
                                playerDragOffset = 0
                            }
                        }
                    }
            )
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
            .ignoresSafeArea()
        }
    }

    var body: some View {
        tabContent
        .animation(Self.playerSheetAnimation, value: isPlayerSheetPresented)
        .onChange(of: isPlayerSheetPresented) { isPresented in
            if isPresented {
                volume = SystemVolume.stepped(Double(SystemVolume.current()))
                volumeSyncTimer?.invalidate()
                let t = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    let systemVol = SystemVolume.current()
                    let newVal = SystemVolume.stepped(Double(systemVol))
                    if abs(newVal - volume) > 0.001 {
                        volume = newVal
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                volumeSyncTimer = t
            } else {
                volumeSyncTimer?.invalidate()
                volumeSyncTimer = nil
            }
            restartProgressTimerIfNeeded()
        }
        .onChange(of: currentTrack) { newTrack in
            guard let newTrack else {
                currentCoverImage = nil
                currentCoverAccent = nil
                NowPlayingManager.shared.clear()
                return
            }
            loadCoverAndAccent(for: newTrack)
            updateNowPlayingInfo()
        }
        .onChange(of: remotePlaybackObserver.pendingCommand) { command in
            guard let cmd = command else { return }
            remotePlaybackObserver.pendingCommand = nil
            switch cmd {
            case .playPause: togglePlayPause()
            case .nextTrack: if hasNextTrack { playNextTrack() }
            case .previousTrack: playPreviousTrack()
            case .seek(let position): seekToTime(position)
            }
        }
        .onAppear {
            if let track = currentTrack, currentCoverImage == nil {
                loadCoverAndAccent(for: track)
            }
        }
        .overlay(alignment: .bottom) {
            playerSheetOverlayContent
        }
        .animation(Self.playerSheetAnimation, value: isPlayerSheetPresented)
        .animation(Self.playerSheetAnimation, value: playerDragOffset)
        .onPreferenceChange(MiniCoverFrameKey.self) { miniCoverFrame = $0 }
        .overlay {
            if currentTrack != nil {
                HeroCoverOverlayView(
                    isPlayerSheetPresented: isPlayerSheetPresented,
                    isPlayerSheetClosing: isPlayerSheetClosing,
                    playerDragOffset: playerDragOffset,
                    miniCoverFrame: miniCoverFrame,
                    onCloseAnimationDidEnd: {
                        if isPlayerSheetClosing {
                            isPlayerSheetPresented = false
                            isPlayerSheetClosing = false
                            playerDragOffset = 0
                        }
                    },
                    currentCoverImage: currentCoverImage,
                    accent: accent,
                    playbackHolder: playbackHolder
                )
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                saveTracksWorkItem?.cancel()
                saveTracksToStorage()
            }
            if newPhase != .active, playerDragOffset > 0 {
                let h = UIScreen.main.bounds.height
                withAnimation(Self.playerSheetAnimation) {
                    playerDragOffset = h
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                    isPlayerSheetPresented = false
                    playerDragOffset = 0
                }
            }
        }
        .fileImporter(isPresented: $isAddingMusic, allowedContentTypes: [UTType.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                copyImportedFileToAppContainer(source: url) { localURL, title, artist in
                    guard let localURL else { return }
                    let newTrack = AppTrack(url: localURL, title: title, artist: artist, addedAt: Date())
                    if !tracks.contains(where: { $0.id == newTrack.id }) {
                        if addNewTracksAtStart {
                            tracks.insert(newTrack, at: 0)
                        } else {
                            tracks.append(newTrack)
                        }
                    }
                    currentTrack = newTrack
                    isMiniPlayerHidden = false
                    loadCoverAndAccent(for: newTrack)
                    startPlayback(for: newTrack)
                }
            case .failure:
                break
            }
        }
        .alert(playbackErrorTitle, isPresented: Binding(get: { playbackErrorMessage != nil }, set: { if !$0 { playbackErrorMessage = nil } })) {
            Button("OK", role: .cancel) { playbackErrorMessage = nil }
        } message: {
            if let msg = playbackErrorMessage { Text(msg) }
        }
        .alert(isEnglish ? "Add by link" : "Добавление по ссылке", isPresented: Binding(get: { addByLinkErrorMessage != nil }, set: { if !$0 { addByLinkErrorMessage = nil } })) {
            Button("OK", role: .cancel) { addByLinkErrorMessage = nil }
        } message: {
            if let msg = addByLinkErrorMessage { Text(msg) }
        }
        .onAppear {
            DispatchQueue.main.async { loadTracksFromStorage() }
        }
        .onChange(of: tracks) { _ in
            scheduleSaveTracks()
        }
    }

    private var homeTab: some View {
        NavigationStack {
            ZStack {
                mainBackground
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text(homeTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)

                    HStack {
                        Text(libraryTitle)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(accent)
                        Spacer()
                        NavigationLink {
                            FullLibraryFullScreenView(
                                tracks: $tracks,
                                accent: accent,
                                colorScheme: colorScheme,
                                isEnglish: isEnglish,
                                onDelete: removeTrack,
                                onPlayTrack: { track in
                                    currentTrack = track
                                    playbackHolder.progress = 0
                                    isMiniPlayerHidden = false
                                    startPlayback(for: track)
                                    openPlayerSheet()
                                }
                            )
                        } label: {
                            Group {
                                if #available(iOS 26.0, *) {
                                    Image(systemName: "chevron.right")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .glassEffect(.regular.tint(accent).interactive(), in: Circle())
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(accent)
                                        .frame(width: 44, height: 44)
                                        .background(accent.opacity(0.2), in: Circle())
                                }
                            }
                        }
                        .buttonStyle(ScaleOnPressRoundButtonStyle())
                    }

                    if tracks.isEmpty {
                        Text(libraryEmptyTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(tracks) { track in
                                    LibraryRowCell(
                                        track: track,
                                        accent: accent,
                                        deleteTitle: deleteTitle,
                                        onTap: {
                                            currentTrack = track
                                            playbackHolder.progress = 0
                                            isMiniPlayerHidden = false
                                            startPlayback(for: track)
                                            openPlayerSheet()
                                        },
                                        onDelete: { removeTrack(id: track.id) }
                                    )
                                }
                            }
                            .padding(.top, 8)
                            .padding(.horizontal, 4)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .tabItem {
            Label {
                Text(homeTitle)
            } icon: {
                Image("sphere")
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(0.03)
                    .frame(width: 24, height: 24)
            }
        }
    }

    /// Режим сортировки списка треков (0 = новые вначале, 1 = новые в конце, 2 = по алфавиту, 3 = пользовательское)
    private enum LibrarySortMode: Int, CaseIterable {
        case newestFirst = 0
        case newestLast = 1
        case alphabet = 2
        case custom = 3
    }

    /// Полная библиотека (сетка, перемещение) — открывается push-переходом справа налево
    private struct FullLibraryFullScreenView: View {
        @Environment(\.dismiss) private var dismiss
        @AppStorage("addNewTracksAtStart") private var addNewTracksAtStart: Bool = true
        @AppStorage("librarySortMode") private var librarySortModeRaw: Int = 3
        @Binding var tracks: [AppTrack]
        let accent: Color
        let colorScheme: ColorScheme
        let isEnglish: Bool
        let onDelete: (AppTrack) -> Void
        let onPlayTrack: (AppTrack) -> Void

        private var fullLibraryTitle: String { isEnglish ? "Library" : "Библиотека" }
        private var searchPlaceholder: String { isEnglish ? "Search tracks" : "Поиск треков" }
        private var libraryEmptyTitle: String { isEnglish ? "Your tracks will appear here" : "Здесь появятся ваши треки" }
        private var noResultsTitle: String { isEnglish ? "No results" : "Ничего не найдено" }
        private var doneTitle: String { isEnglish ? "Done" : "Готово" }
        private var sortCustom: String { isEnglish ? "Custom" : "Пользовательское" }
        private var sortNewestFirst: String { isEnglish ? "Newest first" : "Сначала новые" }
        private var sortOldestFirst: String { isEnglish ? "Oldest first" : "Сначала старые" }
        private var sortAlphabet: String { isEnglish ? "Alphabetical" : "По алфавиту" }

        @State private var libraryDropTargetId: UUID?
        @State private var isLibraryEditMode = false
        @State private var draggedTrackId: UUID?
        @State private var dragPositionInLibrary: CGPoint?
        @State private var libraryCellFrames: [UUID: CGRect] = [:]
        @State private var savedOrderBeforeEdit: [AppTrack]?
        @State private var searchText: String = ""
        @State private var libraryScrollProgress: Double = 0

        private var sortMode: LibrarySortMode {
            LibrarySortMode(rawValue: librarySortModeRaw) ?? .custom
        }

        private var displayedTracks: [AppTrack] {
            var list = tracks
            if !searchText.isEmpty {
                list = list.filter {
                    $0.displayTitle.localizedCaseInsensitiveContains(searchText) ||
                    $0.displayArtist.localizedCaseInsensitiveContains(searchText)
                }
            }
            if isLibraryEditMode {
                return list
            }
            switch sortMode {
            case .newestFirst: return list.sorted { (a, b) in (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast) }
            case .newestLast: return list.sorted { (a, b) in (a.addedAt ?? .distantPast) < (b.addedAt ?? .distantPast) }
            case .alphabet: return list.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
            case .custom: return list
            }
        }

        var body: some View {
            ZStack {
                mainBackgroundFullScreen
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 12) {
                    Text(fullLibraryTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    searchField
                        .padding(.horizontal, 24)

                    HStack(alignment: .center, spacing: 12) {
                        if isLibraryEditMode {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    if let saved = savedOrderBeforeEdit {
                                        tracks = saved
                                    }
                                    savedOrderBeforeEdit = nil
                                    isLibraryEditMode = false
                                    libraryDropTargetId = nil
                                    draggedTrackId = nil
                                    dragPositionInLibrary = nil
                                }
                            } label: { libraryRoundButtonLabel(icon: "xmark") }
                            .buttonStyle(ScaleOnPressRoundButtonStyle())
                            libraryScrollSlider(progress: $libraryScrollProgress, accent: accent)
                                .frame(width: 120, height: 32)
                        } else {
                            Button { dismiss() } label: { libraryRoundButtonLabel(icon: "chevron.left") }
                                .buttonStyle(ScaleOnPressRoundButtonStyle())
                        }
                        Spacer(minLength: 0)
                        if isLibraryEditMode {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isLibraryEditMode = false
                                    libraryDropTargetId = nil
                                    draggedTrackId = nil
                                    dragPositionInLibrary = nil
                                    savedOrderBeforeEdit = nil
                                }
                            } label: {
                                libraryRoundButtonLabel(icon: "checkmark")
                            }
                            .buttonStyle(ScaleOnPressRoundButtonStyle())
                            .accessibilityLabel(doneTitle)
                        } else {
                            Menu {
                                Button {
                                    librarySortModeRaw = LibrarySortMode.custom.rawValue
                                } label: {
                                    Label(sortCustom, systemImage: sortMode == .custom ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    addNewTracksAtStart = true
                                    librarySortModeRaw = LibrarySortMode.newestFirst.rawValue
                                } label: {
                                    Label(sortNewestFirst, systemImage: sortMode == .newestFirst ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    addNewTracksAtStart = false
                                    librarySortModeRaw = LibrarySortMode.newestLast.rawValue
                                } label: {
                                    Label(sortOldestFirst, systemImage: sortMode == .newestLast ? "checkmark.circle.fill" : "circle")
                                }
                                Button {
                                    librarySortModeRaw = LibrarySortMode.alphabet.rawValue
                                } label: {
                                    Label(sortAlphabet, systemImage: sortMode == .alphabet ? "checkmark.circle.fill" : "circle")
                                }
                            } label: {
                                librarySortMenuLabel()
                            }
                            .buttonStyle(ScaleOnPressRoundButtonStyle())
                        }
                    }
                    .padding(.horizontal, 24)
                    .onChange(of: librarySortModeRaw) { _ in
                        if sortMode != .custom && isLibraryEditMode {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isLibraryEditMode = false
                                libraryDropTargetId = nil
                                draggedTrackId = nil
                                dragPositionInLibrary = nil
                                savedOrderBeforeEdit = nil
                            }
                        }
                    }
                    .onChange(of: isLibraryEditMode) { editing in
                        if editing { savedOrderBeforeEdit = tracks }
                        else { savedOrderBeforeEdit = nil }
                    }

                    if displayedTracks.isEmpty {
                        Text(tracks.isEmpty ? libraryEmptyTitle : noResultsTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.horizontal, 24)
                        Spacer(minLength: 0)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                let columns = [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)
                            ]
                            ZStack(alignment: .topLeading) {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                                        let isDropTarget = libraryDropTargetId == track.id
                                        LibraryTrackCell(
                                            track: track,
                                            index: index,
                                            accent: accent,
                                            isEditMode: isLibraryEditMode,
                                            allowsReorder: sortMode == .custom,
                                            isDropTarget: isDropTarget,
                                            colorScheme: colorScheme,
                                            isEnglish: isEnglish,
                                            libraryDropTargetId: $libraryDropTargetId,
                                            tracks: $tracks,
                                            isLibraryEditMode: $isLibraryEditMode,
                                            draggedTrackId: draggedTrackId,
                                            onTap: {
                                                guard !isLibraryEditMode else { return }
                                                onPlayTrack(track)
                                            },
                                            onDelete: { onDelete(track) },
                                            onDragStarted: {
                                                draggedTrackId = track.id
                                                if let f = libraryCellFrames[track.id] {
                                                    dragPositionInLibrary = CGPoint(x: f.midX, y: f.midY)
                                                }
                                            },
                                            onDragChanged: { local in
                                                guard let f = libraryCellFrames[track.id] else { return }
                                                dragPositionInLibrary = CGPoint(x: f.origin.x + local.x, y: f.origin.y + local.y)
                                                let pos = dragPositionInLibrary!
                                                let targetId = resolveDropTargetId(for: pos, frames: libraryCellFrames, excluding: track.id)
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    libraryDropTargetId = targetId
                                                }
                                            },
                                            onDragEnded: { local in
                                                guard let f = libraryCellFrames[track.id] else {
                                                    draggedTrackId = nil
                                                    dragPositionInLibrary = nil
                                                    libraryDropTargetId = nil
                                                    return
                                                }
                                                let pos = CGPoint(x: f.origin.x + local.x, y: f.origin.y + local.y)
                                                if let targetId = resolveDropTargetId(for: pos, frames: libraryCellFrames, excluding: track.id),
                                                   let fromIdx = tracks.firstIndex(where: { $0.id == track.id }),
                                                   let toIdx = tracks.firstIndex(where: { $0.id == targetId }),
                                                   fromIdx != toIdx {
                                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                                                        tracks.swapAt(fromIdx, toIdx)
                                                    }
                                                }
                                                withAnimation(.easeOut(duration: 0.2)) {
                                                    draggedTrackId = nil
                                                    dragPositionInLibrary = nil
                                                    libraryDropTargetId = nil
                                                }
                                            }
                                        )
                                        .id(track.id)
                                    }
                                }
                                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: displayedTracks.map(\.id))
                                .padding(.top, 8)
                                .padding(.horizontal, 12)
                                .coordinateSpace(name: "library")
                                .onPreferenceChange(LibraryCellFrameKey.self) { libraryCellFrames = $0 }

                                if let id = draggedTrackId, let pos = dragPositionInLibrary, let track = tracks.first(where: { $0.id == id }) {
                                    TrackCoverView(track: track, accent: accent, cornerRadius: 20, placeholderPadding: 10)
                                        .aspectRatio(1, contentMode: .fit)
                                        .frame(width: 160, height: 160)
                                        .position(pos)
                                        .allowsHitTesting(false)
                                }
                            }
                            .padding(.horizontal, 24)
                            }
                            .scrollDisabled(isLibraryEditMode)
                            .onChange(of: libraryScrollProgress) { newVal in
                                let list = displayedTracks
                                guard !list.isEmpty else { return }
                                let idx = min(Int(newVal * Double(max(0, list.count - 1)).rounded()), list.count - 1)
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(list[idx].id, anchor: .top)
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
        }

        private var mainBackgroundFullScreen: Color {
            colorScheme == .dark ? Color.black : Color(.systemBackground)
        }

        private var searchField: some View {
            Group {
                if #available(iOS 26.0, *) {
                    TextField(searchPlaceholder, text: $searchText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .glassEffect(.regular.interactive(), in: Capsule())
                } else {
                    TextField(searchPlaceholder, text: $searchText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .background(Material.regular, in: Capsule())
                }
            }
        }

        @ViewBuilder
        private func libraryRoundButtonLabel(icon: String) -> some View {
            Group {
                if #available(iOS 26.0, *) {
                    Image(systemName: icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(accent).interactive(), in: Circle())
                } else {
                    Image(systemName: icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .background(accent.opacity(0.2), in: Circle())
                }
            }
        }

        /// Овальный слайдер между «Отмена» и «Готово» в режиме перемещения: вправо — листать вниз, влево — вверх.
        private func libraryScrollSlider(progress: Binding<Double>, accent: Color) -> some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let thumbSize = min(h * 1.1, w * 0.22)
                let trackWidth = max(0, w - thumbSize)
                let x = thumbSize / 2 + progress.wrappedValue * trackWidth
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(accent.opacity(0.25))
                        .frame(height: h * 0.5)
                    Group {
                        if #available(iOS 26.0, *) {
                            Circle()
                                .fill(accent)
                                .frame(width: thumbSize, height: thumbSize)
                                .glassEffect(.regular.tint(accent).interactive(), in: Circle())
                        } else {
                            Circle()
                                .fill(accent)
                                .frame(width: thumbSize, height: thumbSize)
                        }
                    }
                    .position(x: x, y: h / 2)
                }
                .frame(height: h)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = (value.location.x - thumbSize / 2) / trackWidth
                            progress.wrappedValue = min(max(p, 0), 1)
                        }
                )
            }
        }

        /// Лейбл кнопки сортировки: на iOS 26 — фиолетовый фон и белая иконка (без Liquid Glass, чтобы не обрезалось).
        @ViewBuilder
        private func librarySortMenuLabel() -> some View {
            Group {
                if #available(iOS 26.0, *) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(accent, in: Circle())
                } else {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .background(accent.opacity(0.2), in: Circle())
                }
            }
        }
    }

    /// Компактная ячейка для горизонтального ряда на главной: обложка + название, тап — воспроизведение, контекстное меню — только удаление
    private struct LibraryRowCell: View {
        let track: AppTrack
        let accent: Color
        let deleteTitle: String
        let onTap: () -> Void
        let onDelete: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TrackCoverView(track: track, accent: accent, cornerRadius: 16, placeholderPadding: 8)
                    .frame(width: 120, height: 120)
                Text(track.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .contextMenu {
                Button(role: .destructive, action: onDelete) {
                    Label(deleteTitle, systemImage: "trash")
                }
            }
        }
    }

    private struct LibraryCellFrameKey: PreferenceKey {
        static var defaultValue: [UUID: CGRect] { [:] }
        static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
            value.merge(nextValue()) { _, n in n }
        }
    }

    private struct LibraryTrackCell: View {
        let track: AppTrack
        let index: Int
        let accent: Color
        let isEditMode: Bool
        let allowsReorder: Bool
        let isDropTarget: Bool
        let colorScheme: ColorScheme
        let isEnglish: Bool
        @Binding var libraryDropTargetId: UUID?
        @Binding var tracks: [AppTrack]
        @Binding var isLibraryEditMode: Bool
        let draggedTrackId: UUID?
        let onTap: () -> Void
        let onDelete: () -> Void
        let onDragStarted: () -> Void
        let onDragChanged: (CGPoint) -> Void
        let onDragEnded: (CGPoint) -> Void

        private var deleteTitle: String { isEnglish ? "Delete" : "Удалить" }
        private var moveTitle: String { isEnglish ? "Move" : "Переместить" }

        @State private var shakeAngle: Double = 0
        @State private var isPressed = false

        var body: some View {
            ZStack {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            TrackCoverView(track: track, accent: accent, cornerRadius: 20, placeholderPadding: 10)
                                .aspectRatio(1, contentMode: .fit)
                                .rotationEffect(.degrees(isEditMode ? shakeAngle : 0))
                                .scaleEffect(isEditMode && (isPressed || isDropTarget) ? 1.08 : 1)
                                .opacity(isEditMode && (draggedTrackId == track.id) ? 0.3 : 1)
                            if isDropTarget && isEditMode {
                                RoundedRectangle(cornerRadius: 20)
                                    .fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.5))
                                    .aspectRatio(1, contentMode: .fit)
                                    .scaleEffect(1.08)
                            }
                        }

                        Text(track.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isEditMode)
                .overlay {
                    if isEditMode {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .gesture(
                                DragGesture(minimumDistance: 10)
                                    .onChanged { value in
                                        if draggedTrackId == nil { onDragStarted() }
                                        onDragChanged(value.location)
                                    }
                                    .onEnded { value in
                                        onDragEnded(value.location)
                                    }
                            )
                            .onLongPressGesture(minimumDuration: 0.15, pressing: { pressing in
                                withAnimation(.easeOut(duration: 0.12)) { isPressed = pressing }
                            }, perform: {})
                            .zIndex(0)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isEditMode {
                        libraryCellDeleteButtonView(onDelete: onDelete)
                            .offset(x: 4, y: -4)
                            .zIndex(10)
                    }
                }
            }
            .id(track.id)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: LibraryCellFrameKey.self, value: [track.id: geo.frame(in: .named("library"))])
                }
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .scale(scale: 0.4).combined(with: .opacity)
            ))
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: index)
            .onChange(of: isEditMode) { editing in
                if editing {
                    let seed = track.id.uuidString.utf8.reduce(0) { $0 &+ Int($1) }
                    let initialAngle = Double(abs(seed) % 240) / 240.0 * 2.4 - 1.2
                    let phaseDelay = 0.02 + Double(abs(seed % 160)) / 160.0 * 0.14
                    shakeAngle = initialAngle
                    DispatchQueue.main.asyncAfter(deadline: .now() + phaseDelay) {
                        withAnimation(.easeInOut(duration: 0.08).repeatForever(autoreverses: true)) {
                            shakeAngle = initialAngle > 0 ? -1.2 : 1.2
                        }
                    }
                } else {
                    shakeAngle = 0
                }
            }
            .onAppear {
                if isEditMode {
                    let seed = track.id.uuidString.utf8.reduce(0) { $0 &+ Int($1) }
                    let initialAngle = Double(abs(seed) % 240) / 240.0 * 2.4 - 1.2
                    let phaseDelay = 0.02 + Double(abs(seed % 160)) / 160.0 * 0.14
                    shakeAngle = initialAngle
                    DispatchQueue.main.asyncAfter(deadline: .now() + phaseDelay) {
                        withAnimation(.easeInOut(duration: 0.08).repeatForever(autoreverses: true)) {
                            shakeAngle = initialAngle > 0 ? -1.2 : 1.2
                        }
                    }
                }
            }
            .contextMenu {
                if !isEditMode {
                    Button(role: .destructive, action: onDelete) {
                        Label(deleteTitle, systemImage: "trash")
                    }
                    if allowsReorder {
                        Button {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isLibraryEditMode = true
                            }
                        } label: {
                            Label(moveTitle, systemImage: "arrow.up.arrow.down")
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private func libraryCellDeleteButtonView(onDelete: @escaping () -> Void) -> some View {
            if #available(iOS 26.0, *) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular.tint(Color.red).interactive(), in: Circle())
                    .highPriorityGesture(TapGesture().onEnded { onDelete() })
            } else {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var favoritesTab: some View {
        ZStack {
            mainBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text(favoritesTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                Spacer()
            }
        }
    }

    private var settingsTab: some View {
        ZStack {
            mainBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text(settingsTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 32)

                if #available(iOS 26.0, *) {
                    Button(logoutTitle) {
                        stopPlaybackOnLogout()
                        onLogout()
                    }
                        .buttonStyle(.glassProminent)
                        .tint(accent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                } else {
                    Button(logoutTitle) {
                        stopPlaybackOnLogout()
                        onLogout()
                    }
                        .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: true))
                        .padding(.horizontal, 24)
                }

                Spacer().frame(height: 16)

                if #available(iOS 26.0, *) {
                    Button(addMusicTitle) {
                        isAddingMusic = true
                    }
                    .buttonStyle(.glass)
                    .tint(accent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                } else {
                    Button(addMusicTitle) {
                        isAddingMusic = true
                    }
                    .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: false))
                    .padding(.horizontal, 24)
                }

                Spacer().frame(height: 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isEnglish ? "Spotify API URL (optional)" : "URL API Spotify (по желанию)")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    HStack(spacing: 8) {
                        Group {
                            if #available(iOS 26.0, *) {
                                TextField(spotifyToMp3APIBaseURL, text: $spotifyToMp3APIBaseURLOverride)
                                    .textContentType(.URL)
                                    .keyboardType(.URL)
                                    .autocapitalization(.none)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                            } else {
                                TextField(spotifyToMp3APIBaseURL, text: $spotifyToMp3APIBaseURLOverride)
                                    .textContentType(.URL)
                                    .keyboardType(.URL)
                                    .autocapitalization(.none)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Material.regular, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .font(.caption)
                        if !spotifyToMp3APIBaseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(isEnglish ? "Reset" : "Сброс") {
                                spotifyToMp3APIBaseURLOverride = ""
                            }
                            .font(.caption)
                            .foregroundStyle(accent)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                HStack(spacing: 12) {
                    Group {
                        if #available(iOS 26.0, *) {
                            TextField("", text: $addByLinkInput)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22))
                        } else {
                            TextField("", text: $addByLinkInput)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Material.regular, in: RoundedRectangle(cornerRadius: 22))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        submitAddByLink()
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(accent)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(addByLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingFromLink)
                    .opacity(addByLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingFromLink ? 0.5 : 1)
                    .buttonStyle(.plain)
                    .background {
                        if #available(iOS 26.0, *) {
                            Circle()
                                .glassEffect(.regular.tint(accent).interactive(), in: Circle())
                        } else {
                            Circle()
                                .fill(accent.opacity(0.25))
                        }
                    }
                    .clipShape(Circle())
                }
                .padding(.horizontal, 24)

                if isAddingFromLink {
                    ProgressView()
                        .padding(.top, 8)
                }

                Text(addByLinkLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Spacer(minLength: 0)

                Text(madeByTitle)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tabItem {
            Label(settingsTitle, systemImage: "gearshape.fill")
        }
    }

    private func miniPlayer(for track: AppTrack, namespace: Namespace.ID, playbackHolder: PlaybackStateHolder) -> some View {
        MiniPlayerBarView(track: track, accent: accent, playbackHolder: playbackHolder, onPlayPause: togglePlayPause, onTap: openPlayerSheet, namespace: namespace)
    }

/// Обёртка мини-плеера с @ObservedObject, чтобы только она перерисовывалась при смене прогресса — контекстные меню не мигают.
private struct MiniPlayerBarView: View {
    let track: AppTrack
    let accent: Color
    @ObservedObject var playbackHolder: PlaybackStateHolder
    let onPlayPause: () -> Void
    let onTap: () -> Void
    let namespace: Namespace.ID

    var body: some View {
        let content = HStack(alignment: .center, spacing: 12) {
            Group {
                if #available(iOS 26.0, *) {
                    ZStack {
                        MiniPlayerCoverViewIOS26(track: track, accent: accent)
                            .overlay(
                                GeometryReader { g in
                                    Color.clear.preference(key: MiniCoverFrameKey.self, value: g.frame(in: .global))
                                }
                            )
                    }
                    .frame(width: 40, height: 40)
                    .offset(x: 0, y: 0)
                } else {
                    ZStack {
                        MiniPlayerCoverView(track: track, accent: accent)
                            .overlay(
                                GeometryReader { g in
                                    Color.clear.preference(key: MiniCoverFrameKey.self, value: g.frame(in: .global))
                                }
                            )
                            .opacity(0)
                    }
                    .frame(width: 40, height: 44)
                    .offset(x: -4, y: -7)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !track.displayArtist.isEmpty {
                    Text(track.displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                onPlayPause()
            } label: {
                ZStack {
                    Circle()
                        .stroke(accent.opacity(0.25), lineWidth: 3)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: CGFloat(playbackHolder.progress))
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                    Circle()
                        .fill(accent.opacity(0.9))
                        .frame(width: 36, height: 36)
                    Image(systemName: playbackHolder.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        return Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .offset(y: -62)
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .onTapGesture {
            onTap()
        }
    }
}

    private func topIsland(for track: AppTrack) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10)
                .fill(accent)
                .frame(width: 32, height: 32)
                .overlay(
                    Image("Voxmusic")
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(4)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !track.displayArtist.isEmpty {
                    Text(track.displayArtist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                togglePlayPause()
            } label: {
                Image(systemName: playbackHolder.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(6)
                    .background(Circle().fill(accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(.systemBackground).opacity(0.9))
        )
        .padding(.horizontal, 40)
    }

    /// Модификатор масштаба обложки по isPlaying — только он перерисовывается, контекстное меню не мигает.
    private struct PlayingScaleModifier: ViewModifier {
        @ObservedObject var playbackHolder: PlaybackStateHolder
        let coverScale: CGFloat
        func body(content: Content) -> some View {
            content
                .scaleEffect(coverScale * (playbackHolder.isPlaying ? 1.06 : 0.92))
                .animation(.spring(response: 0.52, dampingFraction: 0.68), value: playbackHolder.isPlaying)
        }
    }

    /// Иконка play/pause в большом плеере — только она перерисовывается при смене isPlaying.
    private struct PlayerSheetPlayPauseIcon: View {
        @ObservedObject var playbackHolder: PlaybackStateHolder
        let font: Font
        let color: Color
        let frameWidth: CGFloat
        let frameHeight: CGFloat
        var body: some View {
            Image(systemName: playbackHolder.isPlaying ? "pause.fill" : "play.fill")
                .font(font)
                .foregroundStyle(color)
                .frame(width: frameWidth, height: frameHeight)
        }
    }

    /// Блок прогресса (время + слайдер) в большом плеере — только он перерисовывается при смене прогресса.
    private struct PlayerSheetProgressSection: View {
        @ObservedObject var playbackHolder: PlaybackStateHolder
        @Binding var isSeeking: Bool
        @Binding var seekValue: Double
        let formatTime: (TimeInterval) -> String
        let onSeek: (Double) -> Void
        let controlsColor: Color
        var body: some View {
            VStack(spacing: 6) {
                HStack {
                    let displayTime = isSeeking ? seekValue * playbackHolder.duration : playbackHolder.currentTime
                    Text(formatTime(displayTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let remaining = isSeeking ? max(playbackHolder.duration - seekValue * playbackHolder.duration, 0) : max(playbackHolder.duration - playbackHolder.currentTime, 0)
                    Text("-" + formatTime(remaining))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { isSeeking ? seekValue : playbackHolder.progress },
                        set: { newValue in seekValue = newValue }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            isSeeking = true
                            seekValue = playbackHolder.progress
                        } else {
                            isSeeking = false
                            onSeek(seekValue)
                        }
                    }
                )
                .tint(controlsColor)
            }
            .onChange(of: playbackHolder.progress) { newValue in
                if newValue < 0.01 {
                    seekValue = 0
                }
            }
        }
    }

    private struct PlayerSheetView: View {
        @Environment(\.colorScheme) private var colorScheme
        let track: AppTrack
        let accent: Color
        var coverImage: UIImage?
        var coverAccent: Color?
        var namespace: Namespace.ID
        let isEnglish: Bool
        let playbackHolder: PlaybackStateHolder
        @ObservedObject var audioRouteObserver: AudioRouteObserver
        @Binding var volume: Double
        let onDismiss: () -> Void
        let onTogglePlayPause: () -> Void
        let onPrevious: () -> Void
        let onNext: () -> Void
        let onSeek: (Double) -> Void
        let onVolumeChange: (Double) -> Void
        let repeatMode: RepeatMode
        let onRepeatModeChange: (RepeatMode) -> Void
        let onRepeatCycle: () -> Void
        var isBottomSheet: Bool = false

        private var repeatPauseAtEndTitle: String { isEnglish ? "Stop after track" : "Заканчивать прослушивание" }
        private var repeatOneTitle: String { isEnglish ? "Repeat one" : "Прослушивать повторно" }
        private var repeatPlayNextTitle: String { isEnglish ? "Play next" : "Воспроизводить следующее" }

        @State private var isSeeking = false
        @State private var seekValue: Double = 0
        @State private var dragOffset: CGFloat = 0
        @State private var titleOffsetY: CGFloat = 28
        @State private var titleScale: CGFloat = 0.88
        @State private var coverBlur: CGFloat = 10
        @State private var coverScale: CGFloat = 0.12
        @State private var isFavorite: Bool = false

        private var repeatModeIcon: String {
            switch repeatMode {
            case .pauseAtEnd: return "pause.circle.fill"
            case .repeatOne: return "repeat"
            case .playNext: return "forward.end.fill"
            }
        }

        private func formatTime(_ seconds: TimeInterval) -> String {
            guard seconds.isFinite && !seconds.isNaN else { return "0:00" }
            let totalSeconds = max(Int(seconds.rounded()), 0)
            let minutes = totalSeconds / 60
            let secs = totalSeconds % 60
            return String(format: "%d:%02d", minutes, secs)
        }

        var body: some View {
            let gradientColor = coverAccent ?? accent
            let isDarkTheme = colorScheme == .dark
            let baseTint = gradientBaseTint(accent: gradientColor, isDarkTheme: isDarkTheme)
            let backgroundGradient: LinearGradient = isDarkTheme
                ? LinearGradient(
                    colors: [
                        baseTint,
                        gradientColor.opacity(0.32),
                        gradientColor.opacity(0.5),
                        baseTint
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                : LinearGradient(colors: [Color.white], startPoint: .top, endPoint: .bottom)

            ZStack {
                (isDarkTheme ? Color(.systemBackground) : Color.white)
                    .ignoresSafeArea(edges: .all)

                if isDarkTheme {
                    backgroundGradient
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .all)
                }

                GeometryReader { geo in
                    let artworkSize = min(geo.size.width - 48, 320)
                    let controlsColor = accentForTheme(gradientColor, isDarkTheme: isDarkTheme)
                    let buttonIconColor = iconColor(onBackground: controlsColor)
                    let textColors: (title: Color, artist: Color) = isDarkTheme
                        ? (Color.white, Color(white: 0.65))
                        : (Color.black, Color(white: 0.38))

                    ZStack {
                        VStack(spacing: 0) {
                        // Обложка: место под hero (hero рисуется в MainAppView поверх всего)
                        RoundedRectangle(cornerRadius: 36)
                            .fill(accent)
                            .frame(width: artworkSize, height: artworkSize)
                            .overlay(
                                Group {
                                    if let cover = coverImage {
                                        Image(uiImage: cover)
                                            .resizable()
                                            .scaledToFill()
                                            .clipShape(RoundedRectangle(cornerRadius: 36))
                                    } else {
                                        Image("Voxmusic")
                                            .resizable()
                                            .scaledToFit()
                                            .clipShape(RoundedRectangle(cornerRadius: 36))
                                            .padding(24)
                                    }
                                }
                            )
                            .opacity(0)
                            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
                            .blur(radius: coverBlur)
                            .modifier(PlayingScaleModifier(playbackHolder: playbackHolder, coverScale: coverScale))
                            .animation(.spring(response: 0.48, dampingFraction: 0.72), value: coverScale)
                            .animation(.easeOut(duration: 0.5), value: coverBlur)
                            .animation(.easeInOut(duration: 0.32), value: track.id)
                            .padding(.top, 56)
                            .offset(y: -5)

                        Spacer(minLength: 0)

                        // Название — чёрный или белый по теме, исполнитель — серый; небольшая тень под текстом
                        VStack(spacing: 6) {
                            Text(track.displayTitle)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(textColors.title)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .scaleEffect(titleScale)
                            if !track.displayArtist.isEmpty {
                                Text(track.displayArtist)
                                    .font(.body)
                                    .foregroundStyle(textColors.artist)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 6)
                        .offset(y: titleOffsetY - 44)
                        .animation(.easeOut(duration: 0.4), value: titleOffsetY)
                        .onAppear {
                            if isBottomSheet {
                                withAnimation(.easeOut(duration: 0.5)) {
                                    coverBlur = 0
                                }
                                withAnimation(.spring(response: 0.48, dampingFraction: 0.72)) {
                                    coverScale = 1
                                }
                                withAnimation(.easeOut(duration: 0.4)) {
                                    titleOffsetY = 0
                                    titleScale = 1
                                }
                            } else {
                                titleOffsetY = 0
                                titleScale = 1
                                coverBlur = 0
                                coverScale = 1
                            }
                        }

                        // Кнопки: цвет с учётом темы (яркость), иконки — по контрасту
                        HStack(spacing: 40) {
                            if #available(iOS 26.0, *) {
                                Button { onPrevious() } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.title2)
                                        .foregroundStyle(buttonIconColor)
                                        .frame(width: 56, height: 56)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(controlsColor).interactive(), in: Circle())

                                Button { onTogglePlayPause() } label: {
                                    PlayerSheetPlayPauseIcon(playbackHolder: playbackHolder, font: .system(size: 28, weight: .semibold), color: buttonIconColor, frameWidth: 72, frameHeight: 72)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(controlsColor).interactive(), in: Circle())

                                Button { onNext() } label: {
                                    Image(systemName: "forward.fill")
                                        .font(.title2)
                                        .foregroundStyle(buttonIconColor)
                                        .frame(width: 56, height: 56)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(controlsColor).interactive(), in: Circle())
                            } else {
                                Button { onPrevious() } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.title2)
                                        .foregroundStyle(buttonIconColor)
                                        .frame(width: 56, height: 56)
                                        .background(controlsColor, in: Circle())
                                }
                                .buttonStyle(ScaleOnPressRoundButtonStyle(isDarkTheme: isDarkTheme))

                                Button { onTogglePlayPause() } label: {
                                    PlayerSheetPlayPauseIcon(playbackHolder: playbackHolder, font: .system(size: 28, weight: .semibold), color: buttonIconColor, frameWidth: 72, frameHeight: 72)
                                        .background(controlsColor, in: Circle())
                                }
                                .buttonStyle(ScaleOnPressRoundButtonStyle(isDarkTheme: isDarkTheme))

                                Button { onNext() } label: {
                                    Image(systemName: "forward.fill")
                                        .font(.title2)
                                        .foregroundStyle(buttonIconColor)
                                        .frame(width: 56, height: 56)
                                        .background(controlsColor, in: Circle())
                                }
                                .buttonStyle(ScaleOnPressRoundButtonStyle(isDarkTheme: isDarkTheme))
                            }
                        }
                        .padding(.bottom, 8)

                        // Ползунок перемотки — время сверху, ползунок снизу
                        PlayerSheetProgressSection(
                            playbackHolder: playbackHolder,
                            isSeeking: $isSeeking,
                            seekValue: $seekValue,
                            formatTime: formatTime,
                            onSeek: onSeek,
                            controlsColor: controlsColor
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)

                        // Громкость — ползунок в цвет акцента обложки
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(
                                value: Binding(
                                    get: { volume },
                                    set: { newValue in onVolumeChange(newValue) }
                                ),
                                in: 0...1
                            )
                            .tint(controlsColor)
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)

                        // Нижний ряд кнопок: избранное, расшифровка, AirPlay, цикл, ещё (три точки)
                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 24) {
                                Button {
                                    isFavorite.toggle()
                                } label: {
                                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                                        .font(.title2)
                                        .foregroundStyle(controlsColor)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 44, height: 44)

                                Button { } label: {
                                    Image(systemName: "text.bubble.fill")
                                        .font(.title2)
                                        .foregroundStyle(controlsColor)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 44, height: 44)

                                ZStack {
                                    AirPlayRoutePickerRepresentable()
                                        .frame(width: 44, height: 44)
                                    Image(systemName: audioRouteObserver.isOutputBluetooth ? "airpodspro" : "airplayaudio")
                                        .font(.title2)
                                        .foregroundStyle(controlsColor)
                                        .allowsHitTesting(false)
                                }
                                .frame(width: 44, height: 44)

                                Button { onRepeatCycle() } label: {
                                    Image(systemName: repeatModeIcon)
                                        .font(.title2)
                                        .foregroundStyle(controlsColor)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 44, height: 44)
                                .contextMenu {
                                    Button { onRepeatModeChange(.pauseAtEnd) } label: {
                                        HStack {
                                            Text(repeatPauseAtEndTitle)
                                            Spacer(minLength: 20)
                                            Image(systemName: "pause.circle.fill")
                                                .font(.body)
                                        }
                                        .foregroundStyle(controlsColor)
                                    }
                                    Button { onRepeatModeChange(.repeatOne) } label: {
                                        HStack {
                                            Text(repeatOneTitle)
                                            Spacer(minLength: 20)
                                            Image(systemName: "repeat")
                                                .font(.body)
                                        }
                                        .foregroundStyle(controlsColor)
                                    }
                                    Button { onRepeatModeChange(.playNext) } label: {
                                        HStack {
                                            Text(repeatPlayNextTitle)
                                            Spacer(minLength: 20)
                                            Image(systemName: "forward.end.fill")
                                                .font(.body)
                                        }
                                        .foregroundStyle(controlsColor)
                                    }
                                }

                                Button { } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.title2)
                                        .foregroundStyle(controlsColor)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 44, height: 44)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Capsule()
                        .fill(Color(.systemGray3))
                        .frame(width: 36, height: 5)
                        .padding(.top, isBottomSheet ? 72 : 10)
                        .padding(.bottom, 6)
                }
                .modifier(PlayerDragModifier(isBottomSheet: isBottomSheet, dragOffset: $dragOffset, onDismiss: onDismiss))
            }
        }
    }
}

    private struct PlayerDragModifier: ViewModifier {
        let isBottomSheet: Bool
        @Binding var dragOffset: CGFloat
        let onDismiss: () -> Void

        func body(content: Content) -> some View {
            if isBottomSheet {
                content
            } else {
                content
                    .offset(y: dragOffset)
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { value in
                                dragOffset = max(0, value.translation.height)
                            }
                            .onEnded { value in
                                if value.translation.height > 120 {
                                    onDismiss()
                                } else {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }
        }
    }

// Экран создания аккаунта: никнейм, эл. почта, пароль, кнопка «Создать» (Liquid Glass)
struct CreateAccountView: View {
    @Binding var isPresented: Bool
    let isEnglish: Bool
    let isDarkMode: Bool
    var onAccountCreated: (() -> Void)? = nil

    @State private var email = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var avatarColorIndex = 0
    @State private var showAvatarPicker = false
    @State private var customAvatarImage: UIImage?
    @State private var hasAttemptedSubmit = false
    @State private var keyboardHeight: CGFloat = 0

    private var accent: Color { Color("AccentColor") }
    private var errorColor: Color { .red }
    private var avatarTitle: String { isEnglish ? "Choose avatar" : "Выбрать аватарку" }
    private var emailLabel: String { isEnglish ? "Email" : "Эл. почта" }
    private var passwordLabel: String { isEnglish ? "Password" : "Пароль" }
    private var nicknameLabel: String { isEnglish ? "Nickname" : "Никнейм" }
    private var createButtonTitle: String { isEnglish ? "Create" : "Создать" }
    private var errorNickname: String { isEnglish ? "Enter nickname" : "Введите никнейм" }
    private var errorEmail: String { isEnglish ? "Enter email" : "Введите почту" }
    private var errorPassword: String { isEnglish ? "Enter password" : "Введите пароль" }

    private var formIsValid: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !password.isEmpty
    }

    private var avatarColors: [Color] {
        [accent,
         Color(red: 0.2, green: 0.5, blue: 1),
         Color(red: 0.2, green: 0.75, blue: 0.4),
         Color(red: 1, green: 0.5, blue: 0.2),
         Color(red: 0.95, green: 0.3, blue: 0.35),
         Color(red: 0.95, green: 0.4, blue: 0.7),
         Color(red: 0.2, green: 0.7, blue: 0.75),
         .black]
    }
    private var pickerColors: [Color] { Array(avatarColors.prefix(8)) }
    private var currentAvatarColor: Color { avatarColors[avatarColorIndex % avatarColors.count] }

    var body: some View {
        ZStack {
            (isDarkMode ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 40)
                            .id("createAccountScrollTop")

                        Text(avatarTitle)
                        .font(.headline)
                        .foregroundStyle(accent)
                        .padding(.bottom, 16)

                    Button {
                        showAvatarPicker = true
                    } label: {
                        ZStack {
                            if avatarColorIndex == 7, let custom = customAvatarImage {
                                Image(uiImage: custom)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(currentAvatarColor)
                                    .frame(width: 120, height: 120)
                                Image("Voxpfp")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 72, height: 72)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 28)

                    VStack(alignment: .leading, spacing: 20) {
                        labelWithError(label: nicknameLabel, error: hasAttemptedSubmit && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? errorNickname : nil)
                        createAccountGlassField(isError: hasAttemptedSubmit && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            TextField("", text: $nickname)
                                .textContentType(.username)
                                .autocapitalization(.none)
                        }

                        labelWithError(label: emailLabel, error: hasAttemptedSubmit && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? errorEmail : nil)
                        createAccountGlassField(isError: hasAttemptedSubmit && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            TextField("", text: $email)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                        }

                        labelWithError(label: passwordLabel, error: hasAttemptedSubmit && password.isEmpty ? errorPassword : nil)
                        createAccountGlassField(isError: hasAttemptedSubmit && password.isEmpty) {
                            SecureField("", text: $password)
                                .textContentType(.newPassword)
                        }

                        Spacer().frame(height: 20)

                        Group {
                            if #available(iOS 26.0, *) {
                                Button(createButtonTitle) {
                                    if formIsValid {
                                        onAccountCreated?()
                                    } else {
                                        hasAttemptedSubmit = true
                                    }
                                }
                                    .buttonStyle(.glassProminent)
                                    .tint(accent)
                                    .controlSize(.large)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 24)
                            } else {
                                Button(createButtonTitle) {
                                    if formIsValid {
                                        onAccountCreated?()
                                    } else {
                                        hasAttemptedSubmit = true
                                    }
                                }
                                    .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: true))
                                    .padding(.horizontal, 24)
                            }
                        }
                    }
                    .padding(24)
                    .padding(.bottom, 40)

                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollDisabled(keyboardHeight == 0)
            .onChange(of: keyboardHeight) { newValue in
                if newValue == 0 {
                    withAnimation(.easeOut(duration: 0.28)) {
                        scrollProxy.scrollTo("createAccountScrollTop", anchor: .top)
                    }
                }
            }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(CloseButtonGlassStyle(accent: accent))
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: keyboardHeight > 0 ? keyboardHeight * 0.55 : 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, frame.height > 0 else { return }
            keyboardHeight = frame.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.28
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = 0
            }
        }
        .sheet(isPresented: $showAvatarPicker) {
            AvatarPickerSheet(
                avatarColorIndex: $avatarColorIndex,
                isPresented: $showAvatarPicker,
                customAvatarImage: $customAvatarImage,
                pickerColors: pickerColors,
                accent: accent,
                isEnglish: isEnglish
            )
        }
    }

    @ViewBuilder
    private func labelWithError(label: String, error: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accent)
            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(errorColor)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func createAccountGlassField<Content: View>(isError: Bool, @ViewBuilder content: () -> Content) -> some View {
        let field = content()
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)

        Group {
            if #available(iOS 26.0, *) {
                field.glassEffect(in: Capsule())
            } else {
                field.background(Material.regular, in: Capsule())
            }
        }
        .overlay(
            Capsule()
                .strokeBorder(isError ? errorColor : .clear, lineWidth: 2)
        )
    }
}

// Экран входа: закрыть справа сверху, эл. почта, пароль, кнопка «Войти» (тот же дизайн, что создание аккаунта)
struct SignInView: View {
    @Binding var isPresented: Bool
    let isEnglish: Bool
    var onSignIn: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var password = ""
    @State private var hasAttemptedSubmit = false
    @State private var keyboardHeight: CGFloat = 0

    private var accent: Color { Color("AccentColor") }
    private var errorColor: Color { .red }
    private var emailLabel: String { isEnglish ? "Email" : "Эл. почта" }
    private var passwordLabel: String { isEnglish ? "Password" : "Пароль" }
    private var signInButtonTitle: String { isEnglish ? "Sign in" : "Войти" }
    private var signInWithGoogleTitle: String { isEnglish ? "Sign in with Google" : "Войти через Google" }
    private var errorEmail: String { isEnglish ? "Enter email" : "Введите почту" }
    private var errorPassword: String { isEnglish ? "Enter password" : "Введите пароль" }

    private var formIsValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !password.isEmpty
    }

    private var sheetBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    var body: some View {
        ZStack {
            sheetBackground
                .ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                            .id("signInScrollTop")

                        VStack(alignment: .leading, spacing: 20) {
                            labelWithError(label: emailLabel, error: hasAttemptedSubmit && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? errorEmail : nil)
                        signInGlassField(isError: hasAttemptedSubmit && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            TextField("", text: $email)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                        }

                        labelWithError(label: passwordLabel, error: hasAttemptedSubmit && password.isEmpty ? errorPassword : nil)
                        signInGlassField(isError: hasAttemptedSubmit && password.isEmpty) {
                            SecureField("", text: $password)
                                .textContentType(.password)
                        }

                        Spacer().frame(height: 28)

                        googleSignInButton

                        Spacer().frame(height: 16)

                        Group {
                            if #available(iOS 26.0, *) {
                                Button(signInButtonTitle) {
                                    if formIsValid {
                                        onSignIn?()
                                    } else {
                                        hasAttemptedSubmit = true
                                    }
                                }
                                .buttonStyle(.glassProminent)
                                .tint(accent)
                                .controlSize(.large)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 24)
                            } else {
                                Button(signInButtonTitle) {
                                    if formIsValid {
                                        onSignIn?()
                                    } else {
                                        hasAttemptedSubmit = true
                                    }
                                }
                                .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: true))
                                .padding(.horizontal, 24)
                            }
                        }
                    }
                    .padding(24)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: UIScreen.main.bounds.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollDisabled(keyboardHeight == 0)
            .onChange(of: keyboardHeight) { newValue in
                if newValue == 0 {
                    withAnimation(.easeOut(duration: 0.28)) {
                        scrollProxy.scrollTo("signInScrollTop", anchor: .top)
                    }
                }
            }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(CloseButtonGlassStyle(accent: accent))
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: keyboardHeight > 0 ? keyboardHeight * 0.55 : 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, frame.height > 0 else { return }
            keyboardHeight = frame.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.28
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = 0
            }
        }
    }

    @ViewBuilder
    private var googleSignInButton: some View {
        if #available(iOS 26.0, *) {
            Button(action: {}) {
                HStack(spacing: 10) {
                    Image(colorScheme == .dark ? "googlewhite" : "google")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                    Text(signInWithGoogleTitle)
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(colorScheme == .dark ? .white : .black)
            }
            .buttonStyle(.glass)
            .tint(.white)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        } else {
            Button(action: {}) {
                HStack(spacing: 10) {
                    Image(colorScheme == .dark ? "googlewhite" : "google")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                    Text(signInWithGoogleTitle)
                        .font(.body.weight(.semibold))
                }
            }
            .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: false, labelColor: colorScheme == .dark ? .white : .black))
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func labelWithError(label: String, error: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accent)
            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(errorColor)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func signInGlassField<Content: View>(isError: Bool, @ViewBuilder content: () -> Content) -> some View {
        let field = content()
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)

        Group {
            if #available(iOS 26.0, *) {
                field.glassEffect(in: Capsule())
            } else {
                field.background(Material.regular, in: Capsule())
            }
        }
        .overlay(
            Capsule()
                .strokeBorder(isError ? errorColor : .clear, lineWidth: 2)
        )
    }
}

// Обёртка для передачи UIImage в fullScreenCover(item:)
private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// Окно выбора аватарки: 4 сверху, 4 снизу (8-й — своё фото), кнопка «Выбрать»
struct AvatarPickerSheet: View {
    @Binding var avatarColorIndex: Int
    @Binding var isPresented: Bool
    @Binding var customAvatarImage: UIImage?
    let pickerColors: [Color]
    let accent: Color
    let isEnglish: Bool

    @State private var selectedIndex: Int = 0
    @State private var showImageSourceDialog = false
    @State private var showGalleryPicker = false
    @State private var showDocumentPicker = false
    @State private var imageForCrop: IdentifiableImage?

    private var selectButtonTitle: String { isEnglish ? "Select" : "Выбрать" }
    private var fromGalleryTitle: String { isEnglish ? "Choose from gallery" : "Выбрать из галереи" }
    private var fromFilesTitle: String { isEnglish ? "Choose from files" : "Выбрать из файлов" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                HStack(spacing: 20) {
                    ForEach(0..<4, id: \.self) { index in
                        avatarCell(index: index)
                    }
                }
                HStack(spacing: 20) {
                    ForEach(4..<8, id: \.self) { index in
                        avatarCell(index: index)
                    }
                }
            }
            .padding(28)

            Group {
                if #available(iOS 26.0, *) {
                    Button(selectButtonTitle) {
                        if selectedIndex == 7, customAvatarImage == nil {
                            showImageSourceDialog = true
                            return
                        }
                        avatarColorIndex = selectedIndex
                        isPresented = false
                    }
                    .buttonStyle(.glassProminent)
                    .tint(accent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                } else {
                    Button(selectButtonTitle) {
                        if selectedIndex == 7, customAvatarImage == nil {
                            showImageSourceDialog = true
                            return
                        }
                        avatarColorIndex = selectedIndex
                        isPresented = false
                    }
                    .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: true))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
        .onAppear { selectedIndex = avatarColorIndex % 8 }
        .confirmationDialog(fromGalleryTitle, isPresented: $showImageSourceDialog, titleVisibility: .visible) {
            Button(fromGalleryTitle) { showGalleryPicker = true }
            Button(fromFilesTitle) { showDocumentPicker = true }
            Button(isEnglish ? "Cancel" : "Отмена", role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showGalleryPicker) {
            PhotoLibraryPicker { image in
                showGalleryPicker = false
                if let image = image { imageForCrop = IdentifiableImage(image: image) }
            }
        }
        .fullScreenCover(isPresented: $showDocumentPicker) {
            DocumentImagePicker { image in
                showDocumentPicker = false
                if let image = image { imageForCrop = IdentifiableImage(image: image) }
            }
        }
        .fullScreenCover(item: $imageForCrop) { item in
            CropAvatarView(
                image: item.image,
                isEnglish: isEnglish,
                onComplete: { cropped in
                    customAvatarImage = cropped
                    avatarColorIndex = 7
                    isPresented = false
                    imageForCrop = nil
                },
                onDelete: { imageForCrop = nil }
            )
        }
    }

    @ViewBuilder
    private func avatarCell(index: Int) -> some View {
        if index == 7 {
            customPhotoButton
        } else {
            avatarCircle(index: index)
        }
    }

    private var customPhotoButton: some View {
        let isSelected = selectedIndex == 7
        return Button {
            selectedIndex = 7
            showImageSourceDialog = true
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.systemGray4))
                    .frame(width: 64, height: 64)
                Circle()
                    .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 3)
                    .frame(width: 64, height: 64)
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(accent)
            }
        }
        .buttonStyle(.plain)
    }

    private func avatarCircle(index: Int) -> some View {
        let color = pickerColors[index]
        let isSelected = selectedIndex == index
        return Button {
            selectedIndex = index
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 64, height: 64)
                Circle()
                    .strokeBorder(isSelected ? Color.primary : Color.clear, lineWidth: 3)
                    .frame(width: 64, height: 64)
                Image("Voxpfp")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            }
        }
        .buttonStyle(.plain)
    }
}

// Выбор фото из галереи (PHPicker)
private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else { onPick(nil); return }
            result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                DispatchQueue.main.async {
                    self?.onPick(obj as? UIImage)
                }
            }
        }
    }
}

// Выбор изображения из файлов
private struct DocumentImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.image])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first,
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { onPick(nil); return }
            onPick(image)
        }
    }
}

// Подгонка фото: заголовок, рамка как фон, круг по теме, кнопки Liquid Glass, крестик
struct CropAvatarView: View {
    let image: UIImage
    let isEnglish: Bool
    let onComplete: (UIImage) -> Void
    let onDelete: () -> Void

    private let circleSize: CGFloat = 260
    private let cornerRadius: CGFloat = 20
    private var containerSize: CGFloat {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        return min(w, h) - 80
    }

    @State private var currentImage: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showImageSourceDialog = false
    @State private var showGalleryPicker = false
    @State private var showDocumentPicker = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(image: UIImage, isEnglish: Bool, onComplete: @escaping (UIImage) -> Void, onDelete: @escaping () -> Void) {
        self.image = image
        self.isEnglish = isEnglish
        self.onComplete = onComplete
        self.onDelete = onDelete
        _currentImage = State(initialValue: image)
    }

    private var accent: Color { Color("AccentColor") }
    private var titleText: String { isEnglish ? "Resize" : "Изменить размер" }
    private var initialScale: CGFloat { circleSize / containerSize }
    private var minScale: CGFloat { initialScale * 0.5 }
    private var maxScale: CGFloat { initialScale * 4 }
    private var chooseAgainTitle: String { isEnglish ? "Choose again" : "Выбрать повторно" }
    private var doneTitle: String { isEnglish ? "Done" : "Готово" }
    private var fromGalleryTitle: String { isEnglish ? "Choose from gallery" : "Выбрать из галереи" }
    private var fromFilesTitle: String { isEnglish ? "Choose from files" : "Выбрать из файлов" }
    private var cancelTitle: String { isEnglish ? "Cancel" : "Отмена" }
    private var frameBackgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.78)
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text(titleText)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .padding(.bottom, 24)

                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(frameBackgroundColor)
                        .frame(width: containerSize, height: containerSize)

                    Image(uiImage: currentImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: containerSize, height: containerSize)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let newScale = lastScale * value
                                    scale = min(max(minScale, newScale), maxScale)
                                }
                                .onEnded { _ in lastScale = scale }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in lastOffset = offset }
                        )
                        .onAppear {
                            scale = initialScale
                            lastScale = initialScale
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(accent, lineWidth: 2)
                        .frame(width: containerSize, height: containerSize)
                }
                .frame(width: containerSize, height: containerSize)
                .clipped()

                VStack(spacing: 12) {
                    if #available(iOS 26.0, *) {
                        Button(chooseAgainTitle) { showImageSourceDialog = true }
                            .buttonStyle(.glassProminent)
                            .tint(accent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        Button(doneTitle) { performCrop() }
                            .buttonStyle(.glassProminent)
                            .tint(accent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button(chooseAgainTitle) { showImageSourceDialog = true }
                            .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: true))
                        Button(doneTitle) { performCrop() }
                            .buttonStyle(GlassMaterialButtonStyle(accent: accent, prominent: true))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 50)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack {
                    Spacer()
                    Button { onDelete() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(CloseButtonGlassStyle(accent: accent))
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
        .confirmationDialog(fromGalleryTitle, isPresented: $showImageSourceDialog, titleVisibility: .visible) {
            Button(fromGalleryTitle) { showGalleryPicker = true }
            Button(fromFilesTitle) { showDocumentPicker = true }
            Button(cancelTitle, role: .cancel) { }
        }
        .sheet(isPresented: $showGalleryPicker) {
            PhotoLibraryPicker { picked in
                DispatchQueue.main.async {
                    showGalleryPicker = false
                    if let img = picked {
                        currentImage = img
                        scale = circleSize / containerSize
                        lastScale = scale
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentImagePicker { picked in
                DispatchQueue.main.async {
                    showDocumentPicker = false
                    if let img = picked {
                        currentImage = img
                        scale = circleSize / containerSize
                        lastScale = scale
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
        }
    }

    private func performCrop() {
        let imgSize = currentImage.size
        let contentSize: CGSize = {
            let r = imgSize.width / imgSize.height
            if r >= 1 {
                return CGSize(width: containerSize, height: containerSize / r)
            } else {
                return CGSize(width: containerSize * r, height: containerSize)
            }
        }()
        let srcCenterX = contentSize.width / 2 - offset.width / scale
        let srcCenterY = contentSize.height / 2 - offset.height / scale
        let srcRadius = (circleSize / 2) / scale
        let scaleToImage = imgSize.width / contentSize.width
        let drawScale = (circleSize / 2) / (srcRadius * scaleToImage)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: circleSize, height: circleSize))
        let cropped = renderer.image { ctx in
            let c = ctx.cgContext
            c.addEllipse(in: CGRect(x: 0, y: 0, width: circleSize, height: circleSize))
            c.clip()
            c.translateBy(x: circleSize / 2, y: circleSize / 2)
            c.scaleBy(x: drawScale, y: drawScale)
            c.translateBy(x: -srcCenterX * scaleToImage, y: -srcCenterY * scaleToImage)
            currentImage.draw(at: .zero)
        }
        onComplete(cropped)
        dismiss()
    }
}

// Стиль кнопки-крестика с Liquid Glass (круглая, большая)
private struct CloseButtonGlassStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .glassEffect(.regular.tint(accent).interactive(), in: Circle())
        } else {
            configuration.label
                .background(accent, in: Circle())
        }
    }
}

// Стиль «стеклянной» кнопки на материалах для iOS 16–25 (без Liquid Glass API)
private struct GlassMaterialButtonStyle: ButtonStyle {
    let accent: Color
    let prominent: Bool
    var labelColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(textColor)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }

    private var textColor: Color {
        if let labelColor { return labelColor }
        return prominent ? .white : accent
    }

    private var backgroundStyle: AnyShapeStyle {
        if prominent {
            AnyShapeStyle(accent.opacity(0.9))
        } else {
            AnyShapeStyle(Material.regular)
        }
    }
}

#Preview {
    ContentView()
}
