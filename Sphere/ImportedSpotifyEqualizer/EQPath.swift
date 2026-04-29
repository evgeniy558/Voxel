//
//  EQPath.swift
//  Vendored from https://github.com/urvi-k/iOS-swiftUI-spotify-equalizer (MIT)
//

import SwiftUI

struct EqualizerPathTopLine: Shape {
    var sliderValues: [CGFloat]
    var sliderFrameH: CGFloat
    var sliderSpacing: CGFloat
    var sliderWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        eqTopLine(rect: rect, sliderValues: sliderValues, sliderFrameH: sliderFrameH, sliderSpacing: sliderSpacing, sliderWidth: sliderWidth)
    }
}

struct EqualizerPath: Shape {
    var sliderValues: [CGFloat]
    var sliderFrameH: CGFloat
    var sliderSpacing: CGFloat
    var sliderWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = eqTopLine(rect: rect, sliderValues: sliderValues, sliderFrameH: sliderFrameH, sliderSpacing: sliderSpacing, sliderWidth: sliderWidth)
        let step = sliderWidth + sliderSpacing
        let halfW = sliderWidth / 2
        let lastX = CGFloat(sliderValues.count - 1) * step + halfW
        path.addLine(to: CGPoint(x: lastX, y: rect.height))
        path.addLine(to: CGPoint(x: halfW, y: rect.height))
        path.closeSubpath()
        return path
    }
}

extension Shape {
    func eqTopLine(rect: CGRect, sliderValues: [CGFloat], sliderFrameH: CGFloat, sliderSpacing: CGFloat, sliderWidth: CGFloat) -> Path {
        var path = Path()
        guard sliderValues.count > 1 else { return path }

        let step = sliderWidth + sliderSpacing
        // Центр каждого слайдера: i * step + sliderWidth / 2
        let halfW = sliderWidth / 2
        let firstY = rect.height - (sliderValues[0] * sliderFrameH)
        path.move(to: CGPoint(x: halfW, y: firstY))

        for index in 1..<sliderValues.count {
            let x = CGFloat(index) * step + halfW
            let y = rect.height - (sliderValues[index] * sliderFrameH)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}
