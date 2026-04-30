//
//  ContentView.swift
//  Sphere
//
//  Created by Evgeniy on 01.03.2026.
//

import SwiftUI
import PhotosUI
import UIKit
import QuartzCore
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import MediaPlayer
import CoreImage
import Combine
import ImageIO

extension Notification.Name {
    static let spherePlayCatalogTrack = Notification.Name("sphere.playCatalogTrack")
}

/// Акцент приложения: кастомный RGB из настроек или цвет из ассета `AccentColor`.
private func sphereAccentResolvedColor() -> Color {
    let d = UserDefaults.standard
    if d.bool(forKey: "sphereUseCustomAccent") {
        let r = d.object(forKey: "sphereAccentR") as? Double ?? (217.0 / 255.0)
        let g = d.object(forKey: "sphereAccentG") as? Double ?? (252.0 / 255.0)
        let b = d.object(forKey: "sphereAccentB") as? Double ?? 1.0
        return Color(red: r, green: g, blue: b)
    }
    // Default app accent (we keep customization via Settings, but default is mint).
    return Color.mint
}

private var sphereAccent: Color { sphereAccentResolvedColor() }

private func sphereDecodedExcludedRecommendationIDs(from json: String) -> Set<UUID> {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(arr.compactMap(UUID.init(uuidString:)))
}

private func sphereEncodedExcludedRecommendationIDs(_ ids: Set<UUID>) -> String {
    let arr = ids.map(\.uuidString).sorted()
    guard let data = try? JSONEncoder().encode(arr) else { return "[]" }
    return String(data: data, encoding: .utf8) ?? "[]"
}

private let spotifyToMp3APIBaseURL: String = "http://192.168.0.8:5001"

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

/// Палитра большого плеера от `coverAccent ?? accent` (бекап «Большой плеер» / PlayerTitleAndBottomBarColors).
private struct PlayerSheetChromePalette {
    let gradientColor: Color
    let isDarkTheme: Bool
    let controlsColor: Color
    let buttonIconColor: Color
    let titleColorLegacy: Color
    let artistColor: Color

    init(gradientColor: Color, isDarkTheme: Bool) {
        self.gradientColor = gradientColor
        self.isDarkTheme = isDarkTheme
        let c = accentForTheme(gradientColor, isDarkTheme: isDarkTheme)
        controlsColor = c
        buttonIconColor = iconColor(onBackground: c)
        if isDarkTheme {
            titleColorLegacy = Color.white
            artistColor = Color(white: 0.65)
        } else {
            titleColorLegacy = c
            artistColor = Color(white: 0.38)
        }
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
        .id("\(track.id.uuidString)|\(track.url.path)")
        .onAppear {
            if loadedImage == nil {
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = loadCoverImage(for: track)
                    DispatchQueue.main.async { loadedImage = img }
                }
            }
        }
        .onChange(of: track.id) { _ in
            loadedImage = nil
            DispatchQueue.global(qos: .userInitiated).async {
                let img = loadCoverImage(for: track)
                DispatchQueue.main.async { loadedImage = img }
            }
        }
        .onChange(of: track.url.path) { _ in
            loadedImage = nil
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

/// Позиция большой обложки в overlay. iOS 26 стиль 1 — чуть выше (41+safeTop); стили 2/3 — 24+safeTop. iOS 16–18 — по стилю.
private func heroBigFrame(overlayWidth: CGFloat, safeTop: CGFloat, playerStyleIndex: Int = 0) -> CGRect {
    let bigSize = min(overlayWidth - 48, 320)
    let x = (overlayWidth - bigSize) / 2
    if #available(iOS 26.0, *) {
        if playerStyleIndex == 0 {
            return CGRect(x: x, y: 41 + safeTop, width: bigSize, height: bigSize)
        }
        return CGRect(x: x, y: 24 + safeTop, width: bigSize, height: bigSize)
    } else {
        let yOffset: CGFloat = [51.0, 48.0, 64.0][min(playerStyleIndex, 2)]
        return CGRect(x: x, y: yOffset + safeTop, width: bigSize, height: bigSize)
    }
}

/// Fallback для мини-обложки в глобальных координатах (hero). iOS 26 стиль 1 — из бэкапа (94); стили 2/3 — 124+34. iOS 16–18 — по стилю.
private func heroMiniFallbackFrame(overlayGlobal: CGRect, playerStyleIndex: Int = 0) -> CGRect {
    let miniSize: CGFloat = 40
    let barLeftInset: CGFloat = 28
    if #available(iOS 26.0, *) {
        if playerStyleIndex == 0 {
            let barCenterFromBottom: CGFloat = 94
            return CGRect(
                x: overlayGlobal.minX + barLeftInset,
                y: overlayGlobal.maxY - barCenterFromBottom - miniSize / 2,
                width: miniSize,
                height: miniSize
            )
        }
        let barCenterFromBottomIOS26: CGFloat = 124 + 34
        return CGRect(
            x: overlayGlobal.minX + barLeftInset,
            y: overlayGlobal.maxY - barCenterFromBottomIOS26 - miniSize / 2,
            width: miniSize,
            height: miniSize
        )
    } else {
        // iOS 16–18: ровно как в Sphere16 — один бар, центр миниплеера на фиксированной высоте.
        let barCenterFromBottom: CGFloat = 143
        return CGRect(
            x: overlayGlobal.minX + barLeftInset,
            y: overlayGlobal.maxY - barCenterFromBottom - miniSize / 2,
            width: miniSize,
            height: miniSize
        )
    }
}

/// Вычисляет тёмную тему из AppStorage + colorScheme.
private func appDarkThemeFromStorage(preferredRaw: String, colorScheme: ColorScheme) -> Bool {
    switch preferredRaw {
    case "dark": return true
    case "light": return false
    default: return colorScheme == .dark
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

// MARK: - Анимация обложки при перемотке (шейк + наклон), общая для hero и sheet

/// Значение смещения и наклона обложки при перемотке (Equatable для PreferenceKey).
private struct CoverSeekShakeValue: Equatable {
    var x: CGFloat
    var y: CGFloat
    var tilt: Double
}

/// Ключ для передачи смещения/наклона обложки при перемотке из TimelineView.
private struct CoverSeekShakePreferenceKey: PreferenceKey {
    static var defaultValue: CoverSeekShakeValue? { nil }
    static func reduce(value: inout CoverSeekShakeValue?, nextValue: () -> CoverSeekShakeValue?) {
        value = nextValue()
    }
}

/// При включённой «анимации обложки при перемотке»: шейк/наклон зависят от скорости движения ползунка (`scrubIntensity` 0…1). Держишь без движения — нет анимации; медленно — медленно; быстрее — быстрее.
private struct CoverSeekShakeTiltModifier: ViewModifier {
    var enable: Bool
    var isSeeking: Bool
    /// 0 = нет движения ползунка, 1 = быстрая перемотка; задаётся из скорости изменения progress.
    var scrubIntensity: CGFloat
    @State private var shakeX: CGFloat = 0
    @State private var shakeY: CGFloat = 0
    @State private var tilt: Double = 0

    /// Базовая амплитуда смещения (pt); на неё ещё умножается `scrubIntensity`.
    private static let moveAmount: CGFloat = 5.5
    private static let maxTiltDegrees: Double = 4.5
    private static let basePhaseSpeed: Double = 7.0

    func body(content: Content) -> some View {
        let w = max(0, min(1, scrubIntensity))
        return content
            .offset(x: shakeX, y: shakeY)
            .rotationEffect(.degrees(tilt))
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isSeeking)
            .overlay {
                if enable && isSeeking && w > 0.02 {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let phase = Double(w) * Self.basePhaseSpeed
                        let x = Self.moveAmount * CGFloat(w) * sin(t * phase)
                        let y = Self.moveAmount * CGFloat(w) * sin(t * phase + 1.4)
                        let tiltDegrees = Self.maxTiltDegrees * Double(w) * sin(t * phase * 0.9)
                        Color.clear
                            .preference(
                                key: CoverSeekShakePreferenceKey.self,
                                value: CoverSeekShakeValue(x: x, y: y, tilt: tiltDegrees)
                            )
                    }
                }
            }
            .onPreferenceChange(CoverSeekShakePreferenceKey.self) { value in
                if let v = value {
                    shakeX = v.x
                    shakeY = v.y
                    tilt = v.tilt
                }
            }
            .onChange(of: isSeeking) { newValue in
                if !newValue {
                    shakeX = 0
                    shakeY = 0
                    tilt = 0
                }
            }
            .onChange(of: scrubIntensity) { newW in
                if newW < 0.02 {
                    shakeX = 0
                    shakeY = 0
                    tilt = 0
                }
            }
    }
}

/// Вращение при перемотке: целевая скорость ∝ `scrubIntensity` (до ±`degreesPerSecond`); при остановке ползунка плавно сходит к 0. Отпустил — пружина к 0°.
private struct CoverSeekSpinModifier: ViewModifier {
    var enable: Bool
    var isSeeking: Bool
    var scrubIntensity: CGFloat
    /// +1 вперёд (по часовой), −1 назад.
    var scrubDirection: CGFloat

    @State private var rotation: Double = 0
    @State private var spinRate: Double = 0
    @State private var lastTickTime: TimeInterval?

    /// Макс. при w=1; ~1 полный оборот за ~0,4 с при быстром скрабе.
    private static let degreesPerSecond: Double = 900
    /// Чем больше, тем быстрее разгон/плавная остановка (1/сек порядка).
    private static let spinRateLerp: Double = 11

    func body(content: Content) -> some View {
        let tickerOn = enable && isSeeking
        return content
            .rotationEffect(.degrees(rotation))
            .background {
                if tickerOn {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onChange(of: t) { newT in
                                let wNow = max(0, min(1, scrubIntensity))
                                let dirNow = Double(scrubDirection)
                                let movingNow = wNow > 0.02 && abs(dirNow) > 0.01
                                let targetRate = (enable && isSeeking && movingNow)
                                    ? Self.degreesPerSecond * Double(wNow) * dirNow
                                    : 0
                                if let last = lastTickTime {
                                    let dt = newT - last
                                    if dt > 0, dt < 0.2 {
                                        let a = min(1, Self.spinRateLerp * dt)
                                        spinRate += (targetRate - spinRate) * a
                                        rotation += spinRate * dt
                                        if abs(spinRate) < 0.08, abs(targetRate) < 0.01 {
                                            spinRate = 0
                                        }
                                    }
                                }
                                lastTickTime = newT
                            }
                    }
                }
            }
            .onChange(of: isSeeking) { seeking in
                if !seeking {
                    lastTickTime = nil
                    spinRate = 0
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        rotation = 0
                    }
                }
            }
            .onChange(of: enable) { on in
                if !on {
                    lastTickTime = nil
                    spinRate = 0
                    rotation = 0
                }
            }
    }
}

/// Overlay с hero-обложкой. На iOS 16–18 стиль 2: при закрытии интерполяция по expandProgress, без отката. При выключенном перелистывании — поведение как в бэкапе (hero виден при открытом sheet).
private struct HeroCoverOverlayView: View {
    let isPlayerSheetPresented: Bool
    let isPlayerSheetClosing: Bool
    let playerDragOffset: CGFloat
    let expandProgress: CGFloat
    let miniCoverFrame: CGRect
    let onCloseAnimationDidEnd: () -> Void
    let currentCoverImage: UIImage?
    let accent: Color
    let playerStyleIndex: Int
    let enableCoverPaging: Bool
    let enableCoverSeekAnimation: Bool
    let isPlayerSeeking: Bool
    let seekScrubIntensity: CGFloat
    let coverSeekWobbleOnSeek: Bool
    let coverSeekSpinOnSeek: Bool
    let seekScrubDirection: CGFloat
    let roundPlayerCover: Bool
    @ObservedObject var playbackHolder: PlaybackStateHolder

    private var heroSeekShakeEnabled: Bool { enableCoverSeekAnimation && !enableCoverPaging && isPlayerSeeking && coverSeekWobbleOnSeek }
    private var heroSeekSpinEnabled: Bool { enableCoverSeekAnimation && !enableCoverPaging && coverSeekSpinOnSeek }
    private static let playerSheetAnimation: Animation = .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.38)
    @State private var closeStartDragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { g in
	            let overlayGlobal = g.frame(in: .global)
	            let safeTop = g.safeAreaInsets.top
            let bigFrame = heroBigFrame(overlayWidth: g.size.width, safeTop: safeTop, playerStyleIndex: playerStyleIndex)
            let miniFrameBase = miniCoverFrame.isEmpty ? heroMiniFallbackFrame(overlayGlobal: overlayGlobal, playerStyleIndex: playerStyleIndex) : miniCoverFrame

            // Для стиля 1 поднимаем точку мини-обложки на 10pt только на iOS 26;
            // на iOS 16–18 miniFrame совпадает с миниплеером по высоте.
            let miniFrame: CGRect = {
                if #available(iOS 26.0, *), playerStyleIndex == 0 {
                    return miniFrameBase.offsetBy(dx: 0, dy: -10)
                } else {
                    return miniFrameBase
                }
            }()

	            if #available(iOS 26.0, *) {
	                if playerStyleIndex == 0 {
	                    let bigSize = bigFrame.size
	                    let heroCR = playerArtworkCornerRadius(squareSide: bigSize.width, round: roundPlayerCover)
	                    let minScale = min(miniFrame.width / bigSize.width, miniFrame.height / bigSize.height)
	                    let progress = max(0, min(1, expandProgress))
	                    let openScale = playbackHolder.isPlaying ? 1.06 : 0.92
	                    let scale = minScale + (openScale - minScale) * progress
	                    let miniX = miniFrame.midX - overlayGlobal.minX
	                    let miniY = miniFrame.midY - overlayGlobal.minY
	                    let posX = miniX + (bigFrame.midX - miniX) * progress
	                    let posY = miniY + (bigFrame.midY + playerDragOffset - miniY) * progress
	                    HeroCoverView(image: currentCoverImage, accent: accent, size: bigSize, cornerRadius: heroCR)
	                        .scaleEffect(scale)
	                        .opacity(
	                            isPlayerSheetPresented || isPlayerSheetClosing
	                            ? (enableCoverPaging ? 0 : 1.0)
	                            : 0.0
	                        )
	                        .modifier(CoverSeekShakeTiltModifier(enable: heroSeekShakeEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity))
	                        .modifier(CoverSeekSpinModifier(enable: heroSeekSpinEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity, scrubDirection: seekScrubDirection))
	                        .animation(.spring(response: 0.52, dampingFraction: 0.68), value: playbackHolder.isPlaying)
                        .position(x: posX, y: posY)
                        .animation(Self.playerSheetAnimation, value: isPlayerSheetPresented)
                        .animation(Self.playerSheetAnimation, value: isPlayerSheetClosing)
                } else if isPlayerSheetPresented || isPlayerSheetClosing {
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
                        playbackHolder: playbackHolder,
                        enableCoverSeekAnimation: enableCoverSeekAnimation,
                        isPlayerSeeking: isPlayerSeeking,
                        seekScrubIntensity: seekScrubIntensity,
                        coverSeekWobbleOnSeek: coverSeekWobbleOnSeek,
                        coverSeekSpinOnSeek: coverSeekSpinOnSeek,
                        seekScrubDirection: seekScrubDirection,
                        roundPlayerCover: roundPlayerCover
                    )
                } else {
                    Color.clear
                }
            } else {
                let bigSize = bigFrame.size
                let heroCR = playerArtworkCornerRadius(squareSide: bigSize.width, round: roundPlayerCover)
                let minScale = min(miniFrame.width / bigSize.width, miniFrame.height / bigSize.height)
                let scaleWhenOpen: (CGFloat, CGFloat) = [(1.06, 0.92), (1.02, 0.94), (1.08, 0.90)][min(playerStyleIndex, 2)]
                let openScale = playbackHolder.isPlaying ? scaleWhenOpen.0 : scaleWhenOpen.1
                let posYOffset: CGFloat = [0, 4, -3][min(playerStyleIndex, 2)]
                let miniX = miniFrame.midX - overlayGlobal.minX
                let miniY = miniFrame.midY - overlayGlobal.minY
                let closingTargetFrame = heroMiniFallbackFrame(overlayGlobal: overlayGlobal, playerStyleIndex: playerStyleIndex)
                let closingMiniX = closingTargetFrame.midX - overlayGlobal.minX
                let closingMiniY = closingTargetFrame.midY - overlayGlobal.minY

	                let heroOpacity: CGFloat = {
	                    if !isPlayerSheetPresented && !isPlayerSheetClosing {
	                        return playerStyleIndex == 1 ? 1 : 0
	                    }
	                    return (isPlayerSheetPresented && !isPlayerSheetClosing) ? (enableCoverPaging ? 0 : 1) : 1
	                }()
                if playerStyleIndex == 1 {
                    let useClosingInterpolation = isPlayerSheetClosing
                    let t = max(0, min(1, expandProgress))
                    let startY = bigFrame.midY + (useClosingInterpolation ? closeStartDragOffset : playerDragOffset) + posYOffset
                    let scale: CGFloat = useClosingInterpolation
                        ? (minScale + (openScale - minScale) * t)
                        : (isPlayerSheetPresented ? openScale : minScale)
                    let posX: CGFloat = useClosingInterpolation
                        ? (closingMiniX + (bigFrame.midX - closingMiniX) * t)
                        : (isPlayerSheetPresented ? bigFrame.midX : miniX)
                    let posY: CGFloat = useClosingInterpolation
                        ? (closingMiniY + (startY - closingMiniY) * t)
                        : (isPlayerSheetPresented ? bigFrame.midY + playerDragOffset + posYOffset : miniY)
                    HeroCoverView(image: currentCoverImage, accent: accent, size: bigSize, cornerRadius: heroCR)
                        .scaleEffect(scale)
                        .opacity(heroOpacity)
                        .modifier(CoverSeekShakeTiltModifier(enable: heroSeekShakeEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity))
                        .modifier(CoverSeekSpinModifier(enable: heroSeekSpinEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity, scrubDirection: seekScrubDirection))
                        .animation(.spring(response: 0.52, dampingFraction: 0.68), value: playbackHolder.isPlaying)
                        .position(x: posX, y: posY)
                } else {
                    let scale: CGFloat = (isPlayerSheetPresented || isPlayerSheetClosing) ? openScale : minScale
                    let posX = (isPlayerSheetPresented || isPlayerSheetClosing) ? bigFrame.midX : miniX
                    let posY = (isPlayerSheetPresented || isPlayerSheetClosing) ? bigFrame.midY + playerDragOffset + posYOffset : miniY
                    HeroCoverView(image: currentCoverImage, accent: accent, size: bigSize, cornerRadius: heroCR)
                        .scaleEffect(scale)
                        .opacity(heroOpacity)
                        .modifier(CoverSeekShakeTiltModifier(enable: heroSeekShakeEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity))
                        .modifier(CoverSeekSpinModifier(enable: heroSeekSpinEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity, scrubDirection: seekScrubDirection))
                        .animation(.spring(response: 0.52, dampingFraction: 0.68), value: playbackHolder.isPlaying)
                        .position(x: posX, y: posY)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(Self.playerSheetAnimation, value: isPlayerSheetPresented)
        .animation(Self.playerSheetAnimation, value: playerDragOffset)
        .animation(Self.playerSheetAnimation, value: expandProgress)
        .animation(Self.playerSheetAnimation, value: playerStyleIndex)
        .onAppear {
            if !isPlayerSheetPresented, isPlayerSheetClosing, playerStyleIndex == 1 {
                closeStartDragOffset = playerDragOffset
            }
        }
        .onChange(of: isPlayerSheetClosing) { closing in
            if closing, playerStyleIndex == 1 {
                closeStartDragOffset = playerDragOffset
            }
        }
    }
}

/// Герой при открытом sheet на iOS 26 (стили 2 и 3): при открытии мини-обложка влетает в большую; при закрытии уменьшается и влетает в мини-плеер. Как в бэкапе Sphere20.
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
    let enableCoverSeekAnimation: Bool
    let isPlayerSeeking: Bool
    let seekScrubIntensity: CGFloat
    let coverSeekWobbleOnSeek: Bool
    let coverSeekSpinOnSeek: Bool
    let seekScrubDirection: CGFloat
    let roundPlayerCover: Bool
    private static let playerSheetAnimation: Animation = .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45)
    private static let closeDuration: Double = 0.45

    @State private var openProgress: CGFloat = 0
    @State private var closeStartDragOffset: CGFloat = 0

    private var heroSeekShakeEnabled: Bool { enableCoverSeekAnimation && isPlayerSeeking && coverSeekWobbleOnSeek }
    private var heroSeekSpinEnabled: Bool { enableCoverSeekAnimation && isPlayerSeeking && coverSeekSpinOnSeek }

    var body: some View {
        let minScale = min(miniFrame.width / bigFrame.width, miniFrame.height / bigFrame.height)
        let baseScale = openProgress * (1 - minScale) + minScale
        let scale = isClosing ? baseScale : (baseScale * (openProgress > 0.01 ? (playbackHolder.isPlaying ? 1.06 : 0.92) : 1))
        let posX = miniFrame.midX + (bigFrame.midX - miniFrame.midX) * openProgress
        let miniTargetY = miniFrame.midY + 70
        let posY: CGFloat = isClosing
            ? miniTargetY + (bigFrame.midY + closeStartDragOffset - miniTargetY) * openProgress
            : miniTargetY + (bigFrame.midY - miniTargetY) * openProgress + playerDragOffset

        let heroCR = playerArtworkCornerRadius(squareSide: bigFrame.size.width, round: roundPlayerCover)
        HeroCoverView(image: currentCoverImage, accent: accent, size: bigFrame.size, cornerRadius: heroCR)
            .glassEffect(.regular.tint(accent).interactive(), in: RoundedRectangle(cornerRadius: heroCR))
            .scaleEffect(scale)
            .modifier(CoverSeekShakeTiltModifier(enable: heroSeekShakeEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity))
            .modifier(CoverSeekSpinModifier(enable: heroSeekSpinEnabled, isSeeking: isPlayerSeeking, scrubIntensity: seekScrubIntensity, scrubDirection: seekScrubDirection))
            .opacity(
                isClosing
                ? max(min((openProgress - 0.2) / 0.8, 1), 0)
                : (openProgress >= 0.7 ? max(0, (1 - openProgress) / 0.3) : 1)
            )
            .animation(.spring(response: 0.52, dampingFraction: 0.68), value: playbackHolder.isPlaying)
            .position(x: posX, y: posY)
            .onAppear {
                if isClosing {
                    closeStartDragOffset = playerDragOffset
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
                    closeStartDragOffset = playerDragOffset
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

private func playerArtworkCornerRadius(squareSide: CGFloat, round: Bool) -> CGFloat {
    round ? squareSide / 2 : 36
}

private func miniPlayerArtworkCornerRadius(round: Bool) -> CGFloat {
    round ? 20 : 10
}

/// Обложка 40×40 для мини-плеера (только iOS 18 и ниже; на iOS 26 не используется).
private struct MiniPlayerCoverView: View {
    let track: AppTrack
    let accent: Color
    var roundPlayerCover: Bool = false
    @State private var loadedImage: UIImage?

    var body: some View {
        let cr = miniPlayerArtworkCornerRadius(round: roundPlayerCover)
        RoundedRectangle(cornerRadius: cr)
            .fill(accent)
            .frame(width: 40, height: 40)
            .overlay(
                Group {
                    if let img = loadedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: cr))
                    } else {
                        Image("Voxmusic")
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: cr))
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
    var roundPlayerCover: Bool = false
    var catalogCoverURL: String? = nil
    @State private var loadedImage: UIImage?

    var body: some View {
        let cr = miniPlayerArtworkCornerRadius(round: roundPlayerCover)
        RoundedRectangle(cornerRadius: cr)
            .fill(accent)
            .frame(width: 40, height: 40)
            .overlay(
                Group {
                    if let img = loadedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: cr))
                    } else if let urlStr = catalogCoverURL, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: cr))
                            default:
                                Image("Voxmusic").resizable().scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: cr)).padding(4)
                            }
                        }
                    } else {
                        Image("Voxmusic")
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: cr))
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
                loadedImage = nil
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
    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: String = ""
    @AppStorage("isEnglish") private var isEnglish = false
    /// После нажатия «Создать» в создании аккаунта — показываем главный экран приложения
    @AppStorage("isInApp") private var isInApp: Bool = false
    /// Фиксированный размер начального экрана (без клавиатуры), чтобы он не смещался при открытой клавиатуре в sheet
    @State private var loginScreenFixedSize: CGSize?
    /// Наблюдаем за сервисом авторизации, чтобы автоматически входить, если сессия уже восстановлена.
    @StateObject private var authService = AuthService.shared

    /// Тема: по системе (""), светлая ("light"), тёмная ("dark")
    private var colorSchemeOverride: ColorScheme? {
        switch preferredColorSchemeRaw {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
    /// Тема: по системе, если override == nil; иначе принудительно светлая или тёмная
    private var isDarkMode: Bool { (colorSchemeOverride ?? colorScheme) == .dark }

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

    /// Иконка кнопки темы = что будет при следующем нажатии: луна → тёмная, солнце → светлая, полукруг → система
    private var themeButtonIcon: String {
        switch preferredColorSchemeRaw {
        case "": return "moon.fill"
        case "dark": return "sun.max.fill"
        case "light": return "circle.lefthalf.filled"
        default: return "moon.fill"
        }
    }

    /// Текст рядом с иконкой темы (что будет после следующего нажатия).
    private var themeButtonTitle: String {
        switch preferredColorSchemeRaw {
        case "":
            // Сейчас система → дальше будет тёмная
            return isEnglish ? "Dark" : "Тёмная"
        case "dark":
            // Сейчас тёмная → дальше будет светлая
            return isEnglish ? "Light" : "Светлая"
        case "light":
            // Сейчас светлая → дальше вернёмся к системе
            return isEnglish ? "System" : "Системная"
        default:
            return isEnglish ? "Dark" : "Тёмная"
        }
    }

    /// Текст рядом с иконкой языка (текущий язык интерфейса).
    private var languageButtonTitle: String {
        isEnglish ? "English" : "Русский"
    }
    private var telegramButtonTitle: String {
        isEnglish ? "Our Telegram channel" : "Наш Telegram канал"
    }

    /// Считаем пользователя «в приложении», если он либо явно нажал «Начать»,
    /// либо у нас есть активная сессия (Google/email) после `restoreSession()` — иначе ему пришлось бы
    /// логиниться заново даже после успешной авторизации в прошлом запуске.
    private var shouldShowMainApp: Bool { isInApp || authService.isSignedIn }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                Group {
                    if shouldShowMainApp {
                        MainAppView(onLogout: {
                            isInApp = false
                            authService.signOut()
                        })
                    } else {
                        WelcomeView(
                            isEnglish: isEnglish,
                            accent: sphereAccent,
                            onAuthenticated: {
                                UserDefaults.standard.set(true, forKey: "sphereJustAuthenticated")
                                isInApp = true
                            }
                        )
                            .frame(
                                width: loginScreenFixedSize?.width ?? w,
                                height: loginScreenFixedSize?.height ?? h
                            )
                    }
                }
                .background(
                    Group {
                        if !shouldShowMainApp {
                            GeometryReader { g in
                                Color.clear
                                    .onAppear { if loginScreenFixedSize == nil { loginScreenFixedSize = g.size } }
                            }
                        }
                    }
                )
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(colorSchemeOverride)
        .onOpenURL { url in
            guard url.scheme == "sphere" else { return }
            if url.host == "import-shared" {
                NotificationCenter.default.post(name: .sphereShareImportRequested, object: nil)
                return
            }
            if url.path.isEmpty || url.path == "/" || url.path == "/play" {
                WidgetShared.sharedUserDefaults?.set(true, forKey: WidgetShared.keyOpenPlayFromWidget)
                WidgetShared.sharedUserDefaults?.synchronize()
            }
        }
    }
}

// Видеофон для стартового экрана: black2.mp4 для тёмной темы, white2.mp4 для светлой.
private struct AuthLoginBackgroundVideoView: UIViewRepresentable {
    let isDark: Bool

    func makeUIView(context: Context) -> UIView {
        let view = AuthLoginBackgroundVideoUIView()
        view.backgroundColor = .black
        view.configure(name: isDark ? "black2" : "white2")
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let v = uiView as? AuthLoginBackgroundVideoUIView else { return }
        v.configure(name: isDark ? "black2" : "white2")
    }
}

private final class AuthLoginBackgroundVideoUIView: UIView {
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var currentName: String?

    func configure(name: String) {
        guard name != currentName else { return }
        currentName = name

        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }

        guard let path = Bundle.main.path(forResource: name, ofType: "mp4") else {
            return
        }
        let url = URL(fileURLWithPath: path)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player

        let layer: AVPlayerLayer
        if let existing = playerLayer {
            layer = existing
            layer.player = player
        } else {
            layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.backgroundColor = UIColor.black.cgColor
            self.layer.insertSublayer(layer, at: 0)
            playerLayer = layer
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }

        player.play()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    deinit {
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }
}

// Главное меню приложения: капсула внизу (как tab bar) с блюром, переключение тапом и свайпом
enum MainAppTab: Int, CaseIterable {
    case home = 0
    case favorites = 1
    case profile = 2
    case search = 3
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
            let effectiveTab: MainAppTab = (effectiveDropletX + dropletWidth / 2 < half) ? .home : .profile

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
                                let target: MainAppTab = (effectiveDropletX + dropletWidth / 2 < half) ? .home : .profile
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
                let target: MainAppTab = location.x < half ? .home : .profile
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
final class PlaybackStateHolder: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var isPlaying: Bool = false
    @Published var duration: TimeInterval = 0
    var statusObserver: NSKeyValueObservation?
}

/// Отслеживает нативный UIScrollView: растяжение сверху (bounce) и смещение контента вниз от «упора вверх» (для сворачивания защёлки).
/// Пока идёт жест / инерция или есть overscroll, `CADisplayLink` шлёт метрики с частотой дисплея (до 120 Hz на ProMotion); в покое — только KVO.
private final class SettingsScrollStretchTrackingView: UIView {
    var onMetrics: ((CGFloat, CGFloat) -> Void)?
    private var offsetObservation: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private weak var trackedScrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var lastEmittedStretch: CGFloat = .nan
    private var lastEmittedDelta: CGFloat = .nan

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.findAndAttachScrollViewIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        DispatchQueue.main.async { [weak self] in
            self?.findAndAttachScrollViewIfNeeded()
        }
    }

    private func findAndAttachScrollViewIfNeeded() {
        guard let scroll = enclosingScrollView() else { return }
        guard scroll !== trackedScrollView else { return }
        offsetObservation?.invalidate()
        lastEmittedStretch = .nan
        lastEmittedDelta = .nan
        trackedScrollView = scroll
        offsetObservation = scroll.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
            guard let self else { return }
            self.displayLink?.isPaused = false
            if Thread.isMainThread {
                self.emitMetrics(from: sv)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.emitMetrics(from: sv)
                }
            }
        }
        ensureDisplayLink()
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayStep))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    @objc private func displayStep() {
        guard let sv = trackedScrollView else { return }
        let stretch = Self.overscrollStretch(from: sv)
        let needsHighFrequency = sv.isDragging || sv.isDecelerating || stretch > 0.25
        if !needsHighFrequency {
            displayLink?.isPaused = true
            return
        }
        emitMetrics(from: sv)
    }

    private func emitMetrics(from sv: UIScrollView) {
        let stretch = Self.overscrollStretch(from: sv)
        let delta = Self.scrollDeltaFromTopRest(from: sv)
        if stretch == lastEmittedStretch, delta == lastEmittedDelta { return }
        lastEmittedStretch = stretch
        lastEmittedDelta = delta
        onMetrics?(stretch, delta)
    }

    private func enclosingScrollView() -> UIScrollView? {
        var v: UIView? = superview
        while let cur = v {
            if let s = cur as? UIScrollView { return s }
            v = cur.superview
        }
        return nil
    }

    /// Сколько пунктов контент «перетянули» вниз за верхний край (резиновый отскок).
    private static func overscrollStretch(from scrollView: UIScrollView) -> CGFloat {
        let top = scrollView.adjustedContentInset.top
        let y = scrollView.contentOffset.y
        return max(0, -(y + top))
    }

    /// Насколько прокрутили список вниз от верхнего упора (палец вверх по экрану) — 0 в упоре, >0 при просмотре контента ниже.
    private static func scrollDeltaFromTopRest(from scrollView: UIScrollView) -> CGFloat {
        let top = scrollView.adjustedContentInset.top
        let y = scrollView.contentOffset.y
        return max(0, y + top)
    }

    deinit {
        offsetObservation?.invalidate()
        displayLink?.invalidate()
    }
}

private final class SettingsScrollOverscrollCoordinator: NSObject {
    /// Чтобы не дублировать «пиковый» отклик за один жест растяжения.
    var expandPeakFiredThisPull = false
}

private struct SettingsScrollOverscrollReporter: UIViewRepresentable {
    var stretch: Binding<CGFloat>
    var avatarExpandedLocked: Binding<Bool>

    /// Порог растяжения, после которого аватар остаётся квадратом до прокрутки вниз.
    private let expandLockStretch: CGFloat = 100
    /// Прокрутка вниз от верха, после которой аватар снова круглый.
    private let collapseScrollDelta: CGFloat = 36

    func makeCoordinator() -> SettingsScrollOverscrollCoordinator {
        SettingsScrollOverscrollCoordinator()
    }

