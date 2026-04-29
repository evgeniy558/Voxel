import Foundation

/// Должна совпадать с `internal/auth/password.go` (min 55 = ок для регистрации).
struct SpherePasswordStrength: Equatable {
    let score: Int
    let labelKey: String

    var isAcceptableForRegister: Bool { score >= 55 }

    static func evaluate(_ password: String) -> SpherePasswordStrength {
        if password.isEmpty { return Self(score: 0, labelKey: "weak") }
        var lower = 0, upper = 0, digit = 0, special = 0
        for c in password {
            if c.isLowercase { lower += 1 }
            else if c.isUppercase { upper += 1 }
            else if c.isNumber { digit += 1 }
            else { special += 1 }
        }
        var kinds = 0
        if lower > 0 { kinds += 1 }
        if upper > 0 { kinds += 1 }
        if digit > 0 { kinds += 1 }
        if special > 0 { kinds += 1 }
        var lengthScore = min(password.count * 3, 40)
        let varietyScore = kinds * 10
        var penalty = 0
        let lp = password.lowercased()
        for w in [
            "password", "123456", "qwerty", "admin", "letmein", "welcome", "monkey", "dragon",
            "111111", "654321", "football", "iloveyou", "пароль", "password1", "passw0rd"
        ] where lp.contains(w) { penalty += 35; break }
        if repeatedRunes(password) { penalty += 15 }
        var score = lengthScore + varietyScore - penalty
        score = min(max(score, 0), 100)
        let label: String
        switch score {
        case 80...: label = "strong"
        case 65..<80: label = "good"
        case 45..<65: label = "fair"
        default: label = "weak"
        }
        return Self(score: score, labelKey: label)
    }

    private static func repeatedRunes(_ p: String) -> Bool {
        if p.count < 4 { return false }
        let chars = Array(p)
        var same = 0
        for i in 1..<chars.count {
            if chars[i] == chars[i - 1] { same += 1; if same >= 4 { return true } } else { same = 0 }
        }
        return false
    }
}
