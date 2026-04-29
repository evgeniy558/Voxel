import Foundation
import Combine

@MainActor
final class DownloadsStore: ObservableObject {
    static let shared = DownloadsStore()

    struct DownloadedTrack: Codable, Equatable {
        let provider: String
        let id: String
        let title: String
        let artist: String
        let coverURL: String?
        let localRelativePath: String
        let sizeBytes: Int64
        let downloadedAt: Date
    }

    @Published private(set) var index: [String: DownloadedTrack] = [:] // key = "<provider>:<id>"
    @Published private(set) var inProgress: Set<String> = []

    private let api = SphereAPIClient.shared

    private init() {
        loadIndex()
    }

    private func key(provider: String, id: String) -> String { "\(provider):\(id)" }

    private var downloadsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("sphere-downloads", isDirectory: true)
    }

    private var indexURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("sphere-downloads-index.json")
    }

    func localFileURL(provider: String, id: String) -> URL? {
        let k = key(provider: provider, id: id)
        guard let e = index[k] else { return nil }
        return downloadsDir.appendingPathComponent(e.localRelativePath, isDirectory: false)
    }

    func isDownloaded(provider: String, id: String) -> Bool {
        localFileURL(provider: provider, id: id) != nil
    }

    func download(track: CatalogTrack) async throws {
        let k = key(provider: track.provider, id: track.id)
        if index[k] != nil { return }
        guard !inProgress.contains(k) else { return }
        inProgress.insert(k)
        defer { inProgress.remove(k) }

        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        let fileName = "\(track.provider)-\(track.id).mp3"
        let dest = downloadsDir.appendingPathComponent(fileName, isDirectory: false)

        let req = try api.makeDownloadRequest(provider: track.provider, id: track.id)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw SphereAPIError.http(status: http.statusCode, message: msg)
        }
        try data.write(to: dest, options: [.atomic])

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(data.count)

        let entry = DownloadedTrack(
            provider: track.provider,
            id: track.id,
            title: track.title,
            artist: track.artist,
            coverURL: track.coverURL,
            localRelativePath: fileName,
            sizeBytes: size,
            downloadedAt: Date()
        )
        index[k] = entry
        persistIndex()
    }

    func delete(provider: String, id: String) {
        let k = key(provider: provider, id: id)
        guard let e = index[k] else { return }
        let url = downloadsDir.appendingPathComponent(e.localRelativePath, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
        index.removeValue(forKey: k)
        persistIndex()
    }

    private func loadIndex() {
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode([String: DownloadedTrack].self, from: data)
            self.index = decoded
        } catch {
            self.index = [:]
        }
    }

    private func persistIndex() {
        do {
            let parent = indexURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(index)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            // ignore
        }
    }
}

import Foundation
import Combine
import SwiftUI

/// Реестр треков, скачанных пользователем для офлайн-воспроизведения.
///
/// Метаданные храним в JSON по адресу `Application Support/sphere-downloads/index.json`,
/// сами файлы (mp3) — в `Documents/sphere-downloads/<provider>-<id>.mp3`,
/// чтобы пользователь мог увидеть их в Files.app.
///
/// Сетевая загрузка (через `/tracks/{provider}/{id}/download`) подключается отдельно —
/// этот стор отвечает только за состояние и отображение пометок «скачано» в UI.
@MainActor
final class DownloadsStore: ObservableObject {
    static let shared = DownloadsStore()

    struct Entry: Codable, Equatable, Identifiable {
        let provider: String
        let trackID: String
        var title: String
        var artist: String
        var coverURL: String?
        var localFilename: String
        var sizeBytes: Int64
        var downloadedAt: Date

        enum CodingKeys: String, CodingKey {
            case provider
            case trackID = "track_id"
            case title, artist
            case coverURL = "cover_url"
            case localFilename = "local_filename"
            case sizeBytes = "size_bytes"
            case downloadedAt = "downloaded_at"
        }

        var compositeKey: String { "\(provider):\(trackID)" }
        var id: String { compositeKey }
    }

