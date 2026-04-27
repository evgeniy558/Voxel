package user

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{db: db}
}

func (s *Service) GetByID(ctx context.Context, id string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(ctx,
		`SELECT id, email, username, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			hide_subscriptions, messages_mutual_only, private_profile,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at
		 FROM users WHERE id = $1`, id,
	).Scan(
		&u.ID, &u.Email, &u.Username, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.HideSubscriptions, &u.MessagesMutualOnly, &u.PrivateProfile,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	return u, nil
}

func (s *Service) Update(ctx context.Context, id, name, avatarURL string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(ctx,
		`UPDATE users SET name = COALESCE(NULLIF($2, ''), name), avatar_url = COALESCE(NULLIF($3, ''), avatar_url), updated_at = now()
		 WHERE id = $1
		 RETURNING id, email, username, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			hide_subscriptions, messages_mutual_only, private_profile,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at`,
		id, name, avatarURL,
	).Scan(
		&u.ID, &u.Email, &u.Username, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.HideSubscriptions, &u.MessagesMutualOnly, &u.PrivateProfile,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("update user: %w", err)
	}
	return u, nil
}

func (s *Service) UpdateAvatarURL(ctx context.Context, id, avatarURL string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(ctx,
		`UPDATE users SET avatar_url = $2, updated_at = now() WHERE id = $1
		 RETURNING id, email, username, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			hide_subscriptions, messages_mutual_only, private_profile,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at`,
		id, avatarURL,
	).Scan(
		&u.ID, &u.Email, &u.Username, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.HideSubscriptions, &u.MessagesMutualOnly, &u.PrivateProfile,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("update avatar: %w", err)
	}
	return u, nil
}

func (s *Service) UpdatePasswordHash(ctx context.Context, id, passwordHash string) error {
	_, err := s.db.Exec(ctx,
		`UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1`,
		id, passwordHash,
	)
	return err
}

func (s *Service) GetPasswordHash(ctx context.Context, id string) (string, error) {
	var h string
	err := s.db.QueryRow(ctx, `SELECT password_hash FROM users WHERE id = $1`, id).Scan(&h)
	return h, err
}

func (s *Service) SetTOTPSecret(ctx context.Context, id, secret string) error {
	_, err := s.db.Exec(ctx,
		`UPDATE users SET totp_secret = $2, updated_at = now() WHERE id = $1::uuid`,
		id, secret,
	)
	return err
}

func (s *Service) GetTOTPSecret(ctx context.Context, id string) (string, error) {
	var sec string
	err := s.db.QueryRow(ctx, `SELECT totp_secret FROM users WHERE id = $1::uuid`, id).Scan(&sec)
	return sec, err
}

func (s *Service) SetTOTPEnabled(ctx context.Context, id string, enabled bool) error {
	_, err := s.db.Exec(ctx,
		`UPDATE users SET totp_enabled = $2, updated_at = now() WHERE id = $1::uuid`,
		id, enabled,
	)
	return err
}

func (s *Service) ClearTOTP(ctx context.Context, id string) error {
	_, err := s.db.Exec(ctx,
		`UPDATE users SET totp_secret = '', totp_enabled = false, updated_at = now() WHERE id = $1::uuid`,
		id,
	)
	return err
}

func (s *Service) SetEmail2FAEnabled(ctx context.Context, id string, v bool) error {
	_, err := s.db.Exec(ctx,
		`UPDATE users SET email_2fa_enabled = $2, updated_at = now() WHERE id = $1::uuid`,
		id, v,
	)
	return err
}

func (s *Service) UpdateEmail(ctx context.Context, id, email string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(ctx,
		`UPDATE users SET email = $2, updated_at = now() WHERE id = $1
		 RETURNING id, email, username, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			hide_subscriptions, messages_mutual_only, private_profile,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at`,
		id, email,
	).Scan(
		&u.ID, &u.Email, &u.Username, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.HideSubscriptions, &u.MessagesMutualOnly, &u.PrivateProfile,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("update email: %w", err)
	}
	return u, nil
}

func (s *Service) UpdatePrivacy(ctx context.Context, id string, hideSubs, mutualOnly, privateProfile bool) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(ctx, `
		UPDATE users
		   SET hide_subscriptions = $2,
		       messages_mutual_only = $3,
		       private_profile = $4,
		       updated_at = now()
		 WHERE id = $1
		 RETURNING id, email, username, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			hide_subscriptions, messages_mutual_only, private_profile,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at
	`, id, hideSubs, mutualOnly, privateProfile).Scan(
		&u.ID, &u.Email, &u.Username, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.HideSubscriptions, &u.MessagesMutualOnly, &u.PrivateProfile,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("update privacy: %w", err)
	}
	return u, nil
}
