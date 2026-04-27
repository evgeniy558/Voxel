package user

import "time"

type User struct {
	ID          string `json:"id"`
	Email       string `json:"email"`
	PasswordHash string `json:"-"`
	Username    string `json:"username"`
	Name        string `json:"name"`
	AvatarURL   string `json:"avatar_url"`
	IsVerified  bool   `json:"is_verified"`
	BadgeText   string `json:"badge_text"`
	BadgeColor  string `json:"badge_color"`
	IsAdmin     bool   `json:"is_admin"`
	Banned      bool   `json:"banned"`
	BannedReason string `json:"banned_reason,omitempty"`
	HideSubscriptions  bool `json:"hide_subscriptions"`
	MessagesMutualOnly bool `json:"messages_mutual_only"`
	PrivateProfile     bool `json:"private_profile"`
	TOTPEnabled bool   `json:"totp_enabled"`
	Email2FAEnabled bool `json:"email_2fa_enabled"`
	GoogleID    *string `json:"-"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}
