//
// JellyCardOverlay.swift
// Желейное окно-оверлей: затемнение, карточка, перетаскивание, расслабление.
//

import SwiftUI

struct JellyCardOverlay<Content: View>: View {
    @Binding var isPresented: Bool
    @Binding var triggerDismiss: Bool
    var onDismissCompleted: (() -> Void)?
    var cardWidthFraction: CGFloat = 0.9
    /// Если `true`, высота карточки по контенту (игнорируется `cardHeightFraction`).
    var fitsContentHeight: Bool = false
    var cardHeightFraction: CGFloat = 0.4
    var dismissThreshold: CGFloat = 100
    var dismissPredictedThreshold: CGFloat = 200
    var dismissVelocityThreshold: CGFloat = 300
    @ViewBuilder var content: () -> Content

    @State private var appeared = false
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastDragTime: Date = Date()
    @State private var lastRelaxScheduleTime: Date = .distantPast
    @StateObject private var dragDriver = JellyDragDriver()
    @StateObject private var relaxController = JellyRelaxController()
    @State private var isContentPressed = false

    private let dismissDuration: Double = 0.35
    private let relaxDelay: Double = 0.18
    private let relaxScheduleInterval: Double = 0.06
    private let velocityToStretch: CGFloat = 6500
    private let maxStretch: CGFloat = 0.12

    private func dismissAnimated() {
        withAnimation(.easeOut(duration: dismissDuration)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDuration) {
            onDismissCompleted?()
            triggerDismiss = false
            dragDriver.reset()
            isPresented = false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cardW = geo.size.width * cardWidthFraction
            let cardH = geo.size.height * cardHeightFraction
            let displayScaleX = 1 + dragDriver.displayStretch.width
            let displayScaleY = 1 + dragDriver.displayStretch.height

            let sizedContent = Group {
                if fitsContentHeight {
                    content()
                        .frame(width: cardW, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    content()
                        .frame(width: cardW, height: cardH, alignment: .top)
                }
            }

            ZStack {
                Color.black.opacity(appeared ? 0.5 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAnimated() }

                sizedContent
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.white.opacity(isContentPressed ? 0.12 : 0))
                            .allowsHitTesting(false)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 12)
                    .compositingGroup()
                    .scaleEffect(
                        x: (appeared ? displayScaleX : 0.85) * (isContentPressed ? 0.98 : 1),
                        y: (appeared ? displayScaleY : 0.85) * (isContentPressed ? 0.98 : 1)
                    )
                    .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isContentPressed)
                    .opacity(appeared ? 1 : 0)
                    .offset(dragDriver.displayOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let now = Date()
                                let dt = now.timeIntervalSince(lastDragTime)
                                let prev = lastDragTranslation
                                lastDragTranslation = value.translation
                                lastDragTime = now
                                var stretch = CGSize.zero
                                if dt > 0.001 && dt < 0.25 {
                                    let vel = CGSize(
                                        width: (value.translation.width - prev.width) / CGFloat(dt),
                                        height: (value.translation.height - prev.height) / CGFloat(dt)
                                    )
                                    stretch = CGSize(
                                        width: max(-maxStretch, min(maxStretch, vel.width / velocityToStretch)),
                                        height: max(-maxStretch, min(maxStretch, vel.height / velocityToStretch))
                                    )
                                }
                                dragDriver.setTarget(offset: value.translation, stretch: stretch)
                                relaxController.cancel()
                                if now.timeIntervalSince(lastRelaxScheduleTime) >= relaxScheduleInterval {
                                    lastRelaxScheduleTime = now
                                    relaxController.scheduleRelax(delay: relaxDelay) {
                                        dragDriver.relaxStretch(animation: .spring(response: 0.4, dampingFraction: 0.78))
                                    }
                                }
                            }
                            .onEnded { value in
                                let vel = value.predictedEndTranslation.height - value.translation.height
                                if value.translation.height > dismissThreshold
                                    || value.predictedEndTranslation.height > dismissPredictedThreshold
                                    || vel > dismissVelocityThreshold {
                                    dismissAnimated()
                                } else {
                                    relaxController.cancel()
                                    dragDriver.releaseWithAnimation(animation: .spring(response: 0.55, dampingFraction: 0.62))
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in isContentPressed = true }
                            .onEnded { _ in isContentPressed = false }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
        .onChange(of: triggerDismiss) { newValue in
            if newValue { dismissAnimated() }
        }
    }
}
