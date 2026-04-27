package auth

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"sphere-backend/internal/middleware"
	"sphere-backend/internal/user"
)

type qrStartResponse struct {
	SessionID string `json:"session_id"`
	QRPayload string `json:"qr_payload"`
	Nonce     string `json:"nonce"`
	ExpiresAt string `json:"expires_at"`
}

// QRLoginStart creates a pending session for scanning from another device.
func (h *Handler) QRLoginStart(w http.ResponseWriter, r *http.Request) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		http.Error(w, `{"error":"rng"}`, http.StatusInternalServerError)
		return
	}
	nonce := hex.EncodeToString(b[:])
	sid := uuid.New()
	exp := time.Now().Add(5 * time.Minute)
	if _, err := h.svc.Pool().Exec(r.Context(),
		`INSERT INTO qr_login_sessions (id, nonce, status, expires_at) VALUES ($1, $2, 'pending', $3)`,
		sid, nonce, exp,
	); err != nil {
		http.Error(w, `{"error":"could not create session"}`, http.StatusInternalServerError)
		return
	}
	payload := fmt.Sprintf("sphere://qr-login?sid=%s&n=%s", sid.String(), nonce)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(qrStartResponse{
		SessionID: sid.String(),
		QRPayload: payload,
		Nonce:     nonce,
		ExpiresAt: exp.UTC().Format(time.RFC3339),
	})
}

// QRLoginPoll returns {token,user} when the session was approved.
func (h *Handler) QRLoginPoll(w http.ResponseWriter, r *http.Request) {
	sidStr := strings.TrimSpace(r.URL.Query().Get("session_id"))
	if sidStr == "" {
		http.Error(w, `{"error":"session_id required"}`, http.StatusBadRequest)
		return
	}
	sid, err := uuid.Parse(sidStr)
	if err != nil {
		http.Error(w, `{"error":"bad session"}`, http.StatusBadRequest)
		return
	}
	ctx := r.Context()
	deadline, ok := ctx.Deadline()
	waitUntil := time.Now().Add(55 * time.Second)
	if ok && deadline.Before(waitUntil) {
		waitUntil = deadline
	}

	for time.Now().Before(waitUntil) {
		var (
			status string
			tok    *string
			uid    *string
		)
		err := h.svc.Pool().QueryRow(ctx,
			`SELECT status, token, user_id FROM qr_login_sessions WHERE id = $1`, sid,
		).Scan(&status, &tok, &uid)
		if err != nil {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		if status == "approved" && tok != nil && *tok != "" && uid != nil {
			u := &user.User{}
			err := h.svc.Pool().QueryRow(ctx,
				`SELECT id, email, name, avatar_url,
					is_verified, badge_text, badge_color, is_admin,
					banned, banned_reason,
					totp_enabled, email_2fa_enabled,
					created_at, updated_at FROM users WHERE id = $1`, *uid,
			).Scan(
				&u.ID, &u.Email, &u.Name, &u.AvatarURL,
				&u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.IsAdmin,
				&u.Banned, &u.BannedReason,
				&u.TOTPEnabled, &u.Email2FAEnabled,
				&u.CreatedAt, &u.UpdatedAt,
			)
			if err != nil {
				http.Error(w, `{"error":"user"}`, http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(authResponse{Token: *tok, User: u})
			return
		}
		if status == "expired" || status == "cancelled" {
			http.Error(w, `{"error":"session ended"}`, http.StatusGone)
			return
		}
		select {
		case <-ctx.Done():
			w.WriteHeader(http.StatusNoContent)
			return
		case <-time.After(800 * time.Millisecond):
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

type qrApproveRequest struct {
	SessionID string `json:"session_id"`
	Nonce     string `json:"nonce"`
}

// QRApprove is called by an authenticated device to approve the web/session client.
func (h *Handler) QRApprove(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req qrApproveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	sid, err := uuid.Parse(strings.TrimSpace(req.SessionID))
	if err != nil {
		http.Error(w, `{"error":"bad session"}`, http.StatusBadRequest)
		return
	}
	nonce := strings.TrimSpace(req.Nonce)
	var dbNonce, status string
	var exp time.Time
	err = h.svc.Pool().QueryRow(r.Context(),
		`SELECT nonce, status, expires_at FROM qr_login_sessions WHERE id = $1`, sid,
	).Scan(&dbNonce, &status, &exp)
	if err != nil || status != "pending" {
		http.Error(w, `{"error":"invalid session"}`, http.StatusBadRequest)
		return
	}
	if time.Now().After(exp) {
		_, _ = h.svc.Pool().Exec(context.Background(), `UPDATE qr_login_sessions SET status = 'expired' WHERE id = $1`, sid)
		http.Error(w, `{"error":"expired"}`, http.StatusGone)
		return
	}
	if dbNonce != nonce {
		http.Error(w, `{"error":"bad nonce"}`, http.StatusUnauthorized)
		return
	}
	tok, err := h.svc.GenerateTokenForUser(userID)
	if err != nil {
		http.Error(w, `{"error":"token"}`, http.StatusInternalServerError)
		return
	}

	if _, err := h.svc.Pool().Exec(r.Context(),
		`UPDATE qr_login_sessions SET status = 'approved', user_id = $2::uuid, token = $3 WHERE id = $1`,
		sid, userID, tok,
	); err != nil {
		http.Error(w, `{"error":"update"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}
