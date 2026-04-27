package auth

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"golang.org/x/crypto/bcrypt"

	"sphere-backend/internal/config"
	"sphere-backend/internal/mail"
	"sphere-backend/internal/middleware"
	"sphere-backend/internal/uploads"
	"sphere-backend/internal/user"
)

// AccountHandler handles /account/* (authenticated).
type AccountHandler struct {
	Svc      *Service
	UserSvc  *user.Service
	Upload   *uploads.Service
	Config   *config.Config
	JWTSecret string // same as cfg.JWTSecret for code hashing
}

func NewAccountHandler(svc *Service, userSvc *user.Service, up *uploads.Service, cfg *config.Config) *AccountHandler {
	return &AccountHandler{Svc: svc, UserSvc: userSvc, Upload: up, Config: cfg, JWTSecret: cfg.JWTSecret}
}

type changePasswordReq struct {
	Old string `json:"old_password"`
	New string `json:"new_password"`
}

func (h *AccountHandler) ChangePassword(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req changePasswordReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	req.Old = strings.TrimSpace(req.Old)
	req.New = strings.TrimSpace(req.New)
	if req.Old == "" || req.New == "" {
		http.Error(w, `{"error":"passwords required"}`, http.StatusBadRequest)
		return
	}
	hash, err := h.UserSvc.GetPasswordHash(r.Context(), userID)
	if err != nil || hash == "" {
		http.Error(w, `{"error":"cannot change password for this account"}`, http.StatusBadRequest)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Old)) != nil {
		http.Error(w, `{"error":"wrong password"}`, http.StatusUnauthorized)
		return
	}
	st := EvaluatePassword(req.New)
	if st.Score < minRegisterPasswordScore {
		b, _ := json.Marshal(map[string]any{"error": "password_too_weak", "score": st.Score, "label": st.Label})
		http.Error(w, string(b), http.StatusBadRequest)
		return
	}
	nh, err := bcrypt.GenerateFromPassword([]byte(req.New), bcrypt.DefaultCost)
	if err != nil {
		http.Error(w, `{"error":"hash failed"}`, http.StatusInternalServerError)
		return
	}
	if err := h.UserSvc.UpdatePasswordHash(r.Context(), userID, string(nh)); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

type changeEmailStartReq struct {
	NewEmail string `json:"new_email"`
	Password string `json:"password"`
}

func (h *AccountHandler) ChangeEmailStart(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req changeEmailStartReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	req.NewEmail = strings.TrimSpace(strings.ToLower(req.NewEmail))
	if req.NewEmail == "" || !strings.Contains(req.NewEmail, "@") {
		http.Error(w, `{"error":"invalid email"}`, http.StatusBadRequest)
		return
	}
	u, err := h.UserSvc.GetByID(r.Context(), userID)
	if err != nil {
		http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		return
	}
	if strings.EqualFold(u.Email, req.NewEmail) {
		http.Error(w, `{"error":"already this email"}`, http.StatusBadRequest)
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
	var dupID string
	if qerr := h.Svc.Pool().QueryRow(r.Context(),
		`SELECT id FROM users WHERE lower(trim(email)) = lower(trim($1)) AND id <> $2::uuid`,
		req.NewEmail, userID,
	).Scan(&dupID); qerr == nil {
		http.Error(w, `{"error":"email already registered"}`, http.StatusConflict)
		return
	}
	plain, err := StoreEmailChangeCode(r.Context(), h.Svc.Pool(), h.JWTSecret, userID, req.NewEmail)
	if err != nil {
		http.Error(w, `{"error":"could not store code"}`, http.StatusInternalServerError)
		return
	}
	if err := mail.SendEmailChangeCode(r.Context(), h.Config.ResendAPIKey, h.Config.MailFrom, req.NewEmail, plain); err != nil {
		http.Error(w, `{"error":"could not send email","detail":"`+escapeJSONString(err.Error())+`"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

type changeEmailConfirmReq struct {
	NewEmail string `json:"new_email"`
	Code     string `json:"code"`
}

func (h *AccountHandler) ChangeEmailConfirm(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req changeEmailConfirmReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	req.NewEmail = strings.TrimSpace(strings.ToLower(req.NewEmail))
	if err := VerifyEmailChangeCode(r.Context(), h.Svc.Pool(), h.JWTSecret, userID, req.NewEmail, req.Code); err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusBadRequest)
		return
	}
	u, err := h.UserSvc.UpdateEmail(r.Context(), userID, req.NewEmail)
	if err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(u)
}

// UploadAvatar expects multipart field "image" (png/jpeg), max ~5MB.
func (h *AccountHandler) UploadAvatar(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	r.Body = http.MaxBytesReader(w, r.Body, 6<<20)
	if err := r.ParseMultipartForm(6 << 20); err != nil {
		http.Error(w, `{"error":"file too large"}`, http.StatusBadRequest)
		return
	}
	file, header, err := r.FormFile("image")
	if err != nil {
		http.Error(w, `{"error":"image required"}`, http.StatusBadRequest)
		return
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		http.Error(w, `{"error":"read failed"}`, http.StatusBadRequest)
		return
	}
	ct := header.Header.Get("Content-Type")
	if ct == "" {
		ct = http.DetectContentType(data)
	}
	if !strings.Contains(ct, "jpeg") && !strings.Contains(ct, "jpg") && !strings.Contains(ct, "png") && !strings.Contains(ct, "webp") {
		http.Error(w, `{"error":"jpeg or png required"}`, http.StatusBadRequest)
		return
	}
	key, err := h.Upload.UploadAvatar(r.Context(), userID, data, ct)
	if err != nil {
		http.Error(w, `{"error":"`+escapeJSONString(err.Error())+`"}`, http.StatusInternalServerError)
		return
	}
	fn := key[strings.LastIndex(key, "/")+1:]
	scheme := "https"
	if p := r.Header.Get("X-Forwarded-Proto"); p != "" {
		scheme = strings.TrimSpace(strings.Split(p, ",")[0])
	} else if r.TLS == nil {
		scheme = "http"
	}
	host := r.Host
	if host == "" {
		host = "localhost"
	}
	avatarURL := scheme + "://" + host + "/public/avatar/" + userID + "/" + fn

	u, err := h.UserSvc.UpdateAvatarURL(r.Context(), userID, avatarURL)
	if err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"user": u, "avatar_url": u.AvatarURL})
}

// PublicAvatar streams an object from S3 at avatars/{userID}/{filename}.
func (h *AccountHandler) PublicAvatar(w http.ResponseWriter, r *http.Request) {
	userID := chi.URLParam(r, "userID")
	fn := chi.URLParam(r, "filename")
	if userID == "" || fn == "" || strings.Contains(fn, "..") || strings.Contains(fn, "/") {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	key := "avatars/" + userID + "/" + fn
	reader, _, err := h.Upload.GetObjectReader(r.Context(), key)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	defer reader.Close()
	ext := strings.ToLower(fn[strings.LastIndex(fn, "."):])
	ct := "image/jpeg"
	switch ext {
	case ".png":
		ct = "image/png"
	case ".webp":
		ct = "image/webp"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = io.Copy(w, reader)
}
