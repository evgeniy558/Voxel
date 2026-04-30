import Foundation
import SwiftUI
import Combine

/// Default public URL of the Sphere Go backend. Override via Settings → Developer Menu.
/// Render.com Web Service hosting the Go backend from kirby-swift/sphere-backend.
///
/// Outgoing mail (signup codes) uses the `MAIL_FROM` env on the Go service; verify
/// `spheremusic.space` in Resend, add DNS in REG.RU, then e.g. `MAIL_FROM=Sphere <noreply@spheremusic.space>`.
private let sphereBackendDefaultURL: String = "https://sphere-backend-8ssb.onrender.com"

/// Errors returned by the API client.
enum SphereAPIError: Error, LocalizedError {
    case invalidURL
    case notAuthenticated
    case unauthorized
    case http(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)
    /// Login succeeded but `/auth/login` requires a second factor (`/auth/2fa/verify`).
    case secondFactorRequired(challengeId: String, methods: [String])

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .notAuthenticated: return "Not authenticated with Sphere backend"
        case .unauthorized: return "Unauthorized (401) — backend JWT is invalid or expired"
        case .http(let status, let msg): return "HTTP \(status): \(msg ?? "error")"
        case .decoding(let err): return "Decode error: \(err.localizedDescription)"
        case .transport(let err): return "Network error: \(err.localizedDescription)"
        case .secondFactorRequired:
            return "Two-factor authentication required"
        }
    }
}

/// Client for the Sphere Go backend. Singleton, shared across the app.
final class SphereAPIClient: ObservableObject {
    static let shared = SphereAPIClient()

    @Published var isAuthenticated: Bool = false

