//
//  DiscordRPC.swift
//  Sphere
//
//  Discord Rich Presence: OAuth2 авторизация + Gateway WebSocket для отображения
//  «Listening to …» в профиле Discord.
//

import Foundation
import Combine
import AuthenticationServices
import SwiftUI

// MARK: - DiscordRPC

@MainActor
final class DiscordRPC: NSObject, ObservableObject {
    static let shared = DiscordRPC()

    // ── Discord Application ─────────────────────────────────────────────
    private static let clientId = "1489251513804128316"
    private static let clientSecret = "BCSO4K5wSgd6Bs2Fe53-TCZaWz0LkS-1"
    private static let redirectScheme = "sphere-discord"
    private static let redirectURI = "\(redirectScheme)://callback"
    private static let scopes = "identify rpc activities.write"
    private static let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!

    // ── Published state ─────────────────────────────────────────────────
    @Published var isConnected = false
    @Published var discordUsername: String?
    @Published var discordAvatar: String?
    @Published var discordUserId: String?
    @Published var statusText: String?

    // ── Persistence ─────────────────────────────────────────────────────
    @AppStorage("discord_access_token") private var accessToken: String = ""
    @AppStorage("discord_refresh_token") private var refreshToken: String = ""
    @AppStorage("discord_username") private var storedUsername: String = ""
    @AppStorage("discord_user_id") private var storedUserId: String = ""
    @AppStorage("discord_avatar") private var storedAvatar: String = ""
    @AppStorage("discord_rpc_enabled") var isEnabled: Bool = false

    // ── WebSocket ───────────────────────────────────────────────────────
    private var webSocket: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var lastSequence: Int?
    private var sessionId: String?
    private var isResuming = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    // ── Current activity ────────────────────────────────────────────────
    private var currentActivity: [String: Any]?

    // ── ASWebAuthenticationSession anchor ────────────────────────────────
    private var authSession: ASWebAuthenticationSession?

    override private init() {
        super.init()
        if !storedUsername.isEmpty {
            discordUsername = storedUsername
            discordUserId = storedUserId
            discordAvatar = storedAvatar
        }
        if !accessToken.isEmpty && isEnabled {
            Task { await connectGateway() }
        }
    }

    // MARK: - Public API

    /// Запуск OAuth2 авторизации через Discord.
    func authorize() {
        let urlString = "https://discord.com/oauth2/authorize"
            + "?client_id=\(Self.clientId)"
            + "&response_type=code"
            + "&redirect_uri=\(Self.redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.redirectURI)"
            + "&scope=\(Self.scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.scopes)"

        guard let url = URL(string: urlString) else { return }

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.redirectScheme) { [weak self] callbackURL, error in
            guard let self, let callbackURL, error == nil else {
                Task { @MainActor in self?.statusText = "Authorization cancelled" }
                return
            }
            Task { await self.handleCallback(callbackURL) }
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        authSession = session
        session.start()
    }

    /// Отключение Discord.
    func disconnect() {
        closeGateway()
        accessToken = ""
        refreshToken = ""
        storedUsername = ""
        storedUserId = ""
        storedAvatar = ""
        discordUsername = nil
        discordUserId = nil
        discordAvatar = nil
        isConnected = false
        isEnabled = false
        statusText = nil
        currentActivity = nil
    }

    /// Обновить присутствие (вызывается при смене трека / play / pause).
    func updatePresence(title: String?, artist: String?, elapsed: TimeInterval = 0) {
        guard isEnabled, !accessToken.isEmpty else { return }

        guard let title, !title.isEmpty else {
            clearPresence()
            return
        }

        var activity: [String: Any] = [
            "name": "Sphere",
            "type": 2, // Listening
            "details": title,
        ]
        if let artist, !artist.isEmpty {
            activity["state"] = artist
        }
        let startEpoch = Int(Date().timeIntervalSince1970 - elapsed)
        activity["timestamps"] = ["start": startEpoch]
        activity["assets"] = [
            "large_image": "sphere_icon",
            "large_text": "Sphere Music Player"
        ]

        currentActivity = activity
        sendPresenceUpdate()
    }

    /// Очистить присутствие (пауза / стоп).
    func clearPresence() {
        currentActivity = nil
        sendPresenceUpdate()
    }

    // MARK: - OAuth2 Callback

