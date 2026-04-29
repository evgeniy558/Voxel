//
//  EquilizerView.swift
//  Vendored from https://github.com/urvi-k/iOS-swiftUI-spotify-equalizer (MIT), adapted for app accent color.
//

import SwiftUI

public struct SpotifyStyleEqualizerView: View {
    private var frequency: Int
    public var sliderFrameHeight: CGFloat
    public var sliderTintColor: Color
    public var gradientColors: [Color]
    @Binding public var sliderValues: [CGFloat]
    @State private var viewWidth: CGFloat = 300
    @Binding private var sliderLabel: [String]

    public init(
        sliderLabels: Binding<[String]>,
        sliderValues: Binding<[CGFloat]>,
        sliderFrameHeight: CGFloat = 200,
        sliderTintColor: Color = .green,
        gradientColors: [Color] = [.green, .clear]
    ) {
        self._sliderValues = sliderValues
        self._sliderLabel = sliderLabels
        let count = max(sliderValues.wrappedValue.count, 1)
        self.frequency = count - 1
        self.sliderFrameHeight = sliderFrameHeight
        self.sliderTintColor = sliderTintColor
        self.gradientColors = gradientColors
    }

    public var body: some View {
        let count = CGFloat(frequency + 1)
        let sliderWidth: CGFloat = count > 0 ? self.viewWidth / count : 50
        let spacing: CGFloat = 0
        VStack {
            ZStack(alignment: .top) {
                addEqPath(spacing: spacing, sliderWidth: sliderWidth)
                setSlider(sliderWidth: sliderWidth)
            }
            .frame(height: sliderFrameHeight)
            setSliderLabel(sliderWidth: sliderWidth)
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { self.viewWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { w in self.viewWidth = w }
            }
        )
    }
}

extension SpotifyStyleEqualizerView {
    func addEqPath(spacing: CGFloat, sliderWidth: CGFloat) -> some View {
        ZStack {
            EqualizerPathTopLine(
                sliderValues: sliderValues,
                sliderFrameH: sliderFrameHeight,
                sliderSpacing: spacing,
                sliderWidth: sliderWidth
            )
            .stroke(sliderTintColor, lineWidth: 3)

            EqualizerPath(
                sliderValues: sliderValues,
                sliderFrameH: sliderFrameHeight,
                sliderSpacing: spacing,
                sliderWidth: sliderWidth
            )
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: gradientColors),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .animation(.easeInOut, value: sliderValues)
        }
    }

    func setSlider(sliderWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0...frequency, id: \.self) { i in
                SpotifyEQSliderView(
                    sliderValue: $sliderValues[i],
                    sliderFrameHeight: sliderFrameHeight,
                    sliderTintColor: sliderTintColor
                )
                .frame(width: sliderWidth)
            }
        }
    }

    func setSliderLabel(sliderWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<sliderLabel.count, id: \.self) { i in
                Text(sliderLabel[i])
                    .foregroundColor(.secondary)
                    .fontWeight(.thin)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: sliderWidth)
                    .font(.system(size: 12))
            }
        }
    }
}