    func makeUIView(context: Context) -> SettingsScrollStretchTrackingView {
        let v = SettingsScrollStretchTrackingView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: SettingsScrollStretchTrackingView, context: Context) {
        let stretchBinding = stretch
        let lockBinding = avatarExpandedLocked
        let coord = context.coordinator
        uiView.onMetrics = { stretchVal, scrollDelta in
            stretchBinding.wrappedValue = stretchVal
            if stretchVal >= expandLockStretch {
                // Без анимации при защёлке: иначе effectivePull «дорисовывается» с pullOffset (~100) до maxPull (120) — квадрат визуально ещё растёт.
                if !lockBinding.wrappedValue {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        lockBinding.wrappedValue = true
                    }
                }
                if !coord.expandPeakFiredThisPull {
                    coord.expandPeakFiredThisPull = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            if stretchVal < 8, !lockBinding.wrappedValue {
                coord.expandPeakFiredThisPull = false
            }
            if lockBinding.wrappedValue, scrollDelta >= collapseScrollDelta {
                lockBinding.wrappedValue = false
                coord.expandPeakFiredThisPull = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}

private struct MainAppView: View {
    let onLogout: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("isEnglish") private var isEnglish = false
    @StateObject private var authService = AuthService.shared
    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: String = ""

    @AppStorage("storedTracksData") private var storedTracksData: Data = Data()
    @AppStorage("addNewTracksAtStart") private var addNewTracksAtStart: Bool = true
    @AppStorage("spotifyToMp3APIBaseURLOverride") private var spotifyToMp3APIBaseURLOverride: String = ""

    private var effectiveSpotifyToMp3APIBaseURL: String {
        let o = spotifyToMp3APIBaseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? spotifyToMp3APIBaseURL : o
    }

    @State private var selectedTab: MainAppTab = .home
    /// 0 = главная, 1 = избранное, 2 = профиль, 3 = поиск; синхронизируется с `selectedTab`.
    @State private var pageScrollOffset: CGFloat = 0
    @State private var showLikedPlaylist = false
    @State private var profileAvatarUIImage: UIImage?
    @State private var tracks: [AppTrack] = []
    @State private var currentTrack: AppTrack?
    @Namespace private var playerCoverNamespace
    @State private var isPlayerSheetPresented = false
    @State private var playerDragOffset: CGFloat = 0
    @State private var isAddingMusic = false
    @State private var shareImportRunning = false
    @State private var addByLinkInput: String = ""
    @State private var isAddingFromLink: Bool = false
    @State private var homeSearchText: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    @State private var addByLinkErrorMessage: String?
    @State private var playbackHolder = PlaybackStateHolder()
    @State private var mediaPlayer: AVPlayer?
    private let sphereEngine = SphereAudioEngine.shared
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
    /// На iOS 26: 0 = мини-бар, 1 = большой плеер — один бар расширяется по ширине и высоте.
    @State private var playerExpandProgress: CGFloat = 0
    /// Смещение при смахивании большого плеера на iOS 26 (синхрон с hero-обложкой).
    @State private var expandingOverlayDragOffset: CGFloat = 0
    @StateObject private var remotePlaybackObserver = RemotePlaybackObserver()
    @StateObject private var audioRouteObserver = AudioRouteObserver()
    @State private var showDeveloperMenu = false
    @State private var showSettingsAvatarPicker = false
    @State private var settingsAvatarColorIndex = 0
    @State private var settingsCustomAvatarImage: UIImage?
    @State private var showSettingsGalleryPicker = false
    @State private var triggerSettingsAvatarPickerDismiss = false
    @AppStorage("playerStyleIndex") private var playerStyleIndex: Int = 0
    @AppStorage("enableCoverPaging") private var enableCoverPaging: Bool = true
    @AppStorage("enableRoundPlayerCover") private var enableRoundPlayerCover: Bool = false
    @AppStorage("enableCoverSeekAnimation") private var enableCoverSeekAnimation: Bool = false
    @AppStorage("coverSeekShakeDotIndex") private var coverSeekShakeDotIndex: Int = 0
    /// Точка 0 — дрожание (`CoverSeekShakeTiltModifier`); точка 1 — вращение при перемотке (`CoverSeekSpinModifier`).
    private var coverSeekWobbleOnSeek: Bool { min(max(coverSeekShakeDotIndex, 0), 1) == 0 }
    private var coverSeekSpinOnSeek: Bool { min(max(coverSeekShakeDotIndex, 0), 1) == 1 }
    /// Общее состояние перемотки (слайдер в большом плеере) — для анимации героя при выключенном перелистывании.
    @State private var isPlayerSeeking: Bool = false
    /// Скорость движения ползунка 0…1 — шейк обложки/героя только при реальном движении, затухает если палец не двигает.
    @State private var seekScrubIntensity: CGFloat = 0
    /// +1 перемотка вперёд, −1 назад (для вращения обложки).
    @State private var seekScrubDirection: CGFloat = 0
    @State private var showShareTrackSheet: Bool = false
    @State private var shareCatalogTrack: CatalogTrack?
    /// Счётчики полноценных стартов воспроизведения по `track.id` (для «Часто прослушиваемое»).
    @State private var trackPlayCounts: [UUID: Int] = [:]

    private static let trackPlayCountsDefaultsKey = "sphereTrackPlayCountsByTrackId"

    /// Next/previous и обложки в большом плеере: только порядок библиотеки по дате добавления (новые → старые), без учёта сортировки экрана и перестановок.
    private var tracksInPlaybackOrder: [AppTrack] {
        tracks.sorted { a, b in
            let da = a.addedAt ?? .distantPast
            let db = b.addedAt ?? .distantPast
            if da != db { return da > db }
            return a.id.uuidString < b.id.uuidString
        }
    }

    @AppStorage("sphereExcludedRecoTrackUUIDsJSON") private var excludedRecoTracksJSON: String = "[]"

    private var tracksExcludedFromRecommendations: Set<UUID> {
        sphereDecodedExcludedRecommendationIDs(from: excludedRecoTracksJSON)
    }

    /// Очередь «следующий / перелистывание обложек» без треков, скрытых из рекомендаций.
    private var tracksInPlaybackOrderForQueue: [AppTrack] {
        let ex = tracksExcludedFromRecommendations
        return tracksInPlaybackOrder.filter { !ex.contains($0.id) }
    }

    private func addCurrentTrackToExcludedRecommendations() {
        guard let id = currentTrack?.id else { return }
        var s = tracksExcludedFromRecommendations
        guard !s.contains(id) else { return }
        s.insert(id)
        excludedRecoTracksJSON = sphereEncodedExcludedRecommendationIDs(s)
    }

    // MARK: - Catalog / Backend

    @StateObject private var apiClient = SphereAPIClient.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @ObservedObject private var recentStore = RecentlyPlayedStore.shared
    @ObservedObject private var downloadsStore = DownloadsStore.shared
    @State private var catalogSearchResults: SearchResults?
    @State private var isCatalogSearching = false
    @State private var catalogSearchError: String?
    @State private var catalogSearchDebounce: Task<Void, Never>?
    private enum SearchMode: String, CaseIterable, Identifiable {
        case tracks
        case people
        var id: String { rawValue }
    }
    @State private var searchMode: SearchMode = .tracks
    @State private var userSearchResults: [BackendUserListItem] = []
    @State private var isUserSearching = false
    @State private var userSearchError: String?
    @State private var userSearchDebounce: Task<Void, Never>?
	    @State private var searchProviderFilter: String = "all"
	    @State private var presentedArtist: ArtistSheetItem?
	    @State private var presentedAlbum: CatalogAlbum?
	    @State private var isLoadingAlbum = false
	    @State private var isLoadingArtist = false
    @State private var currentCatalogTrack: CatalogTrack?
    @State private var catalogQueue: [CatalogTrack] = []
    @State private var catalogQueueIndex: Int = 0
    @State private var recommendations: RecommendationsResponse?
    @State private var isLoadingRecommendations = false
    @State private var showOnboarding = false

	    private func openAlbum(_ album: CatalogAlbum) {
	        presentedAlbum = album
	        isLoadingAlbum = true
	        Task {
	            let provider = album.provider
	            let albumID = album.id
	            do {
	                let full = try await apiClient.getAlbum(provider: album.provider, id: album.id)
	                await MainActor.run {
	                    if presentedAlbum?.provider == provider, presentedAlbum?.id == albumID {
	                        presentedAlbum = full
	                        isLoadingAlbum = false
	                    }
	                }
	            } catch {
	                await MainActor.run {
	                    if presentedAlbum?.provider == provider, presentedAlbum?.id == albumID {
	                        isLoadingAlbum = false
	                    }
	                }
	            }
	        }
	    }

    private func openArtistByName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = ArtistSheetItem.stableKey(forArtistName: trimmed)
        let placeholder = CatalogArtist(placeholder: trimmed)
        presentedArtist = ArtistSheetItem(name: trimmed, artist: placeholder)
        Task {
            do {
                let artist = try await apiClient.getArtistUnified(name: trimmed)
                await MainActor.run {
                    if presentedArtist?.id == key {
                        presentedArtist = ArtistSheetItem(name: trimmed, artist: artist)
                    }
                }
            } catch {
                print("[Sphere] load artist error:", error.localizedDescription)
            }
        }
    }

    private func debouncedCatalogSearch(_ query: String) {
        catalogSearchDebounce?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            catalogSearchResults = nil
            catalogSearchError = nil
            isCatalogSearching = false
            return
        }
        isCatalogSearching = true
        catalogSearchResults = nil
        catalogSearchError = nil
        let debounceNs: UInt64 = trimmed.count < 3 ? 600_000_000 : 400_000_000
        catalogSearchDebounce = Task {
            try? await Task.sleep(nanoseconds: debounceNs)
            guard !Task.isCancelled else { return }
            do {
                let prov = searchProviderFilter == "all" ? nil : searchProviderFilter
                let results = try await apiClient.search(query: trimmed, provider: prov, limit: 15)
                print("[Sphere] catalog search '\(trimmed)' → \(results.tracks.count) tracks, \(results.albums.count) albums, \(results.artists.count) artists")
                await MainActor.run {
                    catalogSearchResults = results
                    catalogSearchError = nil
                    isCatalogSearching = false
                }
            } catch {
                print("[Sphere] catalog search error: \(error.localizedDescription)")
                await MainActor.run {
                    catalogSearchError = error.localizedDescription
                    isCatalogSearching = false
                }
            }
        }
    }

    private func debouncedUserSearch(_ query: String) {
        userSearchDebounce?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            userSearchResults = []
            userSearchError = nil
            isUserSearching = false
            return
        }
        isUserSearching = true
        userSearchError = nil
        let debounceNs: UInt64 = trimmed.count < 3 ? 600_000_000 : 400_000_000
        userSearchDebounce = Task {
            try? await Task.sleep(nanoseconds: debounceNs)
            guard !Task.isCancelled else { return }
            do {
                let res = try await apiClient.searchUsers(query: trimmed, limit: 30)
                await MainActor.run {
                    userSearchResults = res
                    userSearchError = nil
                    isUserSearching = false
                }
            } catch {
                await MainActor.run {
                    userSearchError = error.localizedDescription
                    isUserSearching = false
                }
            }
        }
    }

    private func playCatalogTrack(_ track: CatalogTrack, queue: [CatalogTrack]? = nil, queueIndex: Int? = nil) {
        if let queue, let idx = queueIndex {
            catalogQueue = queue
            catalogQueueIndex = idx
        } else if let queue {
            catalogQueue = queue
            catalogQueueIndex = queue.firstIndex(where: { $0.id == track.id && $0.provider == track.provider }) ?? 0
        } else {
            catalogQueue = [track]
            catalogQueueIndex = 0
        }
        Task {
            do {
                let proxyBase = apiClient.baseURL
                let escapedProvider = track.provider.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.provider
                let escapedId = track.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.id

                let url: URL
                if let local = DownloadsStore.shared.localFileURL(provider: track.provider, id: track.id) {
                    url = local
                } else {
                    let lossless = UserDefaults.standard.bool(forKey: "sphereStreamLossless")
                    let qualitySuffix = lossless ? "?quality=flac" : ""
                    let proxyURLString = "\(proxyBase)/tracks/\(escapedProvider)/\(escapedId)/audio\(qualitySuffix)"
                    guard let u = URL(string: proxyURLString) else {
                        await MainActor.run {
                            playbackErrorMessage = isEnglish
                                ? "This track is not available for streaming"
                                : "Этот трек недоступен для воспроизведения"
                        }
                        return
                    }
                    url = u
                }
                guard !url.absoluteString.isEmpty else {
                    await MainActor.run {
                        playbackErrorMessage = isEnglish
                            ? "This track is not available for streaming"
                            : "Этот трек недоступен для воспроизведения"
                    }
                    return
                }
                print("[Sphere] streaming: \(url.absoluteString.prefix(120))")
                await MainActor.run {
                    mediaPlayer?.pause()
                    sphereEngine.stop()
                    usingEngine = false
                    playbackHolder.progress = 0
                    playbackHolder.currentTime = 0
                    playbackHolder.duration = 0
                    let item = AVPlayerItem(url: url)
                    item.preferredForwardBufferDuration = 8
                    let player = AVPlayer(playerItem: item)
                    mediaPlayer = player
                    player.play()
                    playbackHolder.isPlaying = true
                    let holder = playbackHolder
                    playbackHolder.statusObserver = item.observe(\.status, options: [.new]) { [weak player] item, _ in
                        guard item.status == .readyToPlay, let player else { return }
                        let dur = player.currentItem?.duration.seconds ?? 0
                        if dur.isFinite && dur > 0 {
                            DispatchQueue.main.async {
                                holder.duration = dur
                            }
                        }
                    }
                    NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { note in
                        if let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                            print("[Sphere] playback failed:", err.localizedDescription)
                        }
                    }
                    NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { _ in
                        if let log = item.errorLog()?.events.last {
                            print("[Sphere] AVPlayer error log:", log.errorComment ?? "", log.errorStatusCode)
                        }
                    }
                    let tempTrack = AppTrack(
                        id: UUID(),
                        url: url,
                        title: track.title,
                        artist: track.artist,
                        addedAt: Date()
                    )
                    currentTrack = tempTrack
                    currentCatalogTrack = track
                    playbackHolder.progress = 0
                    isMiniPlayerHidden = false
                    startProgressTimer()
                    loadCoverAndAccent(for: tempTrack)
                    RecentlyPlayedStore.shared.recordCatalog(
                        provider: track.provider,
                        providerId: track.id,
                        title: track.title,
                        artist: track.artist,
                        coverURL: track.coverURL
                    )
                }
                Task { try? await apiClient.recordHistory(track) }
            } catch {
                print("[Sphere] play catalog track error:", error.localizedDescription)
                await MainActor.run {
                    playbackErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private var hasNextTrack: Bool {
        let ordered = tracksInPlaybackOrderForQueue
        guard let current = currentTrack, let index = ordered.firstIndex(of: current) else { return false }
        return index < ordered.count - 1
    }

    /// Для hero-обложки: iOS 26 стиль 1 — playerDragOffset; стили 2/3 при currentTrack — expandingOverlayDragOffset; iOS 16–18 — playerDragOffset.
    private var heroCoverDragOffset: CGFloat {
        if #available(iOS 26.0, *) {
            if currentTrack != nil { return expandingOverlayDragOffset }
        } else {
            if playerStyleIndex == 1, currentTrack != nil { return expandingOverlayDragOffset }
        }
        return playerDragOffset
    }

    private var accent: Color { sphereAccentResolvedColor() }
    @State private var showEqualizerSheet = false
    @State private var showLyricsSheet = false
    /// Тексты песен: ключ — trackId.uuidString, значение — текст
    @AppStorage("sphere_lyrics_data") private var lyricsDataStorage: Data = Data()
    private var homeTitle: String { isEnglish ? "Home" : "Главная" }
    private var favoritesTitle: String { isEnglish ? "Favorites" : "Избранное" }
    private var settingsTitle: String { isEnglish ? "Settings" : "Настройки" }
    private var logoutTitle: String { isEnglish ? "Log out" : "Выйти" }
    private var libraryTitle: String { isEnglish ? "Library" : "Библиотека" }
    private var addMusicTitle: String { isEnglish ? "Add music from device" : "Добавить музыку с устройства" }
    private var libraryEmptyTitle: String { isEnglish ? "Your tracks will appear here" : "Здесь появятся ваши треки" }
    private var noResultsTitle: String { isEnglish ? "No results" : "Ничего не найдено" }
    private var homeSearchPlaceholder: String { isEnglish ? "Search" : "Поиск" }
    private var doneTitle: String { isEnglish ? "Done" : "Готово" }
    private var playbackErrorTitle: String { isEnglish ? "Playback error" : "Ошибка воспроизведения" }
    private var deleteTitle: String { isEnglish ? "Delete" : "Удалить" }
    private var moveTitle: String { isEnglish ? "Move" : "Переместить" }
    private var addByLinkLabel: String { isEnglish ? "Add track by link from Spotify" : "Добавить трек по ссылке из Spotify" }
    private var profileTitle: String { isEnglish ? "Profile" : "Профиль" }
    private var privacyTitle: String { isEnglish ? "Privacy" : "Конфиденциальность" }
    private var themeTitle: String { isEnglish ? "Appearance" : "Оформление" }
    private var otherSettingsNavTitle: String { isEnglish ? "Other" : "Другое" }
    private var customizationNavTitle: String { isEnglish ? "Customization" : "Кастомизация" }
    private var downloadedTracksTitle: String { isEnglish ? "Downloaded tracks" : "Скачанные треки" }

    /// Как `CreateAccountView.pickerColors` — та же сетка выбора аватарки.
    private var settingsAvatarPickerPalette: [Color] {
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

    private var settingsUseSheetForAvatarPicker: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private func syncSettingsAvatarPickerFromProfile() {
        guard let url = authService.currentProfile?.avatarUrl else {
            settingsAvatarColorIndex = 0
            settingsCustomAvatarImage = nil
            return
        }
        if let idx = SphereProfileAvatarPalette.presetIndex(from: url) {
            settingsAvatarColorIndex = idx
            settingsCustomAvatarImage = nil
        } else {
            settingsAvatarColorIndex = 7
            settingsCustomAvatarImage = nil
        }
    }

    private func commitSettingsAvatarSelection() async {
        guard authService.isSignedIn else { return }
        if settingsAvatarColorIndex < 7 {
            let newUrl = SphereProfileAvatarPalette.presetURL(for: settingsAvatarColorIndex)
            if authService.currentProfile?.avatarUrl != newUrl {
                await authService.updateProfile(nickname: nil, username: nil, bio: nil, avatarUrl: newUrl, updateBio: false)
            }
            settingsCustomAvatarImage = nil
        } else if let img = settingsCustomAvatarImage {
            await authService.updateProfileAvatar(image: img)
            settingsCustomAvatarImage = nil
        }
    }

    private var mainBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    private var isDarkMode: Bool { appDarkThemeFromStorage(preferredRaw: preferredColorSchemeRaw, colorScheme: colorScheme) }

    private static let storedTracksUserDefaultsKey = "storedTracksData"
    @State private var saveTracksWorkItem: DispatchWorkItem?

    /// Асинхронный `loadTracksFromStorage` раньше делал `tracks = resolved` и затирал треки, добавленные с устройства,
    /// если декодирование заканчивалось после импорта (до срабатывания debounce сохранения). Сливаем диск + память по `id`.
    private static func mergedTracksFromStorageLoad(disk: [AppTrack], memory: [AppTrack]) -> [AppTrack] {
        var byId = Dictionary(uniqueKeysWithValues: disk.map { ($0.id, $0) })
        for t in memory where byId[t.id] == nil {
            byId[t.id] = t
        }
        return Array(byId.values).sorted { a, b in
            let da = a.addedAt ?? .distantPast
            let db = b.addedAt ?? .distantPast
            if da != db { return da > db }
            return a.id.uuidString < b.id.uuidString
        }
    }

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
                DispatchQueue.main.async {
                    if tracks.isEmpty {
                        tracks = resolved
                    } else {
                        tracks = Self.mergedTracksFromStorageLoad(disk: resolved, memory: tracks)
                    }
                }
            } catch {
                print("Failed to decode tracks:", error)
            }
        }
    }

    private func tryPlayLastTrackFromWidget() {
        guard WidgetShared.sharedUserDefaults?.bool(forKey: WidgetShared.keyOpenPlayFromWidget) == true else { return }
        WidgetShared.sharedUserDefaults?.set(false, forKey: WidgetShared.keyOpenPlayFromWidget)
        WidgetShared.sharedUserDefaults?.synchronize()
        guard let pathComponent = WidgetShared.sharedUserDefaults?.string(forKey: WidgetShared.keyTrackPathComponent), !pathComponent.isEmpty else { return }
        guard let track = tracks.first(where: { $0.url.lastPathComponent == pathComponent }) else { return }
        startPlayback(for: track)
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
        let didStartAccess = src.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if didStartAccess { src.stopAccessingSecurityScopedResource() } }
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

    /// Импорт после «Поделиться → Sphere»: файл лежит в App Group (`ShareInbox/…`).
    private func importSharedInboxFileIfNeeded() {
        guard !shareImportRunning else { return }
        guard let defaults = WidgetShared.sharedUserDefaults,
              let container = WidgetShared.appGroupContainerURL else { return }
        guard let rel = defaults.string(forKey: WidgetShared.keyShareImportRelativePath), !rel.isEmpty else { return }

        shareImportRunning = true
        let displayTitleOverride = defaults.string(forKey: WidgetShared.keyShareImportDisplayTitle)
        let displayArtistOverride = defaults.string(forKey: WidgetShared.keyShareImportDisplayArtist)
        defaults.removeObject(forKey: WidgetShared.keyShareImportRelativePath)
        defaults.removeObject(forKey: WidgetShared.keyShareImportDisplayTitle)
        defaults.removeObject(forKey: WidgetShared.keyShareImportDisplayArtist)
        defaults.synchronize()

        let src = container.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: src.path) else {
            shareImportRunning = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                DispatchQueue.main.async { self.shareImportRunning = false }
                return
            }
            let ext = src.pathExtension.isEmpty ? "mp3" : src.pathExtension
            let dest = documents.appendingPathComponent("imported_\(UUID().uuidString).\(ext)", isDirectory: false)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
                try? fm.removeItem(at: src)
                self.saveArtworkAndMetadataFromAudioFile(at: dest) { title, artist in
                    let resolvedTitle: String? = {
                        if let o = displayTitleOverride, !o.isEmpty { return o }
                        if let t = title, !t.isEmpty { return t }
                        return dest.deletingPathExtension().lastPathComponent
                    }()
                    let resolvedArtist: String? = {
                        if let o = displayArtistOverride, !o.isEmpty { return o }
                        return artist
                    }()
                    DispatchQueue.main.async {
                        self.shareImportRunning = false
                        let newTrack = AppTrack(url: dest, title: resolvedTitle, artist: resolvedArtist, addedAt: Date())
                        if !self.tracks.contains(where: { $0.id == newTrack.id }) {
                            if self.addNewTracksAtStart {
                                self.tracks.insert(newTrack, at: 0)
                            } else {
                                self.tracks.append(newTrack)
                            }
                        }
                        self.currentTrack = newTrack
                        self.isMiniPlayerHidden = false
                        self.loadCoverAndAccent(for: newTrack)
                        self.startPlayback(for: newTrack)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.shareImportRunning = false }
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
                addByLinkErrorMessage = isEnglish ? "Spotify API URL is not set. Set the URL in Settings (spotisaver)." : "Не задан URL API Spotify. Укажите URL в настройках (spotisaver)."
                return
            }
            isAddingFromLink = true
            addByLinkErrorMessage = nil
            fetchViaAPIAndAddToLibrary(linkURL: url)
            return
        }
        addByLinkErrorMessage = isEnglish ? "Link must be a Spotify track link" : "Ссылка должна быть на трек Spotify"
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
        var finalAPIURL: URL?
        if let parsed = URL(string: baseForAPI), let host = parsed.host, !host.isEmpty {
            var comp = URLComponents()
            comp.scheme = parsed.scheme ?? "https"
            comp.host = host
            comp.port = parsed.port
            comp.path = "/api"
            comp.queryItems = [URLQueryItem(name: "url", value: linkURL.absoluteString)]
            finalAPIURL = comp.url
        }
        guard let apiURL = finalAPIURL else {
            DispatchQueue.main.async {
                self.addByLinkErrorMessage = self.isEnglish ? "Invalid conversion API URL" : "Некорректный URL API конвертации"
                self.isAddingFromLink = false
            }
            return
        }
        let addNewTracksAtStart = self.addNewTracksAtStart
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 60 // макс. 1 минута — потом показываем ошибку
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning") // иначе бесплатный ngrok отдаёт HTML-страницу вместо ответа API
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let err = error {
                DispatchQueue.main.async {
                    self.addByLinkErrorMessage = (err as NSError).code == NSURLErrorTimedOut
                        ? (self.isEnglish ? "Request timed out. Try Wi‑Fi." : "Таймаут. Подключитесь по Wi‑Fi и попробуйте снова.")
                        : err.localizedDescription
                    self.isAddingFromLink = false
                }
                return
            }
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
            if data.count < 50_000 {
                DispatchQueue.main.async {
                    self.addByLinkErrorMessage = self.isEnglish
                        ? "File too small (download may have been interrupted). Try again or another track."
                        : "Файл слишком маленький. Попробуйте снова или другой трек."
                    self.isAddingFromLink = false
                }
                return
            }
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