    /// JWT stored in @AppStorage (bridge for UserDefaults).
    private var jwt: String? {
        get { UserDefaults.standard.string(forKey: "sphereBackendJWT") }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "sphereBackendJWT")
            } else {
                UserDefaults.standard.removeObject(forKey: "sphereBackendJWT")
            }
            DispatchQueue.main.async { self.isAuthenticated = newValue != nil }
        }
    }

    var baseURL: String {
        let override = UserDefaults.standard.string(forKey: "sphereBackendBaseURL") ?? ""
        return override.isEmpty ? sphereBackendDefaultURL : override
    }

    var soundcloudClientId: String? {
        UserDefaults.standard.string(forKey: "soundcloudClientId")
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    /// Heavier endpoints (e.g. `/recommendations` with Spotify) need extra time on cold Render.
    /// Cancels the previous in-flight user search when a new query is issued (avoids stale results).
    private var searchUsersTask: Task<[BackendUserListItem], Error>?

    private let longRequestSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    init() {
        // Discard any persisted override pointing at a stale trycloudflare quick-tunnel
        // so each new app build always picks up the current sphereBackendDefaultURL.
        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: "sphereBackendBaseURL"),
           override.contains("trycloudflare.com"),
           override != sphereBackendDefaultURL {
            defaults.removeObject(forKey: "sphereBackendBaseURL")
        }
        isAuthenticated = jwt != nil
    }

    // MARK: - Auth

    struct AuthPublicConfig: Decodable {
        let recaptcha_site_key: String?
        let recaptcha_min_score: Double
        let signup_code_length: Int
    }

    func fetchAuthPublicConfig() async throws -> AuthPublicConfig {
        try await request(path: "/auth/public-config", method: "GET", requiresAuth: false)
    }

    private struct SignupCodeSentResponse: Decodable { let ok: Bool? }

    func sendSignupCode(email: String) async throws {
        let body: [String: Any] = ["email": email]
        _ = try await request(
            path: "/auth/signup-code",
            method: "POST",
            body: body,
            requiresAuth: false
        ) as SignupCodeSentResponse
    }

    /// Регистрация с письмом (код) и reCAPTCHA v3. См. [доки Google](https://developers.google.com/recaptcha/docs/v3).
    func registerWithEmailVerification(
        email: String,
        password: String,
        name: String,
        emailCode: String,
        recaptchaToken: String
    ) async throws -> AuthResponse {
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "name": name,
            "email_code": emailCode,
            "recaptcha_token": recaptchaToken
        ]
        let resp: AuthResponse = try await request(
            path: "/auth/register",
            method: "POST",
            body: body,
            requiresAuth: false
        )
        jwt = resp.token
        return resp
    }

    /// Служебный регистр для `*@sphere.app` / `*@sphere.local` + пароль `sphere_{id}_autopass` (мосты Supabase).
    func register(email: String, password: String, name: String) async throws -> AuthResponse {
        let body = ["email": email, "password": password, "name": name]
        let resp: AuthResponse = try await request(
            path: "/auth/register",
            method: "POST",
            body: body,
            requiresAuth: false
        )
        jwt = resp.token
        return resp
    }

    /// Password step only. When 2FA is enabled, throws `SphereAPIError.secondFactorRequired`.
    func login(email: String, password: String) async throws -> AuthResponse {
        switch try await loginWithPassword(email: email, password: password) {
        case .authenticated(let r):
            return r
        case .requiresTwoFactor(let cid, let methods):
            throw SphereAPIError.secondFactorRequired(challengeId: cid, methods: methods)
        }
    }

    enum PasswordLoginOutcome {
        case authenticated(AuthResponse)
        case requiresTwoFactor(challengeId: String, methods: [String])
    }

    func loginWithPassword(email: String, password: String) async throws -> PasswordLoginOutcome {
        let body = ["email": email, "password": password]
        guard let url = URL(string: baseURL + "/auth/login") else { throw SphereAPIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SphereAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SphereAPIError.http(status: 0, message: "no response")
        }
        if http.statusCode == 401 {
            let msg = String(data: data, encoding: .utf8)
            throw SphereAPIError.http(status: 401, message: msg)
        }
        if !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw SphereAPIError.http(status: http.statusCode, message: msg)
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (obj["requires_2fa"] as? Bool) == true,
           let cid = obj["challenge_id"] as? String {
            let methods = obj["methods"] as? [String] ?? []
            return .requiresTwoFactor(challengeId: cid, methods: methods)
        }
        do {
            let resp = try decoder.decode(AuthResponse.self, from: data)
            jwt = resp.token
            return .authenticated(resp)
        } catch {
            throw SphereAPIError.decoding(error)
        }
    }

    func verifyTwoFactor(challengeId: String, method: String, code: String) async throws -> AuthResponse {
        let body: [String: Any] = [
            "challenge_id": challengeId,
            "method": method,
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let resp: AuthResponse = try await request(
            path: "/auth/2fa/verify",
            method: "POST",
            body: body,
            requiresAuth: false
        )
        jwt = resp.token
        return resp
    }

    struct QRLoginStartResponse: Decodable {
        let sessionId: String
        let qrPayload: String
        let nonce: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case qrPayload = "qr_payload"
            case nonce
        }
    }

    func qrLoginStart() async throws -> QRLoginStartResponse {
        try await request(
            path: "/auth/qr/start",
            method: "POST",
            body: [:] as [String: Any],
            requiresAuth: false
        ) as QRLoginStartResponse
    }

    enum QRLoginPollResult {
        case approved(AuthResponse)
        case pending
        case gone
    }

    /// Long-poll once (server blocks ~55s). Retry when `.pending`.
    func qrLoginPollOnce(sessionId: String) async throws -> QRLoginPollResult {
        guard var comps = URLComponents(string: baseURL + "/auth/qr/poll") else {
            throw SphereAPIError.invalidURL
        }
        comps.queryItems = [URLQueryItem(name: "session_id", value: sessionId)]
        guard let url = comps.url else { throw SphereAPIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 70

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SphereAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SphereAPIError.http(status: 0, message: nil)
        }
        switch http.statusCode {
        case 200:
            let resp = try decoder.decode(AuthResponse.self, from: data)
            jwt = resp.token
            return .approved(resp)
        case 204:
            return .pending
        case 410:
            return .gone
        default:
            let msg = String(data: data, encoding: .utf8)
            throw SphereAPIError.http(status: http.statusCode, message: msg)
        }
    }

    func qrLoginApprove(sessionId: String, nonce: String) async throws {
        let body: [String: Any] = ["session_id": sessionId, "nonce": nonce]
        let _: EmptyResponse = try await request(
            path: "/auth/qr/approve",
            method: "POST",
            body: body,
            requiresAuth: true
        )
    }

    struct TOTPSetupResponse: Decodable {
        let otpauthUrl: String
        let secret: String
        enum CodingKeys: String, CodingKey {
            case otpauthUrl = "otpauth_url"
            case secret
        }
    }

    func totpSetup() async throws -> TOTPSetupResponse {
        try await request(path: "/account/2fa/totp/setup", method: "POST", body: [:])
    }

    func totpEnable(code: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/account/2fa/totp/enable",
            method: "POST",
            body: ["code": code]
        )
    }

    func totpDisable(password: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/account/2fa/totp/disable",
            method: "POST",
            body: ["password": password]
        )
    }

    func email2FAEnable(password: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/account/2fa/email/enable",
            method: "POST",
            body: ["password": password]
        )
    }

    func email2FADisable(password: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/account/2fa/email/disable",
            method: "POST",
            body: ["password": password]
        )
    }

    func loginWithGoogle(idToken: String) async throws -> AuthResponse {
        let body = ["id_token": idToken]
        let resp: AuthResponse = try await request(
            path: "/auth/google",
            method: "POST",
            body: body,
            requiresAuth: false
        )
        jwt = resp.token
        return resp
    }

    func signOut() {
        jwt = nil
    }

    func ensureBackendAuth(email: String, name: String, userId: String) async {
        guard jwt == nil else { return }
        let e = (email as String).lowercased()
        if userId.hasPrefix("email_") {
            if let p = SphereBackendPasswordKeychain.getBackendPassword(forEmail: email) {
                do { _ = try await login(email: email, password: p) } catch {
                    print("[Sphere] Backend email login failed: \(error.localizedDescription)")
                }
            }
            return
        }
        if e.hasSuffix("@sphere.app") || e.hasSuffix("@sphere.local") {
            let password = "sphere_\(userId)_autopass"
            do {
                _ = try await register(email: email, password: password, name: name)
                return
            } catch SphereAPIError.http(status: 409, _) {
            } catch {
            }
            do { _ = try await login(email: email, password: password) } catch {
                print("[Sphere] Backend auth (sphere.*) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Music endpoints

    func search(query: String, provider: String? = nil, limit: Int = 20) async throws -> SearchResults {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let p = provider { items.append(URLQueryItem(name: "provider", value: p)) }
        return try await request(path: "/search", method: "GET", query: items, requiresAuth: false)
    }

    func getTrack(provider: String, id: String) async throws -> CatalogTrack {
        try await request(path: "/tracks/\(escape(provider))/\(escape(id))", method: "GET", requiresAuth: false)
    }

    func getStreamURL(provider: String, id: String) async throws -> String {
        let r: StreamURLResponse = try await request(
            path: "/tracks/\(escape(provider))/\(escape(id))/stream",
            method: "GET",
            requiresAuth: false
        )
        return r.streamURL
    }

    func getLyrics(provider: String, id: String) async throws -> String? {
        let r: LyricsResponse = try await request(
            path: "/tracks/\(escape(provider))/\(escape(id))/lyrics",
            method: "GET",
            requiresAuth: false
        )
        let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : r.text
    }

    func getArtist(provider: String, id: String) async throws -> CatalogArtist {
        try await request(path: "/artists/\(escape(provider))/\(escape(id))", method: "GET", requiresAuth: false)
    }

    func getArtistUnified(name: String) async throws -> CatalogArtist {
        try await request(path: "/artists/unified/\(escape(name))", method: "GET", requiresAuth: false)
    }

    func getAlbum(provider: String, id: String) async throws -> CatalogAlbum {
        try await request(path: "/albums/\(escape(provider))/\(escape(id))", method: "GET", requiresAuth: false)
    }

    // MARK: - Recommendations + history

    func getRecommendations() async throws -> RecommendationsResponse {
        try await request(path: "/recommendations", method: "GET", session: longRequestSession, resourceTimeout: 300)
    }

    /// Wakes a sleeping Render free tier before heavier calls. Best-effort; does not throw on final failure.
    func wakeBackendForColdStart(maxAttempts: Int = 10) async {
        for attempt in 0..<maxAttempts {
            do {
                let _: HealthStatusResponse = try await request(path: "/health", method: "GET", requiresAuth: false, session: session)
                return
            } catch {
                let delay = min(1.2 + Double(attempt) * 0.6, 8.0)
                let ns = UInt64(delay * 1_000_000_000.0)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func recordHistory(_ track: CatalogTrack) async throws {
        let body: [String: Any] = [
            "provider": track.provider,
            "track_id": track.id,
            "title": track.title,
            "artist": track.artist,
            "genres": track.genres ?? [],
        ]
        let _: EmptyResponse = try await request(path: "/history", method: "POST", body: body)
    }

    // MARK: - Lyrics by title+artist

    func getLyricsByName(title: String, artist: String) async throws -> String? {
        let items = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        let resp: LyricsByNameResponse = try await request(path: "/lyrics", method: "GET", query: items, requiresAuth: false)
        let trimmed = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : resp.text
    }

    // MARK: - Comments

    func getComments(provider: String, id: String) async throws -> [TrackComment] {
        try await request(
            path: "/tracks/\(escape(provider))/\(escape(id))/comments",
            method: "GET",
            requiresAuth: false,
            attachAuthIfAvailable: true
        )
    }

    func postComment(provider: String, id: String, text: String, parentId: String? = nil) async throws -> TrackComment {
        var body: [String: Any] = ["text": text]
        if let pid = parentId { body["parent_id"] = pid }
        return try await request(
            path: "/tracks/\(escape(provider))/\(escape(id))/comments",
            method: "POST",
            body: body,
            requiresAuth: true
        )
    }

    func voteComment(id: String, type: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/comments/\(escape(id))/vote",
            method: "POST",
            body: ["type": type]
        )
    }

    // MARK: - History list

    func getHistory() async throws -> [HistoryEntry] {
        try await request(path: "/history", method: "GET")
    }

    func getUserHistory(userID: String, limit: Int = 50) async throws -> [HistoryEntry] {
        try await request(
            path: "/users/\(escape(userID))/history",
            method: "GET",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    // MARK: - Preferences

    func getPreferences() async throws -> UserPreferences {
        try await request(path: "/user/preferences", method: "GET")
    }

    func savePreferences(artists: [String], genres: [String]) async throws {
        let body: [String: Any] = ["selected_artists": artists, "selected_genres": genres]
        let _: EmptyResponse = try await request(path: "/user/preferences", method: "POST", body: body)
    }

    // MARK: - Account (password, email, avatar)

    func fetchCurrentUser() async throws -> BackendUser {
        try await request(path: "/user/me", method: "GET")
    }

    func changePassword(oldPassword: String, newPassword: String) async throws {
        let body: [String: Any] = ["old_password": oldPassword, "new_password": newPassword]
        let _: EmptyResponse = try await request(path: "/account/change-password", method: "POST", body: body)
    }

    func startEmailChange(newEmail: String, password: String) async throws {
        let body: [String: Any] = ["new_email": newEmail, "password": password]
        let _: EmptyResponse = try await request(path: "/account/change-email/start", method: "POST", body: body)
    }

    func confirmEmailChange(newEmail: String, code: String) async throws -> BackendUser {
        let body: [String: Any] = ["new_email": newEmail, "code": code]
        return try await request(path: "/account/change-email/confirm", method: "POST", body: body)
    }

    private struct AvatarUploadAPIResponse: Decodable {
        let user: BackendUser
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case user
            case avatarUrl = "avatar_url"
        }
    }

    /// Uploads profile photo to the Go backend (multipart field `image`).
    func uploadAvatarImage(_ imageData: Data, fileName: String = "avatar.jpg", mimeType: String = "image/jpeg") async throws -> BackendUser {
        guard let token = jwt else { throw SphereAPIError.notAuthenticated }
        guard let url = URL(string: baseURL + "/account/avatar") else { throw SphereAPIError.invalidURL }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SphereAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SphereAPIError.http(status: 0, message: "no response")
        }
        if http.statusCode == 401 {
            jwt = nil
            throw SphereAPIError.unauthorized
        }
        if !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw SphereAPIError.http(status: http.statusCode, message: msg)
        }
        do {
            let decoded = try decoder.decode(AvatarUploadAPIResponse.self, from: data)
            return decoded.user
        } catch {
            throw SphereAPIError.decoding(error)
        }
    }

    // MARK: - User lyrics

    func submitLyrics(provider: String, trackId: String, text: String) async throws {
        let body: [String: Any] = ["provider": provider, "track_id": trackId, "text": text]
        let _: EmptyResponse = try await request(path: "/lyrics", method: "POST", body: body)
    }

    // MARK: - Favorites

    func listFavorites(itemType: String? = nil) async throws -> [FavoriteItem] {
        var q: [URLQueryItem] = []
        if let itemType, !itemType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            q.append(URLQueryItem(name: "item_type", value: itemType))
        }
        return try await request(path: "/favorites", method: "GET", query: q.isEmpty ? nil : q)
    }

    func listLikedTracks() async throws -> [FavoriteItem] { try await listFavorites(itemType: "track") }
    func listLikedAlbums() async throws -> [FavoriteItem] { try await listFavorites(itemType: "album") }
    func listLikedPlaylists() async throws -> [FavoriteItem] { try await listFavorites(itemType: "playlist") }
    func listLikedArtists() async throws -> [FavoriteItem] { try await listFavorites(itemType: "artist") }

    func listUserFavorites(userID: String, itemType: String? = nil) async throws -> [FavoriteItem] {
        var q: [URLQueryItem] = []
        if let itemType, !itemType.isEmpty {
            q.append(URLQueryItem(name: "type", value: itemType))
        }
        return try await request(
            path: "/users/\(escape(userID))/favorites",
            method: "GET",
            query: q.isEmpty ? nil : q
        )
    }

    func addFavorite(
        itemType: String,
        provider: String,
        providerItemID: String,
        title: String,
        artistName: String,
        coverURL: String?
    ) async throws -> FavoriteItem {
        let body: [String: Any] = [
            "item_type": itemType,
            "provider": provider,
            "provider_item_id": providerItemID,
            "title": title,
            "artist_name": artistName,
            "cover_url": coverURL ?? "",
        ]
        return try await request(path: "/favorites", method: "POST", body: body)
    }

    func deleteFavorite(id: String) async throws {
        let _: EmptyResponse = try await request(path: "/favorites/\(escape(id))", method: "DELETE")
    }

    // MARK: - Virtual liked playlist

    func getLikedPlaylist() async throws -> CatalogPlaylist {
        try await request(path: "/playlists/liked", method: "GET")
    }

    // MARK: - Offline download helpers

    func downloadURL(provider: String, id: String, lossless: Bool = false) -> URL? {
        let suffix = lossless ? "?quality=flac" : ""
        return URL(string: baseURL + "/tracks/\(escape(provider))/\(escape(id))/download\(suffix)")
    }

    func makeDownloadRequest(provider: String, id: String, lossless: Bool = false) throws -> URLRequest {
        guard let token = jwt else { throw SphereAPIError.notAuthenticated }
        guard let url = downloadURL(provider: provider, id: id, lossless: lossless) else { throw SphereAPIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")
        return req
    }

    // MARK: - Social (users, subscriptions)

    func searchUsers(query: String, limit: Int = 20) async throws -> [BackendUserListItem] {
        searchUsersTask?.cancel()
        let task = Task<[BackendUserListItem], Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.request(
                path: "/users/search",
                method: "GET",
                query: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
            )
        }
        searchUsersTask = task
        return try await task.value
    }

    func getUserProfile(id: String) async throws -> BackendUserProfileResponse {
        try await request(path: "/users/\(escape(id))/profile", method: "GET")
    }

    func listUserSubscriptions(id: String) async throws -> BackendUserListResponse {
        try await request(path: "/users/\(escape(id))/subscriptions", method: "GET")
    }

    func listUserSubscribers(id: String) async throws -> BackendUserListResponse {
        try await request(path: "/users/\(escape(id))/subscribers", method: "GET")
    }

    private struct SubscribeStatusResponse: Decodable { let status: String }

    func subscribe(userID: String) async throws -> String {
        let r: SubscribeStatusResponse = try await request(path: "/users/\(escape(userID))/subscribe", method: "POST")
        return r.status
    }

    func unsubscribe(userID: String) async throws {
        let _: EmptyResponse = try await request(path: "/users/\(escape(userID))/subscribe", method: "DELETE")
    }

    func listIncomingSubscriptionRequests() async throws -> [BackendSubscriptionRequestItem] {
        try await request(path: "/me/subscription-requests", method: "GET")
    }

    func approveSubscriptionRequest(id: String) async throws {
        let _: EmptyResponse = try await request(path: "/me/subscription-requests/\(escape(id))/approve", method: "POST")
    }

    func denySubscriptionRequest(id: String) async throws {
        let _: EmptyResponse = try await request(path: "/me/subscription-requests/\(escape(id))/deny", method: "POST")
    }

    func updatePrivacy(hideSubscriptions: Bool? = nil, messagesMutualOnly: Bool? = nil, privateProfile: Bool? = nil) async throws -> BackendUserMe {
        var body: [String: Any] = [:]
        if let v = hideSubscriptions { body["hide_subscriptions"] = v }
        if let v = messagesMutualOnly { body["messages_mutual_only"] = v }
        if let v = privateProfile { body["private_profile"] = v }
        return try await request(path: "/account/privacy", method: "PATCH", body: body)
    }

    // MARK: - Chat

    func listChats() async throws -> [BackendChatThread] {
        try await request(path: "/chats", method: "GET")
    }

    private struct OpenChatResponse: Decodable { let chat_id: String }

    func openOrCreateDM(userID: String) async throws -> String {
        let body: [String: Any] = ["user_id": userID]
        let r: OpenChatResponse = try await request(path: "/chats", method: "POST", body: body)
        return r.chat_id
    }

    func listMessages(chatID: String, before: String? = nil, limit: Int = 50) async throws -> [BackendChatMessage] {
        var q: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        return try await request(path: "/chats/\(escape(chatID))/messages", method: "GET", query: q)
    }

    func sendTextMessage(chatID: String, text: String) async throws -> BackendChatMessage {
        let body: [String: Any] = ["kind": "text", "text": text]
        return try await request(path: "/chats/\(escape(chatID))/messages", method: "POST", body: body)
    }

    func sendTrackShare(chatID: String, payload: [String: Any]) async throws -> BackendChatMessage {
        let body: [String: Any] = ["kind": "track_share", "payload": payload]
        return try await request(path: "/chats/\(escape(chatID))/messages", method: "POST", body: body)
    }

    func connectChatWebSocket() throws -> URLSessionWebSocketTask {
        guard let token = jwt else { throw SphereAPIError.notAuthenticated }
        guard var comps = URLComponents(string: baseURL + "/ws") else { throw SphereAPIError.invalidURL }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let httpURL = comps.url else { throw SphereAPIError.invalidURL }

        var wsComps = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)
        if wsComps?.scheme == "https" { wsComps?.scheme = "wss" }
        if wsComps?.scheme == "http" { wsComps?.scheme = "ws" }
        guard let wsURL = wsComps?.url else { throw SphereAPIError.invalidURL }

        let task = session.webSocketTask(with: wsURL)
        task.resume()
        return task
    }

    // MARK: - Private

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        requiresAuth: Bool = true,
        /// When set, sends `Authorization: Bearer` if a JWT exists (no error if missing). Used for public endpoints that return more when logged in.
        attachAuthIfAvailable: Bool = false,
        session: URLSession? = nil,
        resourceTimeout: TimeInterval? = nil
    ) async throws -> T {
        guard var comps = URLComponents(string: baseURL + path) else {
            throw SphereAPIError.invalidURL
        }
        if let q = query { comps.queryItems = q }
        guard let url = comps.url else { throw SphereAPIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let t = resourceTimeout {
            req.timeoutInterval = t
        }
        if requiresAuth {
            guard let token = jwt else { throw SphereAPIError.notAuthenticated }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if attachAuthIfAvailable, let token = jwt {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        let sess = session ?? self.session
        do {
            (data, response) = try await sess.data(for: req)
        } catch {
            throw SphereAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SphereAPIError.http(status: 0, message: "no response")
        }

        if http.statusCode == 401 {
            // JWT invalid — clear it
            jwt = nil
            throw SphereAPIError.unauthorized
        }

        if !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw SphereAPIError.http(status: http.statusCode, message: msg)
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SphereAPIError.decoding(error)
        }
    }
}

/// Marker type for endpoints that return no JSON body (e.g. 201, 204).
struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

private struct HealthStatusResponse: Decodable {
    let status: String?
}

// MARK: - Social/Chat models

struct BackendUserListItem: Decodable, Identifiable {
    let id: String
    let username: String
    let name: String
    let avatar_url: String
    let is_verified: Bool
    let badge_text: String
    let badge_color: String
    let private_profile: Bool
}

struct BackendUserProfileStats: Decodable {
    let monthly_listens: Int
    let subscribers_count: Int
    let subscriptions_count: Int
}

struct BackendUserProfileResponse: Decodable {
    let user: BackendUserListItem
    let stats: BackendUserProfileStats
    let is_subscribed: Bool
    let subscription_request_status: String?
    let hide_subscriptions: Bool
    let private_profile: Bool
    let requires_approval: Bool
    let can_message: Bool
}

enum BackendUserListResponse: Decodable {
    case hidden
    case users([BackendUserListItem])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let hiddenObj = try? c.decode([String: Bool].self), hiddenObj["hidden"] == true {
            self = .hidden
            return
        }
        self = .users(try c.decode([BackendUserListItem].self))
    }
}

struct BackendSubscriptionRequestItem: Decodable, Identifiable {
    let id: String
    let requester: BackendUserListItem
    let status: String
    let created_at: String
}

struct BackendUserMe: Decodable {
    let id: String
    let email: String
    let username: String
    let name: String
    let avatar_url: String
    let hide_subscriptions: Bool
    let messages_mutual_only: Bool
    let private_profile: Bool
    let is_verified: Bool
    let badge_text: String
    let badge_color: String
    let totp_enabled: Bool
    let email_2fa_enabled: Bool
}

enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

struct BackendChatThreadUser: Decodable {
    let id: String
    let username: String
    let name: String
    let avatar_url: String
    let is_verified: Bool
    let badge_text: String
    let badge_color: String
}

struct BackendChatMessage: Decodable, Identifiable {
    let id: String
    let chat_id: String
    let sender_id: String
    let kind: String
    let text: String?
    let payload: JSONValue?
    let created_at: String
}

struct BackendChatThread: Decodable, Identifiable {
    let id: String
    let other_user: BackendChatThreadUser
    let last_message: BackendChatMessage?
    let last_message_at: String?
}
