import Foundation
import SwiftUI
import Combine
import ExyteChat

private let sphereTrackSharePrefix = "sphere_track_share:"

final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published var threads: [BackendChatThread] = []
    @Published var messagesByChat: [String: [BackendChatMessage]] = [:]
    @Published var lastError: String?

    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private var shouldStayConnected: Bool = false

    func refreshThreads() async {
        do {
            let t = try await SphereAPIClient.shared.listChats()
            await MainActor.run { self.threads = t; self.lastError = nil }
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
        }
    }

    func loadMessages(chatID: String) async {
        do {
            let msgs = try await SphereAPIClient.shared.listMessages(chatID: chatID, before: nil, limit: 80)
            // Backend returns newest-first; store oldest-first for ExyteChat (.conversation expects ascending).
            await MainActor.run { self.messagesByChat[chatID] = msgs.reversed(); self.lastError = nil }
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
        }
    }

    func send(chatID: String, text: String) async {
        do {
            let msg = try await SphereAPIClient.shared.sendTextMessage(chatID: chatID, text: text)
            await MainActor.run {
                var arr = self.messagesByChat[chatID] ?? []
                arr.append(msg)
                self.messagesByChat[chatID] = arr
            }
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
        }
    }

    func connectWS() {
        shouldStayConnected = true
        reconnectTask?.cancel()
        reconnectAttempt = 0
        openWS()
    }

    func disconnectWS() {
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func openWS() {
        do {
            let task = try SphereAPIClient.shared.connectChatWebSocket()
            wsTask = task
            receiveTask?.cancel()
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        } catch {
            lastError = error.localizedDescription
            scheduleReconnect()
        }
    }

    private func receiveLoop() async {
        guard let wsTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await wsTask.receive()
                switch message {
                case .string(let s):
                    handleEventString(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        handleEventString(s)
                    }
                @unknown default:
                    break
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
                scheduleReconnect()
                return
            }
        }
    }

    private func handleEventString(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        guard let ev = try? JSONDecoder().decode(BackendWSMessageEvent.self, from: data) else { return }
        if ev.type == "chat.message" {
            Task { @MainActor in
                let chatID = ev.message.chat_id
                var arr = self.messagesByChat[chatID] ?? []
                arr.append(ev.message)
                self.messagesByChat[chatID] = arr

                // Update threads list (preview + move to top).
                if let idx = self.threads.firstIndex(where: { $0.id == chatID }) {
                    let t = self.threads[idx]
                    var newThreads = self.threads
                    let updated = BackendChatThread(
                        id: t.id,
                        other_user: t.other_user,
                        last_message: ev.message,
                        last_message_at: ev.message.created_at
                    )
                    // keep other_user unchanged; only update last message fields
                    newThreads.remove(at: idx)
                    newThreads.insert(updated, at: 0)
                    self.threads = newThreads
                } else {
                    // Unknown thread — refresh lazily.
                    Task { await self.refreshThreads() }
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldStayConnected else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(20.0, pow(2.0, Double(min(reconnectAttempt, 5)))) // 2,4,8,16,20...
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.shouldStayConnected else { return }
            await MainActor.run { self.openWS() }
        }
    }
}

private struct BackendWSMessageEvent: Decodable {
    let type: String
    let message: BackendChatMessage
}

struct ChatListView: View {
    @ObservedObject private var store = ChatStore.shared
    let accent: Color
    let isEnglish: Bool

    var body: some View {
        List {
            if let err = store.lastError {
                Text(err).foregroundStyle(.secondary)
            }
            ForEach(store.threads) { t in
                NavigationLink {
                    ChatScreen(chatID: t.id, otherUserName: t.other_user.name.isEmpty ? t.other_user.username : t.other_user.name, accent: accent, isEnglish: isEnglish)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.other_user.name.isEmpty ? t.other_user.username : t.other_user.name)
                            .font(.system(size: 16, weight: .semibold))
                        if let lm = t.last_message {
                            Text(lm.kind == "text" ? (lm.text ?? "") : (isEnglish ? "Shared a track" : "Поделился треком"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(isEnglish ? "Chats" : "Чаты")
        .task { await store.refreshThreads(); store.connectWS() }
        .onDisappear { }
        .refreshable { await store.refreshThreads() }
    }
}

struct ChatScreen: View {
    let chatID: String
    let otherUserName: String
    let accent: Color
    let isEnglish: Bool

    @ObservedObject private var store = ChatStore.shared
    @StateObject private var authService = AuthService.shared

    private var myUserID: String {
        authService.backendAccountSnapshot?.id ?? ""
    }

    private func parseISO(_ s: String) -> Date {
        let f1 = ISO8601DateFormatter()
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s) ?? Date()
    }

    private func exyteMessages() -> [ExyteChat.Message] {
        let msgs = store.messagesByChat[chatID] ?? []
        let myName = authService.currentProfile?.nickname ?? (isEnglish ? "Me" : "Я")
        let myAvatarURL = authService.backendAccountSnapshot?.avatarUrl.flatMap(URL.init(string:))
        let otherAvatarURL = URL(string: store.threads.first(where: { $0.id == chatID })?.other_user.avatar_url ?? "")
        return msgs.map { m in
            let isMe = !myUserID.isEmpty && m.sender_id == myUserID
            let u = ExyteChat.User(
                id: m.sender_id,
                name: isMe ? myName : otherUserName,
                avatarURL: isMe ? myAvatarURL : otherAvatarURL,
                isCurrentUser: isMe
            )

            if m.kind == "track_share" {
                var payload: [String: String] = [:]
                if case .object(let obj) = m.payload {
                    if case .string(let v) = obj["provider"] { payload["provider"] = v }
                    if case .string(let v) = obj["id"] { payload["id"] = v }
                    if case .string(let v) = obj["title"] { payload["title"] = v }
                    if case .string(let v) = obj["artist"] { payload["artist"] = v }
                    if case .string(let v) = obj["cover_url"] { payload["cover_url"] = v }
                }
                let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return ExyteChat.Message(
                    id: m.id,
                    user: u,
                    status: .sent,
                    createdAt: parseISO(m.created_at),
                    text: sphereTrackSharePrefix + json,
                    attachments: [],
                    recording: nil,
                    replyMessage: nil
                )
            }
            return ExyteChat.Message(
                id: m.id,
                user: u,
                status: .sent,
                createdAt: parseISO(m.created_at),
                text: m.text ?? "",
                attachments: [],
                recording: nil,
                replyMessage: nil
            )
        }
    }

    var body: some View {
        ChatView(messages: exyteMessages()) { draft in
            Task {
                await store.send(chatID: chatID, text: draft.text)
            }
        } messageBuilder: { message, positionInUserGroup, positionInCommentsGroup, showContextMenuClosure, messageActionClosure, showAttachmentClosure in
            if message.text.hasPrefix(sphereTrackSharePrefix),
               let payload = parseTrackSharePayload(message.text) {
                return AnyView(TrackShareMessageCard(
                    isCurrentUser: message.user.isCurrentUser,
                    payload: payload,
                    accent: accent,
                    isEnglish: isEnglish
                )
                .onTapGesture { showContextMenuClosure() })
            } else {
                return AnyView(VStack {
                    Text(message.text)
                        .frame(maxWidth: .infinity, alignment: message.user.isCurrentUser ? .trailing : .leading)
                })
            }
        }
        .navigationTitle(otherUserName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadMessages(chatID: chatID)
            store.connectWS()
        }
    }
}

private struct TrackSharePayload {
    let provider: String
    let id: String
    let title: String
    let artist: String
    let coverURL: String
}

private func parseTrackSharePayload(_ text: String) -> TrackSharePayload? {
    guard text.hasPrefix(sphereTrackSharePrefix) else { return nil }
    let json = String(text.dropFirst(sphereTrackSharePrefix.count))
    guard let data = json.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return TrackSharePayload(
        provider: (obj["provider"] as? String) ?? "",
        id: (obj["id"] as? String) ?? "",
        title: (obj["title"] as? String) ?? "",
        artist: (obj["artist"] as? String) ?? "",
        coverURL: (obj["cover_url"] as? String) ?? ""
    )
}

private struct TrackShareMessageCard: View {
    let isCurrentUser: Bool
    let payload: TrackSharePayload
    let accent: Color
    let isEnglish: Bool

    private var title: String { payload.title.isEmpty ? (isEnglish ? "Track" : "Трек") : payload.title }
    private var artist: String { payload.artist }
    private var coverURL: URL? { payload.coverURL.isEmpty ? nil : URL(string: payload.coverURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let url = coverURL {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.systemGray5))
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemGray5))
                        .frame(width: 46, height: 46)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            Button {
                // “Ideal” UX: delegate playback to the main player via NotificationCenter.
                NotificationCenter.default.post(
                    name: .spherePlayCatalogTrack,
                    object: nil,
                    userInfo: ["provider": payload.provider, "id": payload.id]
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(isEnglish ? "Listen" : "Слушать")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(accent.opacity(0.18))
                .foregroundStyle(accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(12)
        .background(isCurrentUser ? accent.opacity(0.10) : Color(.systemGray6).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 4)
    }
}

