import Foundation

// MARK: - Unified catalog models for Sphere Go backend

/// A catalog track from any provider (spotify, youtube, soundcloud, vk, yandex, deezer).
struct CatalogTrack: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let provider: String
    let title: String
    let artist: String
    let album: String?
    let coverURL: String?
    let duration: Int            // seconds
    let streamURL: String?
    let previewURL: String?
    let clipURL: String?
    let genres: [String]?
    let playCount: Int64?

    enum CodingKeys: String, CodingKey {
        case id, provider, title, artist, album, genres
        case coverURL = "cover_url"
        case duration
        case streamURL = "stream_url"
        case previewURL = "preview_url"
        case clipURL = "clip_url"
        case playCount = "play_count"
    }

    var durationFormatted: String {
        let s = max(duration, 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Composite key for duplication checks: "<provider>:<id>".
    var compositeKey: String { "\(provider):\(id)" }
}

/// A catalog artist. Returned from `/artists/{provider}/{id}` or `/artists/unified/{name}`.
struct CatalogArtist: Identifiable, Codable, Equatable {
    let id: String
    let provider: String
    let name: String
    let imageURL: String?
    let monthlyListeners: Int64?
    let followers: Int64?
    let genres: [String]?
    let tracks: [CatalogTrack]?
    let albums: [CatalogAlbum]?

    enum CodingKeys: String, CodingKey {
        case id, provider, name, tracks, followers, genres, albums
        case imageURL = "image_url"
        case monthlyListeners = "monthly_listeners"
    }

    init(placeholder name: String) {
        self.id = "placeholder"; self.provider = ""; self.name = name
        self.imageURL = nil; self.monthlyListeners = nil; self.followers = nil
        self.genres = nil; self.tracks = nil; self.albums = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        name = try c.decode(String.self, forKey: .name)
        imageURL = try? c.decode(String.self, forKey: .imageURL)
        monthlyListeners = try? c.decode(Int64.self, forKey: .monthlyListeners)
        followers = try? c.decode(Int64.self, forKey: .followers)
        genres = try? c.decode([String].self, forKey: .genres)
        tracks = try? c.decode([CatalogTrack].self, forKey: .tracks)
        albums = try? c.decode([CatalogAlbum].self, forKey: .albums)
    }
}

// MARK: - Artist profile sheet (stable identity while loading unified artist)

struct ArtistSheetItem: Identifiable, Equatable {
    /// Stable per search query so `.sheet(item:)` does not dismiss when the loaded `CatalogArtist` replaces the placeholder.
    let id: String
    var artist: CatalogArtist

    static func stableKey(forArtistName name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(name: String, artist: CatalogArtist) {
        self.id = Self.stableKey(forArtistName: name)
        self.artist = artist
    }
}

struct CatalogAlbum: Identifiable, Codable, Equatable {
    let id: String
    let provider: String
    let title: String
    let artist: String
    let coverURL: String?
    let tracks: [CatalogTrack]?

    enum CodingKeys: String, CodingKey {
        case id, provider, title, artist, tracks
        case coverURL = "cover_url"
    }
}

struct CatalogPlaylist: Identifiable, Codable, Equatable {
    let id: String
    let provider: String
    let title: String
    let coverURL: String?
    let tracks: [CatalogTrack]?

    enum CodingKeys: String, CodingKey {
        case id, provider, title, tracks
        case coverURL = "cover_url"
    }
}

struct LyricsResponse: Codable {
    let trackId: String
    let provider: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case provider
        case text
    }
}

struct SearchResults: Codable {
    let tracks: [CatalogTrack]
    let artists: [CatalogArtist]
    let albums: [CatalogAlbum]
    let playlists: [CatalogPlaylist]

    static let empty = SearchResults(tracks: [], artists: [], albums: [], playlists: [])

    init(tracks: [CatalogTrack] = [], artists: [CatalogArtist] = [], albums: [CatalogAlbum] = [], playlists: [CatalogPlaylist] = []) {
        self.tracks = tracks; self.artists = artists; self.albums = albums; self.playlists = playlists
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = (try? c.decode([CatalogTrack].self, forKey: .tracks)) ?? []
        artists = (try? c.decode([CatalogArtist].self, forKey: .artists)) ?? []
        albums = (try? c.decode([CatalogAlbum].self, forKey: .albums)) ?? []
        playlists = (try? c.decode([CatalogPlaylist].self, forKey: .playlists)) ?? []
    }
}

// MARK: - Recommendations

struct RecommendationsResponse: Codable {
    let tracks: [CatalogTrack]
    let albums: [CatalogAlbum]
    let artists: [CatalogArtist]

    static let empty = RecommendationsResponse(tracks: [], albums: [], artists: [])

    init(tracks: [CatalogTrack] = [], albums: [CatalogAlbum] = [], artists: [CatalogArtist] = []) {
        self.tracks = tracks; self.albums = albums; self.artists = artists
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = (try? c.decode([CatalogTrack].self, forKey: .tracks)) ?? []
        albums = (try? c.decode([CatalogAlbum].self, forKey: .albums)) ?? []
        artists = (try? c.decode([CatalogArtist].self, forKey: .artists)) ?? []
    }
}

// MARK: - Favorites

/// One server-side favorite. `provider == "local"` means a device-stored AppTrack,
/// `providerItemID` is the AppTrack uuid string in that case.
struct FavoriteItem: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let itemType: String
    let provider: String
    let providerItemID: String
    let title: String
    let artistName: String
    let coverURL: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case itemType = "item_type"
        case provider
        case providerItemID = "provider_item_id"
        case title
        case artistName = "artist_name"
        case coverURL = "cover_url"
        case createdAt = "created_at"
    }
}

