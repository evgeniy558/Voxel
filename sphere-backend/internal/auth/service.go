package auth

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pquerna/otp/totp"
	"golang.org/x/crypto/bcrypt"

	"sphere-backend/internal/config"
	"sphere-backend/internal/mail"
	"sphere-backend/internal/user"
)

type Service struct {
	db     *pgxpool.Pool
	cfg    *config.Config
	secret string
}

func NewService(db *pgxpool.Pool, cfg *config.Config) *Service {
	return &Service{db: db, cfg: cfg, secret: cfg.JWTSecret}
}

func (s *Service) Register(ctx context.Context, email, password, name string) (*user.User, string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, "", fmt.Errorf("hash password: %w", err)
	}

	u := &user.User{}
	err = s.db.QueryRow(ctx,
		`INSERT INTO users (email, password_hash, name) VALUES ($1, $2, $3)
		 RETURNING id, email, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at`,
		email, string(hash), name,
	).Scan(
		&u.ID, &u.Email, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		return nil, "", fmt.Errorf("insert user: %w", err)
	}

	token, err := s.generateToken(u.ID)
	if err != nil {
		return nil, "", err
	}
	return u, token, nil
}

// SendSignupCode generates a code, stores it, and emails it (or logs in dev when mail is unset / SIGNUP_LOG_CODE).
func (s *Service) SendSignupCode(ctx context.Context, email string) (string, error) {
	email = strings.TrimSpace(strings.ToLower(email))
	if email == "" {
		return "", errors.New("email required")
	}
	plain, err := StoreSignupCode(ctx, s.db, s.secret, email)
	if err != nil {
		return "", err
	}
	if err := mail.SendSignupCode(ctx, s.cfg.ResendAPIKey, s.cfg.MailFrom, email, plain); err != nil {
		if s.cfg.SignupLogCode {
			//nolint
			println("[signup] code for", email, "=>", plain, "(resend err:", err.Error(), ")")
			return "sent", nil
		}
		if s.cfg.ResendAPIKey == "" {
			//nolint
			println("[signup] RESEND_API_KEY not set; code for", email, "=>", plain)
			return "sent", nil
		}
		return "", err
	}
	return "sent", nil
}

// Pool exposes the DB (rate limiting, etc. in handler).
func (s *Service) Pool() *pgxpool.Pool { return s.db }

// LoginOutcome is returned from Login — either JWT or a 2FA challenge.
type LoginOutcome struct {
	User           *user.User `json:"user,omitempty"`
	Token          string    `json:"-"`
	Requires2FA    bool      `json:"requires_2fa"`
	ChallengeID    string    `json:"challenge_id,omitempty"`
	TwoFAMethods    []string  `json:"methods,omitempty"`
}

func (s *Service) Login(ctx context.Context, email, password string) (*LoginOutcome, error) {
	u := &user.User{}
	err := s.db.QueryRow(ctx,
		`SELECT id, email, password_hash, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at
		 FROM users WHERE email = $1`, email,
	).Scan(
		&u.ID, &u.Email, &u.PasswordHash, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("invalid credentials")
		}
		return nil, fmt.Errorf("query user: %w", err)
	}

	if err := bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(password)); err != nil {
		return nil, fmt.Errorf("invalid credentials")
	}

	if u.Banned {
		return nil, fmt.Errorf("account suspended")
	}

	want2FA := u.Email2FAEnabled || u.TOTPEnabled
	if !want2FA {
		token, err := s.generateToken(u.ID)
		if err != nil {
			return nil, err
		}
		u.PasswordHash = ""
		return &LoginOutcome{User: u, Token: token}, nil
	}

	challengeID := uuid.New()
	expires := time.Now().Add(15 * time.Minute)
	if _, err := s.db.Exec(ctx,
		`INSERT INTO login_2fa_challenges (id, user_id, expires_at, email_sent) VALUES ($1, $2, $3, false)`,
		challengeID, u.ID, expires,
	); err != nil {
		return nil, fmt.Errorf("challenge: %w", err)
	}

	var methods []string
	if u.Email2FAEnabled {
		methods = append(methods, "email")
	}
	if u.TOTPEnabled {
		methods = append(methods, "totp")
	}

	if u.Email2FAEnabled {
		plain, err := StoreSignupCode(ctx, s.db, s.secret, "login:"+challengeID.String())
		if err != nil {
			return nil, err
		}
		if err := mail.SendLoginOTP(ctx, s.cfg.ResendAPIKey, s.cfg.MailFrom, u.Email, plain); err != nil {
			return nil, err
		}
		_, _ = s.db.Exec(ctx, `UPDATE login_2fa_challenges SET email_sent = true WHERE id = $1`, challengeID)
	}

	u.PasswordHash = ""
	return &LoginOutcome{
		User: u, Requires2FA: true, ChallengeID: challengeID.String(), TwoFAMethods: methods,
	}, nil
}

