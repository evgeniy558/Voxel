//
//  WidgetShared.swift
//  Sphere
//
//  Данные для виджета: последний воспроизведённый трек в App Group.
//

import CoreImage
import Foundation
import UIKit
import WidgetKit

extension Notification.Name {
    /// Основное приложение должно забрать файл из App Group (Share Extension).
    static let sphereShareImportRequested = Notification.Name("sphereShareImportRequested")
}

enum WidgetShared {
    static let appGroupId = "group.com.kolyapavlov.sphere"

    static var sharedUserDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    /// Ключи в shared UserDefaults
    static let keyTrackId = "sphere_lastTrackId"
    static let keyTrackTitle = "sphere_lastTrackTitle"
    static let keyTrackArtist = "sphere_lastTrackArtist"
    static let keyTrackPathComponent = "sphere_lastTrackPathComponent"
    static let keyOpenPlayFromWidget = "sphere_openPlayFromWidget"
    /// Градиент фона малого виджета (как в бекапе `виджет`)
    static let keyWidgetBgR = "sphere_widgetBgR"
    static let keyWidgetBgG = "sphere_widgetBgG"
    static let keyWidgetBgB = "sphere_widgetBgB"
    static let keyWidgetCoverSource = "sphere_widgetCoverSource"
    /// Относительный путь в контейнере группы (ShareInbox/...) после «Поделиться» в Sphere.
    static let keyShareImportRelativePath = "sphere_shareImportRelativePath"
    /// Заголовок/исполнитель с превью расширения (имя исходного файла или метаданные), чтобы в библиотеке не было «imported_…».
    static let keyShareImportDisplayTitle = "sphere_shareImportDisplayTitle"
    static let keyShareImportDisplayArtist = "sphere_shareImportDisplayArtist"
    private static let widgetCoverSourceEmbedded = "embedded"
    private static let widgetCoverSourceNone = "none"

    /// Сохранить последний воспроизведённый трек и копировать обложку в контейнер App Group для виджета
    static func saveLastPlayedTrack(id: String, title: String?, artist: String?, pathComponent: String, coverImage: UIImage?) {
        guard let defaults = sharedUserDefaults, let container = appGroupContainerURL else { return }
        defaults.set(id, forKey: keyTrackId)
        defaults.set(title ?? "", forKey: keyTrackTitle)
        defaults.set(artist ?? "", forKey: keyTrackArtist)
        defaults.set(pathComponent, forKey: keyTrackPathComponent)
        defaults.synchronize()

        let coverURL = container.appendingPathComponent("widget_cover.jpg")

        if let cover = coverImage, let data = cover.jpegData(compressionQuality: 0.85) {
            try? data.write(to: coverURL)
            defaults.set(widgetCoverSourceEmbedded, forKey: keyWidgetCoverSource)
            if let rgb = averageRGB(from: cover) {
                defaults.set(rgb.r, forKey: keyWidgetBgR)
                defaults.set(rgb.g, forKey: keyWidgetBgG)
                defaults.set(rgb.b, forKey: keyWidgetBgB)
            }
        } else {
            defaults.set(widgetCoverSourceNone, forKey: keyWidgetCoverSource)
            try? FileManager.default.removeItem(at: coverURL)
            defaults.removeObject(forKey: keyWidgetBgR)
            defaults.removeObject(forKey: keyWidgetBgG)
            defaults.removeObject(forKey: keyWidgetBgB)
        }
        defaults.synchronize()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func averageRGB(from image: UIImage) -> (r: Double, g: Double, b: Double)? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }
        let filter = CIFilter(name: "CIAreaAverage")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height), forKey: kCIInputExtentKey)
        guard let output = filter?.outputImage else { return nil }
        let context = CIContext()
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(bitmap[0]) / 255, Double(bitmap[1]) / 255, Double(bitmap[2]) / 255)
    }

    /// Данные последнего трека для виджета (только чтение)
    struct LastTrackInfo {
        let trackId: String
        let title: String
        let artist: String
        let pathComponent: String
        let coverImage: UIImage?

        static func load() -> LastTrackInfo? {
            guard let defaults = sharedUserDefaults,
                  let id = defaults.string(forKey: keyTrackId), !id.isEmpty else { return nil }
            let title = defaults.string(forKey: keyTrackTitle) ?? ""
            let artist = defaults.string(forKey: keyTrackArtist) ?? ""
            let pathComponent = defaults.string(forKey: keyTrackPathComponent) ?? ""
            var cover: UIImage?
            if let container = appGroupContainerURL {
                let coverURL = container.appendingPathComponent("widget_cover.jpg")
                if let data = try? Data(contentsOf: coverURL) {
                    cover = UIImage(data: data)
                }
            }
            return LastTrackInfo(trackId: id, title: title, artist: artist, pathComponent: pathComponent, coverImage: cover)
        }
    }
}
