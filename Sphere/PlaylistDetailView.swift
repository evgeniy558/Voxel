import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let playlist: CatalogPlaylist
    let accent: Color
    let isDarkMode: Bool
    let isEnglish: Bool
    let onPlayTrack: (CatalogTrack, [CatalogTrack]) -> Void
    let onPlayAll: ([CatalogTrack]) -> Void
    let onShuffle: ([CatalogTrack]) -> Void

    @State private var isDownloading = false

    private var tracks: [CatalogTrack] { playlist.tracks ?? [] }
    private var playlistLabel: String { isEnglish ? "Playlist" : "Плейлист" }

    var body: some View {
        NavigationStack {
            ZStack {
                (isDarkMode ? Color.black : Color(.systemBackground)).ignoresSafeArea()
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 0)
                AlbumDetailArtwork(urlString: playlist.coverURL, accent: accent)
                    .frame(width: 270, height: 270)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.title)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(isDarkMode ? .white : .primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(playlistLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            AlbumDetailArtwork(urlString: playlist.coverURL, accent: accent)
                .frame(width: 44, height: 44)

            Button {
                guard !tracks.isEmpty, !isDownloading else { return }
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
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
            .disabled(tracks.isEmpty)
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEnglish ? "Tracks" : "Треки")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(isDarkMode ? .white : .primary)
                .padding(.top, 6)

            if tracks.isEmpty {
                Text(isEnglish ? "No tracks yet" : "Пока нет треков")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \\.element.id) { idx, track in
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
}