    private func handleCallback(_ url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            statusText = "No authorization code received"
            return
        }
        await exchangeCode(code)
    }

    private func exchangeCode(_ code: String) async {
        let endpoint = URL(string: "https://discord.com/api/v10/oauth2/token")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": Self.clientId,
            "client_secret": Self.clientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                statusText = "Token exchange failed"
                return
            }
            accessToken = token
            if let rt = json["refresh_token"] as? String { refreshToken = rt }
            isEnabled = true

            await fetchCurrentUser()
            await connectGateway()
        } catch {
            statusText = "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Discord REST API

    private func fetchCurrentUser() async {
        let endpoint = URL(string: "https://discord.com/api/v10/users/@me")!
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let username = json["username"] as? String ?? ""
            let globalName = json["global_name"] as? String
            let userId = json["id"] as? String ?? ""
            let avatar = json["avatar"] as? String ?? ""

            discordUsername = globalName ?? username
            discordUserId = userId
            discordAvatar = avatar
            storedUsername = discordUsername ?? ""
            storedUserId = userId
            storedAvatar = avatar
            statusText = nil
        } catch {
            statusText = "Failed to fetch user info"
        }
    }

    // MARK: - Gateway WebSocket

    private func connectGateway() async {
        closeGateway()

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: Self.gatewayURL)
        webSocket = ws
        ws.resume()

        statusText = "Connecting…"
        receiveMessage()
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleGatewayMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleGatewayMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveMessage()

                case .failure(let error):
                    print("[DiscordRPC] WebSocket error: \(error.localizedDescription)")
                    self.isConnected = false
                    self.statusText = "Disconnected"
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleGatewayMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else { return }

        if let s = json["s"] as? Int {
            lastSequence = s
        }

        switch op {
        case 10: // Hello
            guard let d = json["d"] as? [String: Any],
                  let interval = d["heartbeat_interval"] as? Double else { return }
            startHeartbeat(interval: interval / 1000.0)
            sendIdentify()

        case 0: // Dispatch
            let t = json["t"] as? String
            if t == "READY" {
                if let d = json["d"] as? [String: Any] {
                    sessionId = d["session_id"] as? String
                }
                isConnected = true
                reconnectAttempts = 0
                statusText = "Connected"
                sendPresenceUpdate()
            }

        case 7: // Reconnect
            Task { await connectGateway() }

        case 9: // Invalid Session
            let resumable = json["d"] as? Bool ?? false
            if resumable {
                isResuming = true
                Task { await connectGateway() }
            } else {
                sessionId = nil
                isResuming = false
                isConnected = false
                statusText = "Session invalid"
                scheduleReconnect()
            }

        case 1: // Heartbeat request
            sendHeartbeat()

        case 11: // Heartbeat ACK
            break

        default:
            break
        }
    }

    // MARK: - Gateway Payloads

    private func sendIdentify() {
        let identify: [String: Any] = [
            "op": 2,
            "d": [
                "token": accessToken,
                "properties": [
                    "os": "ios",
                    "browser": "Sphere",
                    "device": "Sphere"
                ],
                "presence": presencePayload()
            ]
        ]
        sendJSON(identify)
    }

    private func sendPresenceUpdate() {
        guard isConnected else { return }
        let update: [String: Any] = [
            "op": 3,
            "d": presencePayload()
        ]
        sendJSON(update)
    }

    private func presencePayload() -> [String: Any] {
        var payload: [String: Any] = [
            "status": "online",
            "afk": false,
            "since": 0,
        ]
        if let activity = currentActivity {
            payload["activities"] = [activity]
        } else {
            payload["activities"] = [] as [[String: Any]]
        }
        return payload
    }

    // MARK: - Heartbeat

    private func startHeartbeat(interval: TimeInterval) {
        heartbeatTimer?.invalidate()
        // Первый heartbeat — случайная задержка от 0 до interval (по спецификации Discord).
        let jitter = Double.random(in: 0..<interval)
        DispatchQueue.main.asyncAfter(deadline: .now() + jitter) { [weak self] in
            self?.sendHeartbeat()
            self?.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        let hb: [String: Any?] = ["op": 1, "d": lastSequence]
        if let data = try? JSONSerialization.data(withJSONObject: hb),
           let text = String(data: data, encoding: .utf8) {
            webSocket?.send(.string(text)) { _ in }
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard isEnabled, !accessToken.isEmpty, reconnectAttempts < maxReconnectAttempts else {
            statusText = "Reconnect failed"
            return
        }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isEnabled else { return }
            Task { await self.connectGateway() }
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { error in
            if let error {
                print("[DiscordRPC] Send error: \(error.localizedDescription)")
            }
        }
    }

    private func closeGateway() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension DiscordRPC: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        return windowScene?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
