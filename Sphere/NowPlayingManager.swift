//
//  NowPlayingManager.swift
//  Sphere
//
//  Control Center, Lock Screen, Dynamic Island (Now Playing info + remote commands).
//

import Foundation
import MediaPlayer
import UIKit
import Combine

/// Команда с Lock Screen / Control Center для выполнения во view.
enum RemotePlaybackCommand: Equatable {
    case playPause
    case nextTrack
    case previousTrack
    case seek(position: TimeInterval)
}

/// ObservableObject: при получении удалённой команды выставляет pendingCommand; view обрабатывает в .onChange.
final class RemotePlaybackObserver: ObservableObject {
    @Published var pendingCommand: RemotePlaybackCommand?

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .sphereRemotePlayPause)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pendingCommand = .playPause }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .sphereRemoteNextTrack)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pendingCommand = .nextTrack }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .sphereRemotePreviousTrack)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pendingCommand = .previousTrack }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .sphereRemoteSeek)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let pos = (notification.userInfo?[sphereRemoteSeekPositionKey] as? TimeInterval) ?? 0
                self?.pendingCommand = .seek(position: pos)
            }
            .store(in: &cancellables)
    }
}

/// Уведомления для реакций из ContentView на команды с Lock Screen / Control Center / Dynamic Island.
extension Notification.Name {
    static let sphereRemotePlayPause = Notification.Name("SphereRemotePlayPause")
    static let sphereRemoteNextTrack = Notification.Name("SphereRemoteNextTrack")
    static let sphereRemotePreviousTrack = Notification.Name("SphereRemotePreviousTrack")
    static let sphereRemoteSeek = Notification.Name("SphereRemoteSeek")
}

/// Ключ в userInfo для позиции при seek: TimeInterval.
let sphereRemoteSeekPositionKey = "position"

final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private let center = MPNowPlayingInfoCenter.default()
    private let remote = MPRemoteCommandCenter.shared()

    private var animatedTimer: Timer?
    private var animatedFrames: [UIImage] = []
    private var animatedFrameIndex: Int = 0
    private var animatedClipKey: String?

    /// Системная фиолетовая обложка с Voxmusic для Lock Screen / Control Center, когда у трека нет загруженной обложки.
    private static let defaultPurpleArtworkImage: UIImage = {
        let size: CGFloat = 512
        let color = UIColor(named: "AccentColor") ?? UIColor(red: 0.45, green: 0.25, blue: 0.75, alpha: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            color.setFill()
            ctx.fill(rect)
            if let vox = UIImage(named: "Voxmusic") {
                let padding: CGFloat = 64
                let inner = rect.insetBy(dx: padding, dy: padding)
                let voxSize = vox.size
                let scale = min(inner.width / voxSize.width, inner.height / voxSize.height)
                let drawW = voxSize.width * scale
                let drawH = voxSize.height * scale
                let drawRect = CGRect(
                    x: rect.midX - drawW / 2,
                    y: rect.midY - drawH / 2,
                    width: drawW,
                    height: drawH
                )
                vox.draw(in: drawRect)
            }
        }
    }()

    private init() {
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        remote.playCommand.addTarget { [weak self] _ in
            NotificationCenter.default.post(name: .sphereRemotePlayPause, object: nil)
            return .success
        }
        remote.pauseCommand.addTarget { [weak self] _ in
            NotificationCenter.default.post(name: .sphereRemotePlayPause, object: nil)
            return .success
        }
        remote.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .sphereRemotePlayPause, object: nil)
            return .success
        }
        remote.nextTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .sphereRemoteNextTrack, object: nil)
            return .success
        }
        remote.previousTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .sphereRemotePreviousTrack, object: nil)
            return .success
        }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            NotificationCenter.default.post(
                name: .sphereRemoteSeek,
                object: nil,
                userInfo: [sphereRemoteSeekPositionKey: event.positionTime]
            )
            return .success
        }
    }

    /// Вызывать при смене трека или обновлении позиции/состояния воспроизведения.
    func update(
        title: String?,
        artist: String?,
        duration: TimeInterval,
        currentTime: TimeInterval,
        isPlaying: Bool,
        artwork: UIImage?,
        clipURL: URL? = nil
    ) {
        var info = center.nowPlayingInfo ?? [String: Any]()
        info[MPMediaItemPropertyTitle] = title ?? ""
        info[MPMediaItemPropertyArtist] = artist ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        let imageToShow = artwork ?? Self.defaultPurpleArtworkImage
        let mpArtwork = MPMediaItemArtwork(boundsSize: imageToShow.size) { _ in imageToShow }
        info[MPMediaItemPropertyArtwork] = mpArtwork
        center.nowPlayingInfo = info

        if let clipURL = clipURL {
            startAnimatedArtwork(for: clipURL)
        } else {
            stopAnimatedArtwork()
        }
    }

    private func startAnimatedArtwork(for clipURL: URL) {
        let key = clipURL.absoluteString
        if animatedClipKey == key, !animatedFrames.isEmpty { return }
        stopAnimatedArtwork()
        animatedClipKey = key
        Task { @MainActor in
            guard let frames = await AnimatedArtworkExtractor.shared.frames(for: clipURL),
                  !frames.images.isEmpty,
                  self.animatedClipKey == key else { return }
            self.animatedFrames = frames.images
            self.animatedFrameIndex = 0
            let interval: TimeInterval = 1.0 / 12.0
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.advanceAnimatedFrame()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.animatedTimer = timer
        }
    }

    private func stopAnimatedArtwork() {
        animatedTimer?.invalidate()
        animatedTimer = nil
        animatedFrames = []
        animatedFrameIndex = 0
        animatedClipKey = nil
    }

    private func advanceAnimatedFrame() {
        guard !animatedFrames.isEmpty else { return }
        let image = animatedFrames[animatedFrameIndex % animatedFrames.count]
        animatedFrameIndex = (animatedFrameIndex + 1) % animatedFrames.count
        var info = center.nowPlayingInfo ?? [:]
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        info[MPMediaItemPropertyArtwork] = artwork
        center.nowPlayingInfo = info
    }

    /// Сброс (когда воспроизведение остановлено).
    func clear() {
        stopAnimatedArtwork()
        center.nowPlayingInfo = nil
    }
}
