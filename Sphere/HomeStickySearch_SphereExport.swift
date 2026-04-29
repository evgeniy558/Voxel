//
//  HomeStickySearch_SphereExport.swift
//  Экспорт из Sphere (ContentView.swift) — липкий поиск на главной + UIKit-блюр под капсулой.
//  Добавьте в таргет. Нужны: AccentColor, iOS 16+. На iOS 26 — .glassEffect у капсулы.
//

import SwiftUI
import UIKit
import QuartzCore

// MARK: - Метрики (пара `latchScrollY` + `stickyPlaceholderRowHeight` должна совпадать с вёрсткой скролла)
enum HomeStickySearchMetrics {
    /// Прокрутка, после которой капсула «закрепляется»; в паре с высотой плейсхолдера в скролле.
    static let latchScrollY: CGFloat = 158
    static let blurPanelBottomRoundingBleed: CGFloat = 8
    static let blurPanelLayoutSlack: CGFloat = 4
    static let pinnedBarBottomCornerRadius: CGFloat = 32
    static let searchHorizontalInset: CGFloat = 12
    /// Пустой ряд под капсулу в контенте `ScrollView` (не путать с высотой самой капсулы).
    static let stickyPlaceholderRowHeight: CGFloat = 122
    static let pinnedBlurFadeDistance: CGFloat = 40
}

