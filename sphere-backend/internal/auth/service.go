package auth

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
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
		 RETURNING id, email, name, avatar_url, created_at, updated_at`,
		email, string(hash), name,
	).Scan(&u.ID, &u.Email, &u.Name, &u.AvatarURL, &u.CreatedAt, &u.UpdatedAt)
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

func (s *Service) Login(ctx context.Context, email, password string) (*user.User, string, error) {
	u := &user.User{}
	err := s.db.QueryRow(ctx,
		`SELECT id, email, password_hash, name, avatar_url, created_at, updated_at
		 FROM users WHERE email = $1`, email,
	).Scan(&u.ID, &u.Email, &u.PasswordHash, &u.Name, &u.AvatarURL, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, "", fmt.Errorf("invalid credentials")
		}
		return nil, "", fmt.Errorf("query user: %w", err)
	}

	if err := bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(password)); err != nil {
		return nil, "", fmt.Errorf("invalid credentials")
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
		`SELECT id, email, name, avatar_url, created_at, updated_at
		 FROM users WHERE google_id = $1`, googleID,
	).Scan(&u.ID, &u.Email, &u.Name, &u.AvatarURL, &u.CreatedAt, &u.UpdatedAt)

	if errors.Is(err, pgx.ErrNoRows) {
		err = s.db.QueryRow(ctx,
			`INSERT INTO users (email, name, avatar_url, google_id)
			 VALUES ($1, $2, $3, $4)
			 ON CONFLICT (email) DO UPDATE SET google_id = $4, updated_at = now()
			 RETURNING id, email, name, avatar_url, created_at, updated_at`,
			email, name, avatar, googleID,
		).Scan(&u.ID, &u.Email, &u.Name, &u.AvatarURL, &u.CreatedAt, &u.UpdatedAt)
	}
	if err != nil {
		return nil, "", fmt.Errorf("google auth: %w", err)
	}

	token, err := s.generateToken(u.ID)
	if err != nil {
		return nil, "", err
	}
	return u, token, nil
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
