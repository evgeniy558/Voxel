import SwiftUI
import UIKit
import Combine

// MARK: - Tab paging driver (общий драйвер анимации для свайпа)

final class TabPagingDriver: ObservableObject {
    @Published private(set) var currentPage: CGFloat = 0
    @Published private(set) var isSnapping: Bool = false
    private var snapTarget: CGFloat = 0
    private var snapStart: CGFloat = 0
    private var snapStartTime: CFTimeInterval = 0
    private var snapDuration: Double = 0.25
    private let smoothstep: (Double) -> Double = { t in
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }

    func setPage(_ page: CGFloat) {
        currentPage = page
    }

    private var snapCompletion: (() -> Void)?

    func snap(to targetPage: CGFloat, duration: Double = 0.25, completion: (() -> Void)? = nil) {
        let t = targetPage
        guard abs(t - currentPage) > 0.001 else {
            completion?()
            return
        }
        snapStart = currentPage
        snapTarget = t
        snapStartTime = CACurrentMediaTime()
        snapDuration = max(0.01, duration)
        snapCompletion = completion
        isSnapping = true
    }

    func tick(_ timestamp: CFTimeInterval) {
        let elapsed = timestamp - snapStartTime
        let progress = min(1, elapsed / snapDuration)
        let eased = smoothstep(progress)
        let value = snapStart + (snapTarget - snapStart) * CGFloat(eased)
        currentPage = value
        if progress >= 1 {
            isSnapping = false
            snapCompletion?()
            snapCompletion = nil
        }
    }
}

@available(iOS 15.0, *)
private struct TabPagingDisplayLinkView: UIViewRepresentable {
    @ObservedObject var driver: TabPagingDriver

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.driver = driver
        if driver.isSnapping {
            if context.coordinator.displayLink == nil {
                let link = CADisplayLink(target: context.coordinator, selector: #selector(Coordinator.tick(_:)))
                let maxFPS = UIScreen.main.maximumFramesPerSecond
                let fps = Float(maxFPS > 0 ? min(120, maxFPS) : 120)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30 as Float, maximum: fps, preferred: fps)
                link.add(to: .main, forMode: .common)
                context.coordinator.displayLink = link
            }
        } else {
            context.coordinator.displayLink?.invalidate()
            context.coordinator.displayLink = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var displayLink: CADisplayLink?
        weak var driver: TabPagingDriver?

        @objc func tick(_ link: CADisplayLink) {
            driver?.tick(link.targetTimestamp)
        }
    }
}

// MARK: - Вью слота обложки

struct PlayerSheetCoverSlotView: View {
    let image: UIImage?
    let accent: Color
    let size: CGFloat
    let cornerRadius: CGFloat

    init(image: UIImage?, accent: Color, size: CGFloat, cornerRadius: CGFloat = 36) {
        self.image = image
        self.accent = accent
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(accent)
            .frame(width: size, height: size)
            .overlay(
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    } else {
                        Image("Voxmusic")
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                            .padding(24)
                    }
                }
            )
    }
}

// MARK: - UIScrollView + Coordinator

private let playerCoverSpacing: CGFloat = 48

private final class PlayerSheetCoverScrollViewCoordinator: NSObject, UIScrollViewDelegate {
    var scrollView: UIScrollView?
    var hostingController: UIHostingController<AnyView>?
    weak var pagingDriver: TabPagingDriver?
    var pageWidth: CGFloat = 0
    var trackCount: Int = 0
    var currentIndex: Int = 0
    var onTrackSelected: ((Int) -> Void)?
    var snapDuration: Double = 0.28
    var isSnapping: Bool = false

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard pageWidth > 0, trackCount > 0, !isSnapping else { return }
        let minX = CGFloat(max(0, currentIndex - 1)) * pageWidth
        let maxX = CGFloat(min(trackCount - 1, currentIndex + 1)) * pageWidth
        let x = scrollView.contentOffset.x
        if x < minX {
            scrollView.contentOffset = CGPoint(x: minX, y: 0)
        } else if x > maxX {
            scrollView.contentOffset = CGPoint(x: maxX, y: 0)
        }
        let page = scrollView.contentOffset.x / pageWidth
        pagingDriver?.setPage(page)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate { return }
        snapAndNotify(scrollView: scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        snapAndNotify(scrollView: scrollView)
    }

    /// Порог переключения трека (доля ширины страницы): 0.25 = достаточно небольшого свайпа.
    private static let pageFlipThreshold: CGFloat = 0.25

    private func snapAndNotify(scrollView: UIScrollView) {
        guard pageWidth > 0, trackCount > 0 else { return }
        let page = scrollView.contentOffset.x / pageWidth
        let cur = CGFloat(currentIndex)
        let delta = page - cur
        let target: Int
        if delta > Self.pageFlipThreshold {
            target = min(trackCount - 1, currentIndex + 1)
        } else if delta < -Self.pageFlipThreshold {
            target = max(0, currentIndex - 1)
        } else {
            target = currentIndex
        }
        currentIndex = target
        let targetC = CGFloat(target)
        pagingDriver?.setPage(targetC)
        onTrackSelected?(target)
        isSnapping = true
        UIView.animate(withDuration: snapDuration, delay: 0, options: [.curveEaseOut]) {
            scrollView.contentOffset = CGPoint(x: targetC * self.pageWidth, y: 0)
        } completion: { _ in
            self.isSnapping = false
        }
    }
}

