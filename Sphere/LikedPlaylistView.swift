import SwiftUI

struct LikedPlaylistView: View {
    let isEnglish: Bool
    let accent: Color
    let isDarkMode: Bool
    let onPlayTrack: (CatalogTrack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var playlist: CatalogPlaylist?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var titleText: String { isEnglish ? "Liked" : "Мне нравится" }

    var body: some View {
        NavigationStack {
            ZStack {
                (isDarkMode ? Color.black : Color(.systemBackground))
                    .ignoresSafeArea()

                if isLoading, playlist == nil {
                    ProgressView()
                        .controlSize(.large)
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(isEnglish ? "Couldn't load playlist" : "Не удалось загрузить плейлист")
                            .font(.headline)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(isEnglish ? "Retry" : "Повторить") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 14) {
                            header

                            if let tracks = playlist?.tracks, !tracks.isEmpty {
                                VStack(spacing: 10) {
                                    ForEach(tracks) { t in
                                        Button {
                                            onPlayTrack(t)
                                        } label: {
                                            HStack(spacing: 12) {
                                                AsyncImage(url: catalogRemoteImageURL(t.coverURL)) { phase in
                                                    switch phase {
                                                    case .success(let img):
                                                        img.resizable().scaledToFill()
                                                    default:
                                                        Rectangle().fill(accent.opacity(0.18))
                                                    }
                                                }
                                                .frame(width: 52, height: 52)
                                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(t.title)
                                                        .font(.system(size: 15, weight: .semibold))
                                                        .foregroundStyle(isDarkMode ? .white : .primary)
                                                        .lineLimit(1)
                                                    Text(t.artist)
                                                        .font(.system(size: 13))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                                Spacer(minLength: 0)
                                                if t.provider != "local" {
                                                    ServiceIconBadge(provider: t.provider, size: 18)
                                                }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(isDarkMode ? Color(white: 0.14) : Color(white: 0.94))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } else {
                                Text(isEnglish ? "No tracks yet" : "Пока пусто")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 20)
                            }

                            Color.clear.frame(height: 40)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.95), Color.pink.opacity(0.70)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 78, height: 78)
                .overlay(
                    Image(systemName: "heart.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 6) {
                Text(titleText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isDarkMode ? .white : .primary)
                let count = playlist?.tracks?.count ?? 0
                Text(isEnglish ? "\(count) tracks" : "\(count) треков")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        do {
            let pl = try await SphereAPIClient.shared.getLikedPlaylist()
            await MainActor.run {
                playlist = pl
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

