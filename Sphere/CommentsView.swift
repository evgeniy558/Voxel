import SwiftUI

struct CommentsView: View {
    let provider: String
    let trackId: String
    let accent: Color
    let isDarkMode: Bool

    @State private var comments: [TrackComment] = []
    @State private var isLoading = true
    @State private var newText = ""
    @State private var replyingTo: TrackComment? = nil
    @State private var isSending = false
    @State private var sendError: String?

    private let apiClient = SphereAPIClient.shared

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if comments.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No comments yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Be the first to comment!")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(comments) { comment in
                            CommentCell(
                                comment: comment,
                                accent: accent,
                                isDarkMode: isDarkMode,
                                onReply: { replyingTo = comment },
                                onVote: { type in vote(commentId: comment.id, type: type) }
                            )

                            if let replies = comment.replies, !replies.isEmpty {
                                ForEach(replies) { reply in
                                    CommentCell(
                                        comment: reply,
                                        accent: accent,
                                        isDarkMode: isDarkMode,
                                        onReply: { replyingTo = comment },
                                        onVote: { type in vote(commentId: reply.id, type: type) }
                                    )
                                    .padding(.leading, 48)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 80)
                }
            }

            // Input bar
            VStack(spacing: 0) {
                if let reply = replyingTo {
                    HStack {
                        Text("Replying to \(reply.userName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { replyingTo = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                HStack(spacing: 10) {
                    TextField("Write a comment...", text: $newText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(isDarkMode ? Color(white: 0.15) : Color(white: 0.93))
                        )

                    Button {
                        sendComment()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(newText.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : accent)
                    }
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(
                (isDarkMode ? Color(white: 0.08) : Color.white)
                    .shadow(color: .black.opacity(0.05), radius: 4, y: -2)
            )
        }
        .task { await loadComments() }
        .alert("Comment", isPresented: Binding(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            if let sendError { Text(sendError) }
        }
    }

    private func loadComments() async {
        isLoading = true
        do {
            var result = try await apiClient.getComments(provider: provider, id: trackId)
            if provider == "soundcloud" && !result.contains(where: { $0.source == "soundcloud" }) {
                let scComments = await fetchSCCommentsDirectly()
                result = scComments + result
            }
            comments = result
        } catch {
            print("[Comments] load error: \(error)")
            if provider == "soundcloud" {
                comments = await fetchSCCommentsDirectly()
            }
        }
        isLoading = false
    }

    private func fetchSCCommentsDirectly() async -> [TrackComment] {
        guard let clientId = SphereAPIClient.shared.soundcloudClientId,
              let url = URL(string: "https://api-v2.soundcloud.com/tracks/\(trackId)/comments?client_id=\(clientId)&limit=50&offset=0") else {
            return []
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SCCommentsResponse.self, from: data)
            return decoded.collection.map { sc in
                TrackComment(
                    id: "sc-\(sc.id)",
                    trackProvider: "soundcloud",
                    trackId: trackId,
                    userId: nil,
                    userName: sc.user.username,
                    userAvatarUrl: sc.user.avatar_url,
                    text: sc.body,
                    parentId: nil,
                    likes: 0, dislikes: 0,
                    createdAt: sc.created_at,
                    source: "soundcloud",
                    replies: nil
                )
            }
        } catch {
            return []
        }
    }

    private func sendComment() {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSending = true
        let parentId = replyingTo?.id
        Task {
            do {
                let comment = try await apiClient.postComment(
                    provider: provider, id: trackId,
                    text: text, parentId: parentId
                )
                await MainActor.run {
                    if let parentId = parentId,
                       let idx = comments.firstIndex(where: { $0.id == parentId }) {
                        var parent = comments[idx]
                        var replies = parent.replies ?? []
                        replies.append(comment)
                        parent.replies = replies
                        comments[idx] = parent
                    } else {
                        comments.append(comment)
                    }
                    newText = ""
                    replyingTo = nil
                    isSending = false
                }
            } catch {
                print("[Comments] send error: \(error)")
                let msg: String
                if case SphereAPIError.notAuthenticated = error {
                    msg = "Sign in to the Sphere service to post comments."
                } else {
                    msg = error.localizedDescription
                }
                await MainActor.run {
                    isSending = false
                    sendError = msg
                }
            }
        }
    }

    private func vote(commentId: String, type: String) {
        Task {
            try? await apiClient.voteComment(id: commentId, type: type)
            await loadComments()
        }
    }
}

private struct SCCommentsResponse: Decodable {
    let collection: [SCComment]
}

private struct SCComment: Decodable {
    let id: Int
    let body: String
    let created_at: String
    let user: SCCommentUser
}

private struct SCCommentUser: Decodable {
    let username: String
    let avatar_url: String?
}

struct CommentCell: View {
    let comment: TrackComment
    let accent: Color
    let isDarkMode: Bool
    var onReply: (() -> Void)? = nil
    var onVote: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: URL(string: comment.userAvatarUrl ?? "")) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Circle()
                        .fill(accent.opacity(0.2))
                        .overlay(
                            Text(String(comment.userName.prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accent)
                        )
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.userName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isDarkMode ? .white : .primary)

                    if comment.source == "soundcloud" {
                        ServiceIconBadge(provider: "soundcloud", size: 12)
                    }

                    Text(comment.timeAgo)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Text(comment.text)
                    .font(.system(size: 14))
                    .foregroundStyle(isDarkMode ? Color(white: 0.9) : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Button { onReply?() } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Button { onVote?("like") } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsup")
                            if comment.likes > 0 {
                                Text("\(comment.likes)")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }

                    Button { onVote?("dislike") } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsdown")
                            if comment.dislikes > 0 {
                                Text("\(comment.dislikes)")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
