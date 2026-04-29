import SwiftUI

/// Normalizes provider URLs (Yandex `https://` + `//…`, protocol-relative `//…`) for `AsyncImage` / `URLSession`.
func catalogRemoteImageURL(_ raw: String?) -> URL? {
    guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    if s.hasPrefix("//") { s = "https:" + s }
    else if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
    s = s.replacingOccurrences(of: "https:////", with: "https://")
    s = s.replacingOccurrences(of: "http:////", with: "http://")
    return URL(string: s)
}

// MARK: - Service icon helper

/// Returns the Assets.xcassets image name for a provider string.
/// Falls back to SF Symbol "music.note" if asset is missing.
func serviceIconAssetName(for provider: String) -> String? {
    switch provider.lowercased() {
    case "spotify":       return "spotify icon"
    case "soundcloud":    return "soundcloud icon"
    case "youtube", "youtubemusic", "youtube_music", "ytmusic":
        return "youtube music icon"
    case "deezer":        return "deezer icon"
    case "vk", "vkmusic": return "vk music icon"
    case "yandex", "yandexmusic": return "yandex music icon"
    case "apple", "applemusic": return "apple music icon"
    default: return nil
    }
}

/// Small square service icon view used inside catalog cards.
struct ServiceIconBadge: View {
    let provider: String
    var size: CGFloat = 14

    var body: some View {
        if let name = serviceIconAssetName(for: provider),
           UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol(for: provider))
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(fallbackColor(for: provider))
                .frame(width: size, height: size)
        }
    }

    private func fallbackSymbol(for provider: String) -> String {
        switch provider.lowercased() {
        case "youtube", "youtubemusic", "youtube_music", "ytmusic":
            return "play.rectangle.fill"
        case "deezer": return "waveform.circle.fill"
        default: return "music.note"
        }
    }

    private func fallbackColor(for provider: String) -> Color {
        switch provider.lowercased() {
        case "youtube", "youtubemusic", "youtube_music", "ytmusic": return .red
        case "deezer": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Downloaded badge

/// Маленькая пометка «трек скачан для офлайна», вид как в Apple Music.
struct DownloadedBadge: View {
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color(red: 0.18, green: 0.78, blue: 0.45))
            .accessibilityLabel("Downloaded")
    }
}

// MARK: - Catalog Track Card (horizontal scroll item)

struct CatalogTrackCard: View {
    let track: CatalogTrack
    let accent: Color
    let isDarkMode: Bool
    let onTap: () -> Void
    var onArtistTap: (() -> Void)? = nil

