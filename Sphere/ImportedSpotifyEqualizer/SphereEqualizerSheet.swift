//
//  SphereEqualizerSheet.swift
//

import SwiftUI

struct SphereEqualizerSheet: View {
    let accent: Color
    let isEnglish: Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = SphereAudioEngine.shared
    @State private var selectedType: SphereEqualizerSheet.MusicType?
    @State private var sliderLabel: [String] = ["60", "150", "400", "1k", "2.4k", "15k"]

    enum MusicType: String, CaseIterable, Identifiable {
        case dance = "Dance"
        case deep = "Deep"
        case electronic = "Electronic"
        case flat = "Flat"
        case hipHop = "Hip-Hop"
        case jazz = "Jazz"
        case latin = "Latin"
        var id: String { rawValue }
    }

    private var title: String { isEnglish ? "Equalizer" : "Эквалайзер" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                SpotifyStyleEqualizerView(
                    sliderLabels: $sliderLabel,
                    sliderValues: $engine.eqValues,
                    sliderTintColor: accent,
                    gradientColors: [accent, accent.opacity(0.05)]
                )
                .padding(.vertical, 16)
                .padding(.horizontal, 8)
                .background(Color.gray.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(MusicType.allCases) { type in
                            HStack {
                                Text(type.rawValue)
                                    .font(.system(size: 16, weight: .medium))
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 14)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if type == selectedType {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(accent)
                                        .padding(.trailing, 14)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(type == selectedType ? accent.opacity(0.15) : Color.gray.opacity(0.08))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedType = type
                                    engine.eqValues = presetValues(for: type)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Done" : "Готово") {
                        engine.saveEQ()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEnglish ? "Reset" : "Сброс") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedType = .flat
                            engine.eqValues = [0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
                        }
                    }
                }
            }
        }
    }

    private func presetValues(for type: MusicType) -> [CGFloat] {
        switch type {
        case .dance:      return [0.65, 0.72, 0.50, 0.42, 0.62, 0.55]
        case .deep:       return [0.75, 0.65, 0.50, 0.45, 0.40, 0.35]
        case .electronic: return [0.72, 0.78, 0.55, 0.48, 0.70, 0.65]
        case .flat:       return [0.50, 0.50, 0.50, 0.50, 0.50, 0.50]
        case .hipHop:     return [0.78, 0.70, 0.55, 0.48, 0.58, 0.68]
        case .jazz:       return [0.42, 0.52, 0.62, 0.55, 0.45, 0.38]
        case .latin:      return [0.62, 0.55, 0.45, 0.52, 0.62, 0.70]
        }
    }
}