// CompleteTwoFactor validates the second factor and returns a JWT + public user row.
func (s *Service) CompleteTwoFactor(ctx context.Context, challengeIDStr, method, code string) (*user.User, string, error) {
	challengeIDStr = strings.TrimSpace(challengeIDStr)
	method = strings.TrimSpace(strings.ToLower(method))
	code = strings.TrimSpace(code)
	chID, err := uuid.Parse(challengeIDStr)
	if err != nil || challengeIDStr == "" || code == "" {
		return nil, "", fmt.Errorf("invalid request")
	}

	var userID string
	var exp time.Time
	err = s.db.QueryRow(ctx,
		`SELECT user_id, expires_at FROM login_2fa_challenges WHERE id = $1`, chID,
	).Scan(&userID, &exp)
	if err != nil {
		return nil, "", fmt.Errorf("invalid or expired challenge")
	}
	if time.Now().After(exp) {
		_, _ = s.db.Exec(ctx, `DELETE FROM login_2fa_challenges WHERE id = $1`, chID)
		return nil, "", fmt.Errorf("challenge expired")
	}

	switch method {
	case "email":
		if err := VerifySignupCode(ctx, s.db, s.secret, "login:"+challengeIDStr, code); err != nil {
			return nil, "", err
		}
	case "totp":
		var sec string
		if err := s.db.QueryRow(ctx, `SELECT totp_secret FROM users WHERE id = $1`, userID).Scan(&sec); err != nil || strings.TrimSpace(sec) == "" {
			return nil, "", fmt.Errorf("totp not configured")
		}
		if ok := totp.Validate(code, sec); !ok {
			return nil, "", fmt.Errorf("invalid totp code")
		}
	default:
		return nil, "", fmt.Errorf("unknown method")
	}

	_, _ = s.db.Exec(ctx, `DELETE FROM login_2fa_challenges WHERE id = $1`, chID)

	u := &user.User{}
	err = s.db.QueryRow(ctx,
		`SELECT id, email, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at
		 FROM users WHERE id = $1`, userID,
	).Scan(
		&u.ID, &u.Email, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		return nil, "", err
	}
	token, err := s.generateToken(u.ID)
	if err != nil {
		return nil, "", err
	}
	return u, token, nil
}

func (s *Service) GoogleAuth(ctx context.Context, googleID, email, name, avatar string) (*user.User, string, error) {
	u := &user.User{}
	err := s.db.QueryRow(ctx,
		`SELECT id, email, name, avatar_url,
			is_verified, badge_text, badge_color, is_admin,
			banned, banned_reason,
			totp_enabled, email_2fa_enabled,
			created_at, updated_at
		 FROM users WHERE google_id = $1`, googleID,
	).Scan(
		&u.ID, &u.Email, &u.Name, &u.AvatarURL,
		&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
		&u.Banned, &u.BannedReason,
		&u.TOTPEnabled, &u.Email2FAEnabled,
		&u.CreatedAt, &u.UpdatedAt,
	)

	if errors.Is(err, pgx.ErrNoRows) {
		err = s.db.QueryRow(ctx,
			`INSERT INTO users (email, name, avatar_url, google_id)
			 VALUES ($1, $2, $3, $4)
			 ON CONFLICT (email) DO UPDATE SET google_id = $4, updated_at = now()
			 RETURNING id, email, name, avatar_url,
				is_verified, badge_text, badge_color, is_admin,
				banned, banned_reason,
				totp_enabled, email_2fa_enabled,
				created_at, updated_at`,
			email, name, avatar, googleID,
		).Scan(
			&u.ID, &u.Email, &u.Name, &u.AvatarURL,
			&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
			&u.Banned, &u.BannedReason,
			&u.TOTPEnabled, &u.Email2FAEnabled,
			&u.CreatedAt, &u.UpdatedAt,
		)
	}
	if err != nil {
		return nil, "", fmt.Errorf("google auth: %w", err)
	}

	if u.Banned {
		return nil, "", fmt.Errorf("account suspended")
	}

	token, err := s.generateToken(u.ID)
	if err != nil {
		return nil, "", err
	}
	return u, token, nil
}

// GenerateTokenForUser issues a JWT (QR login approve, tests).
func (s *Service) GenerateTokenForUser(userID string) (string, error) {
	return s.generateToken(userID)
}

func (s *Service) generateToken(userID string) (string, error) {
	claims := jwt.MapClaims{
		"sub": userID,
		"exp": time.Now().Add(30 * 24 * time.Hour).Unix(),
		"iat": time.Now().Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(s.secret))
}
