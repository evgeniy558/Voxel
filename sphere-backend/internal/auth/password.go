package auth

import (
	"strings"
	"unicode"
)

// PasswordStrength mirrors client expectations (similar to commercial “strength” APIs).
type PasswordStrength struct {
	Score int    `json:"score"` // 0–100
	Label string `json:"label"` // weak | fair | good | strong
}

const minRegisterPasswordScore = 55

// EvaluatePassword scores the password locally (we do not send passwords to third-party APIs).
func EvaluatePassword(password string) PasswordStrength {
	s := scorePassword(password)
	label := "weak"
	switch {
	case s >= 80:
		label = "strong"
	case s >= 65:
		label = "good"
	case s >= 45:
		label = "fair"
	default:
		label = "weak"
	}
	return PasswordStrength{Score: s, Label: label}
}

func scorePassword(p string) int {
	if len(p) == 0 {
		return 0
	}
	var (
		lower, upper, digit, special int
	)
	for _, r := range p {
		switch {
		case unicode.IsLower(r):
			lower++
		case unicode.IsUpper(r):
			upper++
		case unicode.IsDigit(r):
			digit++
		case unicode.IsPunct(r) || unicode.IsSymbol(r):
			special++
		}
	}
	kinds := 0
	if lower > 0 {
		kinds++
	}
	if upper > 0 {
		kinds++
	}
	if digit > 0 {
		kinds++
	}
	if special > 0 {
		kinds++
	}
	// Length score (max ~40)
	lengthScore := min(len(p)*3, 40)
	// Variety (max ~40)
	varietyScore := kinds * 10
	// Penalize trivial patterns
	penalty := 0
	lp := strings.ToLower(p)
	if isCommonPassword(lp) {
		penalty += 35
	}
	if repeatedRunes(p) {
		penalty += 15
	}
	score := lengthScore + varietyScore - penalty
	if score < 0 {
		score = 0
	}
	if score > 100 {
		return 100
	}
	return score
}

func repeatedRunes(p string) bool {
	if len(p) < 4 {
		return false
	}
	same := 0
	for i := 1; i < len(p); i++ {
		if p[i] == p[i-1] {
			same++
			if same >= 4 {
				return true
			}
		} else {
			same = 0
		}
	}
	return false
}

var commonPasswordSubstrings = []string{
	"password", "123456", "qwerty", "admin", "letmein", "welcome", "monkey", "dragon",
	"111111", "654321", "football", "iloveyou", "пароль", "password1", "passw0rd",
}

func isCommonPassword(lp string) bool {
	for _, w := range commonPasswordSubstrings {
		if strings.Contains(lp, w) {
			return true
		}
	}
	return false
}
