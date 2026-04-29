import Foundation
import Combine
import CryptoKit
import GoogleSignIn
import UIKit

/// Bridges `AuthService` (Supabase/Google) → `SphereAPIClient` JWT.
///
/// Sphere users don't know about the Go backend — we register/login them transparently
/// whenever `AuthService.shared.currentProfile` is present and the backend JWT is missing.
///
/// Strategy:
/// - Google users: call `POST /auth/google` with the current `GIDSignIn` idToken.
/// - Email users:  derive a deterministic password `SHA256(userId + deviceId)` and try
///                  `POST /auth/login` first; on 401 fall back to `POST /auth/register`.
@MainActor
final class SphereBackendAuth: ObservableObject {
    static let shared = SphereBackendAuth()

    private let api = SphereAPIClient.shared
    private let authService = AuthService.shared
    private var cancellables: Set<AnyCancellable> = []
    private var bridgeTask: Task<Void, Never>?

    /// Stable per-install identifier used as the password salt for email accounts.
    private var deviceId: String {
        let key = "sphere_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    private init() {}

    /// Call once on app launch. Kicks off an initial bridge attempt and listens for Sphere auth changes.
    func start() {
        authService.$currentProfile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] profile in
                guard let self = self else { return }
                if profile != nil {
                    self.bridgeIfNeeded()
                } else {
                    // User signed out of Sphere → also drop backend JWT.
                    self.api.signOut()
                }
            }
            .store(in: &cancellables)

        bridgeIfNeeded()
    }

    /// Ensure we have a backend JWT. No-op if already authenticated.
    func bridgeIfNeeded() {
        guard !api.isAuthenticated else { return }
        guard let profile = authService.currentProfile else { return }
        bridgeTask?.cancel()
        bridgeTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.performBridge(profile: profile)
            } catch {
                print("[SphereBackendAuth] bridge failed:", error.localizedDescription)
            }
        }
    }

    private func performBridge(profile: UserProfile) async throws {
        if profile.authProvider == AuthProvider.google.rawValue,
           let idToken = GIDSignIn.sharedInstance.currentUser?.idToken?.tokenString {
            _ = try await api.loginWithGoogle(idToken: idToken)
            UserDefaults.standard.set(true, forKey: "sphereJustAuthenticated")
            return
        }

        // Email: пароль из Keychain после верификации на бэкенде; иначе старый derive (миграция).
        let email = profile.email ?? "\(profile.userId)@sphere.local"
        if let saved = SphereBackendPasswordKeychain.getBackendPassword(forEmail: email) {
            do {
                _ = try await api.login(email: email, password: saved)
                UserDefaults.standard.set(true, forKey: "sphereJustAuthenticated")
            } catch SphereAPIError.secondFactorRequired {
                print("[SphereBackendAuth] 2FA enabled; open the app and sign in with the second factor")
            } catch {
                print("[SphereBackendAuth] email keychain login:", error.localizedDescription)
            }
            return
        }
        let password = derivePassword(for: profile.userId)
        do {
            _ = try await api.login(email: email, password: password)
            UserDefaults.standard.set(true, forKey: "sphereJustAuthenticated")
        } catch SphereAPIError.secondFactorRequired {
            print("[SphereBackendAuth] 2FA enabled; open the app and sign in with the second factor")
        } catch SphereAPIError.http(let status, _) where status == 401 || status == 404 {
            if email.lowercased().hasSuffix("@sphere.app") || email.lowercased().hasSuffix("@sphere.local") {
                _ = try await api.register(email: email, password: password, name: profile.nickname)
                UserDefaults.standard.set(true, forKey: "sphereJustAuthenticated")
            }
        } catch SphereAPIError.unauthorized {
            if email.lowercased().hasSuffix("@sphere.app") || email.lowercased().hasSuffix("@sphere.local") {
                _ = try await api.register(email: email, password: password, name: profile.nickname)
                UserDefaults.standard.set(true, forKey: "sphereJustAuthenticated")
            }
        }
    }

    private func derivePassword(for userId: String) -> String {
        let material = Data("\(userId):\(deviceId)".utf8)
        let digest = SHA256.hash(data: material)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
