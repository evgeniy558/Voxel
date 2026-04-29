import SwiftUI

// Блок «Библиотека» на главном (перенос из бекапа «Библиотека главный экран»): метрики ряда и кнопка полной библиотеки.

enum HomeLibraryHorizontalRowMetrics {
    static let coverSide: CGFloat = 120
    static let coverCorner: CGFloat = 16
    static let coverToTitleSpacing: CGFloat = 8
    static let titleVerticalPadding: CGFloat = 6
    static let titleLineApproximateHeight: CGFloat = 20
    static var titlePlateBlockHeight: CGFloat { titleLineApproximateHeight + titleVerticalPadding * 2 }
    static var cellTotalHeight: CGFloat { coverSide + coverToTitleSpacing + titlePlateBlockHeight }
    static let openLibraryButtonWidth: CGFloat = 72
    /// Как `Color.clear.frame(width: 12 + 4, …)` у горизонтального ряда на главной — чтобы обложки не подрезались у левого края блока.
    static let trackRowLeadingInset: CGFloat = 12 + 4
}

func libraryTrackTitlePlateCornerRadius(coverCorner: CGFloat, coverSquareSide: CGFloat, verticalLabelPadding: CGFloat) -> CGFloat {
    let approximateLineHeight: CGFloat = 20
    let plateHeight = approximateLineHeight + verticalLabelPadding * 2
    let base = coverCorner * (plateHeight / max(coverSquareSide, 1))
    let r = base * 1.75
    return max(6, min(r, plateHeight * 0.44))
}

struct HomeLibraryOpenFullGridButtonLabel: View {
    let accent: Color

    var body: some View {
        let w = HomeLibraryHorizontalRowMetrics.openLibraryButtonWidth
        let h = HomeLibraryHorizontalRowMetrics.cellTotalHeight
        let r = HomeLibraryHorizontalRowMetrics.coverCorner
        Group {
            if #available(iOS 26.0, *) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: w, height: h)
                    .glassEffect(.regular.tint(accent).interactive(), in: RoundedRectangle(cornerRadius: r, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(accent)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: w, height: h)
            }
        }
    }
}
