import SwiftUI

/// Nickname row with optional verified icon (asset `VerifiedBadge`) and short text badge from Go backend.
struct SphereNicknameWithBadges: View {
    let nickname: String
    /// Latest `/user/me` payload (badges live here, not in Supabase profile).
    let backendUser: BackendUser?
    var nicknameFont: Font = .title2.weight(.bold)
    var nicknameColor: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Text(nickname)
                .font(nicknameFont)
                .foregroundStyle(nicknameColor)
            if backendUser?.isVerified == true {
                Image("VerifiedBadge")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
            if let bu = backendUser {
                let raw = bu.badgeText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    let text = String(raw.prefix(5)).uppercased()
                    Text(text)
                        .font(.system(size: badgeFontSize(for: text), weight: .semibold))
                        .foregroundStyle(badgeStrokeColor(for: bu))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule()
                                .stroke(badgeStrokeColor(for: bu), lineWidth: 1)
                        )
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func badgeStrokeColor(for bu: BackendUser) -> Color {
        let hex = bu.badgeColor
        if let c = Color(hexRRGGBB: hex) { return c }
        return Color("AccentColor")
    }

    private func badgeFontSize(for text: String) -> CGFloat {
        switch text.count {
        case 0...2: return 11
        case 3: return 10
        case 4: return 9
        default: return 8
        }
    }
}

/// Compact display name + verified + short badge (used in search rows and remote profile header).
struct SphereCompactUserBadges: View {
    let displayName: String
    let badgeText: String
    let badgeColor: String
    let isVerified: Bool
    var verifiedBadgeSize: CGFloat = 16
    var nameFont: Font = .system(size: 16, weight: .semibold)

    var body: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(nameFont)
            if isVerified {
                Image("VerifiedBadge")
                    .resizable()
                    .scaledToFit()
                    .frame(width: verifiedBadgeSize, height: verifiedBadgeSize)
            }
            let raw = badgeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                let text = String(raw.prefix(5)).uppercased()
                let stroke = Color(hexRRGGBB: badgeColor) ?? Color("AccentColor")
                Text(text)
                    .font(.system(size: badgeFontSize(for: text), weight: .semibold))
                    .foregroundStyle(stroke)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(stroke, lineWidth: 1))
            }
        }
    }

    private func badgeFontSize(for text: String) -> CGFloat {
        switch text.count {
        case 0...2: return 11
        case 3: return 10
        case 4: return 9
        default: return 8
        }
    }
}

extension Color {
    /// Parses `#RRGGBB` or `RRGGBB`; returns nil if invalid.
    init?(hexRRGGBB: String) {
        var s = hexRRGGBB.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt32(s, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8) & 0xFF) / 255,
            blue: Double(val & 0xFF) / 255,
            opacity: 1
        )
    }
}
