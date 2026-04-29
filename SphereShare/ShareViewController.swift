//
//  ShareViewController.swift
//  SphereShareExtension
//
//  iOS 26+: системный SwiftUI sheet. iOS 16–25: желе-оверлей (JellyCardOverlay), без системного sheet.
//  Импорт только по «Добавить»; смахивание / крестик / тап по фону — отмена.
//

import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let kAppGroupId = "group.com.kolyapavlov.sphere"
private let kShareImportRelativePathKey = "sphere_shareImportRelativePath"
/// Высота sheet; синхронно с `presentationBackgroundInteraction`.
private let kShareSheetDetentFraction: CGFloat = 0.48
private let kShareCloseButtonSide: CGFloat = 40
/// Отступ крестика от правого края sheet.
private let kShareHeaderOuterMargin: CGFloat = 16
/// Одинаковый inset слева и справа у заголовка — иначе текст визуально уезжает влево.
private let kShareHeaderTitleHorizontalInset: CGFloat = kShareCloseButtonSide + kShareHeaderOuterMargin + 2
private let kShareHeaderTitleFontSize: CGFloat = 17
private let kShareJellyCardWidthFraction: CGFloat = 0.92
private let kShareImportDisplayTitleKey = "sphere_shareImportDisplayTitle"
private let kShareImportDisplayArtistKey = "sphere_shareImportDisplayArtist"

/// Вне класса VC: иначе при Swift 6 изоляции MainActor вызов из `loadFileRepresentation` даёт предупреждения/ошибки.
private func sphereShareResolveAppGroupContainerURL() -> URL? {
    if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupId) {
        return u
    }
    Thread.sleep(forTimeInterval: 0.12)
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupId)
}

// MARK: - Метаданные

private func extractAudioMetadata(from audioURL: URL, fallbackTitle: String, completion: @escaping (UIImage?, String, String) -> Void) {
    let asset = AVURLAsset(url: audioURL)
    asset.loadValuesAsynchronously(forKeys: ["metadata"]) {
        var imageData: Data?
        var title: String?
        var artist: String?
        var err: NSError?
        guard asset.statusOfValue(forKey: "metadata", error: &err) == .loaded else {
            DispatchQueue.main.async { completion(nil, fallbackTitle, "") }
            return
        }
        let metadata = asset.metadata
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
        let cover = imageData.flatMap { UIImage(data: $0) }
        let resolvedTitle = (title != nil && !title!.isEmpty) ? title! : fallbackTitle
        let resolvedArtist = artist ?? ""
        DispatchQueue.main.async {
            completion(cover, resolvedTitle, resolvedArtist)
        }
    }
}

// MARK: - Модель

private final class ShareImportViewModel: ObservableObject {
    enum State {
        case loading
        case ready(UIImage?, String, String)
        case loadFailed(String)
    }

    @Published var state: State = .loading
    var pendingRelativePath: String?
    /// Что показали в превью и что передаём в приложение (имя исходного файла или метаданные).
    var pendingDisplayTitle: String?
    var pendingDisplayArtist: String?
}

// MARK: - Стили кнопок (как в меню разработчика)

@available(iOS 26.0, *)
private struct ShareCloseGlassButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: kShareCloseButtonSide, height: kShareCloseButtonSide)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(accent).interactive(), in: Circle())
            .clipShape(Circle())
    }
}

@available(iOS 26.0, *)
private struct ShareAddToLibraryGlassCapsule: View {
    let accent: Color
    let action: () -> Void

    /// Тёмный «режим» листа: стекло с тинтом accent, кружок слева белый с иконкой accent.
    private var capsuleTint: Color { accent }
    private var textColor: Color { .white }
    private var circleFill: Color { .white }
    private var circleIconColor: Color { accent }