    private func loadTrackPlayCountsFromStorage() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.trackPlayCountsDefaultsKey) as? [String: Int] else {
            trackPlayCounts = [:]
            return
        }
        var m: [UUID: Int] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else { continue }
            m[id] = value
        }
        trackPlayCounts = m
    }

    private func persistTrackPlayCounts() {
        var raw: [String: Int] = [:]
        for (id, n) in trackPlayCounts {
            raw[id.uuidString] = n
        }
        UserDefaults.standard.set(raw, forKey: Self.trackPlayCountsDefaultsKey)
    }

    /// true если текущий трек играет через SphereAudioEngine (с EQ), false — через AVPlayer (fallback)
    @State private var usingEngine = false

    private func startPlayback(for track: AppTrack) {
        DispatchQueue.main.async {
            var didRecordPlayCountForThisSession = false
            self.currentTrack = track
            self.currentCatalogTrack = nil
            RecentlyPlayedStore.shared.recordLocal(
                id: track.id,
                title: track.displayTitle,
                artist: track.displayArtist
            )
            let coverImage = loadCoverImage(for: track)
            WidgetShared.saveLastPlayedTrack(
                id: track.id.uuidString,
                title: track.title,
                artist: track.artist,
                pathComponent: track.url.lastPathComponent,
                coverImage: coverImage
            )
            // Сессия уже настроена в SphereApp; только активируем при необходимости
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

            self.stopProgressTimer()
            self.sphereEngine.stop()
            self.mediaPlayer?.pause()
            self.mediaPlayer?.replaceCurrentItem(with: nil)

            var url = track.url
            if !url.isFileURL || !url.path.hasPrefix(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "") {
                _ = url.startAccessingSecurityScopedResource()
            }
            let fileURL = url.isFileURL ? URL(fileURLWithPath: url.path) : url

            if fileURL.isFileURL && !FileManager.default.fileExists(atPath: fileURL.path) {
                self.playbackErrorMessage = self.isEnglish ? "File not found" : "Файл не найден"
                return
            }

            self.playbackHolder.currentTime = 0
            self.playbackHolder.progress = 0
            self.playbackHolder.duration = 0
            self.playbackErrorMessage = nil
            self.playReadyCancellable?.cancel()
            self.playReadyTimeoutWorkItem?.cancel()

            // Пробуем SphereAudioEngine (с эквалайзером)
            if fileURL.isFileURL && self.sphereEngine.load(url: fileURL) {
                self.usingEngine = true
                self.mediaPlayer = nil
                let d = self.sphereEngine.duration
                if d > 0 { self.playbackHolder.duration = d }
                if !didRecordPlayCountForThisSession {
                    didRecordPlayCountForThisSession = true
                    let tid = track.id
                    let n = (self.trackPlayCounts[tid] ?? 0) + 1
                    self.trackPlayCounts[tid] = n
                    self.persistTrackPlayCounts()
                }
                self.sphereEngine.play()
                self.playbackHolder.isPlaying = true
                self.startProgressTimer()
                self.updateNowPlayingInfo()
                return
            }

            // Fallback: AVPlayer (без эквалайзера)
            self.usingEngine = false
            let item = AVPlayerItem(url: fileURL)
            let player = AVPlayer(playerItem: item)
            player.volume = Float(self.volume)
            self.mediaPlayer = player

            func tryStartPlayback() {
                guard self.mediaPlayer?.currentItem === item else { return }
                let d = CMTimeGetSeconds(item.duration)
                if d.isFinite && d > 0 { self.playbackHolder.duration = d }
                if !didRecordPlayCountForThisSession {
                    didRecordPlayCountForThisSession = true
                    let tid = track.id
                    let n = (self.trackPlayCounts[tid] ?? 0) + 1
                    self.trackPlayCounts[tid] = n
                    self.persistTrackPlayCounts()
                }
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
                        let raw = item.error?.localizedDescription ?? ""
                        if raw.contains("Operation Stopped") || raw.contains("stopped") {
                            self.playbackErrorMessage = self.isEnglish
                                ? "File may be corrupted or incomplete. Remove the track and add it again by link."
                                : "Файл мог повредиться или загрузка не завершилась. Удалите трек и добавьте по ссылке снова."
                        } else {
                            self.playbackErrorMessage = raw.isEmpty ? (self.isEnglish ? "Playback error" : "Ошибка воспроизведения") : raw
                        }
                        self.playbackHolder.isPlaying = false
                        self.stopProgressTimer()
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
        }
    }

    private func togglePlayPause() {
        if usingEngine {
            if sphereEngine.isPlaying {
                sphereEngine.pause()
                playbackHolder.isPlaying = false
                stopProgressTimer()
                DiscordRPC.shared.clearPresence()
            } else {
                let dur = sphereEngine.duration
                let atEnd = dur > 0 && sphereEngine.progress >= 0.99
                if atEnd {
                    if repeatMode == .playNext && hasNextTrack {
                        playNextTrack()
                        return
                    }
                    lastSeekTime = Date()
                    sphereEngine.seek(to: 0)
                    playbackHolder.currentTime = 0
                    playbackHolder.progress = 0
                    playbackHolder.duration = dur
                    sphereEngine.play()
                    playbackHolder.isPlaying = true
                    startProgressTimer()
                    lastSeekTime = nil
                    return
                }
                sphereEngine.play()
                playbackHolder.isPlaying = true
                startProgressTimer()
            }
            return
        }

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
            DiscordRPC.shared.clearPresence()
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
        if currentCatalogTrack != nil, !catalogQueue.isEmpty, catalogQueueIndex > 0 {
            catalogQueueIndex -= 1
            playCatalogTrack(catalogQueue[catalogQueueIndex], queue: catalogQueue, queueIndex: catalogQueueIndex)
            return
        }
        let ordered = tracksInPlaybackOrderForQueue
        guard !ordered.isEmpty else { return }
        guard let current = currentTrack,
              let index = ordered.firstIndex(of: current),
              index > 0 else { return }
        let previous = ordered[index - 1]
        currentTrack = previous
        playbackHolder.progress = 0
        startPlayback(for: previous)
    }

    private func playNextTrack() {
        if currentCatalogTrack != nil, !catalogQueue.isEmpty, catalogQueueIndex < catalogQueue.count - 1 {
            catalogQueueIndex += 1
            playCatalogTrack(catalogQueue[catalogQueueIndex], queue: catalogQueue, queueIndex: catalogQueueIndex)
            return
        }
        let ordered = tracksInPlaybackOrderForQueue
        guard !ordered.isEmpty else { return }
        guard let current = currentTrack,
              let index = ordered.firstIndex(of: current),
              index < ordered.count - 1 else { return }
        let next = ordered[index + 1]
        currentTrack = next
        playbackHolder.progress = 0
        startPlayback(for: next)
    }

    private func playTrackAtIndex(_ index: Int) {
        let ordered = tracksInPlaybackOrderForQueue
        guard ordered.indices.contains(index) else { return }
        let track = ordered[index]
        currentTrack = track
        playbackHolder.progress = 0
        isMiniPlayerHidden = false
        startPlayback(for: track)
    }

    private func removeTrack(id trackId: UUID) {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return }
        removeTrack(track)
    }

    private func removeTrack(_ track: AppTrack) {
        let wasCurrent = currentTrack?.id == track.id
        let indexBefore = tracks.firstIndex(where: { $0.id == track.id })
        trackPlayCounts[track.id] = nil
        persistTrackPlayCounts()
        try? FileManager.default.removeItem(at: track.url)
        let coverURL = coverImageURL(for: track)
        try? FileManager.default.removeItem(at: coverURL)
        withAnimation(.easeOut(duration: 0.28)) {
            tracks.removeAll { $0.id == track.id }
        }
        if wasCurrent {
            sphereEngine.stop()
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
        if usingEngine {
            let dur = sphereEngine.duration
            guard dur > 0 else { return }
            let clamped = min(max(progress, 0), 1)
            let isRewindForRepeat = clamped >= 0.98 && repeatMode == .repeatOne
            if !isRewindForRepeat { lastSeekTime = Date() }

            if clamped >= 0.98 {
                if repeatMode == .playNext && hasNextTrack { playNextTrack(); return }
                if repeatMode == .repeatOne {
                    sphereEngine.seek(to: 0)
                    playbackHolder.currentTime = 0
                    playbackHolder.progress = 0
                    playbackHolder.duration = dur
                    sphereEngine.play()
                    playbackHolder.isPlaying = true
                    startProgressTimer()
                    lastSeekTime = nil
                    return
                }
                playbackHolder.progress = 1
                playbackHolder.currentTime = dur
                playbackHolder.duration = dur
                sphereEngine.pause()
                sphereEngine.seek(to: 1)
                playbackHolder.isPlaying = false
                stopProgressTimer()
                return
            }
            sphereEngine.seek(to: clamped)
            playbackHolder.progress = clamped
            playbackHolder.currentTime = clamped * dur
            playbackHolder.duration = dur
            return
        }

        guard let player = mediaPlayer, let currentItem = player.currentItem else { return }
        var dur = currentItem.duration.seconds
        if !dur.isFinite || dur <= 0 {
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
        let interval: TimeInterval = (isPlayerSheetPresented || showLyricsSheet) ? 0.25 : 1.0
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            if let last = lastSeekTime, Date().timeIntervalSince(last) < 0.5 { return }
            DispatchQueue.main.async {
                if usingEngine {
                    let dur = sphereEngine.duration
                    guard dur > 0 else { return }
                    updateNowPlayingInfo()
                    if !sphereEngine.isPlaying {
                        if sphereEngine.progress >= 0.99 {
                            if repeatMode == .playNext && hasNextTrack { playNextTrack(); return }
                            if repeatMode == .repeatOne {
                                sphereEngine.seek(to: 0)
                                playbackHolder.currentTime = 0
                                playbackHolder.progress = 0
                                playbackHolder.duration = dur
                                sphereEngine.play()
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
                        }
                        return
                    }
                    let newTime = sphereEngine.currentTime
                    let newProgress = newTime / dur
                    if abs(newProgress - playbackHolder.progress) > 0.002 || abs(newTime - playbackHolder.currentTime) > 0.15 {
                        playbackHolder.currentTime = newTime
                        playbackHolder.duration = dur
                        playbackHolder.progress = newProgress
                    }
                    if newTime >= dur - 0.01 {
                        if repeatMode == .playNext && hasNextTrack { playNextTrack(); return }
                        if repeatMode == .repeatOne {
                            sphereEngine.seek(to: 0)
                            playbackHolder.currentTime = 0
                            playbackHolder.progress = 0
                            playbackHolder.duration = dur
                            sphereEngine.play()
                            playbackHolder.isPlaying = true
                            startProgressTimer()
                            lastSeekTime = nil
                            return
                        }
                        sphereEngine.pause()
                        playbackHolder.isPlaying = false
                        stopProgressTimer()
                        playbackHolder.progress = 1
                        playbackHolder.currentTime = dur
                    }
                    return
                }
                // AVPlayer fallback
                guard let player = mediaPlayer else { return }
                let dur = player.currentItem?.duration.seconds ?? 0
                guard dur.isFinite, dur > 0 else { return }
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
            artwork: currentCoverImage,
            clipURL: currentCatalogTrack?.clipURL.flatMap { URL(string: $0) }
        )
    }

    /// Полная остановка воспроизведения при выходе из аккаунта (трек не должен играть на экране входа).
    private func stopPlaybackOnLogout() {
        isPlayerSheetPresented = false
        stopProgressTimer()
        sphereEngine.stop()
        mediaPlayer?.pause()
        mediaPlayer?.replaceCurrentItem(with: nil)
        currentTrack = nil
        playbackHolder.isPlaying = false
        playbackHolder.progress = 0
        playbackHolder.currentTime = 0
        playbackHolder.duration = 0
        DiscordRPC.shared.clearPresence()
        currentCoverImage = nil
        currentCoverAccent = nil
    }

    private func loadCoverAndAccent(for track: AppTrack) {
        currentCoverImage = coverImageCache[track.id]
        currentCoverAccent = coverAccentCache[track.id]

        if let catalogTrack = currentCatalogTrack,
           let urlStr = catalogTrack.coverURL,
           let coverURL = URL(string: urlStr) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: coverURL)
                    if let img = UIImage(data: data) {
                        let accentColor = dominantColor(from: img)
                        await MainActor.run {
                            coverImageCache[track.id] = img
                            if let accentColor { coverAccentCache[track.id] = accentColor }
                            currentCoverImage = img
                            currentCoverAccent = accentColor
                            updateNowPlayingInfo()
                        }
                    }
                } catch {
                    print("[Sphere] cover download error:", error.localizedDescription)
                }
            }
            return
        }

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
	        if #available(iOS 26.0, *) {
	            isPlayerSheetPresented = true
	            withAnimation(Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45)) {
                playerExpandProgress = 1
            }
        } else {
            if playerStyleIndex == 1 {
                isPlayerSheetPresented = true
                withAnimation(Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45)) {
                    playerExpandProgress = 1
                }
            } else {
                withAnimation(Self.playerSheetAnimation) {
                    isPlayerSheetPresented = true
                }
            }
	        }
	    }

	    private func finishStyle1ExpandingPlayerDismissIfNeeded() {
	        guard playerStyleIndex == 0 else { return }
	        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
	            if isPlayerSheetClosing {
	                isPlayerSheetPresented = false
	                isPlayerSheetClosing = false
	                playerExpandProgress = 0
	                expandingOverlayDragOffset = 0
	            }
	        }
	    }

	    @ViewBuilder
	    private var tabContent: some View {
        if #available(iOS 26.0, *) {
            tabViewLiquidGlass
        } else {
            tabViewWithInset
        }
    }

    @available(iOS 26.0, *)
    private var tabViewLiquidGlass: some View {
        TabView(selection: $selectedTab) {
            Tab(isEnglish ? "Home" : "Главная", systemImage: "house.fill", value: .home) {
                homeTab
            }
            Tab(isEnglish ? "Favorites" : "Избранное", systemImage: "heart.fill", value: .favorites) {
                favoritesTab
            }
            Tab(value: .profile) {
                settingsTab
            } label: {
                if let avatar = profileAvatarUIImage {
                    Label {
                        Text(authService.currentProfile?.nickname ?? (isEnglish ? "Profile" : "Профиль"))
                    } icon: {
                        Image(uiImage: avatar)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                    }
                } else {
                    Label(isEnglish ? "Profile" : "Профиль", systemImage: "person.fill")
                }
            }
            Tab(isEnglish ? "Search" : "Поиск", systemImage: "magnifyingglass", value: .search, role: .search) {
                searchTab
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(accent)
        .tabViewBottomAccessory {
            EmptyView()
        }
        .onChange(of: selectedTab) { newValue in
            if newValue != .search { homeSearchText = "" }
        }
    }

    /// Анимация перелистывания: spring, чтобы на ProMotion шло до 120 fps.
    private static var pageSnapAnimation: Animation {
        .interactiveSpring(response: 0.38, dampingFraction: 0.86)
    }

    /// Четыре вкладки в одну горизонтальную «ленту»; переключение только по таббару (свайп по контенту отключён).
    private var pagedTabContent: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                homeTab
                    .frame(width: w, height: geo.size.height)
                favoritesTab
                    .frame(width: w, height: geo.size.height)
                settingsTab
                    .frame(width: w, height: geo.size.height)
                searchTab
                    .frame(width: w, height: geo.size.height)
            }
            .frame(width: w * 4, height: geo.size.height, alignment: .leading)
            .offset(x: -pageScrollOffset * w)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            pageScrollOffset = CGFloat(selectedTab.rawValue)
        }
        .onChange(of: selectedTab) { newValue in
            if newValue != .search {
                homeSearchText = ""
            }
            withAnimation(Self.pageSnapAnimation) {
                pageScrollOffset = CGFloat(newValue.rawValue)
            }
        }
    }

    private var tabBarInset: some View {
        VStack(spacing: 0) {
            if let currentTrack, !isPlayerSheetPresented, !isMiniPlayerHidden {
                miniPlayer(for: currentTrack, namespace: playerCoverNamespace, playbackHolder: playbackHolder)
                Spacer().frame(height: 6)
            }
            TabBarSwiftUI(
                homeTitle: homeTitle,
                favoritesTitle: favoritesTitle,
                profileTitle: profileTitle,
                searchTitle: homeSearchPlaceholder,
                accent: accent,
                avatarImage: profileAvatarUIImage,
                selectedTab: $selectedTab,
                onSettingsFiveTaps: { showDeveloperMenu = true }
            )
            .frame(height: 56)
            .padding(.bottom, 2)
        }
        .animation(.easeInOut(duration: 0.25), value: currentTrack != nil)
    }

    /// iOS 26: системный `TabView` — отдельный корень на вкладку, без горизонтальной ленты; анимация переключения штатная. 5 тапов по области «Настройки» на таббаре → меню разработчика.
    @available(iOS 26.0, *)
    private var tabViewIOS26: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .tag(MainAppTab.home)
            favoritesTab
                .tag(MainAppTab.favorites)
            settingsTab
                .tag(MainAppTab.profile)
        }
        .background(mainBackground.ignoresSafeArea())
        .background(TabBarDebugTapInjector(onSettingsFiveTaps: { showDeveloperMenu = true }))
        .onChange(of: selectedTab) { newValue in
            if newValue != .home {
                homeSearchText = ""
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playerStyleIndex == 0, let _ = currentTrack, !isPlayerSheetPresented, !isMiniPlayerHidden {
                // Стиль 0 на iOS 26: мини-бар уже рисуется через ExpandingGlassPlayerOverlay (.overlay в mainBodyBase).
                // Здесь резервируем только высоту, чтобы контент таба не уходил под бар. Иначе обложка дублируется и при сворачивании плеера разворачивается на весь экран.
                Color.clear.frame(height: 64 + 12)
            } else if let currentTrack, !isMiniPlayerHidden {
                Color.clear.frame(height: 64 + 12 + 24)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: currentTrack != nil)
    }

    /// iOS 16–18: перелистывание страниц и кастомный таббар.
    private var tabViewWithInset: some View {
        pagedTabContent
            .background(mainBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                tabBarInset
            }
    }

    /// iOS 26: один liquid glass бар — в мини состоянии внизу экрана, по тапу расширяется до полного плеера и обратно; большой плеер можно стянуть вниз.
    @available(iOS 26.0, *)
    private struct ExpandingGlassPlayerOverlay<Content: View>: View {
        @Binding var expandProgress: CGFloat
        @Binding var fullPlayerDragOffset: CGFloat
        /// Скрывать мини-обложку, когда герой показывается (открытие) или закрывается — одна обложка плавно превращается в другую.
        let hideMiniCover: Bool
        let roundPlayerCover: Bool
        let track: AppTrack
        let accent: Color
        var catalogCoverURL: String? = nil
        /// Цвет от обложки трека — стекло подстраивается под градиентный фон.
        var coverAccent: Color?
        @ObservedObject var playbackHolder: PlaybackStateHolder
        let onTapMini: () -> Void
        let onPlayPause: () -> Void
        let onDismissFull: () -> Void
        @ViewBuilder let fullSheetContent: () -> Content

        private var expandAnimation: Animation { .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45) }

        var body: some View {
            GeometryReader { geo in
                let progress = expandProgress
                let minW = geo.size.width - 32
                let minH: CGFloat = 64
                let barW = minW + (geo.size.width - minW) * progress
                let barH = minH + (geo.size.height - minH) * progress
                let radius = 20 * (1 - progress) + 12 * progress
                let shape = RoundedRectangle(cornerRadius: radius)

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: radius)
                        .frame(width: barW, height: barH)
                        .glassEffect(.regular.interactive(), in: shape)
                        .frame(width: barW, height: barH)

                    ZStack {
                        miniBarContent
                            .opacity(1 - progress)
                            .allowsHitTesting(progress < 0.5)

                        fullSheetContent()
                            .opacity(progress)
                            .allowsHitTesting(progress >= 0.5)
                    }
                    .frame(width: barW, height: barH)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, (1 - progress) * (geo.safeAreaInsets.bottom + 90))
                .offset(y: progress >= 0.5 ? fullPlayerDragOffset : 0)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            if progress >= 0.5, value.translation.height > 0 {
                                fullPlayerDragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if progress >= 0.5 {
                                let threshold: CGFloat = 100
                                if value.translation.height > threshold || value.predictedEndTranslation.height > threshold {
                                    onDismissFull()
                                    fullPlayerDragOffset = 0
                                } else {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        fullPlayerDragOffset = 0
                                    }
                                }
                            }
                        }
                )
                .onChange(of: expandProgress) { newProgress in
                    if newProgress < 0.5 { fullPlayerDragOffset = 0 }
                }
            }
            .ignoresSafeArea()
        }

        private var miniBarContent: some View {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if hideMiniCover {
                        Color.clear.frame(width: 40, height: 40)
                    } else {
                        MiniPlayerCoverViewIOS26(track: track, accent: accent, roundPlayerCover: roundPlayerCover, catalogCoverURL: catalogCoverURL)
                            .frame(width: 40, height: 40)
                    }
                }
                .overlay(
                    GeometryReader { g in
                        Color.clear.preference(key: MiniCoverFrameKey.self, value: g.frame(in: .global))
                    }
                )
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTapMini() }
                Spacer(minLength: 0)
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
        }
    }

    /// iOS 16–18 стиль 2: один бар с блюром — мини перетекает в большой (.ultraThinMaterial + оттенок по теме).
    private struct LegacyExpandingBlurOverlay<Content: View>: View {
        @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: String = ""
        @Environment(\.colorScheme) private var colorScheme
        @Binding var expandProgress: CGFloat
        @Binding var fullPlayerDragOffset: CGFloat
        let hideMiniCover: Bool
        let track: AppTrack
        let accent: Color
        var coverAccent: Color?
        @ObservedObject var playbackHolder: PlaybackStateHolder
        let onTapMini: () -> Void
        let onPlayPause: () -> Void
        let onDismissFull: () -> Void
        @ViewBuilder let fullSheetContent: (Bool) -> Content

        var body: some View {
            GeometryReader { geo in
                let progress = expandProgress
                let minW = geo.size.width - 32
                let minH: CGFloat = 64
                let barW = minW + (geo.size.width - minW) * progress
                let barH = minH + (geo.size.height - minH) * progress
                let radius = 20 * (1 - progress) + 12 * progress
                let appDark = appDarkThemeFromStorage(preferredRaw: preferredColorSchemeRaw, colorScheme: colorScheme)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.ultraThinMaterial)
                        .frame(width: barW, height: barH)
                    RoundedRectangle(cornerRadius: radius)
                        .fill((appDark ? Color.black : Color.white).opacity(appDark ? 0.35 : 0.18))
                        .frame(width: barW, height: barH)
                    ZStack {
                        legacyMiniBarContent
                            .opacity(1 - progress)
                            .allowsHitTesting(progress < 0.5)
                        fullSheetContent(appDark)
                            .opacity(progress)
                            .allowsHitTesting(progress >= 0.5)
                    }
                    .frame(width: barW, height: barH)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                }
                .id("legacyBar-\(preferredColorSchemeRaw)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, (1 - progress) * (geo.safeAreaInsets.bottom + 90))
                .offset(y: (1 - progress) * -55)
                .offset(y: progress >= 0.5 ? fullPlayerDragOffset : 0)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            if progress >= 0.5, value.translation.height > 0 {
                                fullPlayerDragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if progress >= 0.5 {
                                let threshold: CGFloat = 100
                                if value.translation.height > threshold || value.predictedEndTranslation.height > threshold {
                                    onDismissFull()
                                    fullPlayerDragOffset = 0
                                } else {
                                    withAnimation(.easeOut(duration: 0.25)) { fullPlayerDragOffset = 0 }
                                }
                            }
                        }
                )
                .onChange(of: expandProgress) { newProgress in
                    if newProgress < 0.5 { fullPlayerDragOffset = 0 }
                }
            }
            .ignoresSafeArea()
        }

        private var legacyMiniBarContent: some View {
            HStack(alignment: .center, spacing: 12) {
                Color.clear.frame(width: 40, height: 40)
                    .overlay(GeometryReader { g in Color.clear.preference(key: MiniCoverFrameKey.self, value: g.frame(in: .global)) })
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTapMini() }
                Spacer(minLength: 0)
                Button { onPlayPause() } label: {
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
        }
    }

    @ViewBuilder
    private var playerSheetOverlayContent: some View {
        if #available(iOS 26.0, *) {
            if let currentTrack {
	                ExpandingGlassPlayerOverlay(
	                    expandProgress: $playerExpandProgress,
	                    fullPlayerDragOffset: $expandingOverlayDragOffset,
	                    hideMiniCover: isPlayerSheetPresented || isPlayerSheetClosing,
                    roundPlayerCover: enableRoundPlayerCover,
                    track: currentTrack,
                    accent: accent,
                    catalogCoverURL: currentCatalogTrack?.coverURL,
                    coverAccent: currentCoverAccent,
                    playbackHolder: playbackHolder,
                    onTapMini: openPlayerSheet,
                    onPlayPause: togglePlayPause,
	                    onDismissFull: {
	                        isPlayerSheetClosing = true
	                        withAnimation(Self.playerSheetAnimation) {
	                            playerExpandProgress = 0
	                            expandingOverlayDragOffset = 0
	                        }
	                        finishStyle1ExpandingPlayerDismissIfNeeded()
	                    },
                    fullSheetContent: {
                        if playerStyleIndex == 0 {
                            PlayerSheetViewStyle1FromBackup(
                                track: currentTrack,
                                catalogTrack: currentCatalogTrack,
                                accent: accent,
                                coverImage: currentCoverImage,
                                coverAccent: currentCoverAccent,
                                namespace: playerCoverNamespace,
                                isEnglish: isEnglish,
                                playbackHolder: playbackHolder,
                                audioRouteObserver: audioRouteObserver,
                                volume: $volume,
	                                onDismiss: {
	                                    isPlayerSheetClosing = true
	                                    withAnimation(Self.playerSheetAnimation) {
	                                        playerExpandProgress = 0
	                                        expandingOverlayDragOffset = 0
	                                    }
	                                    finishStyle1ExpandingPlayerDismissIfNeeded()
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
                                onDeleteTrackFromDevice: { removeTrack(currentTrack) },
                                onHideTrackFromRecommendations: { addCurrentTrackToExcludedRecommendations() },
                                onOpenEqualizer: { showEqualizerSheet = true },
                                onLyricsTap: { showLyricsSheet = true },
                                onArtistTap: { openArtistByName(currentTrack.displayArtist) },
                                isBottomSheet: true,
                                tracks: tracksInPlaybackOrderForQueue,
                                currentTrackIndex: tracksInPlaybackOrderForQueue.firstIndex(where: { $0.id == currentTrack.id }) ?? 0,
                                coverImages: tracksInPlaybackOrderForQueue.map { coverImageCache[$0.id] },
                                onTrackSelected: { index in playTrackAtIndex(index) },
                                enableCoverPaging: enableCoverPaging,
                                enableCoverSeekAnimation: enableCoverSeekAnimation,
                                coverSeekWobbleOnSeek: coverSeekWobbleOnSeek,
                                coverSeekSpinOnSeek: coverSeekSpinOnSeek,
                                roundPlayerCover: enableRoundPlayerCover,
                                isSeeking: $isPlayerSeeking,
                                seekScrubIntensity: $seekScrubIntensity,
                                seekScrubDirection: $seekScrubDirection
                            )
                        } else {
                            PlayerSheetView(
                                track: currentTrack,
                                catalogTrack: currentCatalogTrack,
                                accent: accent,
                                coverImage: currentCoverImage,
                                coverAccent: currentCoverAccent,
                                namespace: playerCoverNamespace,
                                isEnglish: isEnglish,
                                playbackHolder: playbackHolder,
                                audioRouteObserver: audioRouteObserver,
                                volume: $volume,
                                onDismiss: {
                                    isPlayerSheetClosing = true
                                    withAnimation(Self.playerSheetAnimation) {
                                        playerExpandProgress = 0
                                        expandingOverlayDragOffset = 0
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
                                onDeleteTrackFromDevice: { removeTrack(currentTrack) },
                                onHideTrackFromRecommendations: { addCurrentTrackToExcludedRecommendations() },
                                onOpenEqualizer: { showEqualizerSheet = true },
                                onShareCatalogTrack: { ct in
                                    shareCatalogTrack = ct
                                    showShareTrackSheet = true
                                },
                                onLyricsTap: { showLyricsSheet = true },
                                onArtistTap: { openArtistByName(currentTrack.displayArtist) },
                                tracks: tracksInPlaybackOrderForQueue,
                                currentTrackIndex: tracksInPlaybackOrderForQueue.firstIndex(where: { $0.id == currentTrack.id }) ?? 0,
                                coverImages: tracksInPlaybackOrderForQueue.map { coverImageCache[$0.id] },
                                onTrackSelected: { index in playTrackAtIndex(index) },
                                enableCoverPaging: enableCoverPaging,
                                enableCoverSeekAnimation: enableCoverSeekAnimation,
                                coverSeekWobbleOnSeek: coverSeekWobbleOnSeek,
                                coverSeekSpinOnSeek: coverSeekSpinOnSeek,
                                roundPlayerCover: enableRoundPlayerCover,
                                expandProgress: playerExpandProgress,
                                isBottomSheet: true,
                                transparentBackground: true,
                                playerStyleIndex: playerStyleIndex,
                                isSeeking: $isPlayerSeeking,
                                seekScrubIntensity: $seekScrubIntensity,
                                seekScrubDirection: $seekScrubDirection
                            )
                        }
                    }
                )
            }
        } else if playerStyleIndex == 1, let currentTrack {
            LegacyExpandingBlurOverlay(
                expandProgress: $playerExpandProgress,
                fullPlayerDragOffset: $expandingOverlayDragOffset,
                hideMiniCover: isPlayerSheetPresented || isPlayerSheetClosing,
                track: currentTrack,
                accent: accent,
                coverAccent: currentCoverAccent,
                playbackHolder: playbackHolder,
                onTapMini: openPlayerSheet,
                onPlayPause: togglePlayPause,
                onDismissFull: {
                    isPlayerSheetClosing = true
                    withAnimation(Self.playerSheetAnimation) { playerExpandProgress = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isPlayerSheetPresented = false
                        isPlayerSheetClosing = false
                        expandingOverlayDragOffset = 0
                    }
                },
                fullSheetContent: { isDark in
                    PlayerSheetView(
                        track: currentTrack,
                        catalogTrack: currentCatalogTrack,
                        accent: accent,
                        coverImage: currentCoverImage,
                        coverAccent: currentCoverAccent,
                        namespace: playerCoverNamespace,
                        isEnglish: isEnglish,
                        playbackHolder: playbackHolder,
                        audioRouteObserver: audioRouteObserver,
                        volume: $volume,
                        onDismiss: {
                            isPlayerSheetClosing = true
                            withAnimation(Self.playerSheetAnimation) { playerExpandProgress = 0 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                isPlayerSheetPresented = false
                                isPlayerSheetClosing = false
                                expandingOverlayDragOffset = 0
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
                        onDeleteTrackFromDevice: {
                            removeTrack(currentTrack)
                        },
                        onHideTrackFromRecommendations: { addCurrentTrackToExcludedRecommendations() },
                        onOpenEqualizer: { showEqualizerSheet = true },
                        onShareCatalogTrack: { ct in
                            shareCatalogTrack = ct
                            showShareTrackSheet = true
                        },
                        onLyricsTap: { showLyricsSheet = true },
                        onArtistTap: { openArtistByName(currentTrack.displayArtist) },
                        tracks: tracksInPlaybackOrderForQueue,
                        currentTrackIndex: tracksInPlaybackOrderForQueue.firstIndex(where: { $0.id == currentTrack.id }) ?? 0,
                        coverImages: tracksInPlaybackOrderForQueue.map { coverImageCache[$0.id] },
                        onTrackSelected: { playTrackAtIndex($0) },
                        enableCoverPaging: enableCoverPaging,
                        enableCoverSeekAnimation: enableCoverSeekAnimation,
                        coverSeekWobbleOnSeek: coverSeekWobbleOnSeek,
                        coverSeekSpinOnSeek: coverSeekSpinOnSeek,
                        roundPlayerCover: enableRoundPlayerCover,
                        expandProgress: playerExpandProgress,
                        isBottomSheet: true,
                        transparentBackground: true,
                        isDarkThemeFromParent: isDark,
                        playerStyleIndex: playerStyleIndex,
                        isSeeking: $isPlayerSeeking,
                        seekScrubIntensity: $seekScrubIntensity,
                        seekScrubDirection: $seekScrubDirection
                    )
                }
            )
        } else if isPlayerSheetPresented, let currentTrack {
            PlayerSheetView(
                track: currentTrack,
                catalogTrack: currentCatalogTrack,
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
                onDeleteTrackFromDevice: {
                    removeTrack(currentTrack)
                },
                onHideTrackFromRecommendations: { addCurrentTrackToExcludedRecommendations() },
                onOpenEqualizer: { showEqualizerSheet = true },
                onShareCatalogTrack: { ct in
                    shareCatalogTrack = ct
                    showShareTrackSheet = true
                },
                onLyricsTap: { showLyricsSheet = true },
                onArtistTap: { openArtistByName(currentTrack.displayArtist) },
                tracks: tracksInPlaybackOrderForQueue,
                currentTrackIndex: tracksInPlaybackOrderForQueue.firstIndex(where: { $0.id == currentTrack.id }) ?? 0,
                coverImages: tracksInPlaybackOrderForQueue.map { coverImageCache[$0.id] },
                onTrackSelected: { playTrackAtIndex($0) },
                enableCoverPaging: enableCoverPaging,
                enableCoverSeekAnimation: enableCoverSeekAnimation,
                coverSeekWobbleOnSeek: coverSeekWobbleOnSeek,
                coverSeekSpinOnSeek: coverSeekSpinOnSeek,
                roundPlayerCover: enableRoundPlayerCover,
                expandProgress: 1,
                isBottomSheet: true,
                playerStyleIndex: playerStyleIndex,
                isSeeking: $isPlayerSeeking,
                seekScrubIntensity: $seekScrubIntensity,
                seekScrubDirection: $seekScrubDirection
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

    private var mainBodyBase: some View {
        tabContent
            .animation(Self.playerSheetAnimation, value: isPlayerSheetPresented)
            .onChange(of: isPlayerSeeking) { seeking in
                if !seeking {
                    seekScrubIntensity = 0
                    seekScrubDirection = 0
                }
            }
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
                    DiscordRPC.shared.clearPresence()
                    return
                }
                loadCoverAndAccent(for: newTrack)
                updateNowPlayingInfo()
                DiscordRPC.shared.updatePresence(title: newTrack.displayTitle, artist: newTrack.artist)
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
            .animation(Self.playerSheetAnimation, value: expandingOverlayDragOffset)
            .animation(Self.playerSheetAnimation, value: playerExpandProgress)
            .onPreferenceChange(MiniCoverFrameKey.self) { miniCoverFrame = $0 }
    }

    private var mainBodyWithOverlays: some View {
        mainBodyBase
            .overlay {
                if currentTrack != nil {
                    HeroCoverOverlayView(
                        isPlayerSheetPresented: isPlayerSheetPresented,
                        isPlayerSheetClosing: isPlayerSheetClosing,
                        playerDragOffset: heroCoverDragOffset,
                        expandProgress: playerExpandProgress,
                        miniCoverFrame: miniCoverFrame,
                        onCloseAnimationDidEnd: {
                            if isPlayerSheetClosing {
                                isPlayerSheetPresented = false
                                isPlayerSheetClosing = false
                                playerDragOffset = 0
                                expandingOverlayDragOffset = 0
                            }
                        },
                        currentCoverImage: currentCoverImage,
                        accent: accent,
                        playerStyleIndex: playerStyleIndex,
                        enableCoverPaging: enableCoverPaging,
                        enableCoverSeekAnimation: enableCoverSeekAnimation,
                        isPlayerSeeking: isPlayerSeeking,
                        seekScrubIntensity: seekScrubIntensity,
                        coverSeekWobbleOnSeek: coverSeekWobbleOnSeek,
                        coverSeekSpinOnSeek: coverSeekSpinOnSeek,
                        seekScrubDirection: seekScrubDirection,
                        roundPlayerCover: enableRoundPlayerCover,
                        playbackHolder: playbackHolder
                    )
                    .zIndex(1)
                }
            }
            .fullScreenCover(isPresented: $showDeveloperMenu) {
                DeveloperMenuView(
                    resolvedColorSchemeFromMainApp: colorScheme,
                    accent: accent,
                    onDismiss: { showDeveloperMenu = false },
                    addByLinkInput: $addByLinkInput,
                    submitAddByLink: submitAddByLink,
                    isAddingFromLink: isAddingFromLink
                )
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    tryPlayLastTrackFromWidget()
                    importSharedInboxFileIfNeeded()
                }
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
    }

    var body: some View {
        bodyMainContent
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
            DispatchQueue.main.async {
                loadTracksFromStorage()
                loadTrackPlayCountsFromStorage()
            }
            importSharedInboxFileIfNeeded()
        }
        .task {
            await FavoritesStore.shared.reload()
            // JWT may not exist on first frame; onChange(authenticated) also loads recs.
            if apiClient.isAuthenticated {
                // Parallel: long /recommendations must not block onboarding prefs + sheet.
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { await self.loadRecommendations() }
                    g.addTask { await self.checkOnboarding() }
                }
            }
            loadProfileAvatarImage()
        }
        .onChange(of: apiClient.isAuthenticated) { isAuthed in
            if isAuthed {
                Task {
                    await withTaskGroup(of: Void.self) { g in
                        g.addTask { await self.loadRecommendations() }
                        g.addTask { await self.checkOnboarding() }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sphereShareImportRequested)) { _ in
            importSharedInboxFileIfNeeded()
        }
        .onChange(of: tracks) { _ in
            scheduleSaveTracks()
        }
        .onChange(of: authService.currentProfile?.avatarUrl) { _ in
            loadProfileAvatarImage()
        }
        .sheet(item: $presentedArtist) { item in
            ArtistProfileView(
                artist: item.artist,
                accent: accent,
                isDarkMode: isDarkMode,
                isEnglish: isEnglish,
                onPlayTrack: { track, queue in playCatalogTrack(track, queue: queue) }
            )
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(
                accent: accent,
                isDarkMode: isDarkMode,
                isEnglish: isEnglish
            ) {
                showOnboarding = false
                Task { await loadRecommendations() }
            }
        }
    }

    private var bodyMainContent: some View {
        mainBodyWithOverlays
        .onReceive(NotificationCenter.default.publisher(for: .spherePlayCatalogTrack)) { note in
            guard let info = note.userInfo as? [String: String],
                  let provider = info["provider"],
                  let id = info["id"],
                  !provider.isEmpty,
                  !id.isEmpty else { return }
            Task {
                do {
                    let track = try await apiClient.getTrack(provider: provider, id: id)
                    await MainActor.run {
                        playCatalogTrack(track)
                        isMiniPlayerHidden = false
                    }
                } catch {
                    // ignore
                }
            }
        }
        .background {
            if #available(iOS 26.0, *) {
                Color.clear
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .background(
                        AudioDocumentPickerPresenter(isPresented: $isAddingMusic) { url in
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
                                saveTracksWorkItem?.cancel()
                                saveTracksToStorage()
                            }
                        }
                    )
            }
        }
        .modifier(
            SphereLegacyAudioFileImporterModifier(isPresented: $isAddingMusic) { urls in
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
                    saveTracksWorkItem?.cancel()
                    saveTracksToStorage()
                }
            }
        )
	        .sheet(isPresented: $showEqualizerSheet) {
	            SphereEqualizerSheet(accent: accent, isEnglish: isEnglish)
	        }
        .sheet(isPresented: $showShareTrackSheet) {
            if let track = shareCatalogTrack {
                ShareTrackToUserSheet(track: track, accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode) {
                    showShareTrackSheet = false
                    shareCatalogTrack = nil
                }
            }
        }
	        .sheet(item: $presentedAlbum) { album in
	            AlbumDetailView(
	                album: album,
	                accent: accent,
	                isDarkMode: isDarkMode,
	                isEnglish: isEnglish,
	                isLoading: isLoadingAlbum,
	                onPlayTrack: { track, queue in
	                    playCatalogTrack(track, queue: queue)
	                    presentedAlbum = nil
	                },
	                onPlayAll: { queue in
	                    if let first = queue.first {
	                        playCatalogTrack(first, queue: queue)
	                        presentedAlbum = nil
	                    }
	                },
	                onShuffle: { queue in
	                    let shuffled = queue.shuffled()
	                    if let first = shuffled.first {
	                        playCatalogTrack(first, queue: shuffled)
	                        presentedAlbum = nil
	                    }
	                }
	            )
	            .presentationDetents([.large])
	            .presentationDragIndicator(.visible)
	        }
	        .onChange(of: showLyricsSheet) { open in
	            if open { startProgressTimer() }
	        }
        .sheet(isPresented: $showLyricsSheet) {
            if let track = currentTrack {
                LyricsSheet(
                    trackId: track.id.uuidString,
                    trackTitle: track.title ?? (isEnglish ? "Track" : "Трек"),
                    accent: accent,
                    isEnglish: isEnglish,
                    lyricsStorage: $lyricsDataStorage,
                    provider: currentCatalogTrack?.provider,
                    providerTrackId: currentCatalogTrack?.id,
                    titleHint: currentCatalogTrack?.title ?? track.title,
                    artistHint: currentCatalogTrack?.artist ?? track.artist,
                    playbackHolder: playbackHolder,
                    isDarkMode: isDarkMode
                )
            }
        }
    }

    private func loadProfileAvatarImage() {
        guard let urlStr = authService.currentProfile?.avatarUrl,
              !urlStr.isEmpty,
              let url = URL(string: urlStr) else {
            profileAvatarUIImage = nil
            return
        }
        Task.detached(priority: .userInitiated) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            await MainActor.run { profileAvatarUIImage = img }
        }
    }

    private func loadRecommendations() async {
        guard apiClient.isAuthenticated else { return }
        await MainActor.run { isLoadingRecommendations = true }
        await apiClient.wakeBackendForColdStart()
        for attempt in 0..<4 {
            do {
                let recs = try await apiClient.getRecommendations()
                await MainActor.run {
                    recommendations = recs
                    isLoadingRecommendations = false
                }
                return
            } catch {
                print("[Sphere] load recommendations error (attempt \(attempt + 1)):", error.localizedDescription)
                if attempt < 3 {
                    let sec = 2.0 * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(sec * 1_000_000_000.0))
                    await apiClient.wakeBackendForColdStart(maxAttempts: 3)
                } else {
                    await MainActor.run { isLoadingRecommendations = false }
                }
            }
        }
    }

    private func checkOnboarding() async {
        guard apiClient.isAuthenticated else { return }
        for attempt in 0..<5 {
            do {
                let prefs = try await apiClient.getPreferences()
                if !prefs.onboardingCompleted {
                    let just = UserDefaults.standard.bool(forKey: "sphereJustAuthenticated")
                    await MainActor.run { showOnboarding = true }
                    if just {
                        UserDefaults.standard.set(false, forKey: "sphereJustAuthenticated")
                    }
                } else {
                    UserDefaults.standard.set(false, forKey: "sphereJustAuthenticated")
                }
                return
            } catch {
                print("[Sphere] check onboarding error (attempt \(attempt + 1)):", error.localizedDescription)
                if attempt < 4 {
                    let sec = 1.5 * pow(1.8, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(sec * 1_000_000_000.0))
                    await apiClient.wakeBackendForColdStart(maxAttempts: 4)
                }
            }
        }
    }


    private var homeTab: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                GeometryReader { geo in
                    let homeTopSafe = HomeStickySearchLayout.backingSafeTop(geometryReportedSafeTop: geo.safeAreaInsets.top)
                    ZStack(alignment: .top) {
                        ZStack {
                            mainBackground
                                .ignoresSafeArea()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if currentTrack != nil, playbackHolder.isPlaying {
                                AnimatedCoverGradientBackground(accent: (currentCoverAccent ?? accent), isDarkMode: isDarkMode)
                                    .ignoresSafeArea()
                                    .transition(.opacity)
                            }
                        }
                        .zIndex(0)

                        HomeTabScrollAndStickyChrome(
                            overlayHitTesting: true,
                            scrollContent: { scrollBind in
                                ScrollView(.vertical, showsIndicators: true) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        HomeVerticalScrollOffsetReader(
                                            offsetY: scrollBind,
                                            clampsVerticalOffsetToNonNegative: false,
                                            prefersDisplayLinkWhileScrolling: true
                                        )
                                        .frame(width: 1, height: 1)
                                        .allowsHitTesting(false)
                                        .padding(.bottom, 16)

                                        Text(homeTitle)
                                            .font(.title2.weight(.semibold))
                                            .foregroundStyle(isDarkMode ? .white : accent)
                                            .frame(maxWidth: .infinity)
                                            .padding(.top, homeTopSafe + 24)

                                        Color.clear
                                            .frame(height: HomeStickySearchMetrics.stickyPlaceholderRowHeight)
                                            .frame(maxWidth: .infinity)
                                            .accessibilityHidden(true)

                                        let homeSearchTrimmed = homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                        let recommendationsRailsEmpty: Bool = {
                                            guard let r = recommendations else { return true }
                                            return r.tracks.isEmpty && r.albums.isEmpty && r.artists.isEmpty
                                        }()

                                        if homeSearchTrimmed.isEmpty {
                                            ScrollView(.horizontal, showsIndicators: false) {
                                                HStack(spacing: 10) {
                                                    Text(isEnglish ? "All" : "Все")
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(isDarkMode ? .black : .white)
                                                        .padding(.horizontal, 14)
                                                        .padding(.vertical, 9)
                                                        .background(
                                                            Capsule(style: .continuous)
                                                                .fill(isDarkMode ? Color.white : Color.black)
                                                        )

                                                    ForEach([isEnglish ? "Music" : "Музыка", isEnglish ? "Podcasts" : "Подкасты", isEnglish ? "Audiobooks" : "Аудиокниги"], id: \.self) { t in
                                                        Text(t)
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .foregroundStyle(isDarkMode ? .white : .primary)
                                                            .padding(.horizontal, 14)
                                                            .padding(.vertical, 9)
                                                            .background(
                                                                Capsule(style: .continuous)
                                                                    .fill(Color.white.opacity(isDarkMode ? 0.08 : 0.06))
                                                            )
                                                    }
                                                }
                                                .padding(.horizontal, 16)
                                                .padding(.top, 14)
                                                .padding(.bottom, 6)
                                            }

                                            let recentTiles = Array(recentStore.items.prefix(7))
                                            LazyVGrid(
                                                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                                                spacing: 12
                                            ) {
                                                Button {
                                                    selectedTab = .favorites
                                                } label: {
                                                    HStack(spacing: 12) {
                                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                            .fill(
                                                                LinearGradient(
                                                                    colors: [Color.purple.opacity(0.95), Color.pink.opacity(0.65)],
                                                                    startPoint: .topLeading,
                                                                    endPoint: .bottomTrailing
                                                                )
                                                            )
                                                            .frame(width: 44, height: 44)
                                                            .overlay(
                                                                Image(systemName: "heart.fill")
                                                                    .font(.system(size: 18, weight: .semibold))
                                                                    .foregroundStyle(.white)
                                                            )
                                                        VStack(alignment: .leading, spacing: 2) {
                                                            Text(isEnglish ? "Liked" : "Мне нравится")
                                                                .font(.system(size: 16, weight: .semibold))
                                                                .foregroundStyle(isDarkMode ? .white : .primary)
                                                                .lineLimit(1)
                                                            Text(isEnglish ? "Playlist" : "Плейлист")
                                                                .font(.system(size: 13))
                                                                .foregroundStyle(.secondary)
                                                                .lineLimit(1)
                                                        }
                                                        Spacer(minLength: 0)
                                                    }
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 10)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                                    )
                                                }
                                                .buttonStyle(.plain)

                                                ForEach(recentTiles) { item in
                                                    Button {
                                                        handleRecentTap(item)
                                                    } label: {
                                                        HStack(spacing: 12) {
                                                            Group {
                                                                if let urlString = item.coverURL, let url = URL(string: urlString) {
                                                                    AsyncImage(url: url) { img in
                                                                        img.resizable().scaledToFill()
                                                                    } placeholder: {
                                                                        Color(.systemGray5)
                                                                    }
                                                                } else {
                                                                    Color(.systemGray5)
                                                                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                                                                }
                                                            }
                                                            .frame(width: 44, height: 44)
                                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                                            VStack(alignment: .leading, spacing: 2) {
                                                                Text(item.title)
                                                                    .font(.system(size: 15, weight: .semibold))
                                                                    .foregroundStyle(isDarkMode ? .white : .primary)
                                                                    .lineLimit(1)
                                                                Text(item.artist)
                                                                    .font(.system(size: 13))
                                                                    .foregroundStyle(.secondary)
                                                                    .lineLimit(1)
                                                            }
                                                            Spacer(minLength: 0)
                                                        }
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 10)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                                .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                                        )
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.top, 6)
                                            .padding(.bottom, 14)
                                        }

                                        if isLoadingRecommendations,
                                           homeSearchTrimmed.isEmpty,
                                           recommendationsRailsEmpty {
                                            RecommendationsSkeletonView(isDarkMode: isDarkMode)
                                        } else if let recs = recommendations,
                                           homeSearchTrimmed.isEmpty,
                                           (!recs.tracks.isEmpty || !recs.albums.isEmpty || !recs.artists.isEmpty) {
                                            VStack(alignment: .leading, spacing: 12) {
                                                if !recs.tracks.isEmpty {
                                                    Text(isEnglish ? "Recommended tracks" : "Рекомендованные треки")
                                                        .font(.system(size: 18, weight: .semibold))
                                                        .foregroundStyle(isDarkMode ? .white : accent)
                                                        .padding(.leading, 18)
                                                    ScrollView(.horizontal, showsIndicators: false) {
                                                        HStack(spacing: 12) {
                                                            ForEach(recs.tracks.prefix(15)) { track in
                                                                CatalogTrackCard(
                                                                    track: track,
                                                                    accent: accent,
                                                                    isDarkMode: isDarkMode,
                                                                    onTap: {
                                                                        let q = Array(recs.tracks.prefix(15))
                                                                        playCatalogTrack(track, queue: q)
                                                                    },
                                                                    onArtistTap: { openArtistByName(track.artist) }
                                                                )
                                                            }
                                                        }
                                                        .padding(.horizontal, 16)
                                                    }
                                                }
                                                if !recs.albums.isEmpty {
                                                    Text(isEnglish ? "Recommended albums" : "Рекомендованные альбомы")
                                                        .font(.system(size: 18, weight: .semibold))
                                                        .foregroundStyle(isDarkMode ? .white : accent)
                                                        .padding(.leading, 18)
                                                    ScrollView(.horizontal, showsIndicators: false) {
                                                        HStack(spacing: 12) {
                                                            ForEach(recs.albums.prefix(10)) { album in
                                                                CatalogAlbumCard(album: album, accent: accent, isDarkMode: isDarkMode) { openAlbum(album) }
                                                            }
                                                        }
                                                        .padding(.horizontal, 16)
                                                    }
                                                }
                                                if !recs.artists.isEmpty {
                                                    Text(isEnglish ? "Recommended artists" : "Рекомендованные исполнители")
                                                        .font(.system(size: 18, weight: .semibold))
                                                        .foregroundStyle(isDarkMode ? .white : accent)
                                                        .padding(.leading, 18)
                                                    ScrollView(.horizontal, showsIndicators: false) {
                                                        HStack(spacing: 12) {
                                                            ForEach(recs.artists.prefix(10)) { artist in
                                                                CatalogArtistCard(artist: artist, accent: accent, isDarkMode: isDarkMode) {
                                                                    openArtistByName(artist.name)
                                                                }
                                                            }
                                                        }
                                                        .padding(.horizontal, 16)
                                                    }
                                                }
                                            }
                                            .padding(.bottom, 16)
                                        }

                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(libraryTitle)
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundStyle(isDarkMode ? .white : accent)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.leading, 18)
                                                .padding(.trailing, 12)

                                            VStack(alignment: .leading, spacing: 0) {
                                            let homeFiltered = homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                ? tracks
                                                : tracks.filter {
                                                    $0.displayTitle.localizedCaseInsensitiveContains(homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines))
                                                    || $0.displayArtist.localizedCaseInsensitiveContains(homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines))
                                                }
                                            let displayedTracks = homeFiltered.sorted {
                                                ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast)
                                            }

                                            if tracks.isEmpty {
                                                HStack(alignment: .center, spacing: 12) {
                                                    Text(libraryEmptyTitle)
                                                        .font(.subheadline)
                                                        .foregroundStyle(.secondary)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .padding(.horizontal, 12)
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
                                                        HomeLibraryOpenFullGridButtonLabel(accent: accent)
                                                    }
                                                    .buttonStyle(ScaleOnPressRoundButtonStyle())
                                                }
                                                .padding(.trailing, 12)
                                            } else if displayedTracks.isEmpty && (catalogSearchResults?.tracks.isEmpty ?? true) {
                                                HStack(alignment: .center, spacing: 12) {
                                                    Text(noResultsTitle)
                                                        .font(.subheadline)
                                                        .foregroundStyle(.secondary)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .padding(.horizontal, 12)
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
                                                        HomeLibraryOpenFullGridButtonLabel(accent: accent)
                                                    }
                                                    .buttonStyle(ScaleOnPressRoundButtonStyle())
                                                }
                                                .padding(.trailing, 12)
                                            } else {
                                                let catalogTracksForRow: [CatalogTrack] = {
                                                    guard !homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                                          let res = catalogSearchResults else { return [] }
                                                    return Array(res.tracks.prefix(20))
                                                }()
                                                HStack(alignment: .top, spacing: 12) {
                                                    ScrollView(.horizontal, showsIndicators: false) {
                                                        HStack(alignment: .top, spacing: 0) {
                                                            Color.clear
                                                                .frame(width: 12 + 4, height: HomeLibraryHorizontalRowMetrics.cellTotalHeight)
                                                            HStack(alignment: .top, spacing: 16) {
                                                                ForEach(displayedTracks) { track in
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
                                                                ForEach(catalogTracksForRow) { ctrack in
                                                                    CatalogLibraryRowCell(
                                                                        track: ctrack,
                                                                        accent: accent,
                                                                        onTap: {
                                                                            playCatalogTrack(ctrack, queue: catalogTracksForRow)
                                                                            openPlayerSheet()
                                                                        }
                                                                    )
                                                                }
                                                            }
                                                        }
                                                        .padding(.trailing, 4)
                                                    }
                                                    .frame(maxWidth: .infinity)

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
                                                        HomeLibraryOpenFullGridButtonLabel(accent: accent)
                                                    }
                                                    .buttonStyle(ScaleOnPressRoundButtonStyle())
                                                }
                                                .padding(.trailing, 12)
                                            }
                                            }
                                            .padding(.top, 18)
                                            .padding(.bottom, 18)
                                            .frame(maxWidth: .infinity)
                                        }

                                        Spacer(minLength: 0)
                                    }
                                    .modifier(HomeTabScrollStackTopSafePaddingPreiOS26())
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(minHeight: geo.size.height + HomeStickySearchMetrics.latchScrollY + 24)
                                }
                                .scrollContentBackground(.hidden)
                                .refreshable { await loadRecommendations() }
                            },
                            overlayChrome: { scrollY in
                                HomeStickySearchOverlayChrome(
                                    safeAreaTop: geo.safeAreaInsets.top,
                                    geometryWidth: geo.size.width,
                                    scroll: scrollY,
                                    searchText: $homeSearchText,
                                    placeholder: homeSearchPlaceholder,
                                    accent: accent,
                                    isDarkMode: isDarkMode
                                )
                            }
                        )
                    }
                    .zIndex(1)
                }
            }
            .ignoresSafeArea(edges: .top)
            .homeTabGeometryReaderPreIOS26()
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: homeSearchText) { newValue in
                debouncedCatalogSearch(newValue)
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
                        .foregroundStyle(colorScheme == .dark ? .white : accent)
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

    /// Компактная ячейка для горизонтального ряда на главной: обложка + название в капсуле, тап — воспроизведение, контекстное меню — только удаление
    private struct CatalogLibraryRowCell: View {
        let track: CatalogTrack
        let accent: Color
        let onTap: () -> Void

        @ObservedObject private var downloads = DownloadsStore.shared

        var body: some View {
            VStack(alignment: .leading, spacing: HomeLibraryHorizontalRowMetrics.coverToTitleSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: HomeLibraryHorizontalRowMetrics.coverCorner, style: .continuous)
                        .fill(accent.opacity(0.2))
                    if let url = URL(string: track.coverURL ?? "") {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                Color.clear
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: HomeLibraryHorizontalRowMetrics.coverCorner, style: .continuous))
                    }
                    VStack {
                        HStack {
                            if downloads.isDownloaded(provider: track.provider, id: track.id) {
                                DownloadedBadge(size: 16)
                                    .padding(6)
                                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                            }
                            Spacer()
                            ServiceIconBadge(provider: track.provider, size: 18)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
                .frame(width: HomeLibraryHorizontalRowMetrics.coverSide, height: HomeLibraryHorizontalRowMetrics.coverSide)

                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, HomeLibraryHorizontalRowMetrics.titleVerticalPadding)
                    .frame(maxWidth: HomeLibraryHorizontalRowMetrics.coverSide, alignment: .leading)
                    .background(
                        Color(.systemGray5),
                        in: RoundedRectangle(
                            cornerRadius: libraryTrackTitlePlateCornerRadius(
                                coverCorner: HomeLibraryHorizontalRowMetrics.coverCorner,
                                coverSquareSide: HomeLibraryHorizontalRowMetrics.coverSide,
                                verticalLabelPadding: HomeLibraryHorizontalRowMetrics.titleVerticalPadding
                            ),
                            style: .continuous
                        )
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
    }

    private struct LibraryRowCell: View {
        let track: AppTrack
        let accent: Color
        let deleteTitle: String
        let onTap: () -> Void
        let onDelete: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: HomeLibraryHorizontalRowMetrics.coverToTitleSpacing) {
                TrackCoverView(track: track, accent: accent, cornerRadius: HomeLibraryHorizontalRowMetrics.coverCorner, placeholderPadding: 8)
                    .frame(width: HomeLibraryHorizontalRowMetrics.coverSide, height: HomeLibraryHorizontalRowMetrics.coverSide)
                Text(track.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, HomeLibraryHorizontalRowMetrics.titleVerticalPadding)
                    .frame(maxWidth: HomeLibraryHorizontalRowMetrics.coverSide, alignment: .leading)
                    .background(
                        Color(.systemGray5),
                        in: RoundedRectangle(
                            cornerRadius: libraryTrackTitlePlateCornerRadius(
                                coverCorner: HomeLibraryHorizontalRowMetrics.coverCorner,
                                coverSquareSide: HomeLibraryHorizontalRowMetrics.coverSide,
                                verticalLabelPadding: HomeLibraryHorizontalRowMetrics.titleVerticalPadding
                            ),
                            style: .continuous
                        )
                    )
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
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        Button {
                            showLikedPlaylist = true
                        } label: {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.purple.opacity(0.95), Color.pink.opacity(0.70)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 64, height: 64)
                                    .overlay(
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 24, weight: .semibold))
                                            .foregroundStyle(.white)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isEnglish ? "Liked" : "Мне нравится")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? .white : .primary)
                                    let likedCount = favoritesStore.items.filter { $0.itemType == "track" }.count
                                    Text(isEnglish ? "\(likedCount) tracks" : "\(likedCount) треков")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)

                        let lastLikedTracks = Array(favoritesStore.items.filter { $0.itemType == "track" }.prefix(9))
                        if !lastLikedTracks.isEmpty {
                            Text(isEnglish ? "Recently added" : "Последние добавленные")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(isDarkMode ? .white : .primary)
                                .padding(.horizontal, 2)

                            let rows: [GridItem] = Array(repeating: GridItem(.fixed(92), spacing: 10), count: 3)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHGrid(rows: rows, spacing: 10) {
                                    ForEach(lastLikedTracks) { fav in
                                        Button {
                                            playFavorite(fav)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                AsyncImage(url: catalogRemoteImageURL(fav.coverURL)) { phase in
                                                    switch phase {
                                                    case .success(let img):
                                                        img.resizable().scaledToFill()
                                                    default:
                                                        Rectangle().fill(accent.opacity(0.18))
                                                    }
                                                }
                                                .frame(width: 92, height: 92)
                                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                                Text(fav.title)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(isDarkMode ? .white : .primary)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 92, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }

                        let addedItems = favoritesStore.items.filter { $0.itemType == "album" || $0.itemType == "playlist" }
                        if !addedItems.isEmpty {
                            Text(isEnglish ? "Added" : "Добавлено")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(isDarkMode ? .white : .primary)
                                .padding(.horizontal, 2)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(Array(addedItems.prefix(12))) { item in
                                        VStack(alignment: .leading, spacing: 6) {
                                            AsyncImage(url: catalogRemoteImageURL(item.coverURL)) { phase in
                                                switch phase {
                                                case .success(let img):
                                                    img.resizable().scaledToFill()
                                                default:
                                                    Rectangle().fill(Color.white.opacity(isDarkMode ? 0.08 : 0.06))
                                                }
                                            }
                                            .frame(width: 120, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                            Text(item.title)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(isDarkMode ? .white : .primary)
                                                .lineLimit(1)
                                            Text(item.itemType == "album" ? (isEnglish ? "Album" : "Альбом") : (isEnglish ? "Playlist" : "Плейлист"))
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(width: 120, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }

                        let likedPlaylists = favoritesStore.items.filter { $0.itemType == "playlist" }
                        let likedAlbums = favoritesStore.items.filter { $0.itemType == "album" }
                        let likedArtists = favoritesStore.items.filter { $0.itemType == "artist" }
                        if !likedPlaylists.isEmpty || !likedAlbums.isEmpty || !likedArtists.isEmpty {
                            Text(isEnglish ? "More in your collection" : "Ещё у вас в коллекции")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(isDarkMode ? .white : .primary)
                                .padding(.horizontal, 2)
                                .padding(.top, 6)
                        }

                        if !likedPlaylists.isEmpty {
                            collectionStrip(title: isEnglish ? "Playlists" : "Плейлисты", items: Array(likedPlaylists.prefix(12)))
                        }
                        if !likedAlbums.isEmpty {
                            collectionStrip(title: isEnglish ? "Albums" : "Альбомы", items: Array(likedAlbums.prefix(12)))
                        }
                        if !likedArtists.isEmpty {
                            collectionStrip(title: isEnglish ? "Artists" : "Исполнители", items: Array(likedArtists.prefix(12)))
                        }

                        Color.clear.frame(height: 120)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .refreshable { await FavoritesStore.shared.reload() }
            }
        }
        .tabItem { Label(favoritesTitle, systemImage: "heart.fill") }
        .sheet(isPresented: $showLikedPlaylist) {
            LikedPlaylistView(isEnglish: isEnglish, accent: accent, isDarkMode: isDarkMode, onPlayTrack: { t in
                playCatalogTrack(t)
                openPlayerSheet()
            })
        }
    }

    private func collectionStrip(title: String, items: [FavoriteItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isDarkMode ? .white : .primary)
                .padding(.horizontal, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: catalogRemoteImageURL(item.coverURL)) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().scaledToFill()
                                default:
                                    Rectangle().fill(Color.white.opacity(isDarkMode ? 0.08 : 0.06))
                                }
                            }
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isDarkMode ? .white : .primary)
                                .lineLimit(1)
                        }
                        .frame(width: 96, alignment: .leading)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func playFavorite(_ fav: FavoriteItem) {
        if fav.provider == "local" {
            if let local = tracks.first(where: { $0.id.uuidString == fav.providerItemID }) {
                currentTrack = local
                playbackHolder.progress = 0
                isMiniPlayerHidden = false
                startPlayback(for: local)
                openPlayerSheet()
            }
            return
        }
        Task {
            do {
                let track = try await apiClient.getTrack(provider: fav.provider, id: fav.providerItemID)
                await MainActor.run {
                    playCatalogTrack(track)
                    openPlayerSheet()
                }
            } catch {
                print("[Sphere] play favorite error:", error.localizedDescription)
            }
        }
    }

    private struct FavoriteRowCell: View {
        let item: FavoriteItem
        let isDarkMode: Bool
        let accent: Color
        let onTap: () -> Void

        @ObservedObject private var downloads = DownloadsStore.shared

        var body: some View {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    AsyncImage(url: catalogRemoteImageURL(item.coverURL)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            Rectangle().fill(accent.opacity(0.2))
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if item.itemType == "track",
                           item.provider != "local",
                           downloads.isDownloaded(provider: item.provider, id: item.providerItemID) {
                            DownloadedBadge(size: 14)
                                .padding(.top, 4)
                                .padding(.leading, 4)
                                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isDarkMode ? .white : .primary)
                            .lineLimit(1)
                        Text(item.artistName)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.provider != "local" {
                        ServiceIconBadge(provider: item.provider, size: 18)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isDarkMode ? Color(white: 0.14) : Color(white: 0.94))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsTab: some View {
        ZStack {
            mainBackground
                .ignoresSafeArea()

            NavigationStack {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Text(settingsTitle)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(isDarkMode ? .white : accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                            .padding(.bottom, 16)

                        if authService.isSignedIn {
                            SettingsAccountTapHeader(
                                profile: authService.currentProfile,
                                backendUser: authService.backendAccountSnapshot,
                                accent: accent,
                                nickname: authService.currentProfile?.nickname ?? (isEnglish ? "User" : "Пользователь"),
                                usernameAt: {
                                    guard let u = authService.currentProfile?.username, !u.isEmpty else {
                                        return "@…"
                                    }
                                    return u.hasPrefix("@") ? u : "@\(u)"
                                }(),
                                isDarkMode: isDarkMode,
                                onAvatarTap: {
                                    syncSettingsAvatarPickerFromProfile()
                                    showSettingsAvatarPicker = true
                                }
                            )
                            .padding(.bottom, 24)
                        }

                        if authService.isSignedIn {
                            SettingsGroupContainer(isDarkMode: isDarkMode) {
                                NavigationLink(
                                    destination: ProfileSettingsFlowView(
                                        authService: authService,
                                        tracks: $tracks,
                                        trackPlayCounts: $trackPlayCounts,
                                        accent: accent,
                                        mainBackground: mainBackground,
                                        isEnglish: isEnglish,
                                        onPlayTrack: { track in
                                            if let idx = tracks.firstIndex(where: { $0.id == track.id }) {
                                                startPlayback(for: tracks[idx])
                                            }
                                        }
                                    )
                                ) {
                                    SettingsGroupRowLabel(icon: "person.crop.circle.fill", title: profileTitle)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }

                        SettingsGroupContainer(isDarkMode: isDarkMode) {
                            NavigationLink(destination: PrivacySettingsView(profile: authService.currentProfile, accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)) {
                                SettingsGroupRowLabel(icon: "lock.shield.fill", title: privacyTitle)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                        if authService.isSignedIn {
                            SettingsGroupContainer(isDarkMode: isDarkMode) {
                                NavigationLink(destination: ChatListView(accent: accent, isEnglish: isEnglish)) {
                                    SettingsGroupRowLabel(icon: "message.fill", title: isEnglish ? "Chats" : "Чаты")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }

                        SettingsGroupContainer(isDarkMode: isDarkMode) {
                            NavigationLink(
                                destination: SettingsAppearanceScreen(accent: accent, isEnglish: isEnglish, resolvedColorSchemeFromMainApp: colorScheme)
                            ) {
                                SettingsGroupRowLabel(icon: "paintbrush.fill", title: themeTitle)
                            }
                            .buttonStyle(.plain)

                            Divider().overlay(Color(.systemGray4)).padding(.leading, 58)

                            NavigationLink(
                                destination: SettingsCustomizationScreen(accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)
                            ) {
                                SettingsGroupRowLabel(icon: "paintpalette.fill", title: customizationNavTitle)
                            }
                            .buttonStyle(.plain)

                            Divider().overlay(Color(.systemGray4)).padding(.leading, 58)

                            NavigationLink(
                                destination: SettingsOtherScreen(accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode, onAddMusic: { isAddingMusic = true })
                            ) {
                                SettingsGroupRowLabel(icon: "square.grid.2x2.fill", title: otherSettingsNavTitle)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                        SettingsGroupContainer(isDarkMode: isDarkMode) {
                            Button {
                                stopPlaybackOnLogout()
                                AuthService.shared.signOut()
                                onLogout()
                            } label: {
                                SettingsGroupRowLabel(icon: "rectangle.portrait.and.arrow.right", title: logoutTitle, showsChevron: false)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if showSettingsAvatarPicker && !settingsUseSheetForAvatarPicker {
                AvatarPickerCardView(
                    avatarColorIndex: $settingsAvatarColorIndex,
                    isPresented: $showSettingsAvatarPicker,
                    customAvatarImage: $settingsCustomAvatarImage,
                    pickerColors: settingsAvatarPickerPalette,
                    accent: accent,
                    isEnglish: isEnglish,
                    showGalleryPicker: $showSettingsGalleryPicker,
                    triggerDismiss: $triggerSettingsAvatarPickerDismiss,
                    onDismissCompleted: { triggerSettingsAvatarPickerDismiss = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: Binding(
            get: { showSettingsAvatarPicker && settingsUseSheetForAvatarPicker },
            set: { showSettingsAvatarPicker = $0 }
        )) {
            if #available(iOS 26.0, *) {
                AvatarPickerSheet(
                    avatarColorIndex: $settingsAvatarColorIndex,
                    isPresented: $showSettingsAvatarPicker,
                    customAvatarImage: $settingsCustomAvatarImage,
                    pickerColors: settingsAvatarPickerPalette,
                    accent: accent,
                    isEnglish: isEnglish
                )
            }
        }
        .fullScreenCover(isPresented: $showSettingsGalleryPicker) {
            PhotoLibraryPicker { image in
                showSettingsGalleryPicker = false
                if let image = image {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let cropped = AvatarPickerSheet.cropImageToSquare(image)
                        DispatchQueue.main.async {
                            settingsCustomAvatarImage = cropped
                            settingsAvatarColorIndex = 7
                            triggerSettingsAvatarPickerDismiss = true
                        }
                    }
                }
            }
        }
        .onChange(of: showSettingsAvatarPicker) { isOpen in
            guard !isOpen else { return }
            Task { await commitSettingsAvatarSelection() }
        }
        .tabItem {
            Label {
                Text(isEnglish ? "Profile" : "Профиль")
            } icon: {
                ProfileAvatarCoreView(profile: authService.currentProfile, side: 26, accent: accent)
                    .clipShape(Circle())
                    .frame(width: 26, height: 26)
            }
        }
        .task {
            await authService.ensureProfileAvailable()
        }
    }

    // MARK: - Redesign v3 tabs (native TabView, 4 slots)

    private var homeTabV2: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    homeRecommendationsSectionV2
                    homeLibrarySectionV2
                    homeRecentlyPlayedSection
                    homeArtistsCircleSection
                    Color.clear.frame(height: 40)
                }
                .padding(.vertical, 16)
            }
            .background {
                ZStack {
                    mainBackground.ignoresSafeArea()
                    if currentTrack != nil, playbackHolder.isPlaying {
                        AnimatedCoverGradientBackground(accent: (currentCoverAccent ?? accent), isDarkMode: isDarkMode)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }
                }
            }
            .navigationTitle(homeTitle)
        }
        .tabItem {
            Label(homeTitle, systemImage: "house.fill")
        }
    }

    @ViewBuilder
    private var homeRecommendationsSectionV2: some View {
        if let recs = recommendations,
           !recs.tracks.isEmpty || !recs.albums.isEmpty || !recs.artists.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !recs.tracks.isEmpty {
                    Text(isEnglish ? "Recommended tracks" : "Рекомендованные треки")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 18)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recs.tracks.prefix(15)) { track in
                                CatalogTrackCard(
                                    track: track,
                                    accent: accent,
                                    isDarkMode: isDarkMode,
                                    onTap: {
                                        let q = Array(recs.tracks.prefix(15))
                                        playCatalogTrack(track, queue: q)
                                    },
                                    onArtistTap: { openArtistByName(track.artist) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if !recs.albums.isEmpty {
                    Text(isEnglish ? "Recommended albums" : "Рекомендованные альбомы")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 18)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recs.albums.prefix(10)) { album in
                                CatalogAlbumCard(album: album, accent: accent, isDarkMode: isDarkMode) { openAlbum(album) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if !recs.artists.isEmpty {
                    Text(isEnglish ? "Recommended artists" : "Рекомендованные исполнители")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 18)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recs.artists.prefix(10)) { artist in
                                CatalogArtistCard(artist: artist, accent: accent, isDarkMode: isDarkMode) {
                                    openArtistByName(artist.name)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var homeLibrarySectionV2: some View {
        let sortedTracks = tracks.sorted {
            ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text(libraryTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 18)

            if tracks.isEmpty {
                Text(libraryEmptyTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(sortedTracks) { track in
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
                            HomeLibraryOpenFullGridButtonLabel(accent: accent)
                        }
                        .buttonStyle(ScaleOnPressRoundButtonStyle())
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private var homeRecentlyPlayedSection: some View {
        if !recentStore.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(isEnglish ? "Recently" : "Недавние")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.leading, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(recentStore.items) { item in
                            recentlyPlayedCard(for: item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func recentlyPlayedCard(for item: RecentlyPlayedStore.Item) -> some View {
        Button {
            handleRecentTap(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let urlString = item.coverURL, let url = URL(string: urlString) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color(.systemGray5)
                        }
                    } else {
                        Color(.systemGray5)
                            .overlay(
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isRecentItemDownloaded(item) {
                        DownloadedBadge(size: 16)
                            .padding(.top, 6)
                            .padding(.leading, 6)
                            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                    }
                }

                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)

                Text(item.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    /// Trace a recently played item back to a `(provider, id)` and check if it's downloaded.
    private func isRecentItemDownloaded(_ item: RecentlyPlayedStore.Item) -> Bool {
        guard item.kind == .catalog else { return false }
        let parts = item.id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return downloadsStore.isDownloaded(provider: String(parts[0]), id: String(parts[1]))
    }

    private func handleRecentTap(_ item: RecentlyPlayedStore.Item) {
        switch item.kind {
        case .local:
            let uuidString = String(item.id.dropFirst("local:".count))
            if let uuid = UUID(uuidString: uuidString),
               let track = tracks.first(where: { $0.id == uuid }) {
                currentTrack = track
                playbackHolder.progress = 0
                isMiniPlayerHidden = false
                startPlayback(for: track)
                openPlayerSheet()
            }
        case .catalog:
            let parts = item.id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let provider = String(parts[0])
            let providerId = String(parts[1])
            let stub = CatalogTrack(
                id: providerId,
                provider: provider,
                title: item.title,
                artist: item.artist,
                album: nil,
                coverURL: item.coverURL,
                duration: 0,
                streamURL: nil,
                previewURL: nil,
                clipURL: nil,
                genres: nil,
                playCount: nil
            )
            playCatalogTrack(stub)
            openPlayerSheet()
        }
    }

    @ViewBuilder
    private var homeArtistsCircleSection: some View {
        let artists = recentStore.uniqueArtists()
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(isEnglish ? "Artists" : "Артисты")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.leading, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(artists, id: \.self) { name in
                            artistCircleTile(name: name)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func artistCircleTile(name: String) -> some View {
        Button {
            openArtistByName(name)
        } label: {
            VStack(spacing: 8) {
                Group {
                    if let urlString = recentStore.coverURL(forArtist: name), let url = URL(string: urlString) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color(.systemGray5))
                        }
                    } else {
                        Circle()
                            .fill(Color(.systemGray5))
                            .overlay(
                                Text(String(name.prefix(1)).uppercased())
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())

                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 84)
            }
        }
        .buttonStyle(.plain)
    }

    private func userSearchRow(u: BackendUserListItem) -> some View {
        HStack(spacing: 12) {
            if let url = URL(string: u.avatar_url), !u.avatar_url.isEmpty {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color(.systemGray5))
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(.systemGray5))
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                SphereCompactUserBadges(
                    displayName: u.name.isEmpty ? u.username : u.name,
                    badgeText: u.badge_text,
                    badgeColor: u.badge_color,
                    isVerified: u.is_verified
                )
                if !u.username.isEmpty {
                    Text("@\(u.username)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if u.private_profile {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isDarkMode ? Color(white: 0.12) : Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var searchTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inlineSearchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .background(mainBackground)
                searchResultsListView
            }
            .background(mainBackground.ignoresSafeArea())
            .navigationTitle(isEnglish ? "Search" : "Поиск")
        }
        .tabItem {
            Label(isEnglish ? "Search" : "Поиск", systemImage: "magnifyingglass")
        }
    }

    /// Inline capsule search bar with focus-triggered Cancel button.
    private var inlineSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    isEnglish ? "Tracks, albums, artists" : "Треки, альбомы, артисты",
                    text: $homeSearchText
                )
                .font(.system(size: 15))
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
                .onChange(of: homeSearchText) { newValue in
                    if searchMode == .tracks {
                        debouncedCatalogSearch(newValue)
                    } else {
                        debouncedUserSearch(newValue)
                    }
                }
                if !homeSearchText.isEmpty {
                    Button {
                        homeSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(isDarkMode ? Color(white: 0.14) : Color(.systemGray6))
            )

            if isSearchFieldFocused || !homeSearchText.isEmpty {
                Button {
                    homeSearchText = ""
                    isSearchFieldFocused = false
                } label: {
                    Text(isEnglish ? "Cancel" : "Отмена")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isSearchFieldFocused)
        .animation(.easeInOut(duration: 0.22), value: homeSearchText.isEmpty)
    }

    private var providerFilterChips: some View {
        let options = ["all", "spotify", "soundcloud", "youtube", "deezer"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { (prov: String) in
                    let label: String = prov == "all" ? (isEnglish ? "All" : "Все") : prov.capitalized
                    let isSelected: Bool = searchProviderFilter == prov
                    Button {
                        searchProviderFilter = prov
                        if searchMode == .tracks {
                            debouncedCatalogSearch(homeSearchText)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if prov != "all" {
                                ServiceIconBadge(provider: prov, size: 14)
                            }
                            Text(label)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isSelected ? accent.opacity(0.2) : (isDarkMode ? Color(white: 0.14) : Color(.systemGray6)))
                        )
                        .overlay(Capsule().stroke(isSelected ? accent : .clear, lineWidth: 1.5))
                        .foregroundStyle(isSelected ? accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var searchResultsListView: some View {
        let query = homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !query.isEmpty {
                    Picker("", selection: $searchMode) {
                        Text(isEnglish ? "Tracks" : "Треки").tag(SearchMode.tracks)
                        Text(isEnglish ? "People" : "Люди").tag(SearchMode.people)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .onChange(of: searchMode) { _ in
                        if searchMode == .tracks {
                            debouncedCatalogSearch(homeSearchText)
                        } else {
                            debouncedUserSearch(homeSearchText)
                        }
                    }

                    if searchMode == .tracks {
                        providerFilterChips
                    }
                }
                if query.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(isEnglish ? "Start typing to search" : "Начните вводить, чтобы искать")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if searchMode == .people {
                    if isUserSearching {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            Text(isEnglish ? "Searching…" : "Поиск…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if let err = userSearchError, !err.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text(isEnglish ? "Couldn’t load users" : "Не удалось загрузить пользователей")
                                .font(.subheadline.weight(.medium))
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if userSearchResults.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text(isEnglish ? "No users found" : "Пользователи не найдены")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isEnglish ? "People" : "Пользователи")
                                .font(.system(size: 18, weight: .semibold))
                                .padding(.leading, 16)
                            ForEach(userSearchResults) { u in
                                NavigationLink {
                                    RemoteUserProfileView(userID: u.id, accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)
                                } label: {
                                    userSearchRow(u: u)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    let localFiltered = tracks.filter {
                        $0.displayTitle.localizedCaseInsensitiveContains(query)
                        || $0.displayArtist.localizedCaseInsensitiveContains(query)
                    }
                    let catalogTracks = catalogSearchResults?.tracks ?? []
                    let catalogArtists = catalogSearchResults?.artists ?? []
                    let catalogAlbums = catalogSearchResults?.albums ?? []
                    let catalogSearchCompleted = catalogSearchResults != nil

                    if isCatalogSearching && !catalogSearchCompleted {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            Text(isEnglish ? "Searching…" : "Поиск…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                    if !localFiltered.isEmpty || !catalogTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isEnglish ? "Tracks" : "Треки")
                                .font(.system(size: 18, weight: .semibold))
                                .padding(.leading, 16)
                            ForEach(localFiltered) { track in
                                searchLocalRow(track: track)
                            }
                            ForEach(catalogTracks) { track in
                                searchCatalogRow(track: track)
                            }
                        }
                    }

                    if !catalogArtists.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isEnglish ? "Artists" : "Исполнители")
                                .font(.system(size: 18, weight: .semibold))
                                .padding(.leading, 16)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(catalogArtists) { artist in
                                        CatalogArtistCard(artist: artist, accent: accent, isDarkMode: isDarkMode) {
                                            openArtistByName(artist.name)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    if !catalogAlbums.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isEnglish ? "Albums" : "Альбомы")
                                .font(.system(size: 18, weight: .semibold))
                                .padding(.leading, 16)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(catalogAlbums) { album in
                                        CatalogAlbumCard(album: album, accent: accent, isDarkMode: isDarkMode) { openAlbum(album) }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    if let error = catalogSearchError {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text(isEnglish ? "Connection error" : "Ошибка соединения")
                                .font(.subheadline.weight(.medium))
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button {
                                debouncedCatalogSearch(homeSearchText)
                            } label: {
                                Text(isEnglish ? "Retry" : "Повторить")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color(.systemGray5)))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if catalogSearchCompleted && localFiltered.isEmpty && catalogTracks.isEmpty && catalogArtists.isEmpty && catalogAlbums.isEmpty {
                        Text(isEnglish ? "Nothing found" : "Ничего не найдено")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func searchLocalRow(track: AppTrack) -> some View {
        Button {
            currentTrack = track
            playbackHolder.progress = 0
            isMiniPlayerHidden = false
            startPlayback(for: track)
            openPlayerSheet()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(isEnglish ? "Local" : "В устройстве")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func searchCatalogRow(track: CatalogTrack) -> some View {
        Button {
            playCatalogTrack(track, queue: catalogSearchResults?.tracks ?? [track])
            openPlayerSheet()
        } label: {
            HStack(spacing: 12) {
                if let urlString = track.coverURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color(.systemGray5)
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if downloadsStore.isDownloaded(provider: track.provider, id: track.id) {
                    DownloadedBadge(size: 14)
                }
                ServiceIconBadge(provider: track.provider)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContentV3: some View {
        let base = TabView(selection: $selectedTab) {
            homeTabV2.tag(MainAppTab.home)
            favoritesTab.tag(MainAppTab.favorites)
            settingsTab.tag(MainAppTab.profile)
            searchTab.tag(MainAppTab.search)
        }
        .tint(Color(.systemGray))
        .onChange(of: selectedTab) { newValue in
            if newValue != .search { homeSearchText = "" }
        }

        if #available(iOS 26.0, *) {
            base
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    miniPlayerAccessoryContainer
                }
        } else {
            base
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    miniPlayerAccessoryContainer
                }
        }
    }

    @ViewBuilder
    private var miniPlayerAccessoryContainer: some View {
        if let _ = currentTrack, !isPlayerSheetPresented, !isMiniPlayerHidden, playerStyleIndex == 0 {
            // ExpandingGlassPlayerOverlay (.overlay в mainBodyBase) сам рисует мини-бар на iOS 26.
            // Резервируем только высоту, чтобы контент TabView не уходил под бар, и не было дублирования / разворота обложки.
            Color.clear
                .frame(height: 64 + 12)
                .padding(.bottom, 6)
        } else {
            EmptyView()
        }
    }

    private func settingsRow(title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
    }

    /// Поле в стиле меню входа: капсула, иконка в кружке слева, плейсхолдер внутри. Опционально: кнопка-иконка справа (как глазок в пароле) или кнопка «Сброс». isSearch: true — обычная клавиатура для поиска. verticalPadding: nil = 14, задать 12 для совпадения с кнопками вкладки Настройки.
    private func settingsCapsuleField(
        placeholder: String,
        text: Binding<String>,
        systemImage: String,
        showResetButton: Bool = false,
        onReset: (() -> Void)? = nil,
        trailingSystemImage: String? = nil,
        onTrailingTap: (() -> Void)? = nil,
        isTrailingDisabled: Bool = false,
        showShadow: Bool = true,
        isSearch: Bool = false,
        verticalPadding: CGFloat = 14
    ) -> some View {
        let capsuleColor = isDarkMode ? accent : Color.white
        let textColor = isDarkMode ? Color.white : accent
        let circleFill = isDarkMode ? Color.white : accent
        let iconColor = isDarkMode ? accent : Color.white
        let cursorColor = isDarkMode ? Color.white : accent
        let hasTrailingIcon = trailingSystemImage != nil && onTrailingTap != nil
        let hasTrailingReset = showResetButton && onReset != nil
        let hasTrailing = hasTrailingIcon || hasTrailingReset
        let trailingPadding: CGFloat = hasTrailing ? (hasTrailingIcon ? 52 : 56) : 20

        let field = Group {
            if isSearch {
                TextField("", text: text)
                    .tint(cursorColor)
                    .padding(.leading, 52)
                    .padding(.trailing, trailingPadding)
                    .padding(.vertical, verticalPadding)
                    .frame(maxWidth: .infinity)
            } else {
                TextField("", text: text)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .tint(cursorColor)
                    .padding(.leading, 52)
                    .padding(.trailing, trailingPadding)
                    .padding(.vertical, verticalPadding)
                    .frame(maxWidth: .infinity)
            }
        }

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
        .shadow(color: (isDarkMode || !showShadow) ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
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
        .overlay(alignment: .trailing) {
            if let img = trailingSystemImage, let action = onTrailingTap {
                Button(action: action) {
                    ZStack {
                        Circle().fill(circleFill)
                        Image(systemName: img)
                            .font(.system(size: 16, weight: .semibold))
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

    private func miniPlayer(for track: AppTrack, namespace: Namespace.ID, playbackHolder: PlaybackStateHolder) -> some View {
        MiniPlayerBarView(track: track, catalogTrack: currentCatalogTrack, accent: accent, playbackHolder: playbackHolder, onPlayPause: togglePlayPause, onTap: openPlayerSheet, onArtistTap: { openArtistByName(track.displayArtist) }, namespace: namespace, playerStyleIndex: playerStyleIndex, roundPlayerCover: enableRoundPlayerCover)
    }

private struct MiniPlayerBarView: View {
    let track: AppTrack
    var catalogTrack: CatalogTrack?
    let accent: Color
    @ObservedObject var playbackHolder: PlaybackStateHolder
    let onPlayPause: () -> Void
    let onTap: () -> Void
    var onArtistTap: (() -> Void)?
    let namespace: Namespace.ID
    var playerStyleIndex: Int = 0
    var roundPlayerCover: Bool = false

	    var body: some View {
	        let content = HStack(alignment: .center, spacing: 10) {
	            miniCoverView
	                .frame(width: 44, height: 44)
	                .clipShape(RoundedRectangle(cornerRadius: 8))
	                .overlay(
	                    GeometryReader { g in
	                        Color.clear.preference(key: MiniCoverFrameKey.self, value: g.frame(in: .global))
	                    }
	                )

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
                        .onTapGesture { onArtistTap?() }
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
        .padding(.vertical, 8)

        return Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .onTapGesture { onTap() }
            }
        }
    }

    @ViewBuilder
    private var miniCoverView: some View {
        if let urlStr = catalogTrack?.coverURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    coverPlaceholder
                }
            }
        } else {
            MiniPlayerCoverViewIOS26(track: track, accent: accent, roundPlayerCover: roundPlayerCover)
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(accent.opacity(0.3))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            )
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
    /// displayPlayingOverride: при задании (стили 1 и 3 на iOS 16–18) обложка и масштаб обновляются без задержки при быстром тапе.
    private struct PlayingScaleModifier: ViewModifier {
        @ObservedObject var playbackHolder: PlaybackStateHolder
        let coverScale: CGFloat
        var displayPlayingOverride: Bool? = nil
        func body(content: Content) -> some View {
            let isPlaying = displayPlayingOverride ?? playbackHolder.isPlaying
            content
                .scaleEffect(coverScale * (isPlaying ? 1.06 : 0.92))
                .animation(.spring(response: 0.52, dampingFraction: 0.68), value: isPlaying)
        }
    }

    /// iOS 26: условно применяет Liquid Glass к обложке в большом плеере (стиль 2, перелистывание выключено).
    private struct ConditionalCoverGlassModifier: ViewModifier {
        var apply: Bool
        var tint: Color
        var coverCornerRadius: CGFloat = 36
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                if apply {
                    content.glassEffect(.regular.tint(tint).interactive(), in: RoundedRectangle(cornerRadius: coverCornerRadius))
                } else {
                    content
                }
            } else {
                content
            }
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

    /// Кнопка play/pause для стилей 1 и 3 на iOS 16–18: иконка всегда синхронизирована с playbackHolder.isPlaying (трек играет — пауза, не играет — плей).
    private struct PlayerSheetPlayPauseButtonStyle13Legacy: View {
        @ObservedObject var playbackHolder: PlaybackStateHolder
        let font: Font
        let color: Color
        let frameWidth: CGFloat
        let frameHeight: CGFloat
        let controlsColor: Color
        let isDarkTheme: Bool
        let onTogglePlayPause: () -> Void

        var body: some View {
            Button {
                onTogglePlayPause()
            } label: {
                Image(systemName: playbackHolder.isPlaying ? "pause.fill" : "play.fill")
                    .font(font)
                    .foregroundStyle(color)
                    .frame(width: frameWidth, height: frameHeight)
                    .background(controlsColor, in: Circle())
            }
            .buttonStyle(ScaleOnPressRoundButtonStyle(isDarkTheme: isDarkTheme))
        }
    }

    /// Кнопка play/pause для стиля 2 на iOS 16–18: иконка обновляется сразу по тапу (без подвисания при быстром нажатии).
    private struct PlayerSheetPlayPauseButtonStyle2Legacy: View {
        @ObservedObject var playbackHolder: PlaybackStateHolder
        @State private var displayPlaying: Bool = false
        let font: Font
        let color: Color
        let frameWidth: CGFloat
        let frameHeight: CGFloat
        let controlsColor: Color
        let isDarkTheme: Bool
        let onTogglePlayPause: () -> Void

        var body: some View {
            Button {
                displayPlaying.toggle()
                onTogglePlayPause()
            } label: {
                Image(systemName: displayPlaying ? "pause.fill" : "play.fill")
                    .font(font)
                    .foregroundStyle(color)
                    .frame(width: frameWidth, height: frameHeight)
                    .background(controlsColor, in: Circle())
            }
            .buttonStyle(ScaleOnPressRoundButtonStyle(isDarkTheme: isDarkTheme))
            .onAppear { displayPlaying = playbackHolder.isPlaying }
            .onChange(of: playbackHolder.isPlaying) { new in displayPlaying = new }
        }
    }

    /// Нижний ряд кнопок (избранное, цикл с контекстным меню и т.д.).
    private struct PlayerSheetBottomButtonsRow: View {
        let isFavorite: Bool
        let isDownloaded: Bool
        let isDownloading: Bool
        let repeatMode: RepeatMode
        let repeatModeIcon: String
        let repeatPauseAtEndTitle: String
        let repeatOneTitle: String
        let repeatPlayNextTitle: String
        let deleteFromDeviceTitle: String
        let hideFromRecommendationsTitle: String
        let equalizerTitle: String
        let shareTitle: String
        let controlsColor: Color
        let bottomIconColor: Color
        let bottomCircleTint: Color
        let isBluetooth: Bool
        let useGlassStyle: Bool
        let onFavoriteToggle: () -> Void
        let onDownloadTap: () -> Void
        let onRepeatCycle: () -> Void
        let onRepeatModeChange: (RepeatMode) -> Void
        let onDeleteFromDevice: () -> Void
        let onHideFromRecommendations: () -> Void
        let onOpenEqualizer: () -> Void
        let onShareTrack: () -> Void
        let onLyricsTap: () -> Void

        var body: some View {
            HStack(spacing: 24) {
                if #available(iOS 26.0, *), useGlassStyle {
                    Button { DispatchQueue.main.async { onFavoriteToggle() } } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(bottomIconColor)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(bottomCircleTint).interactive(), in: Circle())

                    Button { DispatchQueue.main.async { onDownloadTap() } } label: {
                        Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(bottomIconColor)
                            .frame(width: 44, height: 44)
                            .opacity(isDownloading ? 0.6 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading)
                    .glassEffect(.regular.tint(bottomCircleTint).interactive(), in: Circle())

                    Button { onLyricsTap() } label: {
                        Image(systemName: "text.bubble.fill")
                            .font(.title2)
                            .foregroundStyle(bottomIconColor)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(bottomCircleTint).interactive(), in: Circle())

                    ZStack {
                        AirPlayRoutePickerRepresentable()
                            .frame(width: 44, height: 44)
                        Image(systemName: isBluetooth ? "airpodspro" : "airplayaudio")
                            .font(.title2)
                            .foregroundStyle(bottomIconColor)
                            .allowsHitTesting(false)
                    }
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(bottomCircleTint).interactive(), in: Circle())

                    Button { DispatchQueue.main.async { onRepeatCycle() } } label: {
                        Image(systemName: repeatModeIcon)
                            .font(.title2)
                            .foregroundStyle(bottomIconColor)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(bottomCircleTint).interactive(), in: Circle())
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

                    Menu {
                        Button(role: .destructive) {
                            DispatchQueue.main.async { onDeleteFromDevice() }
                        } label: {
                            Label(deleteFromDeviceTitle, systemImage: "trash")
                        }
                        Button {
                            DispatchQueue.main.async { onHideFromRecommendations() }
                        } label: {
                            Label(hideFromRecommendationsTitle, systemImage: "eye.slash")
                        }
                        Button {
                            DispatchQueue.main.async { onShareTrack() }
                        } label: {
                            Label(shareTitle, systemImage: "square.and.arrow.up")
                        }
                        Button {
                            DispatchQueue.main.async { onOpenEqualizer() }
                        } label: {
                            Label(equalizerTitle, systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title2)
                            .foregroundStyle(bottomIconColor)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(bottomCircleTint).interactive(), in: Circle())
                } else {
                    Button { DispatchQueue.main.async { onFavoriteToggle() } } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(controlsColor)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)

                    Button { DispatchQueue.main.async { onDownloadTap() } } label: {
                        Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(controlsColor)
                            .opacity(isDownloading ? 0.6 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading)
                    .frame(width: 44, height: 44)

                    Button { onLyricsTap() } label: {
                        Image(systemName: "text.bubble.fill")
                            .font(.title2)
                            .foregroundStyle(controlsColor)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)

                    ZStack {
                        AirPlayRoutePickerRepresentable()
                            .frame(width: 44, height: 44)
                        Image(systemName: isBluetooth ? "airpodspro" : "airplayaudio")
                            .font(.title2)
                            .foregroundStyle(controlsColor)
                            .allowsHitTesting(false)
                    }
                    .frame(width: 44, height: 44)

                    Button { DispatchQueue.main.async { onRepeatCycle() } } label: {
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

                    Menu {
                        Button(role: .destructive) {
                            DispatchQueue.main.async { onDeleteFromDevice() }
                        } label: {
                            Label(deleteFromDeviceTitle, systemImage: "trash")
                        }
                        Button {
                            DispatchQueue.main.async { onHideFromRecommendations() }
                        } label: {
                            Label(hideFromRecommendationsTitle, systemImage: "eye.slash")
                        }
                        Button {
                            DispatchQueue.main.async { onShareTrack() }
                        } label: {
                            Label(shareTitle, systemImage: "square.and.arrow.up")
                        }
                        Button {
                            DispatchQueue.main.async { onOpenEqualizer() }
                        } label: {
                            Label(equalizerTitle, systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title2)
                            .foregroundStyle(controlsColor)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                }
            }
        }
    }

    /// Блок прогресса (время + слайдер) в большом плеере — только он перерисовывается при смене прогресса.
    private struct PlayerSheetProgressSection: View {
        @ObservedObject var playbackHolder: PlaybackStateHolder
        @Binding var isSeeking: Bool
        @Binding var seekValue: Double
        @Binding var seekScrubIntensity: CGFloat
        @Binding var seekScrubDirection: CGFloat
        let formatTime: (TimeInterval) -> String
        let onSeek: (Double) -> Void
        let controlsColor: Color

        @State private var lastSeekSample: (value: Double, time: CFTimeInterval)? = nil
        private let scrubDecayTimer = Timer.publish(every: 0.045, on: .main, in: .common).autoconnect()

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
                        set: { newValue in
                            if isSeeking {
                                let now = CACurrentMediaTime()
                                if let last = lastSeekSample {
                                    let dt = now - last.time
                                    if dt > 0.001 {
                                        let deltaProgress = newValue - last.value
                                        let dv = abs(deltaProgress)
                                        if dv > 1e-7 {
                                            seekScrubDirection = deltaProgress > 0 ? 1 : -1
                                        }
                                        let speed = dv / dt
                                        let instant = min(1 as CGFloat, CGFloat(speed / 1.65))
                                        seekScrubIntensity = min(1, seekScrubIntensity * 0.52 + instant * 0.48)
                                    }
                                }
                                lastSeekSample = (newValue, now)
                            }
                            seekValue = newValue
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            isSeeking = true
                            seekScrubDirection = 0
                            seekValue = playbackHolder.progress
                            lastSeekSample = (playbackHolder.progress, CACurrentMediaTime())
                        } else {
                            isSeeking = false
                            seekScrubIntensity = 0
                            seekScrubDirection = 0
                            lastSeekSample = nil
                            onSeek(seekValue)
                        }
                    }
                )
                .tint(controlsColor)
            }
            .onReceive(scrubDecayTimer) { _ in
                guard isSeeking else { return }
                let next = seekScrubIntensity * 0.88
                seekScrubIntensity = next < 0.04 ? 0 : next
            }
            .onChange(of: playbackHolder.progress) { newValue in
                if newValue < 0.01 {
                    seekValue = 0
                }
            }
        }
    }

    /// Модификатор драга для sheet (стиль 1 из бэкапа): при isBottomSheet контент без offset/жеста.
    private struct PlayerDragModifierStyle1: ViewModifier {
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

    /// Плеер из бэкапа (Sphere16): без капсулы у названия, нижний ряд кнопок без кружков, обложка/название/кнопки/ползунки ниже. Только для стиля 1 на iOS 26.
    private struct PlayerSheetViewStyle1FromBackup: View {
        @Environment(\.colorScheme) private var colorScheme
        let track: AppTrack
        var catalogTrack: CatalogTrack? = nil
        @ObservedObject private var favoritesStore = FavoritesStore.shared
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
        var onDeleteTrackFromDevice: () -> Void = {}
        var onHideTrackFromRecommendations: () -> Void = {}
        var onOpenEqualizer: () -> Void = {}
        var onLyricsTap: () -> Void = {}
        var onArtistTap: (() -> Void)? = nil
        var isBottomSheet: Bool = false
        var tracks: [AppTrack] = []
        var currentTrackIndex: Int = 0
        var coverImages: [UIImage?] = []
        var onTrackSelected: ((Int) -> Void)? = nil
        var enableCoverPaging: Bool = true
        var enableCoverSeekAnimation: Bool = false
        var coverSeekWobbleOnSeek: Bool = true
        var coverSeekSpinOnSeek: Bool = false
        var roundPlayerCover: Bool = false

        @Binding var isSeeking: Bool
        @Binding var seekScrubIntensity: CGFloat
        @Binding var seekScrubDirection: CGFloat
        @StateObject private var coverPagingDriver = TabPagingDriver()

        private var repeatPauseAtEndTitle: String { isEnglish ? "Stop after track" : "Заканчивать прослушивание" }
        private var repeatOneTitle: String { isEnglish ? "Repeat one" : "Прослушивать повторно" }
        private var repeatPlayNextTitle: String { isEnglish ? "Play next" : "Воспроизводить следующее" }
        private var deleteFromDeviceTitle: String { isEnglish ? "Delete track from device" : "Удалить трек с устройства" }
        private var hideFromRecommendationsTitle: String { isEnglish ? "Hide from recommendations" : "Не показывать трек в рекомендациях" }
        private var equalizerSheetTitle: String { isEnglish ? "Equalizer" : "Эквалайзер" }

        @State private var seekValue: Double = 0
        @State private var dragOffset: CGFloat = 0
        @State private var titleOffsetY: CGFloat = 28
        @State private var titleScale: CGFloat = 0.88
        @State private var coverBlur: CGFloat = 10
        @State private var coverScale: CGFloat = 0.12

        private var isFavorite: Bool {
            if let c = catalogTrack {
                return favoritesStore.isFavorite(provider: c.provider, id: c.id)
            }
            return favoritesStore.isFavoriteLocal(uuid: track.id.uuidString)
        }

        private func toggleFavorite() {
            if let c = catalogTrack {
                Task { await favoritesStore.toggle(track: c) }
            } else {
                let title = track.title ?? track.url.deletingPathExtension().lastPathComponent
                let artist = track.artist ?? ""
                Task {
                    await favoritesStore.toggleLocal(
                        uuid: track.id.uuidString,
                        title: title,
                        artist: artist
                    )
                }
            }
        }

        private var coverSeekShakeEnabled: Bool { enableCoverSeekAnimation && coverSeekWobbleOnSeek }
        private var coverSeekSpinEnabled: Bool { enableCoverSeekAnimation && coverSeekSpinOnSeek }

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
                    let coverCR = playerArtworkCornerRadius(squareSide: artworkSize, round: roundPlayerCover)
                    let controlsColor = accentForTheme(gradientColor, isDarkTheme: isDarkTheme)
                    let buttonIconColor = iconColor(onBackground: controlsColor)
                    let textColors: (title: Color, artist: Color) = isDarkTheme
                        ? (Color.white, Color(white: 0.65))
                        : (Color.black, Color(white: 0.38))

                    ZStack {
                        VStack(spacing: 0) {
                        // Обложка: слот под hero + перелистывание (стиль 1 на iOS 26). Высота зафиксирована — не сдвигать.
                        ZStack {
                            RoundedRectangle(cornerRadius: coverCR)
                                .fill(accent)
                                .frame(width: artworkSize, height: artworkSize)
                                .overlay(
                                    Group {
                                        if let cover = coverImage {
                                            Image(uiImage: cover)
                                                .resizable()
                                                .scaledToFill()
                                                .clipShape(RoundedRectangle(cornerRadius: coverCR))
                                        } else if let urlStr = catalogTrack?.coverURL, let url = URL(string: urlStr) {
                                            AsyncImage(url: url) { phase in
                                                switch phase {
                                                case .success(let img):
                                                    img.resizable().scaledToFill()
                                                        .clipShape(RoundedRectangle(cornerRadius: coverCR))
                                                default:
                                                    Image("Voxmusic").resizable().scaledToFit()
                                                        .clipShape(RoundedRectangle(cornerRadius: coverCR)).padding(24)
                                                }
                                            }
                                        } else {
                                            Image("Voxmusic")
                                                .resizable()
                                                .scaledToFit()
                                                .clipShape(RoundedRectangle(cornerRadius: coverCR))
                                                .padding(24)
                                        }
                                    }
                                )
                                .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
                                .blur(radius: coverBlur)
                                .modifier(PlayingScaleModifier(playbackHolder: playbackHolder, coverScale: coverScale))
                                .animation(.spring(response: 0.48, dampingFraction: 0.72), value: coverScale)
                                .animation(.easeOut(duration: 0.5), value: coverBlur)
                                .animation(.easeInOut(duration: 0.32), value: track.id)
                                .opacity(enableCoverPaging && !tracks.isEmpty ? 0 : 1)

                            if enableCoverPaging, !tracks.isEmpty {
                                PlayerSheetCoverPagingView(
                                    pagingDriver: coverPagingDriver,
                                    trackCount: tracks.count,
                                    coverImages: coverImages.isEmpty ? tracks.map { _ in coverImage } : coverImages,
                                    currentIndex: min(max(currentTrackIndex, 0), max(tracks.count - 1, 0)),
                                    accent: accent,
                                    artworkSize: artworkSize,
                                    coverCornerRadius: coverCR,
                                    onTrackSelected: { index in
                                        onTrackSelected?(index)
                                    }
                                )
                                .modifier(PlayingScaleModifier(playbackHolder: playbackHolder, coverScale: coverScale))
                                .animation(.spring(response: 0.48, dampingFraction: 0.72), value: coverScale)
                                .animation(.easeInOut(duration: 0.32), value: track.id)
                            }
                        }
                        .modifier(CoverSeekShakeTiltModifier(enable: coverSeekShakeEnabled, isSeeking: isSeeking, scrubIntensity: seekScrubIntensity))
                        .modifier(CoverSeekSpinModifier(enable: coverSeekSpinEnabled, isSeeking: isSeeking, scrubIntensity: seekScrubIntensity, scrubDirection: seekScrubDirection))
                        .padding(.top, 100)
                        .offset(y: -5)
                        .frame(height: artworkSize + 100)

                        Spacer(minLength: 4)

                        Group {
                        // Название и исполнитель — фиксированная высота, чтобы кнопки и ползунки не сдвигались.
                        VStack(spacing: 6) {
                            Text(track.displayTitle)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(textColors.title)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .scaleEffect(titleScale)
                            if !track.displayArtist.isEmpty {
                                Button { onArtistTap?() } label: {
                                    Text(track.displayArtist)
                                        .font(.body)
                                        .foregroundStyle(textColors.artist)
                                        .multilineTextAlignment(.center)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .padding(.horizontal, 32)
                        .padding(.top, 0)
                        .padding(.bottom, 6)
                        .offset(y: titleOffsetY)
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

                        Spacer(minLength: 4)

                        // Кнопки паузы/перемотки (iOS 26 стиль 1): как до правок — glass(tint: controlsColor), иконки buttonIconColor, async.
                        HStack(spacing: 40) {
                            if #available(iOS 26.0, *) {
                                Button { DispatchQueue.main.async { onPrevious() } } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.title2)
                                        .foregroundStyle(buttonIconColor)
                                        .frame(width: 56, height: 56)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(controlsColor).interactive(), in: Circle())

                                Button { DispatchQueue.main.async { onTogglePlayPause() } } label: {
                                    PlayerSheetPlayPauseIcon(playbackHolder: playbackHolder, font: .system(size: 28, weight: .semibold), color: buttonIconColor, frameWidth: 72, frameHeight: 72)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(controlsColor).interactive(), in: Circle())

                                Button { DispatchQueue.main.async { onNext() } } label: {
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
                        .padding(.top, 2)
                        .padding(.bottom, 6)

                        // Ползунок перемотки — время сверху, ползунок снизу
                        PlayerSheetProgressSection(
                            playbackHolder: playbackHolder,
                            isSeeking: $isSeeking,
                            seekValue: $seekValue,
                            seekScrubIntensity: $seekScrubIntensity,
                            seekScrubDirection: $seekScrubDirection,
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
                        .padding(.bottom, 16)

                        // Нижний ряд из 5 кнопок — без кружков, ближе к центру
                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 24) {
                                Button {
                                    toggleFavorite()
                                } label: {
                                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                                        .font(.title2)
                                        .foregroundStyle(controlsColor)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 44, height: 44)

                                Button { onLyricsTap() } label: {
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

                                Menu {
                                    Button(role: .destructive, action: onDeleteTrackFromDevice) {
                                        Label(deleteFromDeviceTitle, systemImage: "trash")
                                    }
                                    Button(action: onHideTrackFromRecommendations) {
                                        Label(hideFromRecommendationsTitle, systemImage: "eye.slash")
                                    }
                                    Button(action: onOpenEqualizer) {
                                        Label(equalizerSheetTitle, systemImage: "slider.horizontal.3")
                                    }
                                } label: {
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Capsule()
                        .fill(Color(.systemGray3))
                        .frame(width: 36, height: 5)
                        .padding(.top, isBottomSheet ? 92 : 10)
                        .padding(.bottom, 6)
                }
                .modifier(PlayerDragModifierStyle1(isBottomSheet: isBottomSheet, dragOffset: $dragOffset, onDismiss: onDismiss))
            }
        }
    }

    private struct PlayerSheetView: View {
        @Environment(\.colorScheme) private var colorScheme
        let track: AppTrack
        var catalogTrack: CatalogTrack? = nil
        @ObservedObject private var favoritesStore = FavoritesStore.shared
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
        var onDeleteTrackFromDevice: () -> Void = {}
        var onHideTrackFromRecommendations: () -> Void = {}
        var onOpenEqualizer: () -> Void = {}
        var onShareCatalogTrack: (CatalogTrack) -> Void = { _ in }
        var onLyricsTap: () -> Void = {}
        var onArtistTap: (() -> Void)? = nil
        /// Список треков и обложек для перелистывания (используется на iOS 26 в стилях 2 и 3).
        var tracks: [AppTrack] = []
        var currentTrackIndex: Int = 0
        var coverImages: [UIImage?] = []
        var onTrackSelected: ((Int) -> Void)? = nil
        /// Флаг: когда true, показываем перелистывание обложек в большом плеере.
        /// Нужен, чтобы во время анимации «мини → большой» обложку рисовал только герой.
        var enableCoverPaging: Bool = true
        /// Когда true, при перематывании слайдером обложка трясётся и наклоняется, при отпускании возвращается.
        var enableCoverSeekAnimation: Bool = false
        var coverSeekWobbleOnSeek: Bool = true
        var coverSeekSpinOnSeek: Bool = false
        var roundPlayerCover: Bool = false
        /// Прогресс раскрытия (0…1). На iOS 26 стили 2/3: функциональная обложка невидима при < 0.7, появляется вместе с исчезновением героя.
        var expandProgress: CGFloat = 1
        var isBottomSheet: Bool = false
        /// true = без фона (только liquid glass снаружи, iOS 26 expanding overlay)
        var transparentBackground: Bool = false
        /// Тема от оверлея стиля 2 (блюр). nil = по colorScheme.
        var isDarkThemeFromParent: Bool? = nil
        /// Выбранный стиль плеера (0/1/2), используется только на iOS 16–18.
        var playerStyleIndex: Int = 0

        private var repeatPauseAtEndTitle: String { isEnglish ? "Stop after track" : "Заканчивать прослушивание" }
        private var repeatOneTitle: String { isEnglish ? "Repeat one" : "Прослушивать повторно" }
        private var repeatPlayNextTitle: String { isEnglish ? "Play next" : "Воспроизводить следующее" }
        private var deleteFromDeviceTitle: String { isEnglish ? "Delete track from device" : "Удалить трек с устройства" }
        private var hideFromRecommendationsTitle: String { isEnglish ? "Hide from recommendations" : "Не показывать трек в рекомендациях" }
        private var equalizerSheetTitle: String { isEnglish ? "Equalizer" : "Эквалайзер" }

        @Binding var isSeeking: Bool
        @Binding var seekScrubIntensity: CGFloat
        @Binding var seekScrubDirection: CGFloat
        @State private var seekValue: Double = 0
        @State private var dragOffset: CGFloat = 0
        @State private var titleOffsetY: CGFloat = 28
        @State private var titleScale: CGFloat = 0.88
        @State private var coverBlur: CGFloat = 10
        @State private var coverScale: CGFloat = 0.12
        @StateObject private var coverPagingDriver = TabPagingDriver()

        private var isFavorite: Bool {
            if let c = catalogTrack {
                return favoritesStore.isFavorite(provider: c.provider, id: c.id)
            }
            return favoritesStore.isFavoriteLocal(uuid: track.id.uuidString)
        }

        private func toggleFavorite() {
            if let c = catalogTrack {
                Task { await favoritesStore.toggle(track: c) }
            } else {
                let title = track.title ?? track.url.deletingPathExtension().lastPathComponent
                let artist = track.artist ?? ""
                Task {
                    await favoritesStore.toggleLocal(
                        uuid: track.id.uuidString,
                        title: title,
                        artist: artist
                    )
                }
            }
        }
        /// На iOS 16–18 при пейджинге: 0 = обложка поверх функциональной видна, 1 = исчезла. Анимируется при появлении.
        @State private var overlayFadeOutProgress: CGFloat = 0
        /// true только на iOS 16–18 для стилей 1 и 3 (индексы 0 и 2) — кнопка play/pause и масштаб обложки синхронизированы с playbackHolder.isPlaying.
        private var useLegacyOptimisticS13: Bool {
            if #available(iOS 26.0, *) { return false }
            return playerStyleIndex == 0 || playerStyleIndex == 2
        }

        private var coverSeekShakeEnabled: Bool { enableCoverSeekAnimation && coverSeekWobbleOnSeek }
        private var coverSeekSpinEnabled: Bool { enableCoverSeekAnimation && coverSeekSpinOnSeek }

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

        /// На iOS 16–18 стиль 2: сдвиг названия, кнопок и ползунков вверх (обложку не трогаем).
        private var style2ControlsOffsetY: CGFloat {
            if #available(iOS 26.0, *) { return 0 }
            return playerStyleIndex == 1 ? -28 : 0
        }

        /// Непрозрачность слота-обложки: на iOS 26 всегда 0 (hero снаружи). На iOS 16–18 при выключенном перелистывании — 0 (как в бэкапе, обложку рисует hero); при включённом — плавно от 1 до 0.
        private var overlaySlotOpacity: CGFloat {
            if #available(iOS 26.0, *) {
                // Стиль 2 (index 1): при выключенном перелистывании показываем обложку с Liquid Glass в большом плеере.
                if playerStyleIndex == 1, !enableCoverPaging { return 1 }
                return 0
            }
            if enableCoverPaging, !tracks.isEmpty {
                return 1 - overlayFadeOutProgress
            }
            return 0
        }

        /// iOS 26, стиль 2, перелистывание выключено: обложка в большом плеере с Liquid Glass. Без glass при любой анимации перемотки (дрожание или вращение).
        private var useCoverLiquidGlassInSheet: Bool {
            guard #available(iOS 26.0, *) else { return false }
            return playerStyleIndex == 1 && !enableCoverPaging && !enableCoverSeekAnimation
        }

        var body: some View {
            playerSheetContent()
        }

        @ViewBuilder
        private func playerSheetContent() -> some View {
            PlayerSheetConditionalIDWrapper(id: playerStyleIndex) {
            let gradientColor = coverAccent ?? accent
            let isDarkTheme = isDarkThemeFromParent ?? (colorScheme == .dark)
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
                if !transparentBackground {
                    (isDarkTheme ? Color(.systemBackground) : Color.white)
                        .ignoresSafeArea(edges: .all)
                    if isDarkTheme {
                        backgroundGradient
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(edges: .all)
                    }
                }

                GeometryReader { geo in
                    let artworkSize = min(geo.size.width - 48, 320)
                    let coverCR = playerArtworkCornerRadius(squareSide: artworkSize, round: roundPlayerCover)
                    let chromePalette = PlayerSheetChromePalette(gradientColor: gradientColor, isDarkTheme: isDarkTheme)
                    let controlsColor = chromePalette.controlsColor
                    let buttonIconColor = chromePalette.buttonIconColor

                    ZStack {
                        VStack(spacing: 0) {
                        // Область обложки: слот под hero + перелистывание. Высота зафиксирована — не сдвигать.
                        ZStack {
                            // Слот для hero (рисуется в MainAppView поверх всего). На iOS 16–18 при пейджинге — видимая обложка поверх функциональной, плавно исчезает.
                            RoundedRectangle(cornerRadius: coverCR)
                                .fill(accent)
                                .frame(width: artworkSize, height: artworkSize)
                                .overlay(
                                    SwiftUI.Group {
                                        if let cover = coverImage {
                                            Image(uiImage: cover)
                                                .resizable()
                                                .scaledToFill()
                                                .clipShape(RoundedRectangle(cornerRadius: coverCR))
                                        } else if let urlStr = catalogTrack?.coverURL, let url = URL(string: urlStr) {
                                            AsyncImage(url: url) { phase in
                                                switch phase {
                                                case .success(let img):
                                                    img.resizable().scaledToFill()
                                                        .clipShape(RoundedRectangle(cornerRadius: coverCR))
                                                default:
                                                    Image("Voxmusic").resizable().scaledToFit()
                                                        .clipShape(RoundedRectangle(cornerRadius: coverCR)).padding(24)
                                                }
                                            }
                                        } else {
                                            Image("Voxmusic")
                                                .resizable()
                                                .scaledToFit()
                                                .clipShape(RoundedRectangle(cornerRadius: coverCR))
                                                .padding(24)
                                        }
                                    }
                                )
                                .opacity(overlaySlotOpacity)
                                .modifier(ConditionalCoverGlassModifier(apply: useCoverLiquidGlassInSheet, tint: accent, coverCornerRadius: coverCR))
                                .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
                                .blur(radius: coverBlur)
                                .modifier(PlayingScaleModifier(playbackHolder: playbackHolder, coverScale: coverScale, displayPlayingOverride: nil))
                                .animation(.spring(response: 0.48, dampingFraction: 0.72), value: coverScale)
                                .animation(.easeOut(duration: 0.5), value: coverBlur)
                                .animation(.easeInOut(duration: 0.32), value: track.id)

                            // Перелистывание обложек: iOS 26 — стили 2 и 3 (с затуханием по expandProgress);
                            // iOS 16–18 — стили 1, 2 и 3 (все индексы).
                            if enableCoverPaging, !tracks.isEmpty {
                                if #available(iOS 26.0, *), playerStyleIndex != 0 {
                                    PlayerSheetCoverPagingView(
                                        pagingDriver: coverPagingDriver,
                                        trackCount: tracks.count,
                                        coverImages: coverImages.isEmpty ? tracks.map { _ in coverImage } : coverImages,
                                        currentIndex: min(max(currentTrackIndex, 0), max(tracks.count - 1, 0)),
                                        accent: accent,
                                        artworkSize: artworkSize,
                                        coverCornerRadius: coverCR,
                                        onTrackSelected: { index in
                                            onTrackSelected?(index)
                                        }
                                    )
                                    .opacity(expandProgress < 0.7 ? 0 : min(1, (expandProgress - 0.7) / 0.3))
                                    .modifier(PlayingScaleModifier(playbackHolder: playbackHolder, coverScale: coverScale, displayPlayingOverride: nil))
                                    .animation(.spring(response: 0.48, dampingFraction: 0.72), value: coverScale)
                                    .animation(.easeInOut(duration: 0.32), value: track.id)
                                } else {
                                    // iOS 26 стиль 1 или iOS 16–18 все стили (в т.ч. стиль 2).
                                    PlayerSheetCoverPagingView(
                                        pagingDriver: coverPagingDriver,
                                        trackCount: tracks.count,
                                        coverImages: coverImages.isEmpty ? tracks.map { _ in coverImage } : coverImages,
                                        currentIndex: min(max(currentTrackIndex, 0), max(tracks.count - 1, 0)),
                                        accent: accent,
                                        artworkSize: artworkSize,
                                        coverCornerRadius: coverCR,
                                        onTrackSelected: { index in
                                            onTrackSelected?(index)
                                        }
                                    )
                                    .modifier(PlayingScaleModifier(playbackHolder: playbackHolder, coverScale: coverScale, displayPlayingOverride: nil))
                                    .animation(.spring(response: 0.48, dampingFraction: 0.72), value: coverScale)
                                    .animation(.easeInOut(duration: 0.32), value: track.id)
                                }
                            }
                        }
                        .modifier(CoverSeekShakeTiltModifier(enable: coverSeekShakeEnabled, isSeeking: isSeeking, scrubIntensity: seekScrubIntensity))
                        .modifier(CoverSeekSpinModifier(enable: coverSeekSpinEnabled, isSeeking: isSeeking, scrubIntensity: seekScrubIntensity, scrubDirection: seekScrubDirection))
                        .onAppear {
                            if #available(iOS 26.0, *) { return }
                            if enableCoverPaging, !tracks.isEmpty {
                                withAnimation(.easeOut(duration: 0.35)) { overlayFadeOutProgress = 1 }
                            } else {
                                overlayFadeOutProgress = 0
                            }
                        }
                        .onChange(of: enableCoverPaging) { newValue in
                            if #available(iOS 26.0, *) { return }
                            if newValue, !tracks.isEmpty {
                                withAnimation(.easeOut(duration: 0.35)) { overlayFadeOutProgress = 1 }
                            } else {
                                overlayFadeOutProgress = 0
                            }
                        }
                        .padding(.top, 56)
                        .offset(y: -5)
                        .frame(height: artworkSize + 56)

                        Spacer(minLength: 0)

                        Group {
                        // Название и исполнитель — фиксированная высота, чтобы кнопки и ползунки не сдвигались.
                        VStack(spacing: 6) {
                            Group {
                                if #available(iOS 26.0, *) {
                                    let titleCapsuleTint = isDarkTheme ? accent : Color.white
                                    let titleTextColor = isDarkTheme ? Color.white : accent
                                    Text(track.displayTitle)
                                        .font(.headline)
                                        .foregroundStyle(titleTextColor)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .scaleEffect(titleScale)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .glassEffect(.regular.tint(titleCapsuleTint).interactive(), in: RoundedRectangle(cornerRadius: 22))
                                } else {
                                    Text(track.displayTitle)
                                        .font(.title2.weight(.bold))
                                        .foregroundStyle(chromePalette.titleColorLegacy)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .scaleEffect(titleScale)
                                }
                            }
                            if !track.displayArtist.isEmpty {
                                Button { onArtistTap?() } label: {
                                    Text(track.displayArtist)
                                        .font(.body)
                                        .foregroundStyle({
                                            if #available(iOS 26.0, *) {
                                                return isDarkTheme ? Color(white: 0.65) : accent
                                            }
                                            return chromePalette.artistColor
                                        }())
                                        .multilineTextAlignment(.center)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: 72)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 0)
                        .offset(y: titleOffsetY - 62)
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

                        // Кнопки: iOS 26 — как до правок бекапа (accent / glass). iOS 16–18 — палитра обложки + без async на тапе.
                        HStack(spacing: 40) {
                            if #available(iOS 26.0, *) {
                                let glassTintIOS26 = isDarkTheme ? accent : Color.white
                                let iconColorIOS26 = isDarkTheme ? buttonIconColor : accent
                                Button { DispatchQueue.main.async { onPrevious() } } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.title2)
                                        .foregroundStyle(iconColorIOS26)
                                        .frame(width: 56, height: 56)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(glassTintIOS26).interactive(), in: Circle())

                                Button { DispatchQueue.main.async { onTogglePlayPause() } } label: {
                                    PlayerSheetPlayPauseIcon(playbackHolder: playbackHolder, font: .system(size: 28, weight: .semibold), color: iconColorIOS26, frameWidth: 72, frameHeight: 72)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(glassTintIOS26).interactive(), in: Circle())

                                Button { DispatchQueue.main.async { onNext() } } label: {
                                    Image(systemName: "forward.fill")
                                        .font(.title2)
                                        .foregroundStyle(iconColorIOS26)
                                        .frame(width: 56, height: 56)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(glassTintIOS26).interactive(), in: Circle())
                            } else {
                                Button { onPrevious() } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.title2)
                                        .foregroundStyle(buttonIconColor)
                                        .frame(width: 56, height: 56)
                                        .background(controlsColor, in: Circle())
                                }
                                .buttonStyle(ScaleOnPressRoundButtonStyle(isDarkTheme: isDarkTheme))

                                if useLegacyOptimisticS13 {
                                    PlayerSheetPlayPauseButtonStyle13Legacy(
                                        playbackHolder: playbackHolder,
                                        font: .system(size: 28, weight: .semibold),
                                        color: buttonIconColor,
                                        frameWidth: 72,
                                        frameHeight: 72,
                                        controlsColor: controlsColor,
                                        isDarkTheme: isDarkTheme,
                                        onTogglePlayPause: onTogglePlayPause
                                    )
                                } else if playerStyleIndex == 1 {
                                    PlayerSheetPlayPauseButtonStyle2Legacy(
                                        playbackHolder: playbackHolder,
                                        font: .system(size: 28, weight: .semibold),
                                        color: buttonIconColor,
                                        frameWidth: 72,
                                        frameHeight: 72,
                                        controlsColor: controlsColor,
                                        isDarkTheme: isDarkTheme,
                                        onTogglePlayPause: onTogglePlayPause
                                    )
                                } else {
                                    Button { onTogglePlayPause() } label: {
                                        PlayerSheetPlayPauseIcon(playbackHolder: playbackHolder, font: .system(size: 28, weight: .semibold), color: buttonIconColor, frameWidth: 72, frameHeight: 72)
                                            .background(controlsColor, in: Circle())
                                    }
                                    .buttonStyle(ScaleOnPressRoundButtonStyle(isDarkTheme: isDarkTheme))
                                }

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
                        .padding(.bottom, 0)
                        .offset(y: -16)

                        // Ползунок перемотки — время сверху, ползунок снизу
                        PlayerSheetProgressSection(
                            playbackHolder: playbackHolder,
                            isSeeking: $isSeeking,
                            seekValue: $seekValue,
                            seekScrubIntensity: $seekScrubIntensity,
                            seekScrubDirection: $seekScrubDirection,
                            formatTime: formatTime,
                            onSeek: onSeek,
                            controlsColor: controlsColor
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 2)
                        .offset(y: -10)

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
                        .padding(.bottom, 14)
                        .offset(y: -8)

                        // Нижний ряд кнопок: избранное, расшифровка, AirPlay, цикл, меню «ещё».
                        HStack {
                            Spacer(minLength: 0)
                            PlayerSheetBottomButtonsRow(
                                isFavorite: isFavorite,
                                isDownloaded: {
                                    guard let ct = catalogTrack else { return false }
                                    return DownloadsStore.shared.isDownloaded(provider: ct.provider, id: ct.id)
                                }(),
                                isDownloading: {
                                    guard let ct = catalogTrack else { return false }
                                    return DownloadsStore.shared.inProgress.contains("\(ct.provider):\(ct.id)")
                                }(),
                                repeatMode: repeatMode,
                                repeatModeIcon: repeatModeIcon,
                                repeatPauseAtEndTitle: repeatPauseAtEndTitle,
                                repeatOneTitle: repeatOneTitle,
                                repeatPlayNextTitle: repeatPlayNextTitle,
                                deleteFromDeviceTitle: deleteFromDeviceTitle,
                                hideFromRecommendationsTitle: hideFromRecommendationsTitle,
                                equalizerTitle: equalizerSheetTitle,
                                shareTitle: isEnglish ? "Share" : "Поделиться",
                                controlsColor: controlsColor,
                                bottomIconColor: {
                                    if #available(iOS 26.0, *) {
                                        return isDarkTheme ? Color.white : accent
                                    }
                                    return controlsColor
                                }(),
                                bottomCircleTint: {
                                    if #available(iOS 26.0, *) {
                                        return isDarkTheme ? accent : Color.white
                                    }
                                    return Color.clear
                                }(),
                                isBluetooth: audioRouteObserver.isOutputBluetooth,
                                useGlassStyle: { if #available(iOS 26.0, *) { return true } else { return false } }(),
                                onFavoriteToggle: { toggleFavorite() },
                                onDownloadTap: {
                                    guard let ct = catalogTrack else { return }
                                    Task { try? await DownloadsStore.shared.download(track: ct) }
                                },
                                onRepeatCycle: onRepeatCycle,
                                onRepeatModeChange: onRepeatModeChange,
                                onDeleteFromDevice: onDeleteTrackFromDevice,
                                onHideFromRecommendations: onHideTrackFromRecommendations,
                                onOpenEqualizer: onOpenEqualizer,
                                onShareTrack: {
                                    guard let ct = catalogTrack else { return }
                                    onShareCatalogTrack(ct)
                                },
                                onLyricsTap: onLyricsTap
                            )
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .offset(y: -10)
                        .padding(.bottom, transparentBackground ? 12 : 40)
                        }
                        .offset(y: style2ControlsOffsetY)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SwiftUI.Group {
                        if isBottomSheet {
                            // Кнопка‑полоска: на iOS 26 белая, на 16–18 серая.
                            let handleColor: Color = {
                                if #available(iOS 26.0, *) {
                                    return .white
                                } else {
                                    return Color(.systemGray3)
                                }
                            }()
                            Button(action: onDismiss) {
                                Capsule()
                                    .fill(handleColor)
                                    .frame(width: 36, height: 5)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 44, height: 44)
                        } else {
                            if #available(iOS 26.0, *) {
                                Capsule()
                                    .fill(accent)
                                    .frame(width: 36, height: 5)
                            } else {
                                Capsule()
                                    .fill(Color(.systemGray3))
                                    .frame(width: 36, height: 5)
                            }
                        }
                    }
                    .padding(.top, isBottomSheet ? 72 : 10)
                    .padding(.bottom, 6)
                }
                .modifier(PlayerDragModifier(isBottomSheet: isBottomSheet, dragOffset: $dragOffset, onDismiss: onDismiss))
            }
            }
        }
    }
}

    /// На iOS 26 не меняет view; на iOS 16–18 применяет .id(id) к content (для привязки к playerStyleIndex).
    private struct PlayerSheetConditionalIDWrapper<Content: View>: View {
        let id: Int
        @ViewBuilder let content: () -> Content

        var body: some View {
            if #available(iOS 26.0, *) {
                content()
            } else {
                content().id(id)
            }
        }
    }

    private struct PlayerDragModifier: ViewModifier {
        let isBottomSheet: Bool
        @Binding var dragOffset: CGFloat
        let onDismiss: () -> Void

        func body(content: Content) -> some View {
            content
                .offset(y: isBottomSheet ? 0 : dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            if !isBottomSheet {
                                dragOffset = max(0, value.translation.height)
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 120 {
                                onDismiss()
                            } else if !isBottomSheet {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
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
    @State private var showGalleryPicker = false
    @State private var triggerAvatarPickerDismiss = false
    @State private var customAvatarImage: UIImage?
    @State private var hasAttemptedSubmit = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var isCreating = false
    @State private var isPasswordVisible = false
    @State private var isSendingCode = false
    @State private var codeRequestMessage: String?
    @State private var showVerifyCode = false
    @StateObject private var authService = AuthService.shared

    @State private var createTitleShown = false
    @State private var createAvatarShown = false
    @State private var createNicknameShown = false
    @State private var createEmailShown = false
    @State private var createPasswordShown = false
    @State private var createButtonShown = false
    @State private var createCloseShown = false

    private var accent: Color { Color("AccentColor") }
    private var errorColor: Color { .red }
    private var avatarTitle: String { isEnglish ? "Choose avatar" : "Выбор аватарки" }
    private var nicknamePlaceholder: String { isEnglish ? "Nickname" : "Никнейм" }
    private var emailPlaceholder: String { isEnglish ? "Email" : "Почта" }
    private var passwordPlaceholder: String { isEnglish ? "Password" : "Пароль" }
    private var createButtonTitle: String { isEnglish ? "Create" : "Создать" }
    private var createAccountTitle: String { isEnglish ? "Create account" : "Создание аккаунта" }

    private var passwordStrength: SpherePasswordStrength { SpherePasswordStrength.evaluate(password) }

    private var formIsValid: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !password.isEmpty
        && passwordStrength.isAcceptableForRegister
    }

    private func strengthDescription(_ s: SpherePasswordStrength) -> String {
        let label: String
        switch s.labelKey {
        case "strong": label = isEnglish ? "Strong" : "Сильный"
        case "good": label = isEnglish ? "Good" : "Хороший"
        case "fair": label = isEnglish ? "Medium" : "Средний"
        default: label = isEnglish ? "Weak" : "Слабый"
        }
        if isEnglish {
            return "Strength: \(label) · \(s.score)/100"
        }
        return "Сложность: \(label) · \(s.score)/100"
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

    /// Sends verification email then opens full-screen code entry (no separate «Send code» step).
    private func sendSignupCodeAndOpenVerify() async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.contains("@") else {
            await MainActor.run {
                codeRequestMessage = isEnglish ? "Enter a valid email" : "Введите корректную почту"
            }
            return
        }
        guard passwordStrength.isAcceptableForRegister else {
            await MainActor.run {
                codeRequestMessage = isEnglish ? "Password is too weak" : "Слишком слабый пароль"
            }
            return
        }
        await MainActor.run {
            isSendingCode = true
            codeRequestMessage = nil
        }
        defer {
            Task { @MainActor in isSendingCode = false }
        }
        do {
            try await SphereAPIClient.shared.sendSignupCode(email: e)
            await MainActor.run { showVerifyCode = true }
        } catch {
            await MainActor.run { codeRequestMessage = error.localizedDescription }
        }
    }

    private func startCreateAccountAppearAnimation() {
        createTitleShown = false
        createAvatarShown = false
        createNicknameShown = false
        createEmailShown = false
        createPasswordShown = false
        createButtonShown = false
        createCloseShown = false
        let step: Double = 0.09
        withAnimation(.easeOut(duration: 0.40)) { createTitleShown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeOut(duration: 0.30)) { createAvatarShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step) {
            withAnimation(.easeOut(duration: 0.30)) { createNicknameShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 2) {
            withAnimation(.easeOut(duration: 0.30)) { createEmailShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 3) {
            withAnimation(.easeOut(duration: 0.30)) { createPasswordShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 4) {
            withAnimation(.easeOut(duration: 0.30)) { createButtonShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 5) {
            withAnimation(.easeOut(duration: 0.30)) { createCloseShown = true }
        }
    }

    var body: some View {
        ZStack {
            (isDarkMode ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                            .id("createAccountScrollTop")

                        Color.clear.frame(height: 150)

                        Text(createAccountTitle)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(isDarkMode ? Color.white : accent)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 27)
                            .padding(.bottom, 20)
                            .opacity(createTitleShown ? 1 : 0)

                        Button {
                            showAvatarPicker = true
                        } label: {
                            ZStack {
                                if avatarColorIndex == 7, let custom = customAvatarImage {
                                    Image(uiImage: custom)
                                        .resizable()
                                        .scaledToFill()
                                        .aspectRatio(1, contentMode: .fill)
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
                        .padding(.bottom, 24)
                        .opacity(createAvatarShown ? 1 : 0)

                        VStack(alignment: .leading, spacing: 16) {
                            createAccountGlassField(
                                isError: hasAttemptedSubmit && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                systemImage: "person.text.rectangle.fill",
                                placeholder: nicknamePlaceholder,
                                isPlaceholderVisible: nickname.isEmpty
                            ) {
                                TextField("", text: $nickname)
                                    .textContentType(.username)
                                    .autocapitalization(.none)
                            }
                            .opacity(createNicknameShown ? 1 : 0)

                            createAccountGlassField(
                                isError: hasAttemptedSubmit && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                systemImage: "envelope.fill",
                                placeholder: emailPlaceholder,
                                isPlaceholderVisible: email.isEmpty
                            ) {
                                TextField("", text: $email)
                                    .textContentType(.emailAddress)
                                    .autocapitalization(.none)
                                    .keyboardType(.emailAddress)
                            }
                            .opacity(createEmailShown ? 1 : 0)

                            createAccountGlassField(
                                isError: hasAttemptedSubmit && password.isEmpty,
                                systemImage: "lock.fill",
                                placeholder: passwordPlaceholder,
                                isPlaceholderVisible: password.isEmpty,
                                trailingImage: isPasswordVisible ? "eye.slash.fill" : "eye.fill",
                                onTrailingTap: { isPasswordVisible.toggle() }
                            ) {
                                if isPasswordVisible {
                                    TextField("", text: $password)
                                        .textContentType(.newPassword)
                                } else {
                                    SecureField("", text: $password)
                                        .textContentType(.newPassword)
                                }
                            }
                            .opacity(createPasswordShown ? 1 : 0)

                            if !password.isEmpty {
                                Text(strengthDescription(passwordStrength))
                                    .font(.system(size: 12))
                                    .foregroundStyle(passwordStrength.isAcceptableForRegister ? .secondary : errorColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if let m = codeRequestMessage {
                                Text(m)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 27)

                        Group {
                            // Светлая тема: белая капсула, фиолетовый кружок, белая иконка, фиолетовый текст.
                            // Тёмная тема: фиолетовая капсула, белый кружок, фиолетовая иконка, белый текст.
                            let primaryCapsuleColor = isDarkMode ? accent : Color.white
                            let primaryTextColor = isDarkMode ? Color.white : accent
                            let primaryCircleFill = isDarkMode ? Color.white : accent

                            if #available(iOS 26.0, *) {
                                Button(action: {
                                    if formIsValid {
                                        Task { await sendSignupCodeAndOpenVerify() }
                                    } else {
                                        hasAttemptedSubmit = true
                                    }
                                }) {
                                    Text(createButtonTitle)
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .overlay(alignment: .leading) {
                                            ZStack {
                                                Circle()
                                                    .fill(primaryCircleFill)
                                                Image(systemName: "person.crop.circle.fill")
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .foregroundStyle(isDarkMode ? accent : Color.white)
                                            }
                                            .frame(width: 32, height: 32)
                                            .padding(.leading, 6)
                                        }
                                }
                                .glassEffect(
                                    .regular.tint(primaryCapsuleColor).interactive(),
                                    in: Capsule()
                                )
                                .foregroundStyle(primaryTextColor)
                                .disabled(isCreating || isSendingCode)
                            } else {
                                Button(action: {
                                    if formIsValid {
                                        Task { await sendSignupCodeAndOpenVerify() }
                                    } else {
                                        hasAttemptedSubmit = true
                                    }
                                }) {
                                    Text(createButtonTitle)
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .overlay(alignment: .leading) {
                                            ZStack {
                                                Circle()
                                                    .fill(primaryCircleFill)
                                                Image(systemName: "person.crop.circle.fill")
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .foregroundStyle(isDarkMode ? accent : Color.white)
                                            }
                                            .frame(width: 32, height: 32)
                                            .padding(.leading, 6)
                                        }
                                }
                                .background(primaryCapsuleColor, in: Capsule())
                                .foregroundStyle(primaryTextColor)
                                .disabled(isCreating || isSendingCode)
                            }
                        }
                        .opacity(createButtonShown ? 1 : 0)
                        .shadow(
                            color: isDarkMode ? .clear : Color.black.opacity(0.22),
                            radius: 18,
                            x: 0,
                            y: 6
                        )
                        .padding(.top, 16)
                        .padding(.horizontal, 27)
                        .padding(.bottom, 40)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(CloseButtonGlassStyle(accent: accent))
                    .padding(.trailing, 20)
                    .padding(.top, 12)
                    .opacity(createCloseShown ? 1 : 0)
                }
                Spacer()
            }
        }
        .onAppear { startCreateAccountAppearAnimation() }
        .ignoresSafeArea(.keyboard)
        .overlay {
            if showAvatarPicker && !useSheetForAvatarPicker {
                AvatarPickerCardView(
                    avatarColorIndex: $avatarColorIndex,
                    isPresented: $showAvatarPicker,
                    customAvatarImage: $customAvatarImage,
                    pickerColors: pickerColors,
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
                    pickerColors: pickerColors,
                    accent: accent,
                    isEnglish: isEnglish
                )
            }
        }
        .tint(isDarkMode ? .white : accent)
        .onAppear {
            if isDarkMode {
                UITextField.appearance().tintColor = .white
            }
        }
        .onDisappear {
            if isDarkMode {
                UITextField.appearance().tintColor = nil
            }
        }
        .fullScreenCover(isPresented: $showGalleryPicker) {
            PhotoLibraryPicker { image in
                showGalleryPicker = false
                if let image = image {
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
        .fullScreenCover(isPresented: $showVerifyCode) {
            VerifyEmailCodeView(
                isEnglish: isEnglish,
                isDarkMode: isDarkMode,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                nickname: nickname,
                password: password,
                avatarColorIndex: avatarColorIndex,
                customAvatarImage: customAvatarImage,
                onDone: {
                    showVerifyCode = false
                    if authService.isSignedIn { onAccountCreated?() }
                },
                onCancel: { showVerifyCode = false }
            )
        }
    }

    private var useSheetForAvatarPicker: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    @ViewBuilder
    private func createAccountGlassField<Content: View>(
        isError: Bool,
        systemImage: String,
        placeholder: String,
        isPlaceholderVisible: Bool,
        trailingImage: String? = nil,
        onTrailingTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let capsuleColor = isDarkMode ? accent : Color.white
        let textColor = isError ? errorColor : (isDarkMode ? Color.white : accent)
        let circleFill = isDarkMode ? Color.white : accent
        let iconColor = isDarkMode ? accent : Color.white
        let cursorColor = isDarkMode ? Color.white : accent
        let hasTrailing = trailingImage != nil && onTrailingTap != nil
        let trailingPadding: CGFloat = hasTrailing ? 52 : 20

        let field = content()
            .tint(cursorColor)
            .padding(.leading, 52)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)

        Group {
            if #available(iOS 26.0, *) {
                field
                    .glassEffect(
                        .regular.tint(capsuleColor).interactive(),
                        in: Capsule()
                    )
                    .foregroundStyle(textColor)
            } else {
                field
                    .background(capsuleColor, in: Capsule())
                    .foregroundStyle(textColor)
            }
        }
        .tint(cursorColor)
        // Тень только на светлой теме
        .shadow(
            color: isDarkMode ? .clear : Color.black.opacity(0.20),
            radius: 16,
            x: 0,
            y: 6
        )
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .overlay(alignment: .leading) {
            if isPlaceholderVisible {
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
            if let img = trailingImage, let action = onTrailingTap {
                Button(action: action) {
                    ZStack {
                        Circle().fill(circleFill)
                        Image(systemName: img)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }
        }
    }
}

// Контент окна «Забыли пароль»: заголовок (как «Вход в аккаунт»), поле почты (как во вкладке Вход), кнопка Отправить (как Войти). Используется в желейном оверлее (iOS 16–18) и в sheet (iOS 26).
struct ForgotPasswordSheetContent: View {
    let isEnglish: Bool
    let accent: Color
    let onDismiss: () -> Void
    var onShake: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isEmailFocused: Bool
    @State private var resetEmail = ""
    @State private var hasAttemptedSubmit = false

    private var title: String { isEnglish ? "Send recovery email" : "Отправить письмо восстановления" }
    private var emailPlaceholder: String { isEnglish ? "Email" : "Почта" }
    private var sendTitle: String { isEnglish ? "Send" : "Отправить" }

    private let verticalSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 27

    private var isDark: Bool { colorScheme == .dark }
    private var textColor: Color { isDark ? .white : accent }
    private var capsuleFill: Color { isDark ? accent : .white }
    private var isEmailError: Bool { hasAttemptedSubmit && resetEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var circleFill: Color { isDark ? .white : accent }
    private var iconColor: Color { isDark ? accent : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 72)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, verticalSpacing)
                .padding(.bottom, 20)

            // Поле почты и кнопка — фиксированный отступ от заголовка, чтобы при коротком тексте блок не поднимался.
            VStack(alignment: .leading, spacing: verticalSpacing) {
                ZStack {
                    Group {
                        if #available(iOS 26.0, *) {
                            TextField("", text: $resetEmail)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                                .focused($isEmailFocused)
                                .tint(isDark ? .white : accent)
                                .padding(.leading, 52)
                                .padding(.trailing, 20)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity)
                                .glassEffect(.regular.tint(capsuleFill).interactive(), in: Capsule())
                                .foregroundStyle(textColor)
                        } else {
                            TextField("", text: $resetEmail)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                                .focused($isEmailFocused)
                                .tint(isDark ? .white : accent)
                                .padding(.leading, 52)
                                .padding(.trailing, 20)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity)
                                .background(capsuleFill, in: Capsule())
                                .foregroundStyle(textColor)
                        }
                    }
                    .shadow(color: isDark ? .clear : Color.black.opacity(0.22), radius: 18, x: 0, y: 6)
                    .overlay(alignment: .leading) {
                        ZStack {
                            Circle().fill(circleFill)
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(iconColor)
                        }
                        .frame(width: 32, height: 32)
                        .padding(.leading, 6)
                    }
                    .overlay(alignment: .leading) {
                        if resetEmail.isEmpty {
                            Text(emailPlaceholder)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(isEmailError ? Color.red : textColor)
                                .padding(.leading, 52)
                                .padding(.trailing, 20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .allowsHitTesting(false)
                        }
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isEmailFocused = true }
                }
                .frame(maxWidth: .infinity)
                .onChange(of: resetEmail) { newValue in
                    if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        hasAttemptedSubmit = false
                    }
                }

                // Кнопка «Отправить» — такая же как «Войти» (капсула, иконка слева).
                Group {
                if #available(iOS 26.0, *) {
                    Button(action: {
                        if resetEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            hasAttemptedSubmit = true
                            onShake?()
                            return
                        }
                        // TODO: вызов восстановления пароля через AuthService
                        onDismiss()
                    }) {
                        Text(sendTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(circleFill)
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(iconColor)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .glassEffect(.regular.tint(capsuleFill).interactive(), in: Capsule())
                    .foregroundStyle(textColor)
                    .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
                } else {
                    Button(action: {
                        if resetEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            hasAttemptedSubmit = true
                            onShake?()
                            return
                        }
                        // TODO: вызов восстановления пароля через AuthService
                        onDismiss()
                    }) {
                        Text(sendTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle().fill(circleFill)
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(iconColor)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .background(capsuleFill, in: Capsule())
                    .foregroundStyle(textColor)
                    .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
                }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 14)
        }
        .padding(.bottom, verticalSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Verify Email Code (SWCodeField-like UX)

struct VerifyEmailCodeView: View {
    let isEnglish: Bool
    let isDarkMode: Bool
    let email: String
    let nickname: String
    let password: String
    let avatarColorIndex: Int
    let customAvatarImage: UIImage?
    let onDone: () -> Void
    let onCancel: () -> Void

    @StateObject private var authService = AuthService.shared
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var isResending = false
    @FocusState private var isFocused: Bool

    private var accent: Color { Color("AccentColor") }

    private var title: String { isEnglish ? "Email verification" : "Подтверждение почты" }
    private var subtitle: String {
        isEnglish
            ? "Enter the 6-digit code sent to \(email)."
            : "Введите 6-значный код, отправленный на \(email)."
    }

    private var codeDigits: String {
        let d = code.filter { $0.isNumber }
        return d.count > 6 ? String(d.prefix(6)) : d
    }

    private func submitIfReady() {
        let d = codeDigits
        guard d.count == 6 else { return }
        Task { await submit(code: d) }
    }

    private func submit(code: String) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }

        let recaptcha = await RecaptchaTokenLoader(baseURL: SphereAPIClient.shared.baseURL).loadToken() ?? ""
        let presetURL = avatarColorIndex < 7 ? SphereProfileAvatarPalette.presetURL(for: avatarColorIndex) : nil
        await authService.signInWithEmail(
            nickname: nickname,
            email: email,
            password: password,
            emailVerificationCode: code,
            recaptchaToken: recaptcha,
            avatarUrl: presetURL,
            avatarImage: (avatarColorIndex == 7 ? customAvatarImage : nil)
        )
        if authService.isSignedIn {
            onDone()
        } else {
            errorText = authService.authError ?? (isEnglish ? "Invalid code" : "Неверный код")
        }
    }

    var body: some View {
        ZStack {
            (isDarkMode ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)

                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(isDarkMode ? .white : accent)
                    .padding(.top, 6)

                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(isDarkMode ? Color.white.opacity(0.75) : Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                CodeBoxesField(code: $code)
                    .padding(.top, 10)
                    .onTapGesture { isFocused = true }
                    .overlay {
                        TextField("", text: Binding(
                            get: { codeDigits },
                            set: { newValue in
                                code = newValue.filter { $0.isNumber }
                                submitIfReady()
                            }
                        ))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($isFocused)
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                    }

                if let e = errorText, !e.isEmpty {
                    Text(e)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 22)
                }

                Button {
                    Task { await submit(code: codeDigits) }
                } label: {
                    Text(isEnglish ? "Confirm" : "Подтвердить")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 52 / 255, green: 130 / 255, blue: 1),
                                    Color(red: 0 / 255, green: 102 / 255, blue: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: Capsule()
                        )
                        .shadow(color: Color.blue.opacity(0.30), radius: 14, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 26)
                .disabled(isSubmitting || codeDigits.count != 6)
                .opacity((codeDigits.count == 6) ? 1 : 0.6)

                Button {
                    Task {
                        guard !isResending else { return }
                        isResending = true
                        defer { isResending = false }
                        do {
                            try await SphereAPIClient.shared.sendSignupCode(email: email)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Text(isEnglish ? "Resend code" : "Отправить код ещё раз")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .disabled(isResending)
                .padding(.top, 4)

                Spacer()
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
    }
}

private struct CodeBoxesField: View {
    @Binding var code: String

    private var digits: [Character] {
        let d = code.filter { $0.isNumber }
        let trimmed = d.count > 6 ? String(d.prefix(6)) : d
        return Array(trimmed)
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { i in
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                    Text(i < digits.count ? String(digits[i]) : "")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 54)
            }
        }
        .padding(.horizontal, 20)
    }
}

// Экран входа: закрыть справа сверху, эл. почта, пароль, кнопка «Войти» (тот же дизайн, что создание аккаунта)
struct SignInView: View {
    @Binding var isPresented: Bool
    let isEnglish: Bool
    var onSignIn: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var authService = AuthService.shared
    @State private var email = ""
    @State private var password = ""
    @State private var hasAttemptedSubmit = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var isSigningInWithGoogle = false
    @State private var isPasswordVisible = false

    @State private var signInTitleShown = false
    @State private var signInEmailShown = false
    @State private var signInPasswordShown = false
    @State private var signInSignInButtonShown = false
    @State private var signInGoogleShown = false
    @State private var signInForgotShown = false
    @State private var signInCloseShown = false
    @State private var showForgotPassword = false
    @State private var triggerForgotPasswordDismiss = false
    @State private var forgotPasswordShakeCount = 0
    private enum SignInTab: Hashable {
        case password
        case qr
    }

    @State private var signInTab: SignInTab = .password
    @State private var qrPayload: String?
    @State private var qrLoginError: String?
    @State private var isPollingQR = false
    @State private var qrPollGeneration = 0
    @State private var showTwoFactorSheet = false
    @State private var twoFAChallengeId: String?
    @State private var twoFAMethods: [String] = []
    @State private var twoFAMethod = "email"
    @State private var twoFACode = ""
    @State private var isSigningInWithEmail = false

    private var accent: Color { Color("AccentColor") }
    private var errorColor: Color { .red }
    // Короткие плейсхолдеры внутри полей
    private var emailPlaceholder: String { isEnglish ? "Email" : "Почта" }
    private var passwordPlaceholder: String { isEnglish ? "Password" : "Пароль" }
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

    /// На iOS 26 — привязка для sheet «Забыли пароль»; на iOS 16–18 возвращает false, чтобы sheet не показывался (показывается желейный оверлей).
    private var showForgotSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if #available(iOS 26.0, *) { return showForgotPassword }
                return false
            },
            set: { showForgotPassword = $0 }
        )
    }

    private func startSignInAppearAnimation() {
        signInTitleShown = false
        signInEmailShown = false
        signInPasswordShown = false
        signInSignInButtonShown = false
        signInGoogleShown = false
        signInForgotShown = false
        signInCloseShown = false
        let step: Double = 0.09
        withAnimation(.easeOut(duration: 0.40)) { signInTitleShown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeOut(duration: 0.30)) { signInEmailShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step) {
            withAnimation(.easeOut(duration: 0.30)) { signInPasswordShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 2) {
            withAnimation(.easeOut(duration: 0.30)) { signInSignInButtonShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 3) {
            withAnimation(.easeOut(duration: 0.30)) { signInGoogleShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 4) {
            withAnimation(.easeOut(duration: 0.30)) { signInForgotShown = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + step * 5) {
            withAnimation(.easeOut(duration: 0.30)) { signInCloseShown = true }
        }
    }

    private func signInQRLoginPanel(isEnglish: Bool) -> some View {
        VStack(spacing: 18) {
            if let err = qrLoginError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
            }
            if let p = qrPayload {
                SphereQRLoginQRImage(payload: p)
            } else if qrLoginError == nil {
                ProgressView()
                    .padding(.bottom, 8)
            }
            Text(isEnglish ? "Open Sphere on your phone and approve this login." : "Откройте Sphere на телефоне и подтвердите вход.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            if isPollingQR {
                ProgressView()
            }
            Button {
                Task { await startQRLoginSession() }
            } label: {
                Text(isEnglish ? "Refresh QR" : "Обновить QR")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 27)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .opacity(signInEmailShown ? 1 : 0)
        .task(id: signInTab) {
            if signInTab == .qr {
                await startQRLoginSession()
            }
        }
    }

    private func startQRLoginSession() async {
        qrPollGeneration += 1
        let generation = qrPollGeneration
        await MainActor.run {
            qrLoginError = nil
            qrPayload = nil
        }
        do {
            let start = try await SphereAPIClient.shared.qrLoginStart()
            await MainActor.run {
                guard generation == qrPollGeneration else { return }
                qrPayload = start.qrPayload
            }
            await pollQRUntilComplete(sessionId: start.sessionId, generation: generation)
        } catch {
            await MainActor.run {
                qrLoginError = error.localizedDescription
            }
        }
    }

    private func pollQRUntilComplete(sessionId: String, generation: Int) async {
        await MainActor.run {
            guard generation == qrPollGeneration else { return }
            isPollingQR = true
        }
        defer {
            Task { @MainActor in isPollingQR = false }
        }
        let deadline = Date().addingTimeInterval(320)
        while Date() < deadline {
            guard generation == qrPollGeneration else { return }
            do {
                switch try await SphereAPIClient.shared.qrLoginPollOnce(sessionId: sessionId) {
                case .approved(let auth):
                    await MainActor.run {
                        authService.finalizeBackendLoginFromQR(auth)
                        onSignIn?()
                    }
                    return
                case .pending:
                    continue
                case .gone:
                    await MainActor.run {
                        qrLoginError = isEnglish ? "Session expired" : "Сессия истекла"
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    qrLoginError = error.localizedDescription
                }
                return
            }
        }
        await MainActor.run {
            qrLoginError = isEnglish ? "Timed out" : "Время истекло"
        }
    }

    private func submitPasswordSignIn() {
        guard formIsValid else {
            hasAttemptedSubmit = true
            return
        }
        Task { @MainActor in
            isSigningInWithEmail = true
            authService.authError = nil
            let result = await authService.signInWithBackendEmailPassword(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            isSigningInWithEmail = false
            switch result {
            case .success:
                onSignIn?()
            case .needsTwoFactor(let cid, let methods):
                twoFAChallengeId = cid
                twoFAMethods = methods
                twoFAMethod = methods.contains("email") ? "email" : (methods.first ?? "totp")
                twoFACode = ""
                showTwoFactorSheet = true
            case .failure:
                break
            }
        }
    }

    var body: some View {
        let view =
            ZStack {
                sheetBackground
                    .ignoresSafeArea()

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                                .id("signInScrollTop")
                            // Отступ сверху, чтобы контент был чуть ниже центра; кнопка закрытия остаётся в overlay.
                            Color.clear.frame(height: 260)

                            // Заголовок экрана входа
                            Text(isEnglish ? "Sign in to account" : "Вход в аккаунт")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(colorScheme == .dark ? Color.white : accent)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.horizontal, 27)
                                .padding(.bottom, 12)
                                .opacity(signInTitleShown ? 1 : 0)

                            Picker("", selection: $signInTab) {
                                Text(isEnglish ? "Password" : "Пароль").tag(SignInTab.password)
                                Text(isEnglish ? "QR login" : "Вход по QR").tag(SignInTab.qr)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 27)
                            .padding(.bottom, 12)
                            .opacity(signInTitleShown ? 1 : 0)

                            if signInTab == .password {
                            VStack(spacing: 0) {
                            if let signInErr = authService.authError, !signInErr.isEmpty {
                                Text(signInErr)
                                    .font(.caption)
                                    .foregroundStyle(Color.red)
                                    .padding(.horizontal, 27)
                                    .padding(.bottom, 8)
                            }

                            VStack(alignment: .leading, spacing: 16) {
                                // Поле эл. почты: капсула как кнопка, с иконкой конверта в кружке слева.
                                signInGlassField(
                                    isError: hasAttemptedSubmit && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    systemImage: "envelope.fill",
                                    placeholder: emailPlaceholder,
                                    isPlaceholderVisible: email.isEmpty
                                ) {
                                    TextField("", text: $email)
                                        .textContentType(.emailAddress)
                                        .autocapitalization(.none)
                                        .keyboardType(.emailAddress)
                                }
                                .opacity(signInEmailShown ? 1 : 0)

                                // Поле пароля: тот же стиль, другая иконка. тот же стиль, другая иконка.
                                signInGlassField(
                                    isError: hasAttemptedSubmit && password.isEmpty,
                                    systemImage: "lock.fill",
                                    placeholder: passwordPlaceholder,
                                    isPlaceholderVisible: password.isEmpty,
                                    trailingImage: isPasswordVisible ? "eye.slash.fill" : "eye.fill",
                                    onTrailingTap: { isPasswordVisible.toggle() }
                                ) {
                                    if isPasswordVisible {
                                        TextField("", text: $password)
                                            .textContentType(.password)
                                    } else {
                                        SecureField("", text: $password)
                                            .textContentType(.password)
                                    }
                                }
                                .opacity(signInPasswordShown ? 1 : 0)
                            }
                            .padding(.horizontal, 27)

                            Spacer().frame(height: 14)

                            // Блок кнопок в точности как на главном экране:
                            // капсулы с иконкой в кружке слева и одинаковым vertical padding.
                            let isDark = colorScheme == .dark
                            // Светлая тема: белая капсула, фиолетовый кружок, белая иконка, фиолетовый текст.
                            // Тёмная тема: фиолетовая капсула, белый кружок, фиолетовая иконка, белый текст.
                            let primaryCapsuleColor = isDark ? accent : Color.white
                            let primaryTextColor = isDark ? Color.white : accent
                            let primaryCircleFill = isDark ? Color.white : accent

                            VStack(spacing: 14) {
                                Group {
                                    if #available(iOS 26.0, *) {
                                        Button(action: submitPasswordSignIn) {
                                            Text(signInButtonTitle)
                                                .font(.system(size: 17, weight: .semibold))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 14)
                                                .overlay(alignment: .leading) {
                                                    ZStack {
                                                        Circle()
                                                            .fill(primaryCircleFill)
                                                        Image(systemName: "person.crop.circle.fill")
                                                            .font(.system(size: 16, weight: .semibold))
                                                            .foregroundStyle(isDark ? accent : Color.white)
                                                    }
                                                    .frame(width: 32, height: 32)
                                                    .padding(.leading, 6)
                                                }
                                        }
                                        .glassEffect(
                                            .regular.tint(primaryCapsuleColor).interactive(),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(primaryTextColor)
                                        .shadow(
                                            color: isDark ? .clear : Color.black.opacity(0.20),
                                            radius: 16,
                                            x: 0,
                                            y: 6
                                        )
                                        .disabled(isSigningInWithEmail)
                                    } else {
                                        Button(action: submitPasswordSignIn) {
                                            Text(signInButtonTitle)
                                                .font(.system(size: 17, weight: .semibold))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 14)
                                                .overlay(alignment: .leading) {
                                                    ZStack {
                                                        Circle()
                                                            .fill(primaryCircleFill)
                                                        Image(systemName: "person.crop.circle.fill")
                                                            .font(.system(size: 16, weight: .semibold))
                                                            .foregroundStyle(isDark ? accent : Color.white)
                                                    }
                                                    .frame(width: 32, height: 32)
                                                    .padding(.leading, 6)
                                                }
                                        }
                                        .background(primaryCapsuleColor, in: Capsule())
                                        .foregroundStyle(primaryTextColor)
                                        .shadow(
                                            color: isDark ? .clear : Color.black.opacity(0.20),
                                            radius: 16,
                                            x: 0,
                                            y: 6
                                        )
                                        .disabled(isSigningInWithEmail)
                                    }
                                }
                                .opacity(signInSignInButtonShown ? 1 : 0)

                                // 2) Войти через Google
                                Group {
                                    if #available(iOS 26.0, *) {
                                        Button(action: {
                                            Task {
                                                isSigningInWithGoogle = true
                                                await authService.signInWithGoogle()
                                                isSigningInWithGoogle = false
                                                if authService.isSignedIn {
                                                    onSignIn?()
                                                }
                                            }
                                        }) {
                                            Text(signInWithGoogleTitle)
                                                .font(.system(size: 17, weight: .semibold))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 14)
                                                .overlay(alignment: .leading) {
                                                    ZStack {
                                                        Circle()
                                                            .fill(primaryCircleFill)
                                                        Image("google")
                                                            .renderingMode(.template)
                                                            .resizable()
                                                            .scaledToFit()
                                                            .frame(width: 20, height: 20)
                                                            .foregroundStyle(isDark ? accent : Color.white)
                                                    }
                                                    .frame(width: 32, height: 32)
                                                    .padding(.leading, 6)
                                                }
                                        }
                                        .glassEffect(
                                            .regular.tint(primaryCapsuleColor).interactive(),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(primaryTextColor)
                                        .shadow(
                                            color: isDark ? .clear : Color.black.opacity(0.20),
                                            radius: 16,
                                            x: 0,
                                            y: 6
                                        )
                                        .disabled(isSigningInWithGoogle)
                                    } else {
                                        Button(action: {
                                            Task {
                                                isSigningInWithGoogle = true
                                                await authService.signInWithGoogle()
                                                isSigningInWithGoogle = false
                                                if authService.isSignedIn {
                                                    onSignIn?()
                                                }
                                            }
                                        }) {
                                            Text(signInWithGoogleTitle)
                                                .font(.system(size: 17, weight: .semibold))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 14)
                                                .overlay(alignment: .leading) {
                                                    ZStack {
                                                        Circle()
                                                            .fill(primaryCircleFill)
                                                        Image("google")
                                                            .renderingMode(.template)
                                                            .resizable()
                                                            .scaledToFit()
                                                            .frame(width: 20, height: 20)
                                                            .foregroundStyle(isDark ? accent : Color.white)
                                                    }
                                                    .frame(width: 32, height: 32)
                                                    .padding(.leading, 6)
                                                }
                                        }
                                        .background(primaryCapsuleColor, in: Capsule())
                                        .foregroundStyle(primaryTextColor)
                                        .shadow(
                                            color: isDark ? .clear : Color.black.opacity(0.20),
                                            radius: 16,
                                            x: 0,
                                            y: 6
                                        )
                                        .disabled(isSigningInWithGoogle)
                                    }
                                }
                                .opacity(signInGoogleShown ? 1 : 0)

                                // 3) Кнопка «Забыли пароль»: на iOS 16–18 — желейное окно, на iOS 26 — системный sheet
                                Button(action: {
                                    showForgotPassword = true
                                }) {
                                    Text(isEnglish ? "Forgot password" : "Забыли пароль")
                                        .font(.system(size: 15, weight: .semibold))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .padding(.top, 6)
                                .foregroundStyle(colorScheme == .dark ? Color.white : accent)
                                .opacity(signInForgotShown ? 1 : 0)
                            }
                            // ширина полей и кнопок одинаковая за счёт единого горизонтального отступа
                            .padding(.horizontal, 27)
                            }
                            } else {
                                signInQRLoginPanel(isEnglish: isEnglish)
                            }
                        }
                        .padding(.vertical, 24)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .scrollDismissesKeyboard(.interactively)
                }

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 56, height: 56)
                        }
                        .buttonStyle(CloseButtonGlassStyle(accent: accent))
                        .padding(.trailing, 20)
                        // Чуть ниже — финальный уровень относительно экрана создания аккаунта.
                        .padding(.top, 73)
                        .opacity(signInCloseShown ? 1 : 0)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .clipped()

        return view
            .tint(colorScheme == .dark ? .white : accent)
            .onAppear {
                startSignInAppearAnimation()
                if colorScheme == .dark {
                    UITextField.appearance().tintColor = .white
                }
            }
            .onDisappear {
                if colorScheme == .dark {
                    UITextField.appearance().tintColor = nil
                }
            }
            .overlay {
                if showForgotPassword, !showForgotSheetBinding.wrappedValue {
                    JellyCardOverlayView(
                        isPresented: $showForgotPassword,
                        triggerDismiss: $triggerForgotPasswordDismiss,
                        onDismissCompleted: { triggerForgotPasswordDismiss = false },
                        cardHeightFraction: 0.32,
                        shakeTrigger: $forgotPasswordShakeCount
                    ) {
                        ForgotPasswordSheetContent(
                            isEnglish: isEnglish,
                            accent: accent,
                            onDismiss: { triggerForgotPasswordDismiss = true },
                            onShake: { forgotPasswordShakeCount += 1 }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                }
            }
            .sheet(isPresented: showForgotSheetBinding) {
                ForgotPasswordSheetContent(
                    isEnglish: isEnglish,
                    accent: accent,
                    onDismiss: { showForgotPassword = false }
                )
                .presentationDetents([.fraction(0.33)])
            }
            .sheet(isPresented: $showTwoFactorSheet) {
                NavigationStack {
                    Form {
                        Section {
                            if twoFAMethods.count > 1 {
                                Picker("", selection: $twoFAMethod) {
                                    Text(isEnglish ? "Email" : "Почта").tag("email")
                                    Text(isEnglish ? "Authenticator" : "Приложение").tag("totp")
                                }
                                .pickerStyle(.segmented)
                            }
                            SecureField(isEnglish ? "Code" : "Код", text: $twoFACode)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                            if let err = authService.authError, !err.isEmpty {
                                Text(err)
                                    .foregroundStyle(Color.red)
                                    .font(.caption)
                            }
                        }
                        Section {
                            Button(isEnglish ? "Continue" : "Продолжить") {
                                Task { @MainActor in
                                    guard let cid = twoFAChallengeId else { return }
                                    let ok = await authService.completeBackendTwoFactor(
                                        challengeId: cid,
                                        method: twoFAMethod,
                                        code: twoFACode,
                                        email: email,
                                        password: password
                                    )
                                    if ok {
                                        showTwoFactorSheet = false
                                        onSignIn?()
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle(isEnglish ? "Two-factor" : "Двухфакторный вход")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(isEnglish ? "Cancel" : "Отмена") {
                                showTwoFactorSheet = false
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea() // растягиваем overlay на весь экран без «дыр» по бокам
    }

    @ViewBuilder
    private var googleSignInButton: some View {
        if #available(iOS 26.0, *) {
                                Button(action: {
                                    Task {
                                        isSigningInWithGoogle = true
                                        await authService.signInWithGoogle()
                                        isSigningInWithGoogle = false
                                        if authService.isSignedIn {
                                            onSignIn?()
                                        }
                                    }
                                }) {
                                    Text(signInWithGoogleTitle)
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .overlay(alignment: .leading) {
                                            ZStack {
                                                Circle()
                                                    .fill(Color.white)
                                                Image(colorScheme == .dark ? "googlewhite" : "google")
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 20, height: 20)
                                            }
                                            .frame(width: 32, height: 32)
                                            .padding(.leading, 6)
                                        }
                                }
            .buttonStyle(.glass)
            .tint(.white)
            .disabled(isSigningInWithGoogle)
        } else {
                                Button(action: {
                                    Task {
                                        isSigningInWithGoogle = true
                                        await authService.signInWithGoogle()
                                        isSigningInWithGoogle = false
                                        if authService.isSignedIn {
                                            onSignIn?()
                                        }
                                    }
                                }) {
                                    Text(signInWithGoogleTitle)
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .overlay(alignment: .leading) {
                                            ZStack {
                                                Circle()
                                                    .fill(Color.white)
                                                Image(colorScheme == .dark ? "googlewhite" : "google")
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 20, height: 20)
                                            }
                                            .frame(width: 32, height: 32)
                                            .padding(.leading, 6)
                                        }
                                }
            .buttonStyle(
                GlassMaterialButtonStyle(
                    accent: accent,
                    prominent: false,
                    labelColor: colorScheme == .dark ? .white : .black
                )
            )
            .frame(maxWidth: .infinity)
            .disabled(isSigningInWithGoogle)
        }
    }

    @ViewBuilder
    private func signInGlassField<Content: View>(
        isError: Bool,
        systemImage: String,
        placeholder: String,
        isPlaceholderVisible: Bool,
        trailingImage: String? = nil,
        onTrailingTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isDark = colorScheme == .dark
        let capsuleColor = isDark ? accent : Color.white
        // Цвет текста и плейсхолдера: при ошибке красный, иначе белый на тёмной / фиолетовый на светлой
        let textColor = isError ? errorColor : (isDark ? Color.white : accent)
        let circleFill = isDark ? Color.white : accent
        let iconColor = isDark ? accent : Color.white
        let cursorColor = isDark ? Color.white : accent
        let hasTrailing = trailingImage != nil && onTrailingTap != nil
        let trailingPadding: CGFloat = hasTrailing ? 52 : 20

        let field = content()
            .tint(cursorColor)
            .padding(.leading, 52)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)

        Group {
            if #available(iOS 26.0, *) {
                field
                    .glassEffect(
                        .regular.tint(capsuleColor).interactive(),
                        in: Capsule()
                    )
                    .foregroundStyle(textColor)
            } else {
                field
                    .background(capsuleColor, in: Capsule())
                    .foregroundStyle(textColor)
            }
        }
        .tint(cursorColor)
        .shadow(
            color: isDark ? .clear : Color.black.opacity(0.22),
            radius: 18,
            x: 0,
            y: 6
        )
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .overlay(alignment: .leading) {
            if isPlaceholderVisible {
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
            if let img = trailingImage, let action = onTrailingTap {
                Button(action: action) {
                    ZStack {
                        Circle().fill(circleFill)
                        Image(systemName: img)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }
        }
    }
}

// Драйвер желе: обновляет offset и stretch по CADisplayLink (до 120 FPS), чтобы не дропать кадры от лишних обновлений жеста.
private final class JellyDragDriver: ObservableObject {
    @Published var displayOffset: CGSize = .zero
    @Published var displayStretch: CGSize = .zero
    private var targetOffset: CGSize = .zero
    private var targetStretch: CGSize = .zero
    private var displayLink: CADisplayLink?
    private var isRunning = false

    func setTarget(offset: CGSize, stretch: CGSize) {
        targetOffset = offset
        targetStretch = stretch
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            isRunning = true
        }
    }

    @objc private func tick() {
        guard isRunning else { return }
        if displayOffset != targetOffset || displayStretch != targetStretch {
            displayOffset = targetOffset
            displayStretch = targetStretch
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
    }

    func releaseWithAnimation(animation: Animation) {
        stop()
        withAnimation(animation) {
            displayOffset = .zero
            displayStretch = .zero
        }
    }

    func relaxStretch(animation: Animation) {
        withAnimation(animation) {
            displayStretch = .zero
        }
    }

    func reset() {
        displayOffset = .zero
        displayStretch = .zero
        targetOffset = .zero
        targetStretch = .zero
    }
}

// Контроллер расслабления желе при остановке пальца: по таймеру вызывает колбэк (анимация stretch → 0).
private final class AvatarPickerRelaxController: ObservableObject {
    private var workItem: DispatchWorkItem?

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }

    func scheduleRelax(delay: Double, perform: @escaping () -> Void) {
        workItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.workItem = nil
            DispatchQueue.main.async { perform() }
        }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// Универсальный желейный оверлей (как в папке «Код желейного окна»): только окно, контент снаружи.
private struct JellyCardOverlayView<Content: View>: View {
    @Binding var isPresented: Bool
    @Binding var triggerDismiss: Bool
    var onDismissCompleted: (() -> Void)?
    var cardWidthFraction: CGFloat = 0.9
    var cardHeightFraction: CGFloat = 0.4
    var dismissThreshold: CGFloat = 100
    var dismissPredictedThreshold: CGFloat = 200
    var dismissVelocityThreshold: CGFloat = 300
    var shakeTrigger: Binding<Int> = .constant(0)
    @ViewBuilder var content: () -> Content

    @State private var appeared = false
    @State private var shakeOffset: CGFloat = 0
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastDragTime: Date = Date()
    @State private var lastRelaxScheduleTime: Date = .distantPast
    @StateObject private var dragDriver = JellyDragDriver()
    @StateObject private var relaxController = AvatarPickerRelaxController()
    @State private var isContentPressed = false

    private let dismissDuration: Double = 0.35
    private let relaxDelay: Double = 0.18
    private let relaxScheduleInterval: Double = 0.06
    private let velocityToStretch: CGFloat = 6500
    private let maxStretch: CGFloat = 0.12

    private func dismissAnimated() {
        withAnimation(.easeOut(duration: dismissDuration)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDuration) {
            onDismissCompleted?()
            triggerDismiss = false
            dragDriver.reset()
            isPresented = false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cardW = geo.size.width * cardWidthFraction
            let cardH = geo.size.height * cardHeightFraction
            let displayScaleX = 1 + dragDriver.displayStretch.width
            let displayScaleY = 1 + dragDriver.displayStretch.height

            ZStack {
                Color.black.opacity(appeared ? 0.5 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAnimated() }

                content()
                    .frame(width: cardW, height: cardH, alignment: .top)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.white.opacity(isContentPressed ? 0.12 : 0))
                            .allowsHitTesting(false)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 12)
                    .compositingGroup()
                    .scaleEffect(
                        x: (appeared ? displayScaleX : 0.85) * (isContentPressed ? 0.98 : 1),
                        y: (appeared ? displayScaleY : 0.85) * (isContentPressed ? 0.98 : 1)
                    )
                    .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isContentPressed)
                    .opacity(appeared ? 1 : 0)
                    .offset(x: dragDriver.displayOffset.width + shakeOffset, y: dragDriver.displayOffset.height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isContentPressed = true
                                let now = Date()
                                let dt = now.timeIntervalSince(lastDragTime)
                                let prev = lastDragTranslation
                                lastDragTranslation = value.translation
                                lastDragTime = now
                                var stretch = CGSize.zero
                                if dt > 0.001 && dt < 0.25 {
                                    let vel = CGSize(
                                        width: (value.translation.width - prev.width) / CGFloat(dt),
                                        height: (value.translation.height - prev.height) / CGFloat(dt)
                                    )
                                    stretch = CGSize(
                                        width: max(-maxStretch, min(maxStretch, vel.width / velocityToStretch)),
                                        height: max(-maxStretch, min(maxStretch, vel.height / velocityToStretch))
                                    )
                                }
                                dragDriver.setTarget(offset: value.translation, stretch: stretch)
                                relaxController.cancel()
                                if now.timeIntervalSince(lastRelaxScheduleTime) >= relaxScheduleInterval {
                                    lastRelaxScheduleTime = now
                                    relaxController.scheduleRelax(delay: relaxDelay) {
                                        dragDriver.relaxStretch(animation: .spring(response: 0.4, dampingFraction: 0.78))
                                    }
                                }
                            }
                            .onEnded { value in
                                isContentPressed = false
                                let vel = value.predictedEndTranslation.height - value.translation.height
                                if value.translation.height > dismissThreshold
                                    || value.predictedEndTranslation.height > dismissPredictedThreshold
                                    || vel > dismissVelocityThreshold {
                                    dismissAnimated()
                                } else {
                                    relaxController.cancel()
                                    dragDriver.releaseWithAnimation(animation: .spring(response: 0.55, dampingFraction: 0.62))
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in isContentPressed = true }
                            .onEnded { _ in isContentPressed = false }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
        .onChange(of: triggerDismiss) { newValue in
            if newValue { dismissAnimated() }
        }
        .onChange(of: shakeTrigger.wrappedValue) { _ in
            if shakeTrigger.wrappedValue != 0 {
                runShakeAnimation()
            }
        }
    }

    private func runShakeAnimation() {
        let steps: [(CGFloat, Double)] = [(-14, 0.06), (14, 0.12), (-10, 0.18), (10, 0.24), (-6, 0.30), (6, 0.36), (0, 0.42)]
        for (offset, delay) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.linear(duration: 0.06)) {
                    shakeOffset = offset
                }
            }
        }
    }
}

// iOS 16–18: окно точь-в-точь как на скриншоте — затемнённый фон, по центру карточка (⅓ экрана, 80–90% ширины) с блюром, внутри: заголовок «Выбор аватарки», сетка 2×4, кнопка «Выбрать» с галочкой.
struct AvatarPickerCardView: View {
    @Binding var avatarColorIndex: Int
    @Binding var isPresented: Bool
    @Binding var customAvatarImage: UIImage?
    let pickerColors: [Color]
    let accent: Color
    let isEnglish: Bool
    @Binding var showGalleryPicker: Bool
    @Binding var triggerDismiss: Bool
    var onDismissCompleted: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIndex: Int = 0
    @State private var appeared = false
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastDragTime: Date = Date()
    @State private var lastRelaxScheduleTime: Date = .distantPast
    @StateObject private var dragDriver = JellyDragDriver()
    @StateObject private var relaxController = AvatarPickerRelaxController()
    @State private var isContentPressed = false

    private let dismissDuration: Double = 0.35
    private let relaxDelay: Double = 0.18
    private let relaxScheduleInterval: Double = 0.06
    private let velocityToStretch: CGFloat = 6500
    private let maxStretch: CGFloat = 0.12
    private var selectButtonTitle: String { isEnglish ? "Select" : "Выбрать" }
    private var avatarSheetTitle: String { isEnglish ? "Choose avatar" : "Выбор аватарки" }

    private func dismissAnimated() {
        withAnimation(.easeOut(duration: dismissDuration)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDuration) {
            onDismissCompleted?()
            dragDriver.reset()
            isPresented = false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cardW = geo.size.width * 0.9
            let cardH = geo.size.height * 0.4
            let isDark = colorScheme == .dark
            let capsuleFill: Color = isDark ? accent : .white
            let textColor: Color = isDark ? .white : accent
            let circleFill: Color = isDark ? .white : accent
            let circleIconColor: Color = isDark ? accent : .white
            // Желе: обновляется по CADisplayLink (до 120 FPS), без просадок
            let displayScaleX = 1 + dragDriver.displayStretch.width
            let displayScaleY = 1 + dragDriver.displayStretch.height

            ZStack {
                Color.black.opacity(appeared ? 0.5 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAnimated() }

                VStack(spacing: 0) {
                    Text(avatarSheetTitle)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(isDark ? Color.white : accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .padding(.bottom, 16)

                    VStack(spacing: 20) {
                        HStack(spacing: 20) {
                            ForEach(0..<4, id: \.self) { index in
                                cardAvatarCell(index: index)
                            }
                        }
                        HStack(spacing: 20) {
                            ForEach(4..<8, id: \.self) { index in
                                cardAvatarCell(index: index)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                    Spacer(minLength: 24)

                    Button(action: {
                        if selectedIndex == 7, customAvatarImage == nil {
                            showGalleryPicker = true
                            return
                        }
                        avatarColorIndex = selectedIndex
                        dismissAnimated()
                    }) {
                        Text(selectButtonTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle()
                                        .fill(circleFill)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(circleIconColor)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .background(capsuleFill, in: Capsule())
                    .foregroundStyle(textColor)
                    .shadow(
                        color: isDark ? .clear : Color.black.opacity(0.20),
                        radius: 18,
                        x: 0,
                        y: 8
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .frame(width: cardW, height: cardH)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.white.opacity(isContentPressed ? 0.12 : 0))
                        .allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 12)
                .compositingGroup()
                .scaleEffect(
                    x: (appeared ? displayScaleX : 0.85) * (isContentPressed ? 0.98 : 1),
                    y: (appeared ? displayScaleY : 0.85) * (isContentPressed ? 0.98 : 1)
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isContentPressed)
                .opacity(appeared ? 1 : 0)
                .offset(dragDriver.displayOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let now = Date()
                            let dt = now.timeIntervalSince(lastDragTime)
                            let prev = lastDragTranslation
                            lastDragTranslation = value.translation
                            lastDragTime = now
                            var stretch = CGSize.zero
                            if dt > 0.001 && dt < 0.25 {
                                let vel = CGSize(
                                    width: (value.translation.width - prev.width) / CGFloat(dt),
                                    height: (value.translation.height - prev.height) / CGFloat(dt)
                                )
                                stretch = CGSize(
                                    width: max(-maxStretch, min(maxStretch, vel.width / velocityToStretch)),
                                    height: max(-maxStretch, min(maxStretch, vel.height / velocityToStretch))
                                )
                            }
                            dragDriver.setTarget(offset: value.translation, stretch: stretch)
                            relaxController.cancel()
                            if now.timeIntervalSince(lastRelaxScheduleTime) >= relaxScheduleInterval {
                                lastRelaxScheduleTime = now
                                relaxController.scheduleRelax(delay: relaxDelay) {
                                    dragDriver.relaxStretch(animation: .spring(response: 0.4, dampingFraction: 0.78))
                                }
                            }
                        }
                        .onEnded { value in
                            let threshold: CGFloat = 100
                            let vel = value.predictedEndTranslation.height - value.translation.height
                            if value.translation.height > threshold || value.predictedEndTranslation.height > 200 || vel > 300 {
                                dismissAnimated()
                            } else {
                                relaxController.cancel()
                                dragDriver.releaseWithAnimation(animation: .spring(response: 0.55, dampingFraction: 0.62))
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isContentPressed = true }
                        .onEnded { _ in isContentPressed = false }
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            selectedIndex = avatarColorIndex % 8
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
        .onChange(of: triggerDismiss) { newValue in
            if newValue { dismissAnimated() }
        }
    }

    @ViewBuilder
    private func cardAvatarCell(index: Int) -> some View {
        let isDark = colorScheme == .dark
        let isSelected = selectedIndex == index
        if index == 7 {
            Button {
                selectedIndex = 7
                showGalleryPicker = true
            } label: {
                ZStack {
                    if let img = customAvatarImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .aspectRatio(1, contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(isDark ? accent : Color.white)
                            .frame(width: 64, height: 64)
                        Group {
                            if #available(iOS 17.0, *) {
                                Image(systemName: "photo.badge.plus")
                            } else {
                                Image(systemName: "photo.on.rectangle.angled")
                            }
                        }
                        .font(.system(size: 28))
                        .foregroundStyle(isDark ? Color.white : accent)
                    }
                    Circle()
                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 3)
                        .frame(width: 64, height: 64)
                }
            }
            .buttonStyle(.plain)
        } else {
            let color = pickerColors[index]
            Button {
                selectedIndex = index
            } label: {
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: 64, height: 64)
                    Image("Voxpfp")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                    Circle()
                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 3)
                        .frame(width: 64, height: 64)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// Окно выбора аватарки: iOS 26 — сетка 4+4; iOS 16–18 — одна карточка ⅓ экрана с блюром, свайп влево/вправо как в Tinder, 120 fps.
struct AvatarPickerSheet: View {
    @Binding var avatarColorIndex: Int
    @Binding var isPresented: Bool
    @Binding var customAvatarImage: UIImage?
    let pickerColors: [Color]
    let accent: Color
    let isEnglish: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIndex: Int = 0
    @State private var showGalleryPicker = false

    private var selectButtonTitle: String { isEnglish ? "Select" : "Выбрать" }
    private var avatarSheetTitle: String { isEnglish ? "Choose avatar" : "Выбор аватарки" }

    var body: some View {
        // Общий контент sheet-а выбора аватарки
        let content =
        VStack(spacing: 0) {
            Text(avatarSheetTitle)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(colorScheme == .dark ? Color.white : accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                .padding(.bottom, 16)

            Spacer(minLength: 0)

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
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 20)

            Spacer(minLength: 0)

            let isDark = colorScheme == .dark
            // Светлая тема: белая капсула, фиолетовый кружок, белая иконка, фиолетовый текст.
            // Тёмная тема: фиолетовая капсула, белый кружок, фиолетовая иконка, белый текст.
            let primaryCapsuleColor = isDark ? accent : Color.white
            let primaryTextColor = isDark ? Color.white : accent
            let primaryCircleFill = isDark ? Color.white : accent

            Group {
                if #available(iOS 26.0, *) {
                    Button(action: {
                        if selectedIndex == 7, customAvatarImage == nil {
                            showGalleryPicker = true
                            return
                        }
                        avatarColorIndex = selectedIndex
                        isPresented = false
                    }) {
                        Text(selectButtonTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle()
                                        .fill(primaryCircleFill)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDark ? accent : Color.white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .glassEffect(
                        .regular.tint(primaryCapsuleColor).interactive(),
                        in: Capsule()
                    )
                    .foregroundStyle(primaryTextColor)
                } else {
                    Button(action: {
                        if selectedIndex == 7, customAvatarImage == nil {
                            showGalleryPicker = true
                            return
                        }
                        avatarColorIndex = selectedIndex
                        isPresented = false
                    }) {
                        Text(selectButtonTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Circle()
                                        .fill(primaryCircleFill)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDark ? accent : Color.white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.leading, 6)
                            }
                    }
                    .background(primaryCapsuleColor, in: Capsule())
                    .foregroundStyle(primaryTextColor)
                    .shadow(color: isDark ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
                }
            }
            .padding(.horizontal, 27)
            .padding(.top, 32)
            .padding(.bottom, 32)
        }

        // iOS 26: сетка 4+4. iOS < 26: свайпаемые карточки в стиле Tinder (плавный свайп, 120 Гц).
        if #available(iOS 26.0, *) {
            content
                .presentationDetents([.medium])
                .onAppear { selectedIndex = avatarColorIndex % 8 }
                .fullScreenCover(isPresented: $showGalleryPicker) {
                    PhotoLibraryPicker { image in
                        showGalleryPicker = false
                        if let image = image {
                            DispatchQueue.global(qos: .userInitiated).async {
                                let cropped = Self.cropImageToSquare(image)
                                DispatchQueue.main.async {
                                    customAvatarImage = cropped
                                    avatarColorIndex = 7
                                    isPresented = false
                                }
                            }
                        }
                    }
                }
        } else {
            AvatarPickerCardView(
                avatarColorIndex: $avatarColorIndex,
                isPresented: $isPresented,
                customAvatarImage: $customAvatarImage,
                pickerColors: pickerColors,
                accent: accent,
                isEnglish: isEnglish,
                showGalleryPicker: $showGalleryPicker,
                triggerDismiss: .constant(false)
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .fullScreenCover(isPresented: $showGalleryPicker) {
                PhotoLibraryPicker { image in
                    showGalleryPicker = false
                    if let image = image {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let cropped = Self.cropImageToSquare(image)
                            DispatchQueue.main.async {
                                customAvatarImage = cropped
                                avatarColorIndex = 7
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
    }

    /// Центральная обрезка изображения в квадрат (под аватар). Работает с любой ориентацией и форматом.
    static func cropImageToSquare(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let side = min(size.width, size.height)
        let x = (size.width - side) / 2
        let y = (size.height - side) / 2
        let cropRect = CGRect(x: x, y: y, width: side, height: side)
        let scale = min(image.scale, 2)
        let maxSide: CGFloat = 2048
        let outputSide = side > maxSide ? maxSide : side
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide), format: format)
        return renderer.image { ctx in
            let rect = CGRect(x: -x * (outputSide / side), y: -y * (outputSide / side),
                              width: size.width * (outputSide / side), height: size.height * (outputSide / side))
            image.draw(in: rect)
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
        let isDark = colorScheme == .dark
        let isSelected = selectedIndex == 7
        // Светлая тема: белый круг, фиолетовая иконка.
        // Тёмная тема: фиолетовый круг, белая иконка.
        let bgColor = isDark ? accent : Color.white
        let iconColor = isDark ? Color.white : accent
        return Button {
            selectedIndex = 7
            showGalleryPicker = true
        } label: {
            ZStack {
                Circle()
                    .fill(bgColor)
                    .frame(width: 64, height: 64)
                Circle()
                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 3)
                    .frame(width: 64, height: 64)
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(iconColor)
            }
        }
        .buttonStyle(.plain)
        .shadow(
            color: isDark ? .clear : Color.black.opacity(0.18),
            radius: 10,
            x: 0,
            y: 5
        )
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
                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 3)
                    .frame(width: 64, height: 64)
                Image("Voxpfp")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            }
        }
        .buttonStyle(.plain)
        .shadow(
            color: (colorScheme == .dark) ? .clear : Color.black.opacity(0.18),
            radius: 10,
            x: 0,
            y: 5
        )
    }
}

// Выбор фото из галереи (PHPicker)
struct PhotoLibraryPicker: UIViewControllerRepresentable {
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
            let provider = result.itemProvider
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                    if let image = obj as? UIImage {
                        DispatchQueue.main.async { self?.onPick(image) }
                        return
                    }
                    self?.loadImageAsData(provider: provider)
                }
            } else {
                loadImageAsData(provider: provider)
            }
        }
        private func loadImageAsData(provider: NSItemProvider) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                guard let data = data, let image = UIImage(data: data) else {
                    DispatchQueue.main.async { self?.onPick(nil) }
                    return
                }
                DispatchQueue.main.async { self?.onPick(image) }
            }
        }
    }
}

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

// Стиль «стеклянной» кнопки на материалах для iOS 16–18 (без Liquid Glass API)
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

/// Системные аватарки при регистрации (0…6): цвет фона + визуал Vox (`Voxpfp`). Логотип `Voxmusic` в приложении — та же фирменная идентика: при обрезке/масштабе считать частью аватарки, не отделять. Сохранение: `sphere-avatar-preset://n`. Индекс 7 — фото из галереи.
enum SphereProfileAvatarPalette {
    static let presetURLPrefix = "sphere-avatar-preset://"

    static func presetURL(for index: Int) -> String { "\(presetURLPrefix)\(index)" }

    static func presetIndex(from avatarUrl: String?) -> Int? {
        guard let s = avatarUrl, s.hasPrefix(presetURLPrefix) else { return nil }
        return Int(String(s.dropFirst(presetURLPrefix.count)))
    }

    /// Семь цветов сетки выбора аватарки (без чёрного слота «галерея»).
    static func presetBackgroundColors(accent: Color) -> [Color] {
        [
            accent,
            Color(red: 0.2, green: 0.5, blue: 1),
            Color(red: 0.2, green: 0.75, blue: 0.4),
            Color(red: 1, green: 0.5, blue: 0.2),
            Color(red: 0.95, green: 0.3, blue: 0.35),
            Color(red: 0.95, green: 0.4, blue: 0.7),
            Color(red: 0.2, green: 0.7, blue: 0.75)
        ]
    }

    static func presetBackgroundColor(index: Int, accent: Color) -> Color {
        let colors = presetBackgroundColors(accent: accent)
        guard index >= 0, index < colors.count else { return accent.opacity(0.35) }
        return colors[index]
    }
}

/// Содержимое аватарки без формы клипа (квадрат + скругление задаёт снаружи). Удалённый URL — через `URLSession`, чтобы фото реально подгружалось.
struct ProfileAvatarCoreView: View {
    let profile: UserProfile?
    let side: CGFloat
    let accent: Color
    @State private var remoteImage: UIImage?

    var body: some View {
        Group {
            if let idx = SphereProfileAvatarPalette.presetIndex(from: profile?.avatarUrl) {
                ZStack {
                    Rectangle().fill(SphereProfileAvatarPalette.presetBackgroundColor(index: idx, accent: accent))
                    Image("Voxpfp")
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.52, height: side * 0.52)
                }
            } else if let urlString = profile?.avatarUrl,
                      let url = URL(string: urlString),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                if let remoteImage {
                    Image(uiImage: remoteImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: profile?.avatarUrl ?? "") {
            await loadRemoteAvatarIfNeeded()
        }
    }

    private func loadRemoteAvatarIfNeeded() async {
        guard let urlString = profile?.avatarUrl,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            await MainActor.run { remoteImage = nil }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 45)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                await MainActor.run { remoteImage = nil }
                return
            }
            let img = UIImage(data: data)
            await MainActor.run { remoteImage = img }
        } catch {
            await MainActor.run { remoteImage = nil }
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Rectangle().fill(accent.opacity(0.3))
            Image("Voxpfp")
                .resizable()
                .scaledToFit()
                .frame(width: side * 0.5, height: side * 0.5)
        }
    }
}

/// Inset-grouped list container for settings sections (gray background, 14pt corner radius).
private struct SettingsGroupContainer<Content: View>: View {
    let isDarkMode: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isDarkMode ? Color(white: 0.10) : Color(.systemGray6))
            )
    }
}

/// One row inside a settings group: gray-filled circle icon + title + chevron.
private struct SettingsGroupRowLabel: View {
    let icon: String
    let title: String
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color(.systemGray))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(.systemGray3))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Шапка аккаунта на экране «Настройки»: круглая аватарка по тапу открывает тот же выбор, что при регистрации.
private struct SettingsAccountTapHeader: View {
    let profile: UserProfile?
    let backendUser: BackendUser?
    let accent: Color
    let nickname: String
    let usernameAt: String
    let isDarkMode: Bool
    let onAvatarTap: () -> Void

    private let avatarSide: CGFloat = 104

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onAvatarTap) {
                ProfileAvatarCoreView(profile: profile, side: avatarSide, accent: accent)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
                    .frame(width: avatarSide, height: avatarSide)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 5) {
                SphereNicknameWithBadges(
                    nickname: nickname,
                    backendUser: backendUser,
                    nicknameColor: isDarkMode ? .white : .primary
                )
                Text(usernameAt)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        .padding(.bottom, 8)
    }
}

/// Вертикальный ритм шапки настроек: зазор под «Настройки» = зазор от раскрытой аватарки до «Профиль».
private enum SettingsAccountHeaderLayout {
    static let titleToAvatarSpacing: CGFloat = 20
    /// Сворачивание защёлки: spring с сильным демпфированием.
    static var expansionLockAnimation: Animation {
        .spring(response: 0.28, dampingFraction: 0.98, blendDuration: 0)
    }
}

/// Заголовок аккаунта в настройках: по центру круг → при потягивании вниз растягивается в квадрат, имя и @ник уезжают в левый нижний угол.
private struct SettingsAccountStretchHeader: View {
    let profile: UserProfile?
    let backendUser: BackendUser?
    let accent: Color
    let nickname: String
    let usernameAt: String
    let isDarkMode: Bool
    let pullOffset: CGFloat
    /// Защёлка: после порога растяжения остаётся полный квадрат, пока не прокрутить список вниз.
    var expansionLocked: Bool = false

    private var maxPull: CGFloat { 120 }
    private var effectivePull: CGFloat { expansionLocked ? maxPull : pullOffset }
    private var progress: CGFloat { min(1, max(0, effectivePull / maxPull)) }
    private var p: CGFloat {
        let t = progress
        return t * t * (3 - 2 * t)
    }

    private var collapsedSide: CGFloat { 104 }
    private var horizontalInset: CGFloat { 16 }
    private var expandedSide: CGFloat { UIScreen.main.bounds.width - horizontalInset * 2 }
    private var side: CGFloat { collapsedSide + (expandedSide - collapsedSide) * p }
    private var cornerRadius: CGFloat { collapsedSide / 2 * (1 - p) + 14 * p }

    private var overlayTextOpacity: Double {
        Double(min(1, max(0, (p - 0.22) / 0.52)))
    }

    private var belowTextOpacity: Double {
        Double(1 - min(1, max(0, (p - 0.08) / 0.36)))
    }

    /// Высота блока имени под аватаром в свёрнутом виде (padding + две строки). При раскрытии сжимается до 0, чтобы не оставлять щель до кнопок.
    private var belowLabelsFullHeight: CGFloat { 16 + 5 + 30 + 22 }
    private var belowSectionLayoutHeight: CGFloat { belowLabelsFullHeight * (1 - CGFloat(p)) }
    /// В свёрнутом виде — компактный зазор под подписью; в раскрытом — как от «Настройки» до верха аватарки (`titleToAvatarSpacing`).
    private var trailingGapBelowAvatar: CGFloat {
        let collapsed: CGFloat = 8
        let expanded = SettingsAccountHeaderLayout.titleToAvatarSpacing
        return collapsed * (1 - CGFloat(p)) + expanded * CGFloat(p)
    }

    var body: some View {
        let overlayPrimary: Color = .white
        let overlaySecondary: Color = Color.white.opacity(0.88)
        let belowPrimary: Color = isDarkMode ? .white : .primary
        let belowSecondary: Color = Color.secondary

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .bottomLeading) {
                    ProfileAvatarCoreView(profile: profile, side: side, accent: accent)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.22 * Double(p)), radius: 14 * p, x: 0, y: 5 * p)

                    VStack(alignment: .leading, spacing: 4) {
                        SphereNicknameWithBadges(
                            nickname: nickname,
                            backendUser: backendUser,
                            nicknameFont: .title2.weight(.bold),
                            nicknameColor: overlayPrimary
                        )
                        Text(usernameAt)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(overlaySecondary)
                    }
                    .padding(.leading, 14)
                    .padding(.bottom, 14)
                    .opacity(overlayTextOpacity)
                    .shadow(color: .black.opacity(0.55 * overlayTextOpacity), radius: 8, x: 0, y: 2)
                }
                .frame(width: side, height: side)
                Spacer(minLength: 0)
            }

            VStack(spacing: 5) {
                SphereNicknameWithBadges(
                    nickname: nickname,
                    backendUser: backendUser,
                    nicknameFont: .title2.weight(.bold),
                    nicknameColor: belowPrimary
                )
                Text(usernameAt)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(belowSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 16 * (1 - CGFloat(p)))
            .frame(height: belowSectionLayoutHeight, alignment: .top)
            .clipped()
            .opacity(belowTextOpacity)
        }
        .padding(.bottom, trailingGapBelowAvatar)
    }
}

private struct ProfileAvatarView: View {
    let profile: UserProfile?
    var size: CGFloat = 80
    let accent: Color
    var body: some View {
        ProfileAvatarCoreView(profile: profile, side: size, accent: accent)
            .clipShape(Circle())
    }
}

private enum ProfileCardMetrics {
    /// Скользящие 24 часа для блока «Недавно добавлено».
    static let recentlyAddedWindowSeconds: TimeInterval = 86400
}

/// `scroll.pan.require(toFail: interactivePop)` + proxy-delegate у `interactivePop`: скрытая «Назад» отключает жест на всех версиях, в т.ч. iOS 26 — без подмены delegate свайп молчит. Пересылаем вызовы в сохранённый системный delegate.
private struct ProfileNavigationPopGestureEnabler: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.bind(anchor: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var anchor: UIView?
        private weak var nav: UINavigationController?
        private weak var scroll: UIScrollView?
        private weak var popGesture: UIGestureRecognizer?
        private weak var savedPopDelegate: UIGestureRecognizerDelegate?

        func bind(anchor: UIView) {
            self.anchor = anchor
            DispatchQueue.main.async { [weak self] in self?.installIfNeeded() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.installIfNeeded() }
        }

        func installIfNeeded() {
            guard let anchor = anchor else { return }
            guard let n = Self.findNavigationController(from: anchor),
                  let pop = n.interactivePopGestureRecognizer,
                  n.viewControllers.count > 1,
                  let host = n.visibleViewController?.view else { return }

            let sv = Self.findLargestScrollView(in: host)
            guard let scrollView = sv else { return }

            if nav === n, scroll === scrollView, popGesture === pop { return }

            unwindPrevious()

            nav = n
            scroll = scrollView
            popGesture = pop
            pop.isEnabled = true
            scrollView.panGestureRecognizer.require(toFail: pop)

            savedPopDelegate = pop.delegate
            pop.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = nav, gestureRecognizer === nav.interactivePopGestureRecognizer else { return true }
            guard nav.viewControllers.count > 1 else { return false }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            savedPopDelegate?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: otherGestureRecognizer) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            savedPopDelegate?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: otherGestureRecognizer) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            savedPopDelegate?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: otherGestureRecognizer) ?? false
        }

        @available(iOS 13.4, *)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            savedPopDelegate?.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
        }

        private func unwindPrevious() {
            if let pop = popGesture {
                pop.delegate = savedPopDelegate
            }
            savedPopDelegate = nil
            nav = nil
            scroll = nil
            popGesture = nil
        }

        func teardown() {
            unwindPrevious()
            anchor = nil
        }

        private static func findLargestScrollView(in root: UIView) -> UIScrollView? {
            var best: UIScrollView?
            var bestArea: CGFloat = 0
            func walk(_ v: UIView) {
                if let s = v as? UIScrollView {
                    let a = s.bounds.width * s.bounds.height
                    if a > bestArea {
                        bestArea = a
                        best = s
                    }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            return best
        }

        private static func findNavigationController(from view: UIView) -> UINavigationController? {
            var v: UIView? = view
            while let c = v {
                var r: UIResponder? = c
                for _ in 0 ..< 40 {
                    if let nav = r as? UINavigationController { return nav }
                    if let vc = r as? UIViewController, let n = vc.navigationController { return n }
                    r = r?.next
                }
                v = c.superview
            }
            return nil
        }
    }
}

// MARK: - Профиль: верхняя панель с блюром при скролле (как `DeveloperMenuView`)

private let profileNavBlurBottomGutter: CGFloat = 10
private let profileNavToolbarRowHeight: CGFloat = 56
private let profileNavToolbarHorizontalPadding: CGFloat = 20
private let profileNavScrollRevealInset: CGFloat = 4

private var profileNavBlurBottomCornerRadius: CGFloat {
    profileNavToolbarRowHeight / 2 + profileNavToolbarHorizontalPadding
}

private func profileNavTopBlurBarShape() -> UnevenRoundedRectangle {
    let r = profileNavBlurBottomCornerRadius
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

/// Круглые glass-кнопки шапки профиля (общая реализация для overlay и blur-панели).
@ViewBuilder
private func profileGlassToolbarIconButton(systemName: String, accent: Color, stretchP: CGFloat, action: @escaping () -> Void) -> some View {
    let pD = Double(stretchP)
    let expandedChromeOpacity: Double = 0.62
    Button(action: action) {
        Group {
            if #available(iOS 26.0, *) {
                ZStack {
                    Image(systemName: systemName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(accent).interactive(), in: Circle())
                        .opacity(1 - pD)
                        .allowsHitTesting(false)
                    Image(systemName: systemName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.45 * pD), radius: 6 * pD, x: 0, y: 2 * pD)
                        .glassEffect(.clear.interactive(), in: Circle())
                        .opacity(pD * expandedChromeOpacity)
                        .allowsHitTesting(false)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(accent)
                        .opacity(1 - pD)
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(pD)
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .opacity(pD * 0.35)
                    Image(systemName: systemName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55 * pD), radius: 4 * pD, x: 0, y: 1 * pD)
                }
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.28 * (1 - pD)), radius: 5 * (1 - pD), x: 0, y: 2 * (1 - pD))
                .opacity(1 - pD * (1 - expandedChromeOpacity))
            }
        }
    }
    .buttonStyle(.plain)
}

private struct ProfileTopNavigationBlurBar: View {
    let safeAreaTop: CGFloat
    let totalHeight: CGFloat
    let bottomGutter: CGFloat
    let showBlurMaterial: Bool
    let isDarkMode: Bool
    let accent: Color
    let centerTitle: String
    let toolbarStretchP: CGFloat
    let isOwnProfile: Bool
    let onDismiss: () -> Void
    let onEdit: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            profileNavTopBlurBarShape()
                .fill(.ultraThinMaterial)
                .frame(height: totalHeight)
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(showBlurMaterial ? 1 : 0)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Color.clear.frame(height: safeAreaTop)
                ZStack {
                    Text(centerTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isDarkMode ? .white : accent)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .opacity(showBlurMaterial ? 1 : 0)
                        .allowsHitTesting(false)
                    HStack {
                        profileGlassToolbarIconButton(systemName: "xmark", accent: accent, stretchP: toolbarStretchP, action: onDismiss)
                        Spacer(minLength: 0)
                        if isOwnProfile {
                            profileGlassToolbarIconButton(systemName: "square.and.pencil", accent: accent, stretchP: toolbarStretchP, action: onEdit)
                        }
                    }
                    .padding(.horizontal, profileNavToolbarHorizontalPadding)
                }
                .frame(height: profileNavToolbarRowHeight)
                Color.clear.frame(height: bottomGutter)
            }
            .frame(height: totalHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: showBlurMaterial)
        .clipShape(profileNavTopBlurBarShape())
        .shadow(color: Color.black.opacity(showBlurMaterial ? 0.06 : 0), radius: 2, x: 0, y: 1)
        .ignoresSafeArea(edges: .top)
    }
}

/// Экран профиля из настроек: `NavigationLink(destination:)` как у «Конфиденциальность».
private struct ProfileSettingsFlowView: View {
    @ObservedObject var authService: AuthService
    @Binding var tracks: [AppTrack]
    @Binding var trackPlayCounts: [UUID: Int]
    let accent: Color
    let mainBackground: Color
    let isEnglish: Bool
    let onPlayTrack: (AppTrack) -> Void

    var body: some View {
        Group {
            if let profile = authService.currentProfile {
                ProfileView(
                    profile: profile,
                    isOwnProfile: true,
                    libraryTracks: tracks,
                    trackPlayCounts: trackPlayCounts,
                    accent: accent,
                    mainBackground: mainBackground,
                    isEnglish: isEnglish,
                    onPlayTrack: onPlayTrack
                )
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(isEnglish ? "Loading profile..." : "Загружаем профиль...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await authService.ensureProfileAvailable() }
            }
        }
    }
}

private struct ProfileView: View {
    let profile: UserProfile
    let isOwnProfile: Bool
    let libraryTracks: [AppTrack]
    /// Счётчики стартов воспроизведения (см. `ContentView.startPlayback`).
    let trackPlayCounts: [UUID: Int]
    let accent: Color
    let mainBackground: Color
    let isEnglish: Bool
    var onPlayTrack: (AppTrack) -> Void = { _ in }
    @State private var profileScrollPull: CGFloat = 0
    @State private var profileAvatarExpandedLocked = false
    @State private var profileToolbarScrollY: CGFloat = 0
    @State private var showEditProfileMenu = false
    /// Ссылка на соцсеть из экрана редактирования (`sphereEditProfileSocialLinkDefaultsKey`).
    @AppStorage("sphere_edit_profile_social_link") private var profileSocialLinkStorage: String = ""
    /// Доминант с фото-аватарки (URL); пресеты и fallback не используют.
    @State private var profileBlockPhotoTint: Color?
    @State private var listenHistory: [HistoryEntry] = []
    @State private var isLoadingHistory = false
    @StateObject private var authService = AuthService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sphereExcludedRecoTrackUUIDsJSON") private var excludedRecoTracksJSON: String = "[]"
    private var tracksHiddenFromRecommendations: Set<UUID> {
        sphereDecodedExcludedRecommendationIDs(from: excludedRecoTracksJSON)
    }

    private var activeProfile: UserProfile { isOwnProfile ? (authService.currentProfile ?? profile) : profile }

    private var profileSocialLinkTrimmed: String {
        profileSocialLinkStorage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        profile: UserProfile,
        isOwnProfile: Bool,
        libraryTracks: [AppTrack],
        trackPlayCounts: [UUID: Int],
        accent: Color,
        mainBackground: Color,
        isEnglish: Bool,
        onPlayTrack: @escaping (AppTrack) -> Void = { _ in }
    ) {
        self.profile = profile
        self.isOwnProfile = isOwnProfile
        self.libraryTracks = libraryTracks
        self.trackPlayCounts = trackPlayCounts
        self.accent = accent
        self.mainBackground = mainBackground
        self.isEnglish = isEnglish
        self.onPlayTrack = onPlayTrack
    }

    /// Все треки с `addedAt` в последние 24 часа (новые выше).
    private static func recentlyAddedWithin24Hours(_ tracks: [AppTrack]) -> [AppTrack] {
        let cutoff = Date().addingTimeInterval(-ProfileCardMetrics.recentlyAddedWindowSeconds)
        return tracks
            .filter { ($0.addedAt ?? .distantPast) >= cutoff }
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    /// Одна песня с максимальным счётчиком воспроизведений (при равенстве — более новая по `addedAt`).
    private static func mostPlayedTrack(from tracks: [AppTrack], playCounts: [UUID: Int]) -> AppTrack? {
        guard let best = tracks.max(by: { a, b in
            let ca = playCounts[a.id] ?? 0
            let cb = playCounts[b.id] ?? 0
            if ca != cb { return ca < cb }
            let da = a.addedAt ?? .distantPast
            let db = b.addedAt ?? .distantPast
            return da < db
        }) else { return nil }
        return (playCounts[best.id] ?? 0) > 0 ? best : nil
    }

    private var profileDisplayNickname: String {
        let n = activeProfile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "—" : activeProfile.nickname
    }

    private var profileDisplayUsernameAt: String {
        let u = activeProfile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return "@…" }
        return u.hasPrefix("@") ? u : "@\(u)"
    }

    /// Тот же smoothstep `p`, что в `SettingsAccountStretchHeader` (круг ↔ квадрат).
    private var profileAvatarStretchP: CGFloat {
        let maxPull: CGFloat = 120
        let effectivePull = profileAvatarExpandedLocked ? maxPull : profileScrollPull
        let progress = min(1, max(0, effectivePull / maxPull))
        let t = progress
        return t * t * (3 - 2 * t)
    }

    /// Цвет для градиента блока «прослушивания / bio»: пресет аватарки, иначе доминанта фото или акцент.
    private var profileBlockGradientColor: Color {
        if let idx = SphereProfileAvatarPalette.presetIndex(from: activeProfile.avatarUrl) {
            return SphereProfileAvatarPalette.presetBackgroundColor(index: idx, accent: accent)
        }
        return profileBlockPhotoTint ?? accent
    }

    /// Один цвет заливки: почти чёрный/белый с лёгкой примесью `profileBlockGradientColor` (без отдельного слоя поверх).
    private func profileBlockBackgroundColor(isDark: Bool) -> Color {
        let baseWhite: CGFloat = isDark ? 0.052 : 0.981
        let mix: CGFloat = isDark ? 0.078 : 0.092
        let base = UIColor(white: baseWhite, alpha: 1)
        let uiTint = UIColor(profileBlockGradientColor)
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        guard base.getRed(&br, green: &bg, blue: &bb, alpha: &ba),
              uiTint.getRed(&tr, green: &tg, blue: &tb, alpha: &ta) else {
            return Color(white: baseWhite)
        }
        let om = 1 - mix
        return Color(
            red: br * om + tr * mix,
            green: bg * om + tg * mix,
            blue: bb * om + tb * mix
        )
    }

    /// Фон большого блока: тёмная — с лёгким тинтом от аватарки; светлая — тот же серый, что заливка миниблоков (0.92).
    private func profileLargeBlockBackground(isDark: Bool) -> Color {
        if isDark { return profileBlockBackgroundColor(isDark: true) }
        return Color(white: 0.92)
    }

    private func loadProfileBlockPhotoDominantIfNeeded() async {
        if SphereProfileAvatarPalette.presetIndex(from: activeProfile.avatarUrl) != nil {
            await MainActor.run { profileBlockPhotoTint = nil }
            return
        }
        guard let urlString = activeProfile.avatarUrl,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            await MainActor.run { profileBlockPhotoTint = nil }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 45)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
                  let img = UIImage(data: data),
                  let dom = dominantColor(from: img) else {
                await MainActor.run { profileBlockPhotoTint = nil }
                return
            }
            await MainActor.run { profileBlockPhotoTint = dom }
        } catch {
            await MainActor.run { profileBlockPhotoTint = nil }
        }
    }

    private func loadHistory() async {
        do {
            let entries = try await SphereAPIClient.shared.getHistory()
            await MainActor.run { listenHistory = entries }
        } catch {
            print("[Sphere] load history error:", error.localizedDescription)
        }
    }

    @ViewBuilder
    private func profileToolbarIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        profileGlassToolbarIconButton(systemName: systemName, accent: accent, stretchP: profileAvatarStretchP, action: action)
    }

    /// Как `devMenuSectionHeader` в `DeveloperMenu_SphereExport`.
    private func profileDevMenuSectionHeader(_ title: String, isDark: Bool) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isDark ? .white : accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .padding(.trailing, 12)
    }

    /// Карточка Bio: заливка как фон экрана, без обводки (как миниблоки с треками).
    private func profileDevMenuCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            content()
                .padding(.top, 18)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(mainBackground)
        }
        .padding(.horizontal, 12)
    }

    /// Список треков в карточке без внутреннего скролла — все строки видны, высота по контенту (светлая тема без обводки).
    private func profileTrackListStaticCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: 36, style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.leading, HomeLibraryHorizontalRowMetrics.trackRowLeadingInset)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            cardShape.fill(mainBackground)
        }
        .clipShape(cardShape)
        .padding(.horizontal, 12)
    }

    var body: some View {
        GeometryReader { geometry in
            let topInset = geometry.safeAreaInsets.top
            let isDarkMode = colorScheme == .dark
            let p = profileAvatarStretchP
            // Круг — ниже; раскрытый квадрат — под островом (не у самого верха), но выше круга.
            let profileHeaderTopCircle: CGFloat = topInset + 40
            let profileHeaderTopSquare: CGFloat = topInset + 4
            let profileHeaderTopPadding = profileHeaderTopCircle + (profileHeaderTopSquare - profileHeaderTopCircle) * p
            let libraryForRecommendations = libraryTracks.filter { !tracksHiddenFromRecommendations.contains($0.id) }
            let profileRecentlyAddedTracks = ProfileView.recentlyAddedWithin24Hours(libraryForRecommendations)
            let profileMostPlayedTrack = ProfileView.mostPlayedTrack(from: libraryForRecommendations, playCounts: trackPlayCounts)
            let profileHasRecentTracksSection = !profileRecentlyAddedTracks.isEmpty
            let profileHasMostPlayedSection = profileMostPlayedTrack != nil
            /// Совпадает с суммой высот `SettingsAccountStretchHeader` (reporter + отступ + ряд аватарки + подписи + нижний зазор).
            let profileStretchSide: CGFloat = {
                let collapsed: CGFloat = 104
                let inset: CGFloat = 16
                let expanded = UIScreen.main.bounds.width - inset * 2
                return collapsed + (expanded - collapsed) * p
            }()
            let profileStretchBelowH = (16 + 5 + 30 + 22) * (1 - p)
            let profileStretchTrailH = 8 * (1 - p) + SettingsAccountHeaderLayout.titleToAvatarSpacing * p
            let profileStretchHeaderTotal = 1 + profileHeaderTopPadding + profileStretchSide + profileStretchBelowH + profileStretchTrailH
            /// До низа экрана: высота контейнера минус шапка + нижний safe area (полоса под контентом не остаётся).
            let profileColoredBlockMinHeight = max(
                260,
                geometry.size.height - profileStretchHeaderTotal + geometry.safeAreaInsets.bottom
            )
            let profileNavBarTotalHeight = topInset + profileNavToolbarRowHeight + profileNavBlurBottomGutter

            ZStack(alignment: .top) {
                mainBackground.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            if #available(iOS 18.0, *) {
                                Color.clear.frame(height: 0)
                            } else {
                                DevMenuScrollOffsetUIKitReader(offsetY: $profileToolbarScrollY)
                                    .frame(width: 1, height: 1)
                                    .allowsHitTesting(false)
                            }
                        }
                        SettingsScrollOverscrollReporter(stretch: $profileScrollPull, avatarExpandedLocked: $profileAvatarExpandedLocked)
                            .frame(height: 1)
                            .frame(maxWidth: .infinity)

                        SettingsAccountStretchHeader(
                            profile: activeProfile,
                            backendUser: authService.backendAccountSnapshot,
                            accent: accent,
                            nickname: profileDisplayNickname,
                            usernameAt: profileDisplayUsernameAt,
                            isDarkMode: isDarkMode,
                            pullOffset: profileScrollPull,
                            expansionLocked: profileAvatarExpandedLocked
                        )
                        .padding(.top, profileHeaderTopPadding)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("0 прослушиваний в месяц")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 18)
                                .padding(.trailing, 12)
                                .padding(.top, 22)
                                .padding(.bottom, 12)
                            VStack(alignment: .leading, spacing: 8) {
                                profileDevMenuSectionHeader(isEnglish ? "Bio" : "О себе", isDark: isDarkMode)
                                profileDevMenuCard {
                                    let bioText = activeProfile.bio ?? ""
                                    let bioEmpty = bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    Text(bioEmpty ? "Добавьте описание" : bioText)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(bioEmpty ? Color.secondary : (isDarkMode ? Color.white : Color.primary))
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                                        .multilineTextAlignment(.leading)
                                        .padding(.horizontal, 12)
                                }
                            }
                            .padding(.bottom, 4)

                            if isOwnProfile, !profileSocialLinkTrimmed.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    profileDevMenuSectionHeader(isEnglish ? "Social network" : "Социальная сеть", isDark: isDarkMode)
                                    Text(profileSocialLinkTrimmed)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(isDarkMode ? Color.white : Color.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .multilineTextAlignment(.leading)
                                        .padding(.leading, 18)
                                        .padding(.trailing, 12)
                                        .textSelection(.enabled)
                                }
                                .padding(.bottom, 4)
                            }

                            Group {
                                if profileHasMostPlayedSection, let topPlayed = profileMostPlayedTrack {
                                    VStack(alignment: .leading, spacing: 8) {
                                        profileDevMenuSectionHeader("Часто прослушиваемое", isDark: isDarkMode)
                                            .padding(.top, 12)
                                        profileTrackListStaticCard {
                                            CompactTrackRow(track: topPlayed, accent: accent) { onPlayTrack(topPlayed) }
                                                .id(topPlayed.id)
                                        }
                                    }
                                }
                                if profileHasRecentTracksSection {
                                    VStack(alignment: .leading, spacing: 8) {
                                        profileDevMenuSectionHeader("Недавно добавлено", isDark: isDarkMode)
                                            .padding(.top, profileHasMostPlayedSection ? 8 : 12)
                                        profileTrackListStaticCard {
                                            ForEach(profileRecentlyAddedTracks) { track in
                                                CompactTrackRow(track: track, accent: accent) { onPlayTrack(track) }
                                            }
                                        }
                                    }
                                }

                                // Listen history
                                if !listenHistory.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        profileDevMenuSectionHeader(isEnglish ? "Recently Played" : "Прослушанное", isDark: isDarkMode)
                                            .padding(.top, 12)
                                        profileTrackListStaticCard {
                                            ForEach(listenHistory.prefix(10)) { entry in
                                                HStack(spacing: 12) {
                                                    ServiceIconBadge(provider: entry.provider, size: 16)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(entry.title)
                                                            .font(.system(size: 14, weight: .medium))
                                                            .foregroundStyle(isDarkMode ? .white : .primary)
                                                            .lineLimit(1)
                                                        Text(entry.artist)
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(.vertical, 4)
                                                .padding(.horizontal, 12)
                                            }
                                        }
                                    }
                                }
                            }
                            /// Большой зазор цветного блока от последнего контента до низа (скролл доходит сюда).
                            Spacer(minLength: 72)
                        }
                        .frame(width: geometry.size.width, alignment: .leading)
                        .frame(minHeight: profileColoredBlockMinHeight, alignment: .top)
                        .background(profileLargeBlockBackground(isDark: isDarkMode))
                        .clipShape(
                            UnevenRoundedRectangle(
                                cornerRadii: RectangleCornerRadii(
                                    topLeading: 28,
                                    bottomLeading: 28,
                                    bottomTrailing: 28,
                                    topTrailing: 28
                                ),
                                style: .continuous
                            )
                        )
                        .task(id: activeProfile.avatarUrl) {
                            await loadProfileBlockPhotoDominantIfNeeded()
                        }
                        .task {
                            await loadHistory()
                        }
                    }
                }
                .modifier(DeveloperMenuLiveScrollModifier(scrollY: $profileToolbarScrollY))
                .ignoresSafeArea(edges: [.top, .bottom])
                .animation(SettingsAccountHeaderLayout.expansionLockAnimation, value: profileAvatarExpandedLocked)

                ProfileTopNavigationBlurBar(
                    safeAreaTop: topInset,
                    totalHeight: profileNavBarTotalHeight,
                    bottomGutter: profileNavBlurBottomGutter,
                    showBlurMaterial: profileToolbarScrollY >= profileNavScrollRevealInset,
                    isDarkMode: isDarkMode,
                    accent: accent,
                    centerTitle: isEnglish ? "Profile" : "Профиль",
                    toolbarStretchP: profileAvatarStretchP,
                    isOwnProfile: isOwnProfile,
                    onDismiss: { dismiss() },
                    onEdit: { showEditProfileMenu = true }
                )
                .zIndex(1)
            }
        }
        .background(ProfileNavigationPopGestureEnabler())
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onDisappear {
            profileAvatarExpandedLocked = false
            profileToolbarScrollY = 0
        }
        .fullScreenCover(isPresented: $showEditProfileMenu) {
            EditProfileMenuView(
                resolvedColorSchemeFromMainApp: colorScheme,
                isEnglish: isEnglish,
                onDismiss: { showEditProfileMenu = false }
            )
        }
    }
}

private struct CompactTrackRow: View {
    let track: AppTrack
    let accent: Color
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                TrackCoverView(track: track, accent: accent, cornerRadius: 8).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    if !track.displayArtist.isEmpty { Text(track.displayArtist).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }.buttonStyle(.plain)
    }
}

private struct EditBioSheet: View {
    @Binding var bio: String
    let accent: Color
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TextEditor(text: $bio).padding()
                .navigationTitle("Bio").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { onSave(); dismiss() }.fontWeight(.semibold).foregroundStyle(accent) }
                }
        }
    }
}

private struct PrivacyPasswordChangeSheet: View {
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var errorText: String?
    @State private var busy = false

    private var strength: SpherePasswordStrength { SpherePasswordStrength.evaluate(newPassword) }

    var body: some View {
        NavigationStack {
            Form {
                SecureField(isEnglish ? "Current password" : "Текущий пароль", text: $oldPassword)
                SecureField(isEnglish ? "New password" : "Новый пароль", text: $newPassword)
                if !newPassword.isEmpty {
                    Text(isEnglish ? "Strength: \(strength.score)/100" : "Сложность: \(strength.score)/100")
                        .font(.caption)
                        .foregroundStyle(strength.isAcceptableForRegister ? Color.secondary : Color.red)
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(isDarkMode ? Color.black : Color(.systemGroupedBackground))
            .navigationTitle(isEnglish ? "Change password" : "Сменить пароль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Cancel" : "Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEnglish ? "Save" : "Сохранить") {
                        Task {
                            guard strength.isAcceptableForRegister else {
                                errorText = isEnglish ? "Password too weak" : "Пароль слишком слабый"
                                return
                            }
                            busy = true
                            errorText = nil
                            defer { busy = false }
                            do {
                                try await SphereAPIClient.shared.changePassword(oldPassword: oldPassword, newPassword: newPassword)
                                await MainActor.run {
                                    SphereBackendPasswordKeychain.setBackendPassword(newPassword, forEmail: AuthService.shared.currentProfile?.email ?? "")
                                    dismiss()
                                }
                            } catch {
                                await MainActor.run { errorText = error.localizedDescription }
                            }
                        }
                    }
                    .disabled(busy || oldPassword.isEmpty || newPassword.isEmpty)
                    .foregroundStyle(accent)
                }
            }
        }
    }
}

private struct PrivacyEmailChangeSheet: View {
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var authService = AuthService.shared
    @State private var step = 1
    @State private var newEmail = ""
    @State private var accountPassword = ""
    @State private var code = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if step == 1 {
                    TextField(isEnglish ? "New email" : "Новая почта", text: $newEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    SecureField(isEnglish ? "Current password" : "Текущий пароль", text: $accountPassword)
                } else {
                    Text(isEnglish ? "Enter the code sent to the new address." : "Введите код из письма на новый адрес.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(isEnglish ? "6-digit code" : "Код из 6 цифр", text: $code)
                        .keyboardType(.numberPad)
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(isDarkMode ? Color.black : Color(.systemGroupedBackground))
            .navigationTitle(isEnglish ? "Change email" : "Сменить почту")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Cancel" : "Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == 1 {
                        Button(isEnglish ? "Send code" : "Отправить код") {
                            Task {
                                busy = true
                                errorText = nil
                                defer { busy = false }
                                let em = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard em.contains("@") else {
                                    errorText = isEnglish ? "Invalid email" : "Некорректная почта"
                                    return
                                }
                                do {
                                    try await SphereAPIClient.shared.startEmailChange(newEmail: em, password: accountPassword)
                                    await MainActor.run { step = 2 }
                                } catch {
                                    await MainActor.run { errorText = error.localizedDescription }
                                }
                            }
                        }
                        .disabled(busy || newEmail.isEmpty || accountPassword.isEmpty)
                        .foregroundStyle(accent)
                    } else {
                        Button(isEnglish ? "Confirm" : "Подтвердить") {
                            Task {
                                busy = true
                                errorText = nil
                                defer { busy = false }
                                let em = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                                do {
                                    let u = try await SphereAPIClient.shared.confirmEmailChange(newEmail: em, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
                                    await MainActor.run {
                                        authService.applyBackendUser(u)
                                        dismiss()
                                    }
                                } catch {
                                    await MainActor.run { errorText = error.localizedDescription }
                                }
                            }
                        }
                        .disabled(busy || code.count != 6)
                        .foregroundStyle(accent)
                    }
                }
            }
        }
    }
}

private struct PrivacyTotpSetupSheet: View {
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var otpauthPayload: String?
    @State private var code = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let otpauthPayload {
                    SphereQRLoginQRImage(payload: otpauthPayload)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    Text(isEnglish ? "Scan with Google Authenticator or Apple Passwords, then enter the 6-digit code." : "Отсканируйте в Authenticator или Паролях Apple и введите 6 цифр.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(isEnglish ? "Code" : "Код", text: $code)
                        .keyboardType(.numberPad)
                } else if errorText != nil {
                    Text(errorText ?? "").foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                if let errorText, otpauthPayload != nil {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(isDarkMode ? Color.black : Color(.systemGroupedBackground))
            .navigationTitle(isEnglish ? "Authenticator" : "Приложение-ключ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Close" : "Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEnglish ? "Enable" : "Включить") {
                        Task {
                            busy = true
                            errorText = nil
                            defer { busy = false }
                            do {
                                try await SphereAPIClient.shared.totpEnable(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
                                await MainActor.run {
                                    Task { await AuthService.shared.refreshBackendAccountFromServer() }
                                    dismiss()
                                }
                            } catch {
                                await MainActor.run { errorText = error.localizedDescription }
                            }
                        }
                    }
                    .disabled(busy || code.count != 6 || otpauthPayload == nil)
                    .foregroundStyle(accent)
                }
            }
            .task {
                guard otpauthPayload == nil else { return }
                busy = true
                defer { busy = false }
                do {
                    let r = try await SphereAPIClient.shared.totpSetup()
                    otpauthPayload = r.otpauthUrl
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

private struct PrivacyEmail2FASecuritySheet: View {
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var authService = AuthService.shared
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?

    private var enabled: Bool {
        authService.backendAccountSnapshot?.email2FAEnabled ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                SecureField(isEnglish ? "Password" : "Пароль", text: $password)
                    .textContentType(.password)
                Text(
                    enabled
                        ? (isEnglish ? "Email OTP is enabled for login." : "При входе будет код на почту.")
                        : (isEnglish ? "Turn on to require a login code emailed to you." : "При входе будет отправляться код на почту.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(enabled ? (isEnglish ? "Turn off email OTP" : "Выключить код по почте") : (isEnglish ? "Turn on email OTP" : "Включить код по почте")) {
                    Task {
                        guard !password.isEmpty else {
                            errorText = isEnglish ? "Enter password" : "Введите пароль"
                            return
                        }
                        busy = true
                        errorText = nil
                        defer { busy = false }
                        do {
                            if enabled {
                                try await SphereAPIClient.shared.email2FADisable(password: password)
                            } else {
                                try await SphereAPIClient.shared.email2FAEnable(password: password)
                            }
                            password = ""
                            await MainActor.run {
                                Task { await authService.refreshBackendAccountFromServer() }
                                dismiss()
                            }
                        } catch {
                            await MainActor.run { errorText = error.localizedDescription }
                        }
                    }
                }
                .foregroundStyle(accent)
                .disabled(busy)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(isDarkMode ? Color.black : Color(.systemGroupedBackground))
            .navigationTitle(isEnglish ? "Email OTP" : "Код по почте")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Close" : "Закрыть") { dismiss() }
                }
            }
        }
    }
}

private struct PrivacyApproveQRScannerSheet: View {
    let isEnglish: Bool
    let accent: Color
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SphereQRCodeScannerView(
                    onPayload: { raw in
                        guard let parts = Self.parseQrLogin(raw) else {
                            message = isEnglish ? "Invalid QR" : "Неверный QR"
                            return
                        }
                        Task {
                            do {
                                try await SphereAPIClient.shared.qrLoginApprove(sessionId: parts.sid, nonce: parts.nonce)
                                await MainActor.run {
                                    onDone()
                                    dismiss()
                                }
                            } catch {
                                await MainActor.run { message = error.localizedDescription }
                            }
                        }
                    },
                    onError: { message = $0 }
                )
                .ignoresSafeArea()
                VStack {
                    Text(isEnglish ? "Scan the QR on the other device" : "Наведите на QR на другом устройстве")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding()
                    Spacer()
                    if let message {
                        Text(message).foregroundStyle(.red).padding()
                    }
                }
            }
            .navigationTitle(isEnglish ? "Approve login" : "Подтвердить вход")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Close" : "Закрыть") { dismiss() }
                }
            }
        }
    }

    private static func parseQrLogin(_ raw: String) -> (sid: String, nonce: String)? {
        guard let url = URL(string: raw),
              url.scheme == "sphere",
              url.host == "qr-login",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let sid = items.first(where: { $0.name == "sid" })?.value,
              let n = items.first(where: { $0.name == "n" })?.value else { return nil }
        return (sid, n)
    }
}

private struct PrivacySettingsView: View {
    let profile: UserProfile?
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @StateObject private var authService = AuthService.shared
    @State private var nickname: String = ""
    @State private var username: String = ""
    @State private var showChangePassword = false
    @State private var showChangeEmail = false
    @State private var showTotpSetup = false
    @State private var showEmail2FASecurity = false
    @State private var showApproveQRScanner = false
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var accountError: String?
    @State private var isUploadingAvatar = false
    @State private var hideSubscriptions = false
    @State private var messagesMutualOnly = false
    @State private var privateProfile = false
    @State private var isSavingPrivacy = false
    @State private var showSubscriptionRequests = false
    private var activeProfile: UserProfile? { authService.currentProfile ?? profile }
    var body: some View {
        List {
            if let p = activeProfile {
                Section {
                    HStack { Text(isEnglish ? "Display name" : "Отображаемое имя"); TextField("", text: $nickname).multilineTextAlignment(.trailing) }
                    HStack { Text(isEnglish ? "Nickname" : "Никнейм"); TextField("", text: $username).multilineTextAlignment(.trailing) }
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(p.email ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                        HStack {
                            Text(isEnglish ? "Profile photo" : "Фото профиля")
                            Spacer()
                            if isUploadingAvatar { ProgressView() }
                        }
                    }
                    .disabled(!SphereAPIClient.shared.isAuthenticated || isUploadingAvatar)
                    .onChange(of: avatarPickerItem) { newItem in
                        Task {
                            guard let newItem else { return }
                            isUploadingAvatar = true
                            accountError = nil
                            defer { isUploadingAvatar = false }
                            do {
                                guard let data = try await newItem.loadTransferable(type: Data.self) else { return }
                                let mime: String
                                let fn: String
                                if data.count >= 8, data[0] == 0x89, data[1] == 0x50 {
                                    mime = "image/png"
                                    fn = "avatar.png"
                                } else {
                                    mime = "image/jpeg"
                                    fn = "avatar.jpg"
                                }
                                let user = try await SphereAPIClient.shared.uploadAvatarImage(data, fileName: fn, mimeType: mime)
                                await MainActor.run {
                                    authService.applyBackendUser(user)
                                    avatarPickerItem = nil
                                }
                            } catch {
                                await MainActor.run { accountError = error.localizedDescription }
                            }
                        }
                    }
                    if SphereAPIClient.shared.isAuthenticated {
                        Button {
                            showChangePassword = true
                        } label: {
                            Text(isEnglish ? "Change password" : "Сменить пароль")
                        }
                        Button {
                            showChangeEmail = true
                        } label: {
                            Text(isEnglish ? "Change email" : "Сменить почту")
                        }
                        Button {
                            showEmail2FASecurity = true
                        } label: {
                            let on = authService.backendAccountSnapshot?.email2FAEnabled == true
                            Text(isEnglish ? "Email OTP login \(on ? "(on)" : "")" : "Код по почте при входе \(on ? "(вкл.)" : "")")
                        }
                        Button {
                            showTotpSetup = true
                        } label: {
                            Text(isEnglish ? "Authenticator app (TOTP)" : "Приложение-ключ (TOTP)")
                        }
                        Button {
                            showApproveQRScanner = true
                        } label: {
                            Text(isEnglish ? "Approve QR login (scan)" : "Подтвердить вход по QR (сканировать)")
                        }
                    } else {
                        Text(isEnglish ? "Sign in with email on the Sphere backend to change password or email." : "Войдите по почте в бэкенд Sphere, чтобы менять пароль и почту.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let accountError {
                        Text(accountError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: { Text(isEnglish ? "Profile data" : "Данные профиля") }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(isEnglish ? "Loading profile..." : "Загружаем данные профиля...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if SphereAPIClient.shared.isAuthenticated {
                Section {
                    Toggle(isEnglish ? "Hide subscriptions" : "Скрыть подписки", isOn: $hideSubscriptions)
                        .disabled(isSavingPrivacy)
                    Toggle(isEnglish ? "Only allow replies (I message first)" : "Писать только если я первый", isOn: $messagesMutualOnly)
                        .disabled(isSavingPrivacy)
                    Toggle(isEnglish ? "Private profile" : "Приватный профиль", isOn: $privateProfile)
                        .disabled(isSavingPrivacy)

                    NavigationLink(isEnglish ? "Subscription requests" : "Запросы на подписку") {
                        SubscriptionRequestsInboxView(accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)
                    }
                } header: {
                    Text(isEnglish ? "Privacy controls" : "Конфиденциальность профиля")
                } footer: {
                    Text(isEnglish
                         ? "If profile is private, others will need approval to view your activity."
                         : "При приватном профиле другим нужен ваш апрув, чтобы видеть активность.")
                }
            }
        }
        .navigationTitle(isEnglish ? "Privacy" : "Конфиденциальность")
        .sheet(isPresented: $showChangePassword) {
            PrivacyPasswordChangeSheet(accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)
        }
        .sheet(isPresented: $showChangeEmail) {
            PrivacyEmailChangeSheet(accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)
        }
        .sheet(isPresented: $showTotpSetup) {
            PrivacyTotpSetupSheet(accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)
        }
        .sheet(isPresented: $showEmail2FASecurity) {
            PrivacyEmail2FASecuritySheet(accent: accent, isEnglish: isEnglish, isDarkMode: isDarkMode)
        }
        .sheet(isPresented: $showApproveQRScanner) {
            PrivacyApproveQRScannerSheet(isEnglish: isEnglish, accent: accent, onDone: {})
        }
        .task {
            await authService.ensureProfileAvailable()
            await authService.refreshBackendAccountFromServer()
            syncPrivacyFromBackend()
        }
        .onAppear { syncFieldsFromProfile() }
        .onChange(of: authService.currentProfile) { _ in
            syncFieldsFromProfile()
        }
        .onChange(of: authService.backendAccountSnapshot) { _ in
            syncPrivacyFromBackend()
        }
        .onChange(of: hideSubscriptions) { _ in
            Task { await savePrivacy() }
        }
        .onChange(of: messagesMutualOnly) { _ in
            Task { await savePrivacy() }
        }
        .onChange(of: privateProfile) { _ in
            Task { await savePrivacy() }
        }
        .onDisappear {
            guard activeProfile != nil else { return }
            Task {
                await authService.updateProfile(
                    nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : nickname,
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : username,
                    bio: nil,
                    avatarUrl: nil
                )
            }
        }
    }

    private func syncFieldsFromProfile() {
        guard let p = activeProfile else { return }
        nickname = p.nickname
        username = p.username
    }

    private func syncPrivacyFromBackend() {
        guard let b = authService.backendAccountSnapshot else { return }
        hideSubscriptions = b.hideSubscriptions
        messagesMutualOnly = b.messagesMutualOnly
        privateProfile = b.privateProfile
    }

    private func savePrivacy() async {
        guard SphereAPIClient.shared.isAuthenticated else { return }
        guard !isSavingPrivacy else { return }
        isSavingPrivacy = true
        defer { isSavingPrivacy = false }
        do {
            _ = try await SphereAPIClient.shared.updatePrivacy(
                hideSubscriptions: hideSubscriptions,
                messagesMutualOnly: messagesMutualOnly,
                privateProfile: privateProfile
            )
            let u = try await SphereAPIClient.shared.fetchCurrentUser()
            await MainActor.run { authService.applyBackendUser(u) }
        } catch {
            await MainActor.run { accountError = error.localizedDescription }
        }
    }
}

private struct SubscriptionRequestsInboxView: View {
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    @State private var items: [BackendSubscriptionRequestItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 12) { ProgressView(); Text(isEnglish ? "Loading..." : "Загрузка...").foregroundStyle(.secondary) }
            }
            if let e = errorMessage {
                Text(e).foregroundStyle(.secondary)
            }
            ForEach(items) { it in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(it.requester.name.isEmpty ? it.requester.username : it.requester.name)
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text(it.status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button {
                            Task { await approve(it.id) }
                        } label: {
                            Text(isEnglish ? "Approve" : "Одобрить")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)

                        Button {
                            Task { await deny(it.id) }
                        } label: {
                            Text(isEnglish ? "Deny" : "Отклонить")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.plain)
        .navigationTitle(isEnglish ? "Requests" : "Запросы")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await SphereAPIClient.shared.listIncomingSubscriptionRequests()
            await MainActor.run { items = r; errorMessage = nil }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func approve(_ id: String) async {
        do {
            try await SphereAPIClient.shared.approveSubscriptionRequest(id: id)
            await reload()
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func deny(_ id: String) async {
        do {
            try await SphereAPIClient.shared.denySubscriptionRequest(id: id)
            await reload()
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
}

private struct RemoteUserProfileView: View {
    let userID: String
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool

    @State private var profile: BackendUserProfileResponse?
    @State private var favorites: [FavoriteItem] = []
    @State private var history: [HistoryEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var subscriptionActionRunning = false
    @State private var openChatID: String?

    var body: some View {
        let bg = isDarkMode ? Color.black : Color(.systemGroupedBackground)
        ZStack {
            bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .padding(.top, 12)

                    if let p = profile, p.requires_approval {
                        privateGateCard
                    } else {
                        if !favorites.isEmpty {
                            sectionTitle(isEnglish ? "Recently added" : "Недавно добавлено")
                            trackListCard {
                                ForEach(Array(favorites.prefix(12)), id: \.id) { f in
                                    simpleTrackRow(title: f.title, subtitle: f.artistName, coverURL: f.coverURL ?? "")
                                }
                            }
                        }
                        if !history.isEmpty {
                            sectionTitle(isEnglish ? "Recently played" : "Недавно прослушано")
                            trackListCard {
                                ForEach(Array(history.prefix(12)), id: \.id) { h in
                                    simpleTrackRow(title: h.title, subtitle: h.artist, coverURL: "")
                                }
                            }
                        }
                    }

                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.top, 12)
                    } else if let e = errorMessage {
                        Text(e).foregroundStyle(.secondary).padding(.horizontal, 16)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .background {
            NavigationLink(
                destination: Group {
                    if let cid = openChatID {
                        ChatScreen(
                            chatID: cid,
                            otherUserName: (profile?.user.name ?? "").isEmpty ? (profile?.user.username ?? "") : (profile?.user.name ?? ""),
                            accent: accent,
                            isEnglish: isEnglish
                        )
                    } else {
                        EmptyView()
                    }
                },
                isActive: Binding(
                    get: { openChatID != nil },
                    set: { v in if !v { openChatID = nil } }
                )
            ) { EmptyView() }
            .hidden()
        }
        .task { await loadAll() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let urlString = profile?.user.avatar_url, let url = URL(string: urlString), !urlString.isEmpty {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(Color(.systemGray5))
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                } else {
                    Circle().fill(Color(.systemGray5))
                        .frame(width: 72, height: 72)
                }

                VStack(alignment: .leading, spacing: 4) {
                    SphereCompactUserBadges(
                        displayName: (profile?.user.name ?? "").isEmpty ? (profile?.user.username ?? "") : (profile?.user.name ?? ""),
                        badgeText: profile?.user.badge_text ?? "",
                        badgeColor: profile?.user.badge_color ?? "",
                        isVerified: profile?.user.is_verified == true,
                        verifiedBadgeSize: 18,
                        nameFont: .system(size: 22, weight: .bold)
                    )
                    if let u = profile?.user.username, !u.isEmpty {
                        Text("@\(u)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            statsRow
            actionsRow
        }
        .padding(.horizontal, 16)
    }

    private var statsRow: some View {
        let monthly = profile?.stats.monthly_listens ?? 0
        let subs = profile?.stats.subscribers_count ?? 0
        let following = profile?.stats.subscriptions_count ?? 0
        return HStack(spacing: 14) {
            statChip(title: isEnglish ? "Monthly" : "В месяц", value: "\(monthly)")
            statChip(title: isEnglish ? "Subscribers" : "Подписчики", value: "\(subs)")
            statChip(title: isEnglish ? "Following" : "Подписки", value: "\(following)")
            Spacer()
        }
    }

    private var actionsRow: some View {
        let isSubscribed = profile?.is_subscribed ?? false
        let reqStatus = profile?.subscription_request_status ?? "none"
        let requiresApproval = profile?.requires_approval ?? false

        let subscribeLabel: String = {
            if requiresApproval {
                if reqStatus == "pending" { return isEnglish ? "Requested" : "Запрошено" }
                return isEnglish ? "Request access" : "Запросить доступ"
            }
            return isSubscribed ? (isEnglish ? "Subscribed" : "Вы подписаны") : (isEnglish ? "Subscribe" : "Подписаться")
        }()

        return HStack(spacing: 12) {
            Button {
                Task { await toggleSubscribe() }
            } label: {
                Text(subscribeLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(accent.opacity(0.18))
                    .foregroundStyle(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(subscriptionActionRunning || userID.isEmpty)

            Button {
                Task { await openChat() }
            } label: {
                Text(isEnglish ? "Chat" : "Чат")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(isDarkMode ? Color(white: 0.14) : Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!(profile?.can_message ?? true))
        }
    }

    private var privateGateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(isEnglish ? "Private profile" : "Приватный профиль")
                    .font(.system(size: 17, weight: .semibold))
            }
            Text(isEnglish
                 ? "This user has hidden their profile. Request access to view their activity."
                 : "Пользователь скрыл профиль. Отправьте запрос, чтобы видеть информацию.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDarkMode ? Color(white: 0.12) : Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func statChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold))
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isDarkMode ? Color(white: 0.12) : Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 18, weight: .semibold))
            .padding(.horizontal, 16)
    }

    private func trackListCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 6)
        .background(isDarkMode ? Color(white: 0.12) : Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func simpleTrackRow(title: String, subtitle: String, coverURL: String) -> some View {
        HStack(spacing: 12) {
            if let url = URL(string: coverURL), !coverURL.isEmpty {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.systemGray5))
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemGray5))
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let p = try await SphereAPIClient.shared.getUserProfile(id: userID)
            await MainActor.run { profile = p; errorMessage = nil }
            if !p.requires_approval {
                async let favs = SphereAPIClient.shared.listUserFavorites(userID: userID)
                async let hist = SphereAPIClient.shared.getUserHistory(userID: userID, limit: 50)
                let (f, h) = try await (favs, hist)
                await MainActor.run {
                    favorites = f
                    history = h
                }
            } else {
                await MainActor.run {
                    favorites = []
                    history = []
                }
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func toggleSubscribe() async {
        guard !subscriptionActionRunning else { return }
        subscriptionActionRunning = true
        defer { subscriptionActionRunning = false }
        do {
            if profile?.is_subscribed == true {
                try await SphereAPIClient.shared.unsubscribe(userID: userID)
            } else {
                _ = try await SphereAPIClient.shared.subscribe(userID: userID)
            }
            await loadAll()
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func openChat() async {
        do {
            let cid = try await SphereAPIClient.shared.openOrCreateDM(userID: userID)
            await MainActor.run { openChatID = cid }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
}

private struct ShareTrackToUserSheet: View {
    let track: CatalogTrack
    let accent: Color
    let isEnglish: Bool
    let isDarkMode: Bool
    let onDone: () -> Void

    @StateObject private var authService = AuthService.shared
    @State private var users: [BackendUserListItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            ZStack {
                (isDarkMode ? Color.black : Color(.systemGroupedBackground)).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text(isEnglish ? "Share to" : "Кому отправить")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 8)
                        .padding(.horizontal, 16)

                    if isLoading {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else if let e = errorMessage {
                        Spacer()
                        Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 16)
                        Spacer()
                    } else if users.isEmpty {
                        Spacer()
                        Text(isEnglish ? "No subscriptions yet" : "Пока нет подписок")
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        List {
                            ForEach(users) { u in
                                Button {
                                    Task { await send(to: u) }
                                } label: {
                                    HStack(spacing: 12) {
                                        if let url = URL(string: u.avatar_url), !u.avatar_url.isEmpty {
                                            AsyncImage(url: url) { img in
                                                img.resizable().scaledToFill()
                                            } placeholder: {
                                                Circle().fill(Color(.systemGray5))
                                            }
                                            .frame(width: 40, height: 40)
                                            .clipShape(Circle())
                                        } else {
                                            Circle().fill(Color(.systemGray5))
                                                .frame(width: 40, height: 40)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(u.name.isEmpty ? u.username : u.name)
                                                .font(.system(size: 15, weight: .semibold))
                                            if !u.username.isEmpty {
                                                Text("@\(u.username)")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                }
                                .disabled(isSending)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEnglish ? "Cancel" : "Отмена") { onDone() }
                }
            }
            .task { await loadSubscriptions() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func loadSubscriptions() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard let myID = authService.backendAccountSnapshot?.id else {
            await MainActor.run { errorMessage = isEnglish ? "Not signed in" : "Нужно войти" }
            return
        }
        do {
            let res = try await SphereAPIClient.shared.listUserSubscriptions(id: myID)
            switch res {
            case .hidden:
                await MainActor.run {
                    users = []
                    errorMessage = isEnglish ? "Subscriptions are hidden" : "Подписки скрыты"
                }
            case .users(let u):
                await MainActor.run { users = u; errorMessage = nil }
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func send(to u: BackendUserListItem) async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let chatID = try await SphereAPIClient.shared.openOrCreateDM(userID: u.id)
            let payload: [String: Any] = [
                "provider": track.provider,
                "id": track.id,
                "title": track.title,
                "artist": track.artist,
                "cover_url": track.coverURL ?? ""
            ]
            _ = try await SphereAPIClient.shared.sendTrackShare(chatID: chatID, payload: payload)
            onDone()
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
}

private struct DownloadedTracksListView: View {
    let tracks: [AppTrack]
    let accent: Color
    let mainBackground: Color
    let isEnglish: Bool
    var onPlayTrack: (AppTrack) -> Void
    var onDeleteTrack: (AppTrack) -> Void
    var body: some View {
        ZStack {
            mainBackground.ignoresSafeArea()
            if tracks.isEmpty {
                Text(isEnglish ? "No downloaded tracks" : "Нет скачанных треков").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(tracks) { track in
                        CompactTrackRow(track: track, accent: accent) { onPlayTrack(track) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { onDeleteTrack(track) } label: { Label(isEnglish ? "Delete" : "Удалить", systemImage: "trash") }
                            }
                    }
                }.listStyle(.plain)
            }
        }.navigationTitle(isEnglish ? "Downloaded tracks" : "Скачанные треки")
    }
}

// MARK: - Animated Cover Gradient Background

private struct AnimatedCoverGradientBackground: View {
    let accent: Color
    let isDarkMode: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [accent.opacity(0.5), .clear],
                center: phase ? .topLeading : .bottomTrailing,
                startRadius: 50,
                endRadius: 400
            )
            RadialGradient(
                colors: [accent.opacity(0.35), .clear],
                center: phase ? .bottomTrailing : .topLeading,
                startRadius: 30,
                endRadius: 350
            )
        }
        .opacity(isDarkMode ? 0.8 : 0.5)
        .animation(.easeInOut(duration: 7).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

#Preview {
    ContentView()
}
