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

        let lossless = UserDefaults.standard.bool(forKey: "sphereStreamLossless")
        let req = try api.makeDownloadRequest(provider: track.provider, id: track.id, lossless: lossless)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw SphereAPIError.http(status: http.statusCode, message: msg)
        }

        // Pick extension from server-reported content type so lossless tracks
        // are saved as .flac and play back natively in AVPlayer.
        let contentType = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let ext: String
        if contentType.contains("flac") {
            ext = "flac"
        } else if contentType.contains("wav") {
            ext = "wav"
        } else {
            ext = "mp3"
        }
        let fileName = "\(track.provider)-\(track.id).\(ext)"
        let dest = downloadsDir.appendingPathComponent(fileName, isDirectory: false)
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
