package auth

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/pquerna/otp/totp"
	"golang.org/x/crypto/bcrypt"

	"sphere-backend/internal/middleware"
)

type totpSetupResponse struct {
	OtpAuthURL string `json:"otpauth_url"`
	Secret     string `json:"secret"`
}

// TOTPSetup generates a secret and stores it (totp stays disabled until /totp/enable).
func (h *AccountHandler) TOTPSetup(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	u, err := h.UserSvc.GetByID(r.Context(), userID)
	if err != nil {
		http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		return
	}
	if u.TOTPEnabled {
		http.Error(w, `{"error":"disable totp first"}`, http.StatusBadRequest)
		return
	}
	key, err := totp.Generate(totp.GenerateOpts{
		Issuer:      "Sphere",
		AccountName: u.Email,
	})
	if err != nil {
		http.Error(w, `{"error":"totp generate failed"}`, http.StatusInternalServerError)
		return
	}
	if err := h.UserSvc.SetTOTPSecret(r.Context(), userID, key.Secret()); err != nil {
		http.Error(w, `{"error":"save failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(totpSetupResponse{
		OtpAuthURL: key.URL(),
		Secret:     key.Secret(),
	})
}

type totpEnableReq struct {
	Code string `json:"code"`
}

// TOTPEnable validates the first code and enables TOTP.
func (h *AccountHandler) TOTPEnable(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req totpEnableReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	code := strings.TrimSpace(req.Code)
	if code == "" {
		http.Error(w, `{"error":"code required"}`, http.StatusBadRequest)
		return
	}
	sec, err := h.UserSvc.GetTOTPSecret(r.Context(), userID)
	if err != nil || strings.TrimSpace(sec) == "" {
		http.Error(w, `{"error":"run totp setup first"}`, http.StatusBadRequest)
		return
	}
	if !totp.Validate(code, sec) {
		http.Error(w, `{"error":"invalid code"}`, http.StatusBadRequest)
		return
	}
	if err := h.UserSvc.SetTOTPEnabled(r.Context(), userID, true); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

type passwordOnlyReq struct {
	Password string `json:"password"`
}

// TOTPDisable removes TOTP after password check.
func (h *AccountHandler) TOTPDisable(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req passwordOnlyReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	hash, err := h.UserSvc.GetPasswordHash(r.Context(), userID)
	if err != nil || hash == "" {
		http.Error(w, `{"error":"password not set"}`, http.StatusBadRequest)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil {
		http.Error(w, `{"error":"wrong password"}`, http.StatusUnauthorized)
		return
	}
	if err := h.UserSvc.ClearTOTP(r.Context(), userID); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

// Email2FAEnable enables email OTP at login.
func (h *AccountHandler) Email2FAEnable(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req passwordOnlyReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	hash, err := h.UserSvc.GetPasswordHash(r.Context(), userID)
	if err != nil || hash == "" {
		http.Error(w, `{"error":"password not set"}`, http.StatusBadRequest)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil {
		http.Error(w, `{"error":"wrong password"}`, http.StatusUnauthorized)
		return
	}
	if err := h.UserSvc.SetEmail2FAEnabled(r.Context(), userID, true); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

// Email2FADisable disables email OTP at login.
func (h *AccountHandler) Email2FADisable(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req passwordOnlyReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	hash, err := h.UserSvc.GetPasswordHash(r.Context(), userID)
	if err != nil || hash == "" {
		http.Error(w, `{"error":"password not set"}`, http.StatusBadRequest)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil {
		http.Error(w, `{"error":"wrong password"}`, http.StatusUnauthorized)
		return
	}
	if err := h.UserSvc.SetEmail2FAEnabled(r.Context(), userID, false); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}
