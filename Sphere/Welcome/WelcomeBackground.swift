import SwiftUI

// MARK: - Colors

extension Color {
    static let welcomeBackground = Color(red: 13 / 255, green: 13 / 255, blue: 27 / 255)
}

// MARK: - Grid (thin lines)

struct WelcomeGridCanvas: View {
    var spacing: CGFloat = 24
    var lineWidth: CGFloat = 0.5
    var lineOpacity: Double = 0.06

    var body: some View {
        Canvas { context, size in
            let gridColor = Color.white.opacity(lineOpacity)
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(gridColor), lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Soft moving white light (radial gradient orb)

struct WelcomeLightOrb: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
            GeometryReader { geo in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let w = geo.size.width
                let h = geo.size.height
                // Gentle Lissajous-ish path so the glow feels alive
                let ax = w * 0.35
                let ay = h * 0.28
                let cx = w * 0.5 + CGFloat(sin(t * 0.35)) * ax
                let cy = h * 0.42 + CGFloat(cos(t * 0.29)) * ay

                RadialGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.04),
                        Color.white.opacity(0),
                    ],
                    center: UnitPoint(x: cx / max(w, 1), y: cy / max(h, 1)),
                    startRadius: 40,
                    endRadius: min(w, h) * 0.48
                )
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Snow (small dots falling)

private struct SnowParticle: Sendable {
    var xNorm: CGFloat
    var speed: CGFloat
    var drift: CGFloat
    var size: CGFloat
    var phase: CGFloat
}

struct WelcomeSnowCanvas: View {
    private let particleCount = 52
    @State private var particles: [SnowParticle] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let t = CGFloat(timeline.date.timeIntervalSinceReferenceDate)
                Canvas { context, size in
                    guard !particles.isEmpty else { return }
                    for p in particles {
                        let fall = (t * p.speed + p.phase).truncatingRemainder(dividingBy: 1)
                        let y = fall * (h + 80) - 40
                        let sway = sin(t * p.drift + p.phase * 10) * 14
                        let x = p.xNorm * w + sway
                        let rect = CGRect(x: x - p.size * 0.5, y: y - p.size * 0.5, width: p.size, height: p.size)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)))
                    }
                }
                .onAppear {
                    if particles.isEmpty {
                        particles = (0..<particleCount).map { i in
                            let seed = CGFloat(i)
                            return SnowParticle(
                                xNorm: CGFloat((i * 9973 % 1000)) / 1000,
                                speed: 0.12 + CGFloat(i % 7) * 0.02,
                                drift: 0.5 + CGFloat(i % 5) * 0.13,
                                size: 1 + CGFloat(i % 3),
                                phase: seed * 0.01
                            )
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Stack

struct WelcomeBackgroundView: View {
    var body: some View {
        ZStack {
            Color.welcomeBackground
            WelcomeGridCanvas()
                .mask(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color.white.opacity(0.55),
                            Color.white.opacity(0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            WelcomeLightOrb()
            WelcomeSnowCanvas()
        }
    }
}
