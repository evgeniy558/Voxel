//
//  SphereWidget.swift
//  SphereWidget
//
//  Малый виджет (systemSmall): крупная обложка, отступы ~14 pt, Spherelogo справа сверху, текст снизу — как бекап «виджет».
//  App Group совпадает с WidgetShared / entitlements. Deployment 16+: на iOS 17+ — `.contentMarginsDisabled()`; на iOS 16 — без него.
//

import SwiftUI
import UIKit
import WidgetKit

private enum Bridge {
    static let timelineKind = "SphereWidget"
    static let appGroupId = "group.com.kolyapavlov.sphere"
    static let keyTrackId = "sphere_lastTrackId"
    static let keyTrackTitle = "sphere_lastTrackTitle"
    static let keyTrackArtist = "sphere_lastTrackArtist"
    static let keyBackgroundR = "sphere_widgetBgR"
    static let keyBackgroundG = "sphere_widgetBgG"
    static let keyBackgroundB = "sphere_widgetBgB"
    static let keyWidgetCoverSource = "sphere_widgetCoverSource"
    static let widgetCoverSourceEmbedded = "embedded"
    static let widgetCoverSourceNone = "none"
    static let coverFilename = "widget_cover.jpg"
    static let fallbackTint = (r: 0.42, g: 0.25, b: 0.93)
    /// Как в бекапе: не подгружать крошечный JPEG как обложку.
    static let legacyFakeCoverMaxBytes = 20_000
}

// MARK: - Модель (логика как в бекапе `виджет`)

private struct WidgetTrackModel {
    var hasDisplayableTrack: Bool
    var title: String
    var artist: String
    var cover: UIImage?
    var tintRGB: (Double, Double, Double)

    static let idle = WidgetTrackModel(
        hasDisplayableTrack: false,
        title: "Sphere",
        artist: "",
        cover: nil,
        tintRGB: Bridge.fallbackTint
    )

    /// Как в бекапе: id, title, artist и `widget_cover.jpg`; отображение без обязательного id.
    static func loadFromAppGroup() -> WidgetTrackModel {
        let defaults = UserDefaults(suiteName: Bridge.appGroupId)
        let trackId = defaults?.string(forKey: Bridge.keyTrackId) ?? ""
        let rawTitle = defaults?.string(forKey: Bridge.keyTrackTitle) ?? ""
        let rawArtist = defaults?.string(forKey: Bridge.keyTrackArtist) ?? ""
        let tint = readTintRGB(from: defaults)

        var cover: UIImage?
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Bridge.appGroupId) {
            let url = dir.appendingPathComponent(Bridge.coverFilename)
            let source = defaults?.string(forKey: Bridge.keyWidgetCoverSource)
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            let fileSize: Int = {
                guard fileExists,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let n = attrs[.size] as? NSNumber else { return 0 }
                return n.intValue
            }()
            let loadFile: Bool
            if let source {
                if source == Bridge.widgetCoverSourceEmbedded {
                    loadFile = fileExists && fileSize >= Bridge.legacyFakeCoverMaxBytes
                } else {
                    loadFile = false
                }
            } else {
                loadFile = fileSize > Bridge.legacyFakeCoverMaxBytes
            }
            if loadFile, let data = try? Data(contentsOf: url), !data.isEmpty, data.count < 12_000_000 {
                cover = UIImage(data: data)
            }
        }

        let hasText = !rawTitle.isEmpty || !rawArtist.isEmpty
        let hasId = !trackId.isEmpty
        guard hasText || hasId || cover != nil else { return .idle }

