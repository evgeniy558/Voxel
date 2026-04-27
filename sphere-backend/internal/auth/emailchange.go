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

func hashEmailChange(pepper, userID, newEmail, code string) string {
	em := strings.ToLower(strings.TrimSpace(newEmail))
	h := sha256.Sum256([]byte(pepper + "|email-change|" + userID + "|" + em + "|" + strings.TrimSpace(code)))
	return hex.EncodeToString(h[:])
}

// StoreEmailChangeCode generates a 6-digit code for confirming a new email address.
func StoreEmailChangeCode(ctx context.Context, pool *pgxpool.Pool, pepper, userID, newEmail string) (plain string, err error) {
	newEmail = strings.TrimSpace(strings.ToLower(newEmail))
	if newEmail == "" || userID == "" {
		return "", fmt.Errorf("invalid")
	}
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	plain = fmt.Sprintf("%06d", n.Int64())
	hash := hashEmailChange(pepper, userID, newEmail, plain)
	exp := time.Now().Add(signupCodeTTL)
	_, err = pool.Exec(ctx,
		`INSERT INTO email_change_codes (user_id, new_email, code_hash, expires_at)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (user_id) DO UPDATE SET new_email = EXCLUDED.new_email, code_hash = EXCLUDED.code_hash, expires_at = EXCLUDED.expires_at`,
		userID, newEmail, hash, exp,
	)
	if err != nil {
		return "", err
	}
	return plain, nil
}

// VerifyEmailChangeCode validates the code and deletes the row on success.
func VerifyEmailChangeCode(ctx context.Context, pool *pgxpool.Pool, pepper, userID, newEmail, code string) error {
	newEmail = strings.TrimSpace(strings.ToLower(newEmail))
	code = strings.TrimSpace(code)
	if userID == "" || newEmail == "" || code == "" {
		return fmt.Errorf("invalid code")
	}
	var (
		storedHash string
		expires    time.Time
		storedMail string
	)
	err := pool.QueryRow(ctx,
		`SELECT code_hash, expires_at, new_email FROM email_change_codes WHERE user_id = $1`, userID,
	).Scan(&storedHash, &expires, &storedMail)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("code not found")
		}
		return err
	}
	if storedMail != newEmail {
		return fmt.Errorf("email mismatch")
	}
	if time.Now().After(expires) {
		_, _ = pool.Exec(ctx, `DELETE FROM email_change_codes WHERE user_id = $1`, userID)
		return fmt.Errorf("code expired")
	}
	if hashEmailChange(pepper, userID, newEmail, code) != storedHash {
		return fmt.Errorf("invalid code")
	}
	_, err = pool.Exec(ctx, `DELETE FROM email_change_codes WHERE user_id = $1`, userID)
	return err
}
