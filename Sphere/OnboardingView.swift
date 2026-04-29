import SwiftUI

struct OnboardingView: View {
    let accent: Color
    let isDarkMode: Bool
    let isEnglish: Bool
    var onComplete: () -> Void

    @State private var step = 0
    @State private var selectedGenres: Set<String> = []
    @State private var selectedArtists: Set<String> = []
    @State private var artistSearch = ""
    @State private var searchResults: [CatalogArtist] = []
    @State private var isSearching = false
    @State private var searchDebounce: Task<Void, Never>?
    @State private var isSaving = false
    @State private var saveError: String?

    private let genres = [
        "Pop", "Rock", "Hip-Hop", "R&B", "Electronic",
        "Jazz", "Classical", "Metal", "Indie", "K-Pop",
        "Latin", "Country", "Reggaeton", "Lo-Fi", "Punk",
        "Русский рэп", "Поп", "Рок"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text(step == 0
                     ? (isEnglish ? "What do you listen to?" : "Что ты слушаешь?")
                     : (isEnglish ? "Pick your favorite artists" : "Выбери любимых артистов"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(isDarkMode ? .white : .primary)

                Text(step == 0
                     ? (isEnglish ? "Select genres you enjoy" : "Выбери жанры, которые тебе нравятся")
                     : (isEnglish ? "Search and select artists" : "Найди и выбери артистов"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 60)
            .padding(.bottom, 24)

            if step == 0 {
                genreGrid
            } else {
                artistSelection
            }

            Spacer()

            // Continue button
            Button {
                if step == 0 {
                    withAnimation { step = 1 }
                } else {
                    save()
                }
            } label: {
                Text(step == 0
                     ? (isEnglish ? "Continue" : "Далее")
                     : (isEnglish ? "Get Started" : "Начать"))
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .disabled((step == 0 && selectedGenres.isEmpty) || isSaving)
            .opacity((step == 0 && selectedGenres.isEmpty) || isSaving ? 0.5 : 1)

            // Skip — still marks onboarding completed on the server so recommendations aren’t stuck on cold-start.
            Button {
                Task { await skipAndSavePreferences() }
            } label: {
                Text(isEnglish ? "Skip for now" : "Пропустить")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .padding(.bottom, 40)
        }
        .background(isDarkMode ? Color.black : Color.white)
        .alert(isEnglish ? "Couldn’t save" : "Не удалось сохранить", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Genre grid

    private var genreGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 90), spacing: 10)
            ], spacing: 10) {
                ForEach(genres, id: \.self) { genre in
                    let selected = selectedGenres.contains(genre)
                    Button {
                        if selected {
                            selectedGenres.remove(genre)
                        } else {
                            selectedGenres.insert(genre)
                        }
                    } label: {
                        Text(genre)
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(selected ? accent.opacity(0.2) : (isDarkMode ? Color(white: 0.12) : Color(.systemGray6)))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(selected ? accent : .clear, lineWidth: 1.5)
                            )
                            .foregroundStyle(selected ? accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Artist selection

    private var artistSelection: some View {
        VStack(spacing: 12) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(isEnglish ? "Search artists..." : "Поиск артистов...", text: $artistSearch)
                    .font(.system(size: 15))
                    .onChange(of: artistSearch) { newValue in
                        searchArtists(newValue)
                    }
                if !artistSearch.isEmpty {
                    Button { artistSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Capsule().fill(isDarkMode ? Color(white: 0.14) : Color(.systemGray6)))
            .padding(.horizontal, 20)

            // Selected chips
            if !selectedArtists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(selectedArtists), id: \.self) { name in
                            HStack(spacing: 4) {
                                Text(name)
                                    .font(.system(size: 13))
                                Button {
                                    selectedArtists.remove(name)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(accent)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }

            // Results
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isSearching {
                        ProgressView()
                            .padding(.top, 30)
                    }
                    ForEach(searchResults) { artist in
                        let isSelected = selectedArtists.contains(artist.name)
                        Button {
                            if isSelected {
                                selectedArtists.remove(artist.name)
                            } else {
                                selectedArtists.insert(artist.name)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: catalogRemoteImageURL(artist.imageURL)) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                    default:
                                        Circle()
                                            .fill(isDarkMode ? Color(white: 0.15) : Color(.systemGray5))
                                            .overlay(
                                                Image(systemName: "person.fill")
                                                    .foregroundStyle(.secondary)
                                            )
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(isDarkMode ? .white : .primary)
                                    if let provider = artist.provider.isEmpty ? nil : artist.provider {
                                        HStack(spacing: 4) {
                                            ServiceIconBadge(provider: provider, size: 12)
                                            if let followers = artist.followers, followers > 0 {
                                                Text(formatFollowers(followers))
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }

                                Spacer()

                                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(isSelected ? accent : .secondary)
                            }
                            .padding(.horizontal, 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func searchArtists(_ query: String) {
        searchDebounce?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await SphereAPIClient.shared.search(query: trimmed, limit: 10)
                await MainActor.run {
                    searchResults = results.artists
                    isSearching = false
                }
            } catch {
                await MainActor.run { isSearching = false }
            }
        }
    }

    private func save() {
        Task {
            await MainActor.run {
                isSaving = true
                saveError = nil
            }
            do {
                try await SphereAPIClient.shared.savePreferences(
                    artists: Array(selectedArtists),
                    genres: Array(selectedGenres)
                )
                await MainActor.run {
                    isSaving = false
                    onComplete()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    private func skipAndSavePreferences() async {
        await MainActor.run {
            isSaving = true
            saveError = nil
        }
        do {
            try await SphereAPIClient.shared.savePreferences(artists: [], genres: [])
            await MainActor.run {
                isSaving = false
                onComplete()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
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