        let title = rawTitle.isEmpty ? "—" : rawTitle
        let artist = rawArtist
        return WidgetTrackModel(hasDisplayableTrack: true, title: title, artist: artist, cover: cover, tintRGB: tint)
    }

    private static func readTintRGB(from defaults: UserDefaults?) -> (Double, Double, Double) {
        guard let defaults else { return Bridge.fallbackTint }
        guard let r = plistNumber(defaults, Bridge.keyBackgroundR),
              let g = plistNumber(defaults, Bridge.keyBackgroundG),
              let b = plistNumber(defaults, Bridge.keyBackgroundB) else {
            return Bridge.fallbackTint
        }
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        let cr = clamp(r), cg = clamp(g), cb = clamp(b)
        let lum = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
        if lum < 0.02 { return Bridge.fallbackTint }
        return (cr, cg, cb)
    }

    private static func plistNumber(_ defaults: UserDefaults, _ key: String) -> Double? {
        guard let o = defaults.object(forKey: key) else { return nil }
        switch o {
        case let d as Double: return d
        case let f as Float: return Double(f)
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    func backgroundGradient() -> LinearGradient {
        let base = UIColor(red: CGFloat(tintRGB.0), green: CGFloat(tintRGB.1), blue: CGFloat(tintRGB.2), alpha: 1)
        let stops = base.sphereWidgetTwoStopRGB()
        return LinearGradient(
            colors: [
                Color(red: stops.0.r, green: stops.0.g, blue: stops.0.b),
                Color(red: stops.1.r, green: stops.1.g, blue: stops.1.b)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var tintColor: Color {
        Color(red: tintRGB.0, green: tintRGB.1, blue: tintRGB.2)
    }
}

private extension UIColor {
    func sphereWidgetTwoStopRGB() -> ((r: Double, g: Double, b: Double), (r: Double, g: Double, b: Double)) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            let br1 = min(0.62, max(0.18, b * 0.52 + 0.04))
            let br2 = max(0.09, b * 0.34 - 0.02)
            let u1 = UIColor(hue: h, saturation: min(1, s * 1.04), brightness: br1, alpha: 1)
            let u2 = UIColor(hue: h, saturation: min(1, s * 1.1), brightness: br2, alpha: 1)
            return (u1.rgbTuple(), u2.rgbTuple())
        }
        var w: CGFloat = 0
        if getWhite(&w, alpha: &a) {
            let u1 = UIColor(white: min(0.52, max(0.16, w * 0.48 + 0.05)), alpha: 1)
            let u2 = UIColor(white: max(0.08, w * 0.30 - 0.03), alpha: 1)
            return (u1.rgbTuple(), u2.rgbTuple())
        }
        return (rgbTuple(), rgbTuple())
    }

    func rgbTuple() -> (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return Bridge.fallbackTint }
        return (Double(r), Double(g), Double(b))
    }
}

// MARK: - Timeline

private struct Entry: TimelineEntry {
    let date: Date
    let model: WidgetTrackModel
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(
            date: Date(),
            model: WidgetTrackModel(
                hasDisplayableTrack: true,
                title: "Midnight Run",
                artist: "Artist",
                cover: nil,
                tintRGB: Bridge.fallbackTint
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), model: WidgetTrackModel.loadFromAppGroup()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), model: WidgetTrackModel.loadFromAppGroup())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

private final class WidgetExtensionBundleToken {}

private enum WidgetCatalogImage {
    private static let bundle = Bundle(for: WidgetExtensionBundleToken.self)
    private static let embeddedFolder = "EmbeddedLogos"

    private static func bundledPNGInFolder(_ name: String) -> UIImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: embeddedFolder) else { return nil }
        guard let img = UIImage(contentsOfFile: url.path), img.size.width > 0 else { return nil }
        return img
    }

    private static func bundledPNGAtRoot(_ name: String) -> UIImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png") else { return nil }
        guard let img = UIImage(contentsOfFile: url.path), img.size.width > 0 else { return nil }
        return img
    }

    @ViewBuilder
    static func spherelogo(size: CGFloat) -> some View {
        if UIImage(named: "WidgetSpherelogo", in: bundle, compatibleWith: nil) != nil {
            Image("WidgetSpherelogo", bundle: bundle)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundColor(.white)
        } else if let ui = bundledPNGAtRoot("Spherelogo") ?? bundledPNGInFolder("Spherelogo") {
            Image(uiImage: ui)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundColor(.white)
        } else {
            Color.clear
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    static func voxmusic(padding: CGFloat) -> some View {
        if UIImage(named: "WidgetVoxmusic", in: bundle, compatibleWith: nil) != nil {
            Image("WidgetVoxmusic", bundle: bundle)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(padding)
        } else if let ui = bundledPNGAtRoot("Voxmusic") ?? bundledPNGInFolder("Voxmusic") {
            Image(uiImage: ui)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(padding)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(padding)
                .accessibilityHidden(true)
        }
    }
}

private enum SmallWidgetLayout {
    /// Как в бекапе `виджет`: 12 pt (после `.contentMarginsDisabled()` на iOS 17+ визуально совпадает со старыми ОС).
    static let contentPadding: CGFloat = 12
    static let coverSideToWidgetMin: CGFloat = 0.98
    static let coverToTextMinGap: CGFloat = 1
    static let metadataBandHeight: CGFloat = 46
    static let titleToArtistGap: CGFloat = 2
    static let cornerRadius: CGFloat = 10
    static let logoMin: CGFloat = 18
    static let logoMax: CGFloat = 24
    static let voxmusicPlayerCoverReferenceSide: CGFloat = 320
    static let voxmusicPlayerCoverInset: CGFloat = 24

    static func voxmusicPlaceholderPadding(coverSide: CGFloat) -> CGFloat {
        max(3, coverSide * (voxmusicPlayerCoverInset / voxmusicPlayerCoverReferenceSide))
    }
}

// MARK: - Малый виджет

private struct SphereSmallWidgetView: View {
    let model: WidgetTrackModel
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        Group {
            if let url = tapURL {
                foreground.widgetURL(url)
            } else {
                foreground
            }
        }
        .modifier(WidgetBackgroundModifier(gradient: model.backgroundGradient()))
        .unredacted()
    }

    private var tapURL: URL? {
        if redactionReasons.contains(.placeholder) { return nil }
        return URL(string: "sphere://play")
    }

    @ViewBuilder
    private var foreground: some View {
        foregroundGeometry
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var foregroundGeometry: some View {
        GeometryReader { geo in
            let side = coverSide(widgetSize: geo.size)
            let logoSize = min(
                SmallWidgetLayout.logoMax,
                max(SmallWidgetLayout.logoMin, side * 0.13)
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    coverArtOnly(side: side)
                    Spacer(minLength: 4)
                    WidgetCatalogImage.spherelogo(size: logoSize)
                        .layoutPriority(1)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: SmallWidgetLayout.coverToTextMinGap)

                VStack(alignment: .leading, spacing: SmallWidgetLayout.titleToArtistGap) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !model.artist.isEmpty {
                        Text(model.artist)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.76))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(SmallWidgetLayout.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coverSide(widgetSize: CGSize) -> CGFloat {
        let w = max(widgetSize.width, 1)
        let h = max(widgetSize.height, 1)
        let pad = SmallWidgetLayout.contentPadding * 2
        let innerH = h - pad
        let innerW = w - pad
        let band = SmallWidgetLayout.metadataBandHeight + SmallWidgetLayout.coverToTextMinGap
        let verticalForCover = max(0, innerH - band)
        let fromReference = min(w, h) * SmallWidgetLayout.coverSideToWidgetMin
        let logoLane = SmallWidgetLayout.logoMax + 6 + 6 + 4
        let side = min(fromReference, verticalForCover, innerW - logoLane)
        return max(56, side)
    }

    private func coverArtOnly(side: CGFloat) -> some View {
        let voxPadding = SmallWidgetLayout.voxmusicPlaceholderPadding(coverSide: side)
        return Group {
            if let ui = model.cover {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(model.tintColor)
                    WidgetCatalogImage.voxmusic(padding: voxPadding)
                }
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: SmallWidgetLayout.cornerRadius, style: .continuous))
    }
}

private struct WidgetBackgroundModifier: ViewModifier {
    let gradient: LinearGradient

    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) {
                ContainerRelativeShape()
                    .fill(gradient)
            }
        } else {
            ZStack(alignment: .topLeading) {
                gradient
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// iOS 16: без API 17+.
private struct SphereHomeScreenWidgetLegacy: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Bridge.timelineKind, provider: Provider()) { entry in
            SphereSmallWidgetView(model: entry.model)
        }
        .configurationDisplayName("Sphere")
        .description("Просмотр последней воспроизводимой песни")
        .supportedFamilies([.systemSmall])
    }
}

/// iOS 17+: как раньше — `.contentMarginsDisabled()`.
@available(iOSApplicationExtension 17.0, *)
private struct SphereHomeScreenWidgetModern: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Bridge.timelineKind, provider: Provider()) { entry in
            SphereSmallWidgetView(model: entry.model)
        }
        .configurationDisplayName("Sphere")
        .description("Просмотр последней воспроизводимой песни")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

@main
struct SphereWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOSApplicationExtension 17.0, *) {
            return SphereHomeScreenWidgetModern()
        } else {
            return SphereHomeScreenWidgetLegacy()
        }
    }
}
