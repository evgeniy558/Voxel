//
//  SplashScreenView.swift
//  Sphere
//
//  Заставка при первом запуске: sphereblack3.mp4 для тёмной темы, spherewhite3.mp4 для светлой.
//

import SwiftUI
import AVFoundation

/// Ключ флага "заставка уже показана" (используется в SphereApp через @AppStorage).
let kSphereHasSeenLaunchSplash = "SphereHasSeenLaunchSplash"

struct SplashScreenView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("preferredColorScheme") private var preferredColorSchemeRaw: String = ""
    let onFinish: () -> Void
    @State private var isVisible: Bool = true

    /// Темнота заставки: если в приложении выбрана явная тема — используем её; иначе опираемся на системную.
    private var isDark: Bool {
        switch preferredColorSchemeRaw {
        case "dark":
            return true
        case "light":
            return false
        default:
            return colorScheme == .dark
        }
    }

    var body: some View {
        ZStack {
            (isDark ? Color.black : Color.white)
                .ignoresSafeArea()

            SplashVideoPlayer(
                videoName: isDark ? "sphereblack3" : "spherewhite3",
                onDidFinish: handleVideoFinished
            )
            .ignoresSafeArea()
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: isVisible)
        .statusBarHidden(true)
    }

    private func handleVideoFinished() {
        // Плавное исчезновение заставки, затем переход в приложение
        isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onFinish()
        }
    }
}

// MARK: - AVPlayerLayer на весь экран

private struct SplashVideoPlayer: UIViewRepresentable {
    let videoName: String
    let onDidFinish: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = SplashVideoUIView()
        view.backgroundColor = .clear
        view.configure(with: videoName, onDidFinish: onDidFinish)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class SplashVideoUIView: UIView {
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func configure(with name: String, onDidFinish: @escaping () -> Void) {
        // 1) path из бандла (как в примерах на SO)
        guard let path = Bundle.main.path(forResource: name, ofType: "mp4") else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onDidFinish() }
            return
        }
        let url = URL(fileURLWithPath: path)
        print("Splash: found path = \(path)")

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.isMuted = false

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.black.cgColor
        self.layer.addSublayer(layer)
        playerLayer = layer

        // По окончании — переходим в приложение
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.finish(onDidFinish: onDidFinish)
        }

        player.play()
    }

    private func finish(onDidFinish: @escaping () -> Void) {
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
        }
        endObserver = nil
        onDidFinish()
    }

    deinit {
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}

