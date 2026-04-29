//
// JellyDragDriver.swift
// Драйвер желе: offset и stretch по CADisplayLink.
//

import QuartzCore
import SwiftUI

final class JellyDragDriver: ObservableObject {
    @Published var displayOffset: CGSize = .zero
    @Published var displayStretch: CGSize = .zero
    private var targetOffset: CGSize = .zero
    private var targetStretch: CGSize = .zero
    private var displayLink: CADisplayLink?
    private var isRunning = false

    func setTarget(offset: CGSize, stretch: CGSize) {
        targetOffset = offset
        targetStretch = stretch
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            isRunning = true
        }
    }

    @objc private func tick() {
        guard isRunning else { return }
        if displayOffset != targetOffset || displayStretch != targetStretch {
            displayOffset = targetOffset
            displayStretch = targetStretch
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
    }

    func releaseWithAnimation(animation: Animation) {
        stop()
        withAnimation(animation) {
            displayOffset = .zero
            displayStretch = .zero
        }
    }

    func relaxStretch(animation: Animation) {
        withAnimation(animation) {
            displayStretch = .zero
        }
    }

    func reset() {
        displayOffset = .zero
        displayStretch = .zero
        targetOffset = .zero
        targetStretch = .zero
    }
}