// MARK: - Геометрия липкой панели и блюра
enum HomeStickySearchLayout {
    static func backingSafeTop(geometryReportedSafeTop: CGFloat) -> CGFloat {
        if geometryReportedSafeTop >= 12 { return geometryReportedSafeTop }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let w = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            let t = w.safeAreaInsets.top
            if t > 0 { return t }
        }
        return 47
    }

    /// Нижняя граница «lead» при закреплении: совпадает с динамическим safe area (без фиксированного 85 pt на iOS 16–18).
    static func pinnedLeadFloor(geometryReportedSafeTop: CGFloat) -> CGFloat {
        backingSafeTop(geometryReportedSafeTop: geometryReportedSafeTop)
    }

    static func searchCapsuleBlockHeight() -> CGFloat {
        let font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        let line = ceil(font.lineHeight)
        let fromTextAndPadding = line + 12 + 12
        let fromCircle: CGFloat = 32 + 8
        return max(fromTextAndPadding, fromCircle, 62)
    }

    static func searchLeadHeightForChrome(geometryWidth: CGFloat, scroll: CGFloat, geometryReportedSafeTop: CGFloat) -> CGFloat {
        let scale = max(geometryWidth > 0 ? UIScreen.main.scale : 1, 1)
        let travel = HomeStickySearchMetrics.latchScrollY - scroll
        let floor = pinnedLeadFloor(geometryReportedSafeTop: geometryReportedSafeTop)
        let total = max(floor, travel)
        return (total * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    static func blurPanelTotalHeight(geometryReportedSafeTop: CGFloat, geometryWidth: CGFloat, scroll: CGFloat) -> CGFloat {
        let safeTop = backingSafeTop(geometryReportedSafeTop: geometryReportedSafeTop)
        let lead = searchLeadHeightForChrome(
            geometryWidth: geometryWidth,
            scroll: scroll,
            geometryReportedSafeTop: geometryReportedSafeTop
        )
        let cap = searchCapsuleBlockHeight()
        return max(lead, safeTop) + cap + HomeStickySearchMetrics.blurPanelBottomRoundingBleed + HomeStickySearchMetrics.blurPanelLayoutSlack
    }

    static func blurPanelBottomCornerRadius(totalHeight: CGFloat) -> CGFloat {
        let maxR = HomeStickySearchMetrics.pinnedBarBottomCornerRadius
        return min(maxR, max(14, totalHeight * 0.22))
    }

    static func pinnedBlurOpacity(scroll: CGFloat) -> CGFloat {
        guard scroll >= HomeStickySearchMetrics.latchScrollY else { return 0 }
        let d = max(HomeStickySearchMetrics.pinnedBlurFadeDistance, 1)
        return min(1, (scroll - HomeStickySearchMetrics.latchScrollY) / d)
    }
}

// MARK: - UIKit blur panel
private struct HomeStickySearchBlurUIKitPanel: UIViewRepresentable {
    var height: CGFloat
    var bottomCornerRadius: CGFloat
    var opacity: CGFloat

    final class Coordinator {
        var heightConstraint: NSLayoutConstraint?
        weak var effectView: UIVisualEffectView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func applyBottomCorners(to blur: UIVisualEffectView, bottomCornerRadius: CGFloat) {
        if bottomCornerRadius <= 0.5 {
            blur.layer.cornerRadius = 0
            blur.layer.maskedCorners = []
        } else {
            blur.layer.cornerRadius = bottomCornerRadius
            blur.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .clear
        box.clipsToBounds = false

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.clipsToBounds = true
        blur.isUserInteractionEnabled = false
        Self.applyBottomCorners(to: blur, bottomCornerRadius: bottomCornerRadius)
        box.addSubview(blur)

        let hc = blur.heightAnchor.constraint(equalToConstant: max(1, height))
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: box.topAnchor),
            blur.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            hc,
        ])
        context.coordinator.heightConstraint = hc
        context.coordinator.effectView = blur
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {
        context.coordinator.heightConstraint?.constant = max(1, height)
        guard let blur = context.coordinator.effectView else { return }
        blur.alpha = CGFloat(opacity)
        Self.applyBottomCorners(to: blur, bottomCornerRadius: bottomCornerRadius)
    }
}

// MARK: - Scroll offset (KVO + DisplayLink)
struct HomeVerticalScrollOffsetReader: UIViewRepresentable {
    @Binding var offsetY: CGFloat
    /// Если `true` — только `y ≥ 0` (нормализованный скролл). Если `false` (главная): нормализованный `y`, отрицательный при резинке вверху — поле едет вместе с контентом.
    var clampsVerticalOffsetToNonNegative: Bool = true
    /// Главная: KVO не всегда совпадает с частотой кадра ProMotion — подписываемся на `CADisplayLink` на время жеста/инерции, чтобы капсула ехала в такт с `UIScrollView`.
    var prefersDisplayLinkWhileScrolling: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(offsetY: $offsetY) }

    func makeUIView(context: Context) -> DetectorView {
        let v = DetectorView()
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: DetectorView, context: Context) {
        context.coordinator.offsetY = $offsetY
        context.coordinator.clampsVerticalOffsetToNonNegative = clampsVerticalOffsetToNonNegative
        context.coordinator.prefersDisplayLinkWhileScrolling = prefersDisplayLinkWhileScrolling
        context.coordinator.attachIfPossible(from: uiView)
    }

    final class Coordinator: NSObject {
        var offsetY: Binding<CGFloat>
        var clampsVerticalOffsetToNonNegative = true
        var prefersDisplayLinkWhileScrolling = false
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var insetObservation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?

        init(offsetY: Binding<CGFloat>) {
            self.offsetY = offsetY
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// Снимаем линк, если `DetectorView` ушёл из окна — иначе тикаем впустую.
        func cancelDisplayLinkForHostRemoval() {
            stopDisplayLink()
        }

        private func startDisplayLinkIfNeeded() {
            guard prefersDisplayLinkWhileScrolling else { return }
            guard displayLink == nil, observedScrollView != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(stepDisplayLink(_:)))
            if #available(iOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func stepDisplayLink(_ link: CADisplayLink) {
            guard let sv = observedScrollView else {
                stopDisplayLink()
                return
            }
            pushScrollOffset(from: sv, fromDisplayLink: true)
            if !sv.isDragging, !sv.isDecelerating {
                stopDisplayLink()
            }
        }

        private func pushScrollOffset(from sv: UIScrollView, fromDisplayLink: Bool = false) {
            let raw = sv.contentOffset.y
            // Без нормализации на новых iOS в покое часто `contentOffset.y ≈ -adjustedContentInset.top`,
            // тогда latch − offset завышает ведущий спейсер и поле поиска «съезжает» на блок библиотеки.
            let scrollFromVisualTop = raw + sv.adjustedContentInset.top
            let y = clampsVerticalOffsetToNonNegative ? max(0, scrollFromVisualTop) : scrollFromVisualTop
            // Без `async`: иначе на новых iOS / ProMotion оверлей поиска отстаёт на кадр и «плавает» относительно скролла.
            let scale = max(sv.traitCollection.displayScale, 1)
            let aligned = (y * scale).rounded(.toNearestOrAwayFromZero) / scale
            let apply = { self.offsetY.wrappedValue = aligned }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
            if !fromDisplayLink, prefersDisplayLinkWhileScrolling, sv.isDragging || sv.isDecelerating {
                startDisplayLinkIfNeeded()
            }
        }

        func attachIfPossible(from view: UIView) {
            var v: UIView? = view.superview
            while let current = v {
                if let sv = current as? UIScrollView {
                    /// `SystemPagedScrollView`: paging + `isScrollEnabled = false`. Если цепочка superview когда‑то даёт его раньше вертикального `ScrollView`, `contentOffset.y` ≈ 0 — «липкая» панель не закрепляется и едет с контентом.
                    if sv.isPagingEnabled, !sv.isScrollEnabled {
                        v = current.superview
                        continue
                    }
                    if sv !== observedScrollView {
                        stopDisplayLink()
                        observation?.invalidate()
                        observation = nil
                        insetObservation?.invalidate()
                        insetObservation = nil
                        observedScrollView = sv
                        observation = sv.observe(\.contentOffset, options: [.new, .initial]) { [weak self] sv, _ in
                            self?.pushScrollOffset(from: sv, fromDisplayLink: false)
                        }
                        insetObservation = sv.observe(\.contentInset, options: [.new, .initial]) { [weak self] sv, _ in
                            self?.pushScrollOffset(from: sv, fromDisplayLink: false)
                        }
                    }
                    return
                }
                v = current.superview
            }
        }

        deinit {
            stopDisplayLink()
            observation?.invalidate()
            insetObservation?.invalidate()
        }
    }

    final class DetectorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attachIfPossible(from: self)
            } else {
                coordinator?.cancelDisplayLinkForHostRemoval()
            }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attachIfPossible(from: self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.attachIfPossible(from: self)
        }
    }
}

