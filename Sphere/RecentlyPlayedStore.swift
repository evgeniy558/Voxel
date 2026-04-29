import Foundation
import Combine

@MainActor
final class RecentlyPlayedStore: ObservableObject {
    static let shared = RecentlyPlayedStore()

    struct Item: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case local, catalog }
        let id: String
        let kind: Kind
        let title: String
        let artist: String
        let coverURL: String?
        var playedAt: Date
    }

    @Published private(set) var items: [Item] = []

    private let storageKey = "sphereRecentlyPlayed.v1"
    private let limit = 20
    private let defaults = UserDefaults.standard

    init() { load() }

    func recordLocal(id: UUID, title: String, artist: String, coverURL: String? = nil) {
        upsert(Item(
            id: "local:\(id.uuidString)",
            kind: .local,
            title: title,
            artist: artist,
            coverURL: coverURL,
            playedAt: Date()
        ))
    }

    func recordCatalog(provider: String, providerId: String, title: String, artist: String, coverURL: String?) {
        upsert(Item(
            id: "\(provider):\(providerId)",
            kind: .catalog,
            title: title,
            artist: artist,
            coverURL: coverURL,
            playedAt: Date()
        ))
    }

    /// Unique artist names in recency order (most recent first).
    func uniqueArtists() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let name = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out
    }

    func coverURL(forArtist name: String) -> String? {
        items.first { $0.artist == name && $0.coverURL != nil }?.coverURL
    }

    private func upsert(_ item: Item) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
