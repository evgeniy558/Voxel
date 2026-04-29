import SwiftUI

struct LyricsSheet: View {
    let trackId: String
    let trackTitle: String
    let accent: Color
    let isEnglish: Bool
    @Binding var lyricsStorage: Data
    var provider: String? = nil
    var providerTrackId: String? = nil
    var titleHint: String? = nil
    var artistHint: String? = nil
    @ObservedObject var playbackHolder: PlaybackStateHolder
    var isDarkMode: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var editText = ""
    @State private var backendLyrics: String?
    @State private var isLoadingBackend = false
    @State private var selectedTab = 0

    private var lyrics: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: lyricsStorage)) ?? [:]
    }

    private var currentLyrics: String? {
        if let text = backendLyrics, !text.isEmpty { return text }
        let dict = lyrics
        guard let text = dict[trackId], !text.isEmpty else { return nil }
        return text
    }

    private func loadBackendLyricsIfNeeded() async {
        guard backendLyrics == nil, !isLoadingBackend else { return }
        isLoadingBackend = true
        defer { isLoadingBackend = false }
        if let provider = provider, let pid = providerTrackId {
            if let text = try? await SphereAPIClient.shared.getLyrics(provider: provider, id: pid),
               !text.isEmpty {
                backendLyrics = text
                return
            }
        }
        let title = (titleHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (artistHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let text = try? await SphereAPIClient.shared.getLyricsByName(title: title, artist: artist),
           !text.isEmpty {
            backendLyrics = text
        }
    }

    private var title: String { isEnglish ? "Lyrics" : "Текст песни" }
    private var noLyricsText: String { isEnglish ? "No lyrics added yet" : "Текст ещё не добавлен" }
    private var addButtonText: String { isEnglish ? "Add lyrics" : "Добавить текст" }
    private var editButtonText: String { isEnglish ? "Edit" : "Редактировать" }
    private var saveButtonText: String { isEnglish ? "Save" : "Сохранить" }
    private var cancelButtonText: String { isEnglish ? "Cancel" : "Отмена" }
    private var doneButtonText: String { isEnglish ? "Done" : "Готово" }
    private var placeholderText: String { isEnglish ? "Paste or type the lyrics here..." : "Вставьте или введите текст песни..." }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text(isEnglish ? "Lyrics" : "Текст").tag(0)
                    Text(isEnglish ? "Comments" : "Комментарии").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if selectedTab == 0 {
                    Group {
                        if isEditing {
                            editorView
                        } else if isLoadingBackend {
                            VStack(spacing: 16) {
                                Spacer()
                                ProgressView().controlSize(.large)
                                Text(isEnglish ? "Loading lyrics…" : "Загрузка текста…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        } else if let text = currentLyrics {
                            SyncedLyricsView(
                                text: text,
                                playbackHolder: playbackHolder,
                                isDarkMode: isDarkMode,
                                accent: accent
                            )
                        } else {
                            emptyView
                        }
                    }
                } else {
                    if let prov = provider, let pid = providerTrackId {
                        CommentsView(
                            provider: prov,
                            trackId: pid,
                            accent: accent,
                            isDarkMode: isDarkMode
                        )
                    } else {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text(isEnglish ? "Comments unavailable for local tracks" : "Комментарии недоступны для локальных треков")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(trackTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadBackendLyricsIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button(cancelButtonText) {
                            isEditing = false
                        }
                    } else {
                        Button(doneButtonText) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selectedTab == 0 {
                        if isEditing {
                            Button(saveButtonText) {
                                saveLyrics(editText)
                                if let prov = provider, let pid = providerTrackId, !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Task { try? await SphereAPIClient.shared.submitLyrics(provider: prov, trackId: pid, text: editText) }
                                }
                                isEditing = false
                            }
                            .fontWeight(.semibold)
                        } else if currentLyrics != nil && backendLyrics == nil {
                            Button(editButtonText) {
                                editText = currentLyrics ?? ""
                                isEditing = true
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 56))
                .foregroundStyle(accent.opacity(0.4))
            Text(noLyricsText)
                .font(.body)
                .foregroundStyle(.secondary)
            Button {
                editText = ""
                isEditing = true
            } label: {
                Text(addButtonText)
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var editorView: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $editText)
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .scrollContentBackground(.hidden)

            if editText.isEmpty {
                Text(placeholderText)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private func saveLyrics(_ text: String) {
        var dict = lyrics
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict.removeValue(forKey: trackId)
        } else {
            dict[trackId] = text
        }
        if let data = try? JSONEncoder().encode(dict) {
            lyricsStorage = data
        }
    }
}

// MARK: - Synced Lyrics View

private struct TimedLine: Identifiable {
    let id: Int
    let time: TimeInterval
    let text: String
}

private struct SyncedLyricsView: View {
    let text: String
    @ObservedObject var playbackHolder: PlaybackStateHolder
    let isDarkMode: Bool
    let accent: Color

    @State private var timedLines: [TimedLine] = []
    @State private var isSynced = false
    @Namespace private var scrollSpace

    private var activeIndex: Int {
        guard isSynced, !timedLines.isEmpty else { return -1 }
        var best = 0
        for i in timedLines.indices {
            if timedLines[i].time <= playbackHolder.currentTime + 0.3 {
                best = i
            } else {
                break
            }
        }
        return best
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if isSynced {
                        ForEach(timedLines) { line in
                            let isActive = line.id == activeIndex
                            let isPast = line.id < activeIndex
                            Text(line.text)
                                .font(.system(size: isActive ? 22 : 19, weight: isActive ? .bold : .semibold))
                                .foregroundStyle(
                                    isActive
                                        ? (isDarkMode ? Color.white : Color.black)
                                        : isPast
                                            ? (isDarkMode ? Color.white.opacity(0.7) : Color.black.opacity(0.7))
                                            : (isDarkMode ? Color.white.opacity(0.3) : Color.black.opacity(0.3))
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, isActive ? 4 : 2)
                                .id(line.id)
                                .animation(.easeInOut(duration: 0.35), value: isActive)
                        }
                    } else {
                        Text(text)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isDarkMode ? .white : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .onChange(of: activeIndex) { newIndex in
                guard newIndex >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .onAppear { parse() }
    }

    private func parse() {
        let pattern = /^\[(\d{1,2}):(\d{2})\.(\d{2,3})\]\s?(.*)$/
        var lines: [TimedLine] = []
        var idx = 0
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let match = trimmed.firstMatch(of: pattern) {
                let mins = Double(match.1) ?? 0
                let secs = Double(match.2) ?? 0
                let ms: Double
                let msStr = String(match.3)
                if msStr.count == 2 {
                    ms = (Double(msStr) ?? 0) / 100.0
                } else {
                    ms = (Double(msStr) ?? 0) / 1000.0
                }
                let time = mins * 60 + secs + ms
                let lineText = String(match.4).trimmingCharacters(in: .whitespaces)
                if !lineText.isEmpty {
                    lines.append(TimedLine(id: idx, time: time, text: lineText))
                    idx += 1
                }
            }
        }
        if lines.count >= 3 {
            timedLines = lines
            isSynced = true
        }
    }
}