// MARK: - Капсула поиска (как `settingsCapsuleField` с поисковой клавиатурой и pin progress)
struct HomeStickySearchCapsuleField: View {
    let placeholder: String
    @Binding var text: String
    let isDarkMode: Bool
    let accent: Color
    /// 0...1: при закреплении фон капсулы смещается к цвету карточки библиотеки.
    let pinProgress: CGFloat
    var showShadow: Bool = false
    var verticalPadding: CGFloat = 12

    private var pinT: CGFloat { min(1, max(0, pinProgress)) }
    private var libraryCardWhite: CGFloat { isDarkMode ? 0.12 : 0.92 }
    private var libraryPinnedWhite: CGFloat { isDarkMode ? 0.07 : 1.0 }
    private var capsuleColor: Color {
        let w = libraryCardWhite + (libraryPinnedWhite - libraryCardWhite) * pinT
        return Color(white: w)
    }
    private var textColor: Color { isDarkMode ? .white : accent }
    private var circleFill: Color { accent }
    private var iconColor: Color { .white }
    private var cursorColor: Color { isDarkMode ? .white : accent }

    var body: some View {
        let field = TextField("", text: $text)
            .tint(cursorColor)
            .padding(.leading, 52)
            .padding(.trailing, 20)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity)

        Group {
            if #available(iOS 26.0, *) {
                field
                    .glassEffect(.regular.tint(capsuleColor).interactive(), in: Capsule())
                    .foregroundStyle(textColor)
            } else {
                field
                    .background(capsuleColor, in: Capsule())
                    .foregroundStyle(textColor)
            }
        }
        .tint(cursorColor)
        .shadow(color: (isDarkMode || !showShadow) ? .clear : Color.black.opacity(0.20), radius: 16, x: 0, y: 6)
        .overlay(alignment: .leading) {
            ZStack {
                Circle().fill(circleFill)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 32, height: 32)
            .padding(.leading, 6)
        }
        .overlay(alignment: .leading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(textColor)
                    .padding(.leading, 52)
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Оверлей: блюр под капсулой + капсула (ZStack на весь экран таба)
struct HomeStickySearchOverlayChrome: View {
    let safeAreaTop: CGFloat
    let geometryWidth: CGFloat
    let scroll: CGFloat
    @Binding var searchText: String
    let placeholder: String
    let accent: Color
    let isDarkMode: Bool

    private var blurOpacity: CGFloat { HomeStickySearchLayout.pinnedBlurOpacity(scroll: scroll) }

    var body: some View {
        let totalHeight = HomeStickySearchLayout.blurPanelTotalHeight(
            geometryReportedSafeTop: safeAreaTop,
            geometryWidth: geometryWidth,
            scroll: scroll
        )
        let cornerR = HomeStickySearchLayout.blurPanelBottomCornerRadius(totalHeight: totalHeight)
        let searchLead = HomeStickySearchLayout.searchLeadHeightForChrome(
            geometryWidth: geometryWidth,
            scroll: scroll,
            geometryReportedSafeTop: safeAreaTop
        )

        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    HomeStickySearchBlurUIKitPanel(
                        height: totalHeight,
                        bottomCornerRadius: cornerR,
                        opacity: CGFloat(blurOpacity)
                    )
                    .frame(height: totalHeight)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .animation(nil, value: scroll)
                    .ignoresSafeArea(edges: [.horizontal, .top])
                    .transaction { $0.animation = nil }
                }
            HomeStickySearchCapsuleField(
                placeholder: placeholder,
                text: $searchText,
                isDarkMode: isDarkMode,
                accent: accent,
                pinProgress: blurOpacity,
                showShadow: false,
                verticalPadding: 12
            )
            .padding(.horizontal, HomeStickySearchMetrics.searchHorizontalInset)
            .padding(.top, searchLead)
            .frame(maxWidth: .infinity, alignment: .top)
            .background { Color.clear.allowsHitTesting(false) }
            .animation(nil, value: scroll)
            .transaction { $0.animation = nil }
        }
    }
}

// MARK: - Обёртка: вертикальный скролл + оверлей (scroll state изолирован — не перерисовывает всё приложение)
struct HomeTabScrollAndStickyChrome<ScrollContent: View, OverlayContent: View>: View {
    @State private var scrollOffset: CGFloat = 0
    let overlayHitTesting: Bool
    let scrollContent: (Binding<CGFloat>) -> ScrollContent
    let overlayChrome: (CGFloat) -> OverlayContent

    var body: some View {
        ZStack(alignment: .top) {
            scrollContent($scrollOffset)
            overlayChrome(scrollOffset)
                .zIndex(45)
                .allowsHitTesting(overlayHitTesting)
        }
    }
}

/// iOS 16–18: корень таба под статус-бар (до iOS 26).
struct HomeTabGeometryReaderPreiOS26Layout: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .ignoresSafeArea(edges: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Заглушка-модификатор: в Sphere контент без доп. safe padding сверху (панель в оверлее).
struct HomeTabScrollStackTopSafePaddingPreiOS26: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func homeTabGeometryReaderPreIOS26() -> some View {
        modifier(HomeTabGeometryReaderPreiOS26Layout())
    }
}
