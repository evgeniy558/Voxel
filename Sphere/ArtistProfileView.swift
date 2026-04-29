import SwiftUI

/// Artist profile screen. Loads the unified artist (tracks merged across all providers)
/// and lets the user tap a track to play it. Opened as a sheet from `homeTab`.
///
/// Apple Music iOS 26.4 hero layout: large square cover on blurred/gradient background,
/// artist name in 32pt bold, Play + Shuffle capsule buttons, stats + tracks below.
struct ArtistProfileView: View {
    let artist: CatalogArtist
    let accent: Color
    let isDarkMode: Bool
    let isEnglish: Bool
    let onPlayTrack: (CatalogTrack, [CatalogTrack]) -> Void

    @Environment(\.dismiss) private var dismiss
    private let apiClient = SphereAPIClient.shared
    @State private var unified: CatalogArtist?
    @State private var isLoading = false
    @State private var loadError: String?

    private var displayArtist: CatalogArtist { unified ?? artist }
    private var tracks: [CatalogTrack] { displayArtist.tracks ?? [] }
    private var albums: [CatalogAlbum] { displayArtist.albums ?? [] }

    private var isPlaceholder: Bool { artist.id == "placeholder" }

    var body: some View {
        NavigationStack {
            Group {
                if isPlaceholder && unified == nil {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView().controlSize(.large)
                        Text(artist.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(contentBackground.ignoresSafeArea())
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            heroSection
                            contentSection
                        }
                    }
                    .background(contentBackground.ignoresSafeArea())
                }
            }
            .navigationTitle(displayArtist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEnglish ? "Done" : "Готово") { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
        }
        .task { await loadUnified() }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            blurredBackdrop
            heroForeground
        }
        .frame(maxWidth: .infinity)
    }

    private var blurredBackdrop: some View {
        GeometryReader { proxy in
            AsyncImage(url: catalogRemoteImageURL(displayArtist.imageURL)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle().fill(isDarkMode ? Color(white: 0.12) : Color(white: 0.85))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .blur(radius: 50)
            .scaleEffect(1.25)
            .overlay(
                LinearGradient(
                    colors: [
                        .clear,
                        (isDarkMode ? Color.black : Color(.systemBackground)).opacity(0.35),
                        (isDarkMode ? Color.black : Color(.systemBackground)),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(height: 520)
    }

    private var heroForeground: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)

            AsyncImage(url: catalogRemoteImageURL(displayArtist.imageURL)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(isDarkMode ? Color(white: 0.18) : Color(white: 0.9))
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 14)

            Text(displayArtist.name)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(isDarkMode ? .white : .primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            playButtons
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 24)
    }

    private var playButtons: some View {
        HStack(spacing: 12) {
            Button {
                if let first = tracks.first { onPlayTrack(first, tracks) }
            } label: {
                Label(isEnglish ? "Play" : "Слушать", systemImage: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray5), in: Capsule())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            Button {
                if let pick = tracks.randomElement() { onPlayTrack(pick, tracks.shuffled()) }
            } label: {
                Label(isEnglish ? "Shuffle" : "Перемешать", systemImage: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray5), in: Capsule())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
        }
    }

    // MARK: - Content

    private var contentBackground: Color {
        isDarkMode ? Color.black : Color(.systemBackground)
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !statsItems.isEmpty {
                stats
            }
            if !albums.isEmpty {
                popularReleasesSection
            }
            tracksSection
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var popularReleasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isEnglish ? "Popular releases" : "Популярные релизы")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isDarkMode ? .white : .primary)
                Spacer()
                NavigationLink {
                    ArtistDiscographyView(albums: albums, isEnglish: isEnglish, isDarkMode: isDarkMode)
                } label: {
                    Text(isEnglish ? "Open discography" : "Открыть дискографию")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(isDarkMode ? 0.08 : 0.06)))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(albums.prefix(12)) { al in
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: catalogRemoteImageURL(al.coverURL)) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().scaledToFill()
                                default:
                                    Rectangle().fill(Color.white.opacity(isDarkMode ? 0.08 : 0.06))
                                }
                            }
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Text(al.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isDarkMode ? .white : .primary)
                                .lineLimit(1)
                            Text(isEnglish ? "Album" : "Альбом")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 120, alignment: .leading)
                    }
                }
            }
        }
    }

    private var statsItems: [(value: String, label: String)] {
        var out: [(String, String)] = []
        if let listeners = displayArtist.monthlyListeners, listeners > 0 {
            out.append((formatNumber(listeners), isEnglish ? "Monthly listeners" : "Слушателей в месяц"))
        }
        if let followers = displayArtist.followers, followers > 0 {
            out.append((formatNumber(followers), isEnglish ? "Followers" : "Подписчиков"))
        }
        return out
    }

    private var stats: some View {
        HStack(spacing: 24) {
            ForEach(statsItems.indices, id: \.self) { idx in
                let item = statsItems[idx]
                VStack(spacing: 2) {
                    Text(item.value)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isDarkMode ? .white : .primary)
                    Text(item.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isEnglish ? "Tracks" : "Треки")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isDarkMode ? .white : .primary)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if let error = loadError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if tracks.isEmpty && !isLoading {
                Text(isEnglish ? "No tracks yet" : "Пока нет треков")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        ArtistTrackRow(
                            index: idx + 1,
                            track: track,
                            isDarkMode: isDarkMode,
                            onTap: { onPlayTrack(track, tracks) }
                        )
                        if idx < tracks.count - 1 {
                            Divider()
                                .overlay(Color(.systemGray5))
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func loadUnified() async {
        guard unified == nil else { return }
        isLoading = true
        loadError = nil
        do {
            let result = try await apiClient.getArtistUnified(name: artist.name)
            self.unified = result
        } catch {
            self.loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func formatNumber(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Row

struct ArtistTrackRow: View {
    let index: Int
    let track: CatalogTrack
    let isDarkMode: Bool
    let onTap: () -> Void

    @ObservedObject private var downloads = DownloadsStore.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isDarkMode ? .white : .primary)
                        .lineLimit(1)
                    if let album = track.album, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if downloads.isDownloaded(provider: track.provider, id: track.id) {
                    DownloadedBadge(size: 14)
                }
                ServiceIconBadge(provider: track.provider, size: 16)

                Text(track.durationFormatted)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