    var body: some View {
        Button(action: action) {
            Text("Добавить")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(alignment: .leading) {
                    ZStack {
                        Circle().fill(circleFill)
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(circleIconColor)
                    }
                    .frame(width: 32, height: 32)
                    .padding(.leading, 6)
                }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(capsuleTint).interactive(), in: Capsule())
        .foregroundStyle(textColor)
        .shadow(color: Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Корень: iOS 26 — sheet; ниже — желе-оверлей

private struct ShareExtensionRootView: View {
    @ObservedObject var model: ShareImportViewModel
    @State private var sheetPresented = true
    @State private var jellyPresented = true
    @State private var triggerJellyDismiss = false
    let onSheetDismissed: () -> Void
    let onAdd: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Color.clear
                    .ignoresSafeArea()
                    .sheet(isPresented: $sheetPresented, onDismiss: onSheetDismissed) {
                        ShareImportSheetContent(
                            model: model,
                            layout: .systemSheet,
                            onAdd: onAdd,
                            onCancel: { sheetPresented = false }
                        )
                        .presentationDetents([.fraction(kShareSheetDetentFraction)])
                        .presentationDragIndicator(.visible)
                        .applyShareSheetLiquidGlassBackground()
                        .applyPresentationBackgroundInteractionIfAvailable()
                    }
            } else {
                ZStack {
                    Color.clear.ignoresSafeArea()
                    if jellyPresented {
                        JellyCardOverlay(
                            isPresented: $jellyPresented,
                            triggerDismiss: $triggerJellyDismiss,
                            onDismissCompleted: {
                                triggerJellyDismiss = false
                                onSheetDismissed()
                            },
                            cardWidthFraction: kShareJellyCardWidthFraction,
                            fitsContentHeight: true,
                            dismissThreshold: 100,
                            dismissPredictedThreshold: 200,
                            dismissVelocityThreshold: 300
                        ) {
                            ShareImportSheetContent(
                                model: model,
                                layout: .jellyCard,
                                onAdd: {
                                    onAdd()
                                    triggerJellyDismiss = true
                                },
                                onCancel: { triggerJellyDismiss = true }
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                    }
                }
            }
        }
    }
}

private extension View {
    /// Фон самого sheet: iOS 26 — Liquid Glass как у карточек в приложении; раньше — материал.
    @ViewBuilder
    func applyShareSheetLiquidGlassBackground() -> some View {
        if #available(iOS 26.0, *) {
            let sheetShape = UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 28,
                style: .continuous
            )
            presentationBackground {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular.interactive(), in: sheetShape)
            }
            .presentationCornerRadius(28)
        } else if #available(iOS 16.4, *) {
            presentationBackground(.regularMaterial)
        } else {
            self
        }
    }

    @ViewBuilder
    func applyPresentationBackgroundInteractionIfAvailable() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackgroundInteraction(.enabled(upThrough: .fraction(kShareSheetDetentFraction)))
        } else {
            self
        }
    }

}

// MARK: - Содержимое sheet / желе-карточки

private enum ShareImportContentLayout {
    case systemSheet
    case jellyCard
}

private struct ShareImportSheetContent: View {
    @ObservedObject var model: ShareImportViewModel
    var layout: ShareImportContentLayout = .systemSheet
    var onAdd: () -> Void
    var onCancel: () -> Void

    private let purple = Color(red: 0.42, green: 0.25, blue: 0.93)

