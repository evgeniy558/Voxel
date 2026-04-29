//
//  SliderView.swift
//  Vendored from https://github.com/urvi-k/iOS-swiftUI-spotify-equalizer (MIT)
//

import SwiftUI
import UIKit

struct SpotifyEQSliderView: View {
    @Binding var sliderValue: CGFloat
    var sliderFrameHeight: CGFloat
    var sliderTintColor: Color

    var body: some View {
        Slider(value: $sliderValue, label: {})
            .rotationEffect(.degrees(-90))
            .tint(sliderTintColor)
            .frame(width: sliderFrameHeight)
            .frame(height: sliderFrameHeight)
    }
}