// MARK: - Lyrics by title+artist

struct LyricsByNameResponse: Codable {
    let title: String
    let artist: String
    let text: String
}

struct StreamURLResponse: Codable {
    let streamURL: String

    enum CodingKeys: String, CodingKey {
        case streamURL = "stream_url"
    }
}

// MARK: - Comments

struct TrackComment: Identifiable, Codable {
    let id: String
    let trackProvider: String?
    let trackId: String?
    let userId: String?
    let userName: String
    let userAvatarUrl: String?
    let text: String
    let parentId: String?
    let likes: Int
    let dislikes: Int
    let createdAt: String
    let source: String
    var replies: [TrackComment]?

    enum CodingKeys: String, CodingKey {
        case id
        case trackProvider = "track_provider"
        case trackId = "track_id"
        case userId = "user_id"
        case userName = "user_name"
        case userAvatarUrl = "user_avatar_url"
        case text
        case parentId = "parent_id"
        case likes, dislikes
        case createdAt = "created_at"
        case source, replies
    }

    var timeAgo: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: createdAt) else { return createdAt }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

// MARK: - History

struct HistoryEntry: Identifiable, Codable {
    let id: String
    let provider: String
    let trackId: String
    let title: String
    let artist: String
    let listenedAt: String

    enum CodingKeys: String, CodingKey {
        case id, provider, title, artist
        case trackId = "track_id"
        case listenedAt = "listened_at"
    }
}

// MARK: - Preferences

struct UserPreferences: Codable {
    let selectedArtists: [String]
    let selectedGenres: [String]
    let onboardingCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case selectedArtists = "selected_artists"
        case selectedGenres = "selected_genres"
        case onboardingCompleted = "onboarding_completed"
    }

    /// Go's `json.Marshal` encodes `nil` slices as JSON `null`; `[String]` would fail to decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedArtists = (try? c.decodeIfPresent([String].self, forKey: .selectedArtists)) ?? []
        selectedGenres = (try? c.decodeIfPresent([String].self, forKey: .selectedGenres)) ?? []
        onboardingCompleted = (try? c.decode(Bool.self, forKey: .onboardingCompleted)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedArtists, forKey: .selectedArtists)
        try c.encode(selectedGenres, forKey: .selectedGenres)
        try c.encode(onboardingCompleted, forKey: .onboardingCompleted)
    }
}

// MARK: - Auth

struct BackendUser: Codable, Equatable {
    let id: String
    let email: String
    let username: String?
    let name: String
    let avatarUrl: String?
    /// Extended fields from Go `users` (optional for older responses).
    let isVerified: Bool
    let badgeText: String
    let badgeColor: String
    let isAdmin: Bool
    let banned: Bool
    let hideSubscriptions: Bool
    let messagesMutualOnly: Bool
    let privateProfile: Bool
    let totpEnabled: Bool
    let email2FAEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, email, username, name
        case avatarUrl = "avatar_url"
        case isVerified = "is_verified"
        case badgeText = "badge_text"
        case badgeColor = "badge_color"
        case isAdmin = "is_admin"
        case banned
        case hideSubscriptions = "hide_subscriptions"
        case messagesMutualOnly = "messages_mutual_only"
        case privateProfile = "private_profile"
        case totpEnabled = "totp_enabled"
        case email2FAEnabled = "email_2fa_enabled"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        name = try c.decode(String.self, forKey: .name)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        isVerified = try c.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
        badgeText = try c.decodeIfPresent(String.self, forKey: .badgeText) ?? ""
        badgeColor = try c.decodeIfPresent(String.self, forKey: .badgeColor) ?? ""
        isAdmin = try c.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
        banned = try c.decodeIfPresent(Bool.self, forKey: .banned) ?? false
        hideSubscriptions = try c.decodeIfPresent(Bool.self, forKey: .hideSubscriptions) ?? false
        messagesMutualOnly = try c.decodeIfPresent(Bool.self, forKey: .messagesMutualOnly) ?? false
        privateProfile = try c.decodeIfPresent(Bool.self, forKey: .privateProfile) ?? false
        totpEnabled = try c.decodeIfPresent(Bool.self, forKey: .totpEnabled) ?? false
        email2FAEnabled = try c.decodeIfPresent(Bool.self, forKey: .email2FAEnabled) ?? false
    }
}

struct AuthResponse: Codable {
    let token: String
    let user: BackendUser
}