private struct PlayerSheetCoverScrollViewRepresentable: UIViewRepresentable {
    let artworkSize: CGFloat
    let coverCornerRadius: CGFloat
    let coverImages: [UIImage?]
    let currentIndex: Int
    let accent: Color
    @ObservedObject var pagingDriver: TabPagingDriver
    var onTrackSelected: (Int) -> Void

    private var trackCount: Int { coverImages.count }
    private var pageWidth: CGFloat { artworkSize + playerCoverSpacing }
    private var totalWidth: CGFloat {
        guard trackCount > 0 else { return 0 }
        return CGFloat(trackCount) * artworkSize + CGFloat(max(0, trackCount - 1)) * playerCoverSpacing
    }

    func makeCoordinator() -> PlayerSheetCoverScrollViewCoordinator {
        let c = PlayerSheetCoverScrollViewCoordinator()
        c.pageWidth = pageWidth
        c.trackCount = trackCount
        c.currentIndex = max(0, min(currentIndex, trackCount - 1))
        c.onTrackSelected = onTrackSelected
        return c
    }

    func makeUIView(context: Context) -> UIScrollView {
        let w = artworkSize
        let spacing = playerCoverSpacing
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.clipsToBounds = true
        sv.decelerationRate = UIScrollView.DecelerationRate(rawValue: 0.85)
        sv.delegate = context.coordinator
        context.coordinator.scrollView = sv
        context.coordinator.pagingDriver = pagingDriver

        let row = HStack(spacing: spacing) {
            ForEach(Array(coverImages.enumerated()), id: \.offset) { _, img in
                PlayerSheetCoverSlotView(image: img, accent: accent, size: w, cornerRadius: coverCornerRadius)
                    .frame(width: w, height: w)
            }
        }
        .frame(width: totalWidth, height: w, alignment: .leading)

        let host = UIHostingController(rootView: AnyView(row))
        context.coordinator.hostingController = host
        host.view.backgroundColor = UIColor.clear
        host.view.frame = CGRect(x: 0, y: 0, width: totalWidth, height: w)
        sv.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            host.view.heightAnchor.constraint(equalToConstant: w)
        ])

        sv.contentSize = CGSize(width: totalWidth, height: w)
        let targetX = CGFloat(currentIndex) * pageWidth
        sv.contentOffset = CGPoint(x: targetX, y: 0)
        pagingDriver.setPage(CGFloat(currentIndex))

        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.pagingDriver = pagingDriver
        context.coordinator.pageWidth = pageWidth
        context.coordinator.trackCount = trackCount
        context.coordinator.currentIndex = max(0, min(currentIndex, trackCount - 1))
        context.coordinator.onTrackSelected = onTrackSelected

        let row = HStack(spacing: playerCoverSpacing) {
            ForEach(Array(coverImages.enumerated()), id: \.offset) { _, img in
                PlayerSheetCoverSlotView(image: img, accent: accent, size: artworkSize, cornerRadius: coverCornerRadius)
                    .frame(width: artworkSize, height: artworkSize)
            }
        }
        .frame(width: totalWidth, height: artworkSize, alignment: .leading)
        context.coordinator.hostingController?.rootView = AnyView(row)

        let targetX = CGFloat(currentIndex) * pageWidth
        if !context.coordinator.isSnapping, !sv.isDragging, !sv.isDecelerating, abs(sv.contentOffset.x - targetX) > 1 {
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
                sv.contentOffset = CGPoint(x: targetX, y: 0)
            }
            pagingDriver.setPage(CGFloat(currentIndex))
        }
        if sv.contentSize.width != totalWidth || sv.contentSize.height != artworkSize {
            sv.contentSize = CGSize(width: totalWidth, height: artworkSize)
        }
    }
}

// MARK: - Обёртка для SwiftUI (календарь обложек)

struct PlayerSheetCoverPagingView: View {
    @ObservedObject var pagingDriver: TabPagingDriver
    let trackCount: Int
    let coverImages: [UIImage?]
    let currentIndex: Int
    let accent: Color
    let artworkSize: CGFloat
    var coverCornerRadius: CGFloat = 36
    let onTrackSelected: (Int) -> Void

    var body: some View {
        let w = artworkSize
        if trackCount == 0 {
            Color.clear.frame(width: w, height: w)
        } else if trackCount == 1 {
            PlayerSheetCoverSlotView(image: coverImages.first ?? nil, accent: accent, size: w, cornerRadius: coverCornerRadius)
                .frame(width: w, height: w)
                .frame(maxWidth: .infinity)
        } else {
            PlayerSheetCoverScrollViewRepresentable(
                artworkSize: w,
                coverCornerRadius: coverCornerRadius,
                coverImages: coverImages,
                currentIndex: max(0, min(currentIndex, trackCount - 1)),
                accent: accent,
                pagingDriver: pagingDriver,
                onTrackSelected: onTrackSelected
            )
            .frame(width: w, height: w)
        }
    }
}