    @Published private(set) var entries: [Entry] = []

    private let indexURL: URL
    private let mediaDir: URL

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let metaDir = appSupport.appendingPathComponent("sphere-downloads", isDirectory: true)
        try? fm.createDirectory(at: metaDir, withIntermediateDirectories: true)
        self.indexURL = metaDir.appendingPathComponent("index.json")

        let docs = (try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let media = docs.appendingPathComponent("sphere-downloads", isDirectory: true)
        try? fm.createDirectory(at: media, withIntermediateDirectories: true)
        self.mediaDir = media

        load()
    }

    // MARK: - Queries

    /// Скачан ли трек данного провайдера с этим id (и файл реально существует).
    func isDownloaded(provider: String, id: String) -> Bool {
        guard let entry = entry(provider: provider, id: id) else { return false }
        return FileManager.default.fileExists(atPath: localFileURL(for: entry).path)
    }

    /// Локальный URL mp3-файла, если трек скачан и существует на диске.
    func localFileURL(provider: String, id: String) -> URL? {
        guard let entry = entry(provider: provider, id: id) else { return nil }
        let url = localFileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func entry(provider: String, id: String) -> Entry? {
        entries.first { $0.provider == provider && $0.trackID == id }
    }

    /// Полный путь к локальному mp3 для записи (даже если файла ещё нет на диске).
    func localFileURL(for entry: Entry) -> URL {
        mediaDir.appendingPathComponent(entry.localFilename)
    }

    /// Целевой путь для нового скачивания (используется логикой загрузки).
    func suggestedFileURL(provider: String, id: String) -> URL {
        mediaDir.appendingPathComponent(Self.makeFilename(provider: provider, id: id))
    }

    // MARK: - Mutation

    /// Регистрирует уже существующий локальный файл как скачанный трек.
    /// Если `fileURL != suggestedFileURL`, файл переносится в нашу директорию.
    @discardableResult
    func register(
        provider: String,
        id: String,
        title: String,
        artist: String,
        coverURL: String?,
        fileURL: URL,
        sizeBytes: Int64? = nil
    ) -> Entry? {
        let filename = Self.makeFilename(provider: provider, id: id)
        let target = mediaDir.appendingPathComponent(filename)
        let fm = FileManager.default
        if fileURL != target {
            try? fm.removeItem(at: target)
            do {
                try fm.moveItem(at: fileURL, to: target)
            } catch {
                return nil
            }
        }
        let resolvedSize: Int64
        if let s = sizeBytes {
            resolvedSize = s
        } else if let attrs = try? fm.attributesOfItem(atPath: target.path),
                  let n = attrs[.size] as? NSNumber {
            resolvedSize = n.int64Value
        } else {
            resolvedSize = 0
        }
        let entry = Entry(
            provider: provider,
            trackID: id,
            title: title,
            artist: artist,
            coverURL: coverURL,
            localFilename: filename,
            sizeBytes: resolvedSize,
            downloadedAt: Date()
        )
        if let i = entries.firstIndex(where: { $0.provider == provider && $0.trackID == id }) {
            entries[i] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        save()
        return entry
    }

    func remove(provider: String, id: String) {
        guard let i = entries.firstIndex(where: { $0.provider == provider && $0.trackID == id }) else { return }
        let url = localFileURL(for: entries[i])
        try? FileManager.default.removeItem(at: url)
        entries.remove(at: i)
        save()
    }

    /// Сверяет состояние записей с файловой системой и удаляет осиротевшие записи
    /// (метаданные есть, а mp3 пропал — например, после ручной чистки в Files.app).
    func reconcile() {
        let fm = FileManager.default
        let kept = entries.filter { fm.fileExists(atPath: localFileURL(for: $0).path) }
        if kept.count != entries.count {
            entries = kept
            save()
        }
    }

    // MARK: - Persistence

    private static func makeFilename(provider: String, id: String) -> String {
        let safe = "\(provider)-\(id)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safe).mp3"
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
