package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const signupCodeTTL = 10 * time.Minute

func hashSignupCode(pepper, email, code string) string {
	h := sha256.Sum256([]byte(pepper + "|" + strings.ToLower(strings.TrimSpace(email)) + "|" + strings.TrimSpace(code)))
	return hex.EncodeToString(h[:])
}

// StoreSignupCode generates a 6-digit code and stores its hash.
func StoreSignupCode(ctx context.Context, pool *pgxpool.Pool, pepper, email string) (plain string, err error) {
	email = strings.TrimSpace(strings.ToLower(email))
	if email == "" {
		return "", fmt.Errorf("email required")
	}
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	plain = fmt.Sprintf("%06d", n.Int64())
	hash := hashSignupCode(pepper, email, plain)
	exp := time.Now().Add(signupCodeTTL)
	_, err = pool.Exec(ctx,
		`INSERT INTO signup_email_codes (email, code_hash, expires_at)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (email) DO UPDATE SET code_hash = EXCLUDED.code_hash, expires_at = EXCLUDED.expires_at`,
		email, hash, exp,
	)
	if err != nil {
		return "", err
	}
	return plain, nil
}

// VerifySignupCode checks the code for this email and deletes the row on success.
func VerifySignupCode(ctx context.Context, pool *pgxpool.Pool, pepper, email, code string) error {
	email = strings.TrimSpace(strings.ToLower(email))
	code = strings.TrimSpace(code)
	if email == "" || code == "" {
		return fmt.Errorf("invalid code")
	}
	var (
		storedHash string
		expires    time.Time
	)
	err := pool.QueryRow(ctx,
		`SELECT code_hash, expires_at FROM signup_email_codes WHERE email = $1`, email,
	).Scan(&storedHash, &expires)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("code not found or expired — request a new code")
		}
		return err
	}
	if time.Now().After(expires) {
		_, _ = pool.Exec(ctx, `DELETE FROM signup_email_codes WHERE email = $1`, email)
		return fmt.Errorf("code expired")
	}
	if hashSignupCode(pepper, email, code) != storedHash {
		return fmt.Errorf("invalid code")
	}
	_, err = pool.Exec(ctx, `DELETE FROM signup_email_codes WHERE email = $1`, email)
	return err
}
