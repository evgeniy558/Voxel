//
//  AuthService.swift
//  Sphere
//
//  Google Sign-In + Supabase session and profile sync.
//

import Foundation
import SwiftUI
import UIKit
import Combine
import CryptoKit
import GoogleSignIn
import Supabase

/// Тип регистрации/входа пользователя
enum AuthProvider: String, Codable {
    case google
    case email
}

/// Модель профиля пользователя в Supabase (таблица profiles)
struct UserProfile: Codable, Equatable {
    var id: UUID?
    var userId: String
    var email: String?
    var nickname: String
    var username: String
    var avatarUrl: String?
    var bio: String?
    var authProvider: String
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case email
        case nickname
        case username
        case avatarUrl = "avatar_url"
        case bio
        case authProvider = "auth_provider"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static func placeholder(userId: String, email: String?, nickname: String, username: String, provider: AuthProvider) -> UserProfile {
        UserProfile(
            id: nil,
            userId: userId,
            email: email,
            nickname: nickname,
            username: username,
            avatarUrl: nil,
            bio: nil,
            authProvider: provider.rawValue,
            createdAt: nil,
            updatedAt: nil
        )
    }
}

/// Сервис авторизации: Google Sign-In и синхронизация с Supabase
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    private let supabaseURL = URL(string: "https://yqfcgwzrlciujrepwxny.supabase.co")!
    private let supabaseAnonKey = "sb_publishable_OpFfXtT6-E5KIiyAUeqZAA_8k4CyYaF"
    private(set) var client: SupabaseClient?

    @Published private(set) var currentProfile: UserProfile?
    @Published private(set) var isSignedIn: Bool = false
    /// Last `/user/me` from Go (badges, verified, etc.).
    @Published private(set) var backendAccountSnapshot: BackendUser?
    @Published var authError: String?

    private init() {
        client = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseAnonKey,
            options: .init(
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
        restoreSession()
    }

    /// Восстановить сессию из Keychain/UserDefaults и подтянуть профиль из Supabase
    func restoreSession() {
        // Локально сохранённый userId после входа через Google или email
        let savedUserId = UserDefaults.standard.string(forKey: "sphere_user_id")
        let savedProfileData = UserDefaults.standard.data(forKey: "sphere_profile")

        if let data = savedProfileData, let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            currentProfile = profile
            isSignedIn = true
            authError = nil
            if savedUserId != nil {
                Task {
                    await ensureProfileAvailable()
                    await SphereAPIClient.shared.ensureBackendAuth(
                        email: profile.email ?? "\(profile.userId)@sphere.app",
                        name: profile.nickname,
                        userId: profile.userId
                    )
                    await refreshBackendAccountFromServer()
                }
            }
            return
        }

        if savedUserId != nil {
            isSignedIn = true
            Task { await ensureProfileAvailable() }
        } else {
            currentProfile = nil
            isSignedIn = false
        }
    }

    /// Вход через Google: показать UI Google, получить токен, залогинить в Supabase и создать/обновить профиль.
    /// GoTrue сравнивает hex(SHA256(тело)) с nonce в id_token, поэтому в Google передаём hex-хэш, в Supabase — сырой nonce.
    func signInWithGoogle() async {
        authError = nil
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            authError = "No window"
            return
        }

        let rawNonce = randomNonceString()
        // GoTrue в token_oidc.go использует fmt.Sprintf("%x", sha256.Sum256([]byte(params.Nonce))) — сравнивает hex-хэш с id_token.nonce
        let hashedNonceForGoogle = sha256Hex(rawNonce)

        do {
            let result: GIDSignInResult = try await withCheckedThrowingContinuation { continuation in
                GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootVC,
                    hint: nil,
                    additionalScopes: nil,
                    nonce: hashedNonceForGoogle,
                    claims: nil
                ) { signInResult, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let signInResult = signInResult else {
                        continuation.resume(throwing: NSError(domain: "Sphere", code: -1, userInfo: [NSLocalizedDescriptionKey: "No sign-in result"]))
                        return
                    }
                    continuation.resume(returning: signInResult)
                }
            }

            let user = result.user
            guard let idToken = user.idToken?.tokenString else {
                authError = "No Google token"
                return
            }

            let email = user.profile?.email
            let displayName = user.profile?.name ?? "User"
            let photoURL = user.profile?.imageURL(withDimension: 200)?.absoluteString

            // Сначала логинимся в Sphere-бэкенде по Google id_token: это обязательно для работы API
            // (рекомендации, чаты, профиль). Backend сам валидирует токен и выдаёт JWT.
            let backendResponse: AuthResponse
            do {
                backendResponse = try await SphereAPIClient.shared.loginWithGoogle(idToken: idToken)
            } catch {
                authError = error.localizedDescription
                print("[AuthService] Sphere backend Google login failed: \(error.localizedDescription)")
                return
            }

            // Supabase (GoTrue): hash = hex(SHA256(params.Nonce)), сравнивается с id_token.nonce —
            // мы передали hashedNonceForGoogle в Google, поэтому в теле передаём rawNonce.
            // Если Supabase упадёт (например, временная ошибка GoTrue), мы всё равно входим — основной
            // авторитет авторизации это наш Sphere-бэкенд, Supabase используется только для синка профиля.
            var supabaseUserId: String?
            if let client = client {
                do {
                    let session = try await client.auth.signInWithIdToken(
                        credentials: .init(provider: .google, idToken: idToken, nonce: rawNonce)
                    )
                    supabaseUserId = session.user.id.uuidString
                } catch {
                    print("[AuthService] Supabase signInWithIdToken failed (non-fatal): \(error.localizedDescription)")
                }
            }

            let resolvedUserId = supabaseUserId ?? "google_\(backendResponse.user.id)"
            let displayNickname = backendResponse.user.name.isEmpty ? displayName : backendResponse.user.name
            let resolvedEmail = backendResponse.user.email.isEmpty ? (email ?? "") : backendResponse.user.email

            let usernameSeed = displayNickname.lowercased().filter { $0.isLetter || $0.isNumber }
            let username = usernameSeed.isEmpty ? "user_\(resolvedUserId.prefix(8))" : String(usernameSeed.prefix(30))
            var profile = UserProfile.placeholder(
                userId: resolvedUserId,
                email: resolvedEmail.isEmpty ? nil : resolvedEmail,
                nickname: displayNickname,
                username: normalizedUsername(from: username, fallbackUserId: resolvedUserId),
                provider: .google
            )
            let backendAvatar = backendResponse.user.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.avatarUrl = (backendAvatar?.isEmpty == false ? backendAvatar : photoURL)

            currentProfile = profile
            isSignedIn = true
            authError = nil
            persistProfileLocally(profile)
            UserDefaults.standard.set(resolvedUserId, forKey: "sphere_user_id")
            applyBackendUser(backendResponse.user)

            // Дотягиваем профиль из Supabase асинхронно — если он не дотянется, ничего страшного,
            // основная авторизация уже работает через Sphere-бэкенд.
            if supabaseUserId != nil {
                do {
                    try await upsertProfileInSupabase(profile)
                    _ = await fetchProfileFromSupabase()
                } catch {
                    print("[AuthService] Supabase profile sync failed (non-fatal): \(error.localizedDescription)")
                }
            }
        } catch {
            authError = error.localizedDescription
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let err = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        if err != errSecSuccess {
            return UUID().uuidString
        }
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex-строка SHA256 (как в GoTrue: fmt.Sprintf("%x", sha256.Sum256(...)))
    private func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Вход/регистрация по email: Go-бэкенд (код с почты, reCAPTCHA, сложность пароля) + Supabase profile.
    func signInWithEmail(
        nickname: String,
        email: String,
        password: String,
        emailVerificationCode: String,
        recaptchaToken: String,
        avatarUrl: String?,
        avatarImage: UIImage?
    ) async {
        authError = nil
        let userId = "email_\(email.hashValue)"
        let authResponse: AuthResponse
        do {
            authResponse = try await SphereAPIClient.shared.registerWithEmailVerification(
                email: email,
                password: password,
                name: nickname,
                emailCode: emailVerificationCode,
                recaptchaToken: recaptchaToken
            )
        } catch {
            let en = Locale.current.language.languageCode?.identifier != "ru"
            authError = error.localizedDescription
            if let e = error as? SphereAPIError, case .http(_, let msg) = e, let msg, let data = msg.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = j["error"] as? String {
                switch code {
                case "password_too_weak":
                    authError = en
                        ? "Password is too weak. Use more characters and mix letters, numbers, and symbols."
                        : "Слишком слабый пароль. Добавьте длину и разные типы символов."
                case "recaptcha_failed":
                    authError = en ? "Security check failed. Try again." : "Проверка безопасности не пройдена. Попробуйте снова."
                case "rate_limited":
                    authError = en ? "Too many code requests. Wait a minute." : "Слишком часто. Подождите минуту."
                default:
                    if code.contains("invalid") || code.contains("code") {
                        authError = en ? "Invalid or expired verification code." : "Неверный или просроченный код."
                    }
                }
            }
            return
        }
        SphereBackendPasswordKeychain.setBackendPassword(password, forEmail: email)

        var profile = UserProfile.placeholder(
            userId: userId,
            email: email,
            nickname: nickname,
            username: normalizedUsername(from: nickname, fallbackUserId: userId),
            provider: .email
        )
        profile.avatarUrl = avatarUrl
        if let image = avatarImage {
            await uploadAvatarIfNeeded(image: image, profile: &profile)
        }
        currentProfile = profile
        isSignedIn = true
        persistProfileLocally(profile)
        UserDefaults.standard.set(userId, forKey: "sphere_user_id")
        applyBackendUser(authResponse.user)

        do {
            try await upsertProfileInSupabase(profile)
            let avatarBeforeFetch = profile.avatarUrl
            _ = await fetchProfileFromSupabase()
            restoreAvatarUrlAfterFetchIfServerMissing(fallback: avatarBeforeFetch)
        } catch {
            authError = error.localizedDescription
        }
    }

    /// Создаёт локальный профиль `email_*` и Supabase-строку после успешного `/auth/login` или 2FA.
    func finalizeBackendEmailSignIn(response: AuthResponse, email: String, password: String) {
        SphereBackendPasswordKeychain.setBackendPassword(password, forEmail: email)
        let userId = "email_\(email.hashValue)"
        var profile = UserProfile.placeholder(
            userId: userId,
            email: response.user.email,
            nickname: response.user.name,
            username: normalizedUsername(from: response.user.name, fallbackUserId: userId),
            provider: .email
        )
        let trimmedAvatar = response.user.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAvatar.isEmpty {
            profile.avatarUrl = trimmedAvatar
        }
        currentProfile = profile
        isSignedIn = true
        persistProfileLocally(profile)
        UserDefaults.standard.set(userId, forKey: "sphere_user_id")
        applyBackendUser(response.user)
        Task {
            try? await upsertProfileInSupabase(profile)
            _ = await fetchProfileFromSupabase()
            await refreshBackendAccountFromServer()
        }
    }

    /// После входа по QR пароль неизвестен — JWT достаточно; keychain для почты не трогаем.
    func finalizeBackendLoginFromQR(_ response: AuthResponse) {
        let email = response.user.email
        let userId = "email_\(email.hashValue)"
        var profile = UserProfile.placeholder(
            userId: userId,
            email: email,
            nickname: response.user.name,
            username: normalizedUsername(from: response.user.name, fallbackUserId: userId),
            provider: .email
        )
        let trimmedAvatar = response.user.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAvatar.isEmpty {
            profile.avatarUrl = trimmedAvatar
        }
        currentProfile = profile
        isSignedIn = true
        persistProfileLocally(profile)
        UserDefaults.standard.set(userId, forKey: "sphere_user_id")
        applyBackendUser(response.user)
        Task {
            try? await upsertProfileInSupabase(profile)
            _ = await fetchProfileFromSupabase()
            await refreshBackendAccountFromServer()
        }
    }

    enum BackendPasswordLoginResult {
        case success
        case needsTwoFactor(challengeId: String, methods: [String])
        case failure(String)
    }

    func signInWithBackendEmailPassword(email: String, password: String) async -> BackendPasswordLoginResult {
        authError = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            switch try await SphereAPIClient.shared.loginWithPassword(email: trimmedEmail, password: password) {
            case .authenticated(let resp):
                finalizeBackendEmailSignIn(response: resp, email: trimmedEmail, password: password)
                return .success
            case .requiresTwoFactor(let cid, let methods):
                return .needsTwoFactor(challengeId: cid, methods: methods)
            }
        } catch {
            let isEnglish = Locale.current.language.languageCode?.identifier != "ru"
            if let e = error as? SphereAPIError, case .http(let status, let msg) = e {
                // 401 — invalid credentials; 404 — пользователь не найден.
                let msgLower = (msg ?? "").lowercased()
                if status == 401 || status == 404 || msgLower.contains("invalid") || msgLower.contains("not found") {
                    authError = isEnglish
                        ? "Invalid email or password. If you signed up with Google, use \"Continue with Google\" below."
                        : "Неверная почта или пароль. Если регистрировались через Google — войдите кнопкой ниже."
                    return .failure(authError ?? (isEnglish ? "Invalid credentials" : "Неверные данные"))
                }
                if status == 429 {
                    authError = isEnglish ? "Too many attempts. Wait a minute and try again." : "Слишком много попыток. Подождите минуту."
                    return .failure(authError ?? "")
                }
            }
            authError = error.localizedDescription
            return .failure(error.localizedDescription)
        }
    }

    func completeBackendTwoFactor(
        challengeId: String,
        method: String,
        code: String,
        email: String,
        password: String
    ) async -> Bool {
        authError = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let resp = try await SphereAPIClient.shared.verifyTwoFactor(
                challengeId: challengeId,
                method: method,
                code: code
            )
            finalizeBackendEmailSignIn(response: resp, email: trimmedEmail, password: password)
            return true
        } catch {
            authError = error.localizedDescription
            return false
        }
    }

    /// Если в ответе БД `avatar_url` пустой, а в памяти уже был валидный URL (локальный кэш / только что загрузили) — сохраняем его.
    private func mergeAvatarIfServerReturnedEmpty(local: UserProfile?, remote: UserProfile) -> UserProfile {
        var r = remote
        let remoteEmpty = r.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        guard remoteEmpty,
              let loc = local?.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else { return r }
        let scheme = URL(string: loc)?.scheme?.lowercased()
        let okRemote = scheme == "http" || scheme == "https"
        let okPreset = loc.hasPrefix("sphere-avatar-preset://")
        if okRemote || okPreset { r.avatarUrl = loc }
        return r
    }

    /// После регистрации Supabase иногда отдаёт строку без `avatar_url`; не затираем URL из Storage или пресет `sphere-avatar-preset://`.
    private func restoreAvatarUrlAfterFetchIfServerMissing(fallback: String?) {
        let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, var p = currentProfile else { return }
        let scheme = URL(string: trimmed)?.scheme?.lowercased()
        let okRemote = scheme == "http" || scheme == "https"
        let okPreset = trimmed.hasPrefix("sphere-avatar-preset://")
        guard okRemote || okPreset else { return }
        let fb = trimmed
        let cur = p.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard cur.isEmpty else { return }
        p.avatarUrl = fb
        currentProfile = p
        persistProfileLocally(p)
        Task {
            try? await upsertProfileInSupabase(p)
        }
    }

    private func uploadAvatarIfNeeded(image: UIImage, profile: inout UserProfile) async {
        guard let data = image.jpegData(compressionQuality: 0.7),
              let client = client,
              let userId = profile.userId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        let fileName = "\(userId)-\(Int(Date().timeIntervalSince1970)).jpg"
        do {
            _ = try await client.storage.from("avatars").upload(
                fileName,
                data: data,
                options: .init(contentType: "image/jpeg", upsert: true)
            )
            let url = try client.storage.from("avatars").getPublicURL(path: fileName)
            profile.avatarUrl = url.absoluteString
        } catch {
            authError = error.localizedDescription
        }
    }

    /// Загрузить профиль из Supabase по текущему userId
    @discardableResult
    private func fetchProfileFromSupabase() async -> Bool {
        guard let client = client else { return false }
        let userId = UserDefaults.standard.string(forKey: "sphere_user_id") ?? client.auth.currentUser?.id.uuidString
        guard let userId else { return false }
        do {
            let response: [UserProfile] = try await client.database
                .from("profiles")
                .select()
                .eq("user_id", value: userId)
                .execute()
                .value
            if let profile = response.first {
                let merged = mergeAvatarIfServerReturnedEmpty(local: currentProfile, remote: profile)
                currentProfile = merged
                isSignedIn = true
                persistProfileLocally(merged)
                UserDefaults.standard.set(merged.userId, forKey: "sphere_user_id")
                return true
            }
        } catch {
            // Сессия есть, профиль не найден — не сбрасываем isSignedIn
        }
        return false
    }

    /// Гарантирует, что в UI будет профиль: сначала пробуем прочитать строку из Supabase,
    /// затем строим локальный fallback из текущей auth/google-сессии.
    func ensureProfileAvailable() async {
        if await fetchProfileFromSupabase() { return }
        guard currentProfile == nil, let fallback = fallbackProfileFromAuthState() else { return }
        currentProfile = fallback
        isSignedIn = true
        persistProfileLocally(fallback)
        UserDefaults.standard.set(fallback.userId, forKey: "sphere_user_id")
    }

    /// Создать или обновить запись профиля в Supabase
    private func upsertProfileInSupabase(_ profile: UserProfile) async throws {
        var payload = profile
        payload.updatedAt = Date()
        if payload.createdAt == nil { payload.createdAt = Date() }
        do {
            guard let client = client else { return }
            try await client.database
                .from("profiles")
                .upsert(payload, onConflict: "user_id")
                .execute()
        } catch {
            throw error
        }
    }

    /// Локально обновить био без сети (предпросмотр на профиле при вводе в листе редактирования).
    func patchLocalBio(_ text: String) {
        guard var p = currentProfile else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        p.bio = trimmed.isEmpty ? nil : text
        currentProfile = p
    }

    /// Обновить профиль (никнейм, юзернейм, bio, аватар) и сохранить в Supabase.
    /// - Parameter updateBio: если `true`, поле `bio` перезаписывается значением `bio` (в том числе `nil` — очистка). Если `false`, био не меняем.
    func updateProfile(nickname: String?, username: String?, bio: String?, avatarUrl: String?, updateBio: Bool = false) async {
        guard var profile = currentProfile else { return }
        if let n = nickname { profile.nickname = n }
        if let u = username { profile.username = u }
        if updateBio { profile.bio = bio }
        if let a = avatarUrl { profile.avatarUrl = a }
        profile.updatedAt = Date()
        currentProfile = profile
        persistProfileLocally(profile)
        do {
            try await upsertProfileInSupabase(profile)
            _ = await fetchProfileFromSupabase()
        } catch {
            authError = error.localizedDescription
        }
    }

    func updateProfileAvatar(image: UIImage) async {
        guard var profile = currentProfile else { return }
        await uploadAvatarIfNeeded(image: image, profile: &profile)
        profile.updatedAt = Date()
        currentProfile = profile
        persistProfileLocally(profile)
        do {
            try await upsertProfileInSupabase(profile)
            _ = await fetchProfileFromSupabase()
        } catch {
            authError = error.localizedDescription
        }
    }

    /// Merge Go backend user (email login) into the local Supabase-backed profile.
    func applyBackendUser(_ u: BackendUser) {
        backendAccountSnapshot = u
        guard var profile = currentProfile else { return }
        profile.email = u.email
        profile.nickname = u.name
        let trimmed = u.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            profile.avatarUrl = trimmed
        }
        profile.updatedAt = Date()
        currentProfile = profile
        persistProfileLocally(profile)
        Task {
            try? await upsertProfileInSupabase(profile)
        }
    }

    /// Loads `/user/me` when a backend JWT exists (badges, verified, email).
    func refreshBackendAccountFromServer() async {
        guard SphereAPIClient.shared.isAuthenticated else {
            backendAccountSnapshot = nil
            return
        }
        do {
            let u = try await SphereAPIClient.shared.fetchCurrentUser()
            await MainActor.run {
                self.applyBackendUser(u)
            }
        } catch {
            await MainActor.run { backendAccountSnapshot = nil }
        }
    }

    private func persistProfileLocally(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: "sphere_profile")
        }
    }

    private func fallbackProfileFromAuthState() -> UserProfile? {
        if let user = client?.auth.currentUser {
            let metadata = user.userMetadata
            let userId = user.id.uuidString
            let email = user.email
            let nickname =
                metadata["full_name"]?.stringValue ??
                metadata["name"]?.stringValue ??
                email?.split(separator: "@").first.map(String.init) ??
                "User"
            let usernameSource =
                metadata["user_name"]?.stringValue ??
                metadata["preferred_username"]?.stringValue ??
                nickname

            var profile = UserProfile.placeholder(
                userId: userId,
                email: email,
                nickname: nickname,
                username: normalizedUsername(from: usernameSource, fallbackUserId: userId),
                provider: metadata["provider"]?.stringValue == AuthProvider.google.rawValue ? .google : .email
            )
            profile.avatarUrl = metadata["avatar_url"]?.stringValue
            profile.bio = metadata["bio"]?.stringValue
            return profile
        }

        if let googleUser = GIDSignIn.sharedInstance.currentUser {
            let userId = UserDefaults.standard.string(forKey: "sphere_user_id") ?? googleUser.userID ?? UUID().uuidString
            let email = googleUser.profile?.email
            let nickname = googleUser.profile?.name ?? "User"

            var profile = UserProfile.placeholder(
                userId: userId,
                email: email,
                nickname: nickname,
                username: normalizedUsername(from: nickname, fallbackUserId: userId),
                provider: .google
            )
            profile.avatarUrl = googleUser.profile?.imageURL(withDimension: 200)?.absoluteString
            return profile
        }

        return nil
    }

    private func normalizedUsername(from value: String, fallbackUserId: String) -> String {
        let cleaned = value.lowercased().filter { $0.isLetter || $0.isNumber }
        if cleaned.isEmpty {
            return "user_\(fallbackUserId.prefix(8))"
        }
        return String(cleaned.prefix(30))
    }

    /// Выход: очистить сессию и профиль
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        SphereAPIClient.shared.signOut()
        UserDefaults.standard.removeObject(forKey: "sphere_user_id")
        UserDefaults.standard.removeObject(forKey: "sphere_profile")
        currentProfile = nil
        backendAccountSnapshot = nil
        isSignedIn = false
        authError = nil
    }
}
