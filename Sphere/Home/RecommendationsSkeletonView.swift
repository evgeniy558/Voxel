import SwiftUI

/// Placeholder rails while `/recommendations` is loading.
struct RecommendationsSkeletonView: View {
    let isDarkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            skeletonRail()
            skeletonRail()
            skeletonRail()
        }
        .padding(.bottom, 16)
    }

    private func skeletonRail() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShimmerCapsule(height: 18, width: 160)
                .padding(.leading, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        ShimmerRoundedRect(corner: 14, width: 132, height: 172)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .accessibilityLabel(Text("Loading recommendations"))
    }
}

private struct ShimmerRoundedRect: View {
    let corner: CGFloat
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ShimmerOverlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: width, height: height)
        }
    }
}

private struct ShimmerCapsule: View {
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        ShimmerOverlay {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: width, height: height)
        }
    }
}

private struct ShimmerOverlay<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { t in
            let phase = abs(sin(t.date.timeIntervalSinceReferenceDate * 1.2))
            content()
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.12 + phase * 0.08),
                            Color.white.opacity(0.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .blendMode(.plusLighter)
                }
                .clipped()
        }
    }
}