    var body: some View {
        Group {
            if layout == .jellyCard {
                VStack(spacing: 0) {
                    shareSheetHeaderBar(compact: true)
                    jellyStateGroup
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    shareSheetHeaderBar(compact: false)
                    sheetStateGroup
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private var jellyStateGroup: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
        case .loadFailed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Button("OK", action: onCancel)
                    .buttonStyle(.borderedProminent)
                    .tint(purple)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        case .ready(let image, let title, let artist):
            jellyReadyContent(image: image, title: title, artist: artist)
        }
    }

    @ViewBuilder
    private var sheetStateGroup: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            case .loadFailed(let message):
                VStack(spacing: 16) {
                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    Button("OK", action: onCancel)
                        .buttonStyle(.borderedProminent)
                        .tint(purple)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding(.vertical, 8)
            case .ready(let image, let title, let artist):
                sheetReadyScroll(image: image, title: title, artist: artist)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func jellyReadyContent(image: UIImage?, title: String, artist: String) -> some View {
        VStack(spacing: 0) {
            artworkBlock(image: image)
                .padding(.top, 2)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Text(artist.isEmpty ? "\u{00A0}" : artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            addButtonLegacy
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func sheetReadyScroll(image: UIImage?, title: String, artist: String) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                artworkBlock(image: image)
                    .padding(.top, 4)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                Text(artist.isEmpty ? "\u{00A0}" : artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                Group {
                    if #available(iOS 26.0, *) {
                        ShareAddToLibraryGlassCapsule(accent: purple, action: onAdd)
                            .padding(.bottom, 8)
                    } else {
                        addButtonLegacy
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
        }
    }

    /// Симметричный отступ у заголовка; `compact` — плотнее для желе-карточки по высоте контента.
    private func shareSheetHeaderBar(compact: Bool) -> some View {
        let titleVPad: CGFloat = compact ? 6 : 12
        let outerTop: CGFloat = compact ? 4 : 10
        let outerBottom: CGFloat = compact ? 4 : 8
        return ZStack(alignment: .top) {
            Text("Добавить в библиотеку")
                .font(.system(size: kShareHeaderTitleFontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .padding(.vertical, titleVPad)
                .padding(.horizontal, kShareHeaderTitleHorizontalInset)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                Spacer()
                Group {
                    if #available(iOS 26.0, *) {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(ShareCloseGlassButtonStyle(accent: purple))
                    } else {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: kShareCloseButtonSide, height: kShareCloseButtonSide)
                                .background(purple, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, kShareHeaderOuterMargin)
            }
        }
        .padding(.top, outerTop)
        .padding(.bottom, outerBottom)
    }

    private var addButtonLegacy: some View {
        Button(action: onAdd) {
            Text("Добавить")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(alignment: .leading) {
                    ZStack {
                        Circle().fill(Color.white)
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(purple)
                    }
                    .frame(width: 32, height: 32)
                    .padding(.leading, 6)
                }
        }
        .buttonStyle(.plain)
        .background(purple, in: Capsule())
        .foregroundStyle(.white)
        .shadow(color: Color.black.opacity(0.20), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private func artworkBlock(image: UIImage?) -> some View {
        let side: CGFloat = 132
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    purple
                    if let ui = UIImage(named: "Voxmusic", in: .main, compatibleWith: nil) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .padding(side * 0.18)
                    } else {
                        Text("voxmusic")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - UIViewController

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareImportViewModel()
    private var started = false
    private var didConfirmAdd = false
    private var didCompleteExtension = false
    private var hostingController: UIViewController?

    /// Система (особенно iOS 26) может подставлять непрозрачный root — иначе виден чёрный/белый «слой» за SwiftUI sheet.
    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        v.isOpaque = false
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false

        let root = ShareExtensionRootView(
            model: model,
            onSheetDismissed: { [weak self] in self?.handleSheetDismissed() },
            onAdd: { [weak self] in self?.confirmAdd() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        hostingController = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        clearExtensionChromeIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        clearExtensionChromeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.clearExtensionChromeIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.clearExtensionChromeIfNeeded()
        }
        guard !started else { return }
        started = true
        beginShareFlow()
    }

    private func clearExtensionChromeIfNeeded() {
        view.window?.backgroundColor = .clear
        view.window?.isOpaque = false
        stripSystemBackdropBehindExtension()
    }

    /// Убирает лишнее «окно»/подложку: контейнеры выше нашего VC на iOS 26 часто остаются непрозрачными.
    private func stripSystemBackdropBehindExtension() {
        var v: UIView? = view
        while let node = v {
            node.backgroundColor = .clear
            node.isOpaque = false
            v = node.superview
        }
        guard let window = view.window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        // Отдельный системный dimming-слой иногда сосед с иерархией расширения, а не предок.
        if let superv = view.superview {
            for sub in superv.subviews where sub !== view {
                let name = NSStringFromClass(type(of: sub))
                if name.contains("Dimming") {
                    sub.isHidden = true
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        clearExtensionChromeIfNeeded()
    }

    private func handleSheetDismissed() {
        guard !didCompleteExtension else { return }
        removePendingInboxFile()
        model.pendingRelativePath = nil
        finish()
    }

    private func beginShareFlow() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            model.state = .loadFailed("Нет данных для отправки")
            return
        }
        for item in items {
            guard let providers = item.attachments else { continue }
            for provider in providers {
                if tryLoadAudio(provider: provider) { return }
            }
        }
        model.state = .loadFailed("Не удалось получить аудиофайл")
    }

    private func tryLoadAudio(provider: NSItemProvider) -> Bool {
        let types: [UTType] = [.mp3, .mpeg4Audio, .audio]
        for ut in types where provider.hasItemConformingToTypeIdentifier(ut.identifier) {
            _ = provider.loadFileRepresentation(for: ut) { [weak self] tempURL, _, error in
                guard let self else { return }
                guard let tempURL, error == nil else {
                    DispatchQueue.main.async {
                        self.model.state = .loadFailed("Не удалось прочитать файл")
                    }
                    return
                }
                let originalStem = tempURL.deletingPathExtension().lastPathComponent
                let accessing = tempURL.startAccessingSecurityScopedResource()
                defer { if accessing { tempURL.stopAccessingSecurityScopedResource() } }
                let container = sphereShareResolveAppGroupContainerURL()
                guard let container else {
                    DispatchQueue.main.async { self.model.state = .loadFailed("Нет доступа к App Group. Убедитесь, что у приложения и расширения «Поделиться» включена одна и та же группа в Signing & Capabilities.") }
                    return
                }
                let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    let ext = tempURL.pathExtension.isEmpty ? "mp3" : tempURL.pathExtension
                    let name = "share_\(UUID().uuidString).\(ext)"
                    let dest = inbox.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: tempURL, to: dest)
                    let rel = "ShareInbox/\(name)"
                    extractAudioMetadata(from: dest, fallbackTitle: originalStem) { cover, title, artist in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.model.pendingRelativePath = rel
                            self.model.pendingDisplayTitle = title
                            self.model.pendingDisplayArtist = artist
                            self.model.state = .ready(cover, title, artist)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.model.state = .loadFailed(error.localizedDescription)
                    }
                }
            }
            return true
        }
        return false
    }

    private func confirmAdd() {
        guard !didConfirmAdd else { return }
        guard let rel = model.pendingRelativePath else {
            finish()
            return
        }
        didConfirmAdd = true
        if let defaults = UserDefaults(suiteName: kAppGroupId) {
            defaults.set(rel, forKey: kShareImportRelativePathKey)
            if let t = model.pendingDisplayTitle, !t.isEmpty {
                defaults.set(t, forKey: kShareImportDisplayTitleKey)
            }
            if let a = model.pendingDisplayArtist, !a.isEmpty {
                defaults.set(a, forKey: kShareImportDisplayArtistKey)
            }
            defaults.synchronize()
        }
        guard let url = URL(string: "sphere://import-shared") else {
            finish()
            return
        }
        extensionContext?.open(url) { _ in
            self.finish()
        }
    }

    private func removePendingInboxFile() {
        guard let rel = model.pendingRelativePath,
              let container = sphereShareResolveAppGroupContainerURL() else { return }
        let u = container.appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: u)
    }

    private func finish() {
        guard !didCompleteExtension else { return }
        didCompleteExtension = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