    @ObservedObject private var downloads = DownloadsStore.shared

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: catalogRemoteImageURL(track.coverURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isDarkMode ? Color(white: 0.18) : Color(white: 0.88))
                            .overlay(ProgressView())
                    case .failure:
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isDarkMode ? Color(white: 0.18) : Color(white: 0.88))
                            .overlay(
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .font(.title2)
                            )
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if downloads.isDownloaded(provider: track.provider, id: track.id) {
                        DownloadedBadge(size: 16)
                            .padding(.top, 6)
                            .padding(.leading, 6)
                            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                    }
                }

                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDarkMode ? .white : .primary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)

                Group {
                    if let onArtistTap = onArtistTap {
                        Button(action: onArtistTap) {
                            Text(track.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 140, alignment: .leading)

                HStack(spacing: 4) {
                    ServiceIconBadge(provider: track.provider, size: 12)
                    Text(track.durationFormatted)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Catalog Album Card

struct CatalogAlbumCard: View {
    let album: CatalogAlbum
    let accent: Color
    let isDarkMode: Bool
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button { onTap?() } label: {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: catalogRemoteImageURL(album.coverURL)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDarkMode ? Color(white: 0.18) : Color(white: 0.88))
                        .overlay(ProgressView())
                case .failure:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDarkMode ? Color(white: 0.18) : Color(white: 0.88))
                        .overlay(
                            Image(systemName: "square.stack")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                        )
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(album.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDarkMode ? .white : .primary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Text(album.artist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                ServiceIconBadge(provider: album.provider, size: 12)
                if let count = album.tracks?.count, count > 0 {
                    Text("\(count) tracks")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)
        }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Catalog Artist Card (circle)

struct CatalogArtistCard: View {
    let artist: CatalogArtist
    let accent: Color
    let isDarkMode: Bool
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(spacing: 8) {
                AsyncImage(url: catalogRemoteImageURL(artist.imageURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        Circle()
                            .fill(isDarkMode ? Color(white: 0.18) : Color(white: 0.88))
                            .overlay(ProgressView())
                    case .failure:
                        Circle()
                            .fill(isDarkMode ? Color(white: 0.18) : Color(white: 0.88))
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                            )
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())

                Text(artist.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isDarkMode ? .white : .primary)
                    .lineLimit(1)
                    .frame(width: 80)

                HStack(spacing: 3) {
                    ServiceIconBadge(provider: artist.provider, size: 10)
                    if let f = artist.followers, f > 0 {
                        Text(formatFollowers(f))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 80)
            }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private func formatFollowers(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}

// MARK: - Album Detail

struct AlbumDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let album: CatalogAlbum
    let accent: Color
    let isDarkMode: Bool
    let isEnglish: Bool
    let isLoading: Bool
    let onPlayTrack: (CatalogTrack, [CatalogTrack]) -> Void
    let onPlayAll: ([CatalogTrack]) -> Void
    let onShuffle: ([CatalogTrack]) -> Void

    private var tracks: [CatalogTrack] { album.tracks ?? [] }
    private var albumLabel: String { isEnglish ? "Album" : "Альбом" }
    private var tracksLabel: String { isEnglish ? "Tracks" : "Треки" }
    @State private var isDownloading = false

    var body: some View {
        NavigationStack {
            ZStack {
                background
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        actionRow
                        trackList
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var background: some View {
        ZStack(alignment: .top) {
            (isDarkMode ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()
            if let url = URL(string: album.coverURL ?? "") {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(height: 320)
                            .blur(radius: 38)
                            .opacity(isDarkMode ? 0.42 : 0.22)
                            .clipped()
                    }
                }
                .ignoresSafeArea(edges: .top)
            }
            LinearGradient(
                colors: [
                    (isDarkMode ? Color.black.opacity(0.2) : Color.white.opacity(0.1)),
                    isDarkMode ? Color.black : Color(.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 0)
                AlbumDetailArtwork(urlString: album.coverURL, accent: accent)
                    .frame(width: 270, height: 270)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(isDarkMode ? .white : .primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if !album.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(isDarkMode ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            )
                        Text(album.artist)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isDarkMode ? .white.opacity(0.88) : .primary)
                            .lineLimit(1)
                    }
                }

                Text(albumLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            AlbumDetailArtwork(urlString: album.coverURL, accent: accent)
                .frame(width: 44, height: 44)

            Button {} label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                guard !tracks.isEmpty else { return }
                guard !isDownloading else { return }
                isDownloading = true
                Task { @MainActor in
                    defer { isDownloading = false }
                    for t in tracks {
                        try? await DownloadsStore.shared.download(track: t)
                    }
                }
            } label: {
                Image(systemName: isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isDownloading || tracks.isEmpty)

            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { onShuffle(tracks) } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
            }
            .disabled(tracks.isEmpty)

            Button { onPlayAll(tracks) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Color.green))
            }
            .disabled(tracks.isEmpty)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trackList: some View {
        VStack(alignment: .leading, spacing: 8) {
            // В макете со скрина заголовка "Tracks/Треки" нет — сразу список.

            if isLoading && tracks.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(accent)
                    Spacer()
                }
                .frame(height: 120)
            } else if tracks.isEmpty {
                Text(isEnglish ? "No tracks available" : "Треки недоступны")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.compositeKey) { index, track in
                    AlbumTrackRow(
                        index: index + 1,
                        track: track,
                        isDarkMode: isDarkMode,
                        onTap: { onPlayTrack(track, tracks) }
                    )
                }
            }
        }
    }
}

private struct AlbumDetailArtwork: View {
    let urlString: String?
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.24))
                .overlay(
                    Image(systemName: "square.stack")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 22, x: 0, y: 12)
    }
}

private struct AlbumTrackRow: View {
    let index: Int
    let track: CatalogTrack
    let isDarkMode: Bool
    let onTap: () -> Void

    @ObservedObject private var downloads = DownloadsStore.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isDarkMode ? .white : .primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if downloads.isDownloaded(provider: track.provider, id: track.id) {
                    DownloadedBadge(size: 16)
                }

                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
