import Foundation
import Combine
import SwiftUI

/// Shared in-memory mirror of `GET /favorites`.
/// Tracks-only for now — no album/artist favorites.
///
/// Two kinds of entries:
/// - catalog: provider != "local", providerItemID = provider's track id
/// - local: provider == "local", providerItemID = AppTrack.id.uuidString
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var items: [FavoriteItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private let api = SphereAPIClient.shared

    /// Pulls `/favorites` from the backend and replaces local state.
    func reload() async {
        guard api.isAuthenticated else {
            items = []
            return
        }
        isLoading = true
        lastError = nil
        do {
            items = try await api.listFavorites()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func isFavorite(provider: String, id: String) -> Bool {
        items.contains { $0.provider == provider && $0.providerItemID == id }
    }

    func isFavoriteLocal(uuid: String) -> Bool {
        items.contains { $0.provider == "local" && $0.providerItemID == uuid }
    }

    /// Toggle a catalog track (Spotify/YouTube/etc.) in/out of favorites.
    func toggle(track: CatalogTrack) async {
        guard api.isAuthenticated else { return }
        if let existing = items.first(where: { $0.provider == track.provider && $0.providerItemID == track.id }) {
            await remove(favoriteID: existing.id)
        } else {
            do {
                let fav = try await api.addFavorite(
                    itemType: "track",
                    provider: track.provider,
                    providerItemID: track.id,
                    title: track.title,
                    artistName: track.artist,
                    coverURL: track.coverURL
                )
                items.insert(fav, at: 0)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Toggle a locally-imported track in/out of favorites.
    func toggleLocal(uuid: String, title: String, artist: String) async {
        guard api.isAuthenticated else { return }
        if let existing = items.first(where: { $0.provider == "local" && $0.providerItemID == uuid }) {
            await remove(favoriteID: existing.id)
        } else {
            do {
                let fav = try await api.addFavorite(
                    itemType: "track",
                    provider: "local",
                    providerItemID: uuid,
                    title: title,
                    artistName: artist,
                    coverURL: nil
                )
                items.insert(fav, at: 0)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func remove(favoriteID: String) async {
        do {
            try await api.deleteFavorite(id: favoriteID)
            items.removeAll { $0.id == favoriteID }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
