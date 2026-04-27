package auth

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"sphere-backend/internal/config"
)

type Handler struct {
	svc      *Service
	cfg      *config.Config
	lastSend map[string]time.Time
	sendMu   sync.Mutex
}

func NewHandler(svc *Service, cfg *config.Config) *Handler {
	return &Handler{svc: svc, cfg: cfg, lastSend: make(map[string]time.Time)}
}

type registerRequest struct {
	Email          string `json:"email"`
	Password       string `json:"password"`
	Name           string `json:"name"`
	EmailCode      string `json:"email_code"`
	RecaptchaToken string `json:"recaptcha_token"`
}

type sendCodeRequest struct {
	Email string `json:"email"`
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type googleRequest struct {
	IDToken string `json:"id_token"`
}

type authResponse struct {
	Token string `json:"token"`
	User  any    `json:"user"`
}

// RecaptchaEmbedPage returns a minimal HTML that runs reCAPTCHA v3 and posts the token to the iOS app via WKWebView messageHandlers.
//
// Some networks block `www.google.com` but allow `www.recaptcha.net`, so we support:
//   - /auth/recaptcha-embed            → google endpoint
//   - /auth/recaptcha-embed?alt=1      → recaptcha.net endpoint
//
// See docs: https://developers.google.com/recaptcha/docs/v3
func (h *Handler) RecaptchaEmbedPage(w http.ResponseWriter, r *http.Request) {
	key := strings.TrimSpace(h.cfg.RecaptchaSiteKey)
	if key == "" {
		http.Error(w, "recaptcha not configured", http.StatusNotFound)
		return
	}
	endpoint := "https://www.google.com/recaptcha/api.js?render=%s"
	if r.URL.Query().Get("alt") == "1" {
		endpoint = "https://www.recaptcha.net/recaptcha/api.js?render=%s"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = fmt.Fprintf(w, `<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width"/>
<script src="`+endpoint+`"></script>
</head><body>
<script>
grecaptcha.ready(function() {
  grecaptcha.execute("%s", {action: "signup"}).then(function(token) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.recaptcha) {
      window.webkit.messageHandlers.recaptcha.postMessage(token);
    }
  }).catch(function(e) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.recaptcha) {
      window.webkit.messageHandlers.recaptcha.postMessage("");
    }
  });
});
</script>
</body></html>`, key, key)
}

// PublicConfig exposes client-safe settings (reCAPTCHA site key, etc.).
func (h *Handler) PublicConfig(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"recaptcha_site_key":  strings.TrimSpace(h.cfg.RecaptchaSiteKey),
		"recaptcha_min_score": h.cfg.RecaptchaMinScore,
		"signup_code_length":  6,
	})
}

// SendSignupCode emails a 6-digit code (or logs when mail is not configured).
func (h *Handler) SendSignupCode(w http.ResponseWriter, r *http.Request) {
	var req sendCodeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	email := strings.TrimSpace(strings.ToLower(req.Email))
	if email == "" {
		http.Error(w, `{"error":"email required"}`, http.StatusBadRequest)
		return
	}
	h.sendMu.Lock()
	if t, ok := h.lastSend[email]; ok && time.Since(t) < 60*time.Second {
		h.sendMu.Unlock()
		http.Error(w, `{"error":"rate_limited","detail":"try again in a minute"}`, http.StatusTooManyRequests)
		return
	}
	h.lastSend[email] = time.Now()
	h.sendMu.Unlock()

	if _, err := h.svc.SendSignupCode(r.Context(), email); err != nil {
		log.Printf("[signup-code] %v", err)
		http.Error(w, `{"error":"could not send code","detail":"`+escapeJSONString(err.Error())+`"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

func escapeJSONString(s string) string {
	b, _ := json.Marshal(s)
	if len(b) >= 2 {
		return string(b[1 : len(b)-1])
	}
	return s
}

func (h *Handler) Register(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	if req.Email == "" || req.Password == "" || req.Name == "" {
		http.Error(w, `{"error":"email, password and name are required"}`, http.StatusBadRequest)
		return
	}
	le := strings.ToLower(strings.TrimSpace(req.Email))
	isLegacyAuto := strings.HasPrefix(req.Password, "sphere_") && strings.HasSuffix(req.Password, "_autopass") &&
		(strings.HasSuffix(le, "@sphere.app") || strings.HasSuffix(le, "@sphere.local"))
	if isLegacyAuto {
		u, token, err := h.svc.Register(r.Context(), req.Email, req.Password, req.Name)
		if err != nil {
			http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusConflict)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(authResponse{Token: token, User: u})
		return
	}
	if strings.TrimSpace(req.EmailCode) == "" {
		http.Error(w, `{"error":"email_code required"}`, http.StatusBadRequest)
		return
	}

	// reCAPTCHA v3 — optional in dev when RECAPTCHA_SECRET is empty
	if h.cfg.RecaptchaSecret != "" {
		rip := r.RemoteAddr
		if xf := r.Header.Get("X-Forwarded-For"); xf != "" {
			rip = strings.TrimSpace(strings.Split(xf, ",")[0])
		}
		if err := VerifyRecaptchaV3(r.Context(), h.cfg.RecaptchaSecret, req.RecaptchaToken, rip, h.cfg.RecaptchaMinScore); err != nil {
			http.Error(w, `{"error":"recaptcha_failed","detail":"`+err.Error()+`"}`, http.StatusBadRequest)
			return
		}
	}

	st := EvaluatePassword(req.Password)
	if st.Score < minRegisterPasswordScore {
		b, _ := json.Marshal(map[string]any{"error": "password_too_weak", "score": st.Score, "label": st.Label})
		http.Error(w, string(b), http.StatusBadRequest)
		return
	}

	if err := VerifySignupCode(r.Context(), h.svc.Pool(), h.cfg.JWTSecret, req.Email, req.EmailCode); err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusBadRequest)
		return
	}

	u, token, err := h.svc.Register(r.Context(), req.Email, req.Password, req.Name)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusConflict)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(authResponse{Token: token, User: u})
}

func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	out, err := h.svc.Login(r.Context(), req.Email, req.Password)
	if err != nil {
		msg := err.Error()
		st := http.StatusUnauthorized
		if strings.Contains(msg, "suspended") {
			st = http.StatusForbidden
		}
		http.Error(w, `{"error":"`+escapeJSONString(msg)+`"}`, st)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if out.Requires2FA {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"requires_2fa":  true,
			"challenge_id":  out.ChallengeID,
			"methods":       out.TwoFAMethods,
			"user":          out.User,
		})
		return
	}
	json.NewEncoder(w).Encode(authResponse{Token: out.Token, User: out.User})
}

type twoFactorVerifyRequest struct {
	ChallengeID string `json:"challenge_id"`
	Method      string `json:"method"`
	Code        string `json:"code"`
}

// TwoFactorVerify completes login after password step when 2FA is enabled.
func (h *Handler) TwoFactorVerify(w http.ResponseWriter, r *http.Request) {
	var req twoFactorVerifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	u, token, err := h.svc.CompleteTwoFactor(r.Context(), req.ChallengeID, req.Method, req.Code)
	if err != nil {
		http.Error(w, `{"error":"`+escapeJSONString(err.Error())+`"}`, http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(authResponse{Token: token, User: u})
}

func (h *Handler) Google(w http.ResponseWriter, r *http.Request) {
	var req googleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	info, err := VerifyGoogleToken(r.Context(), req.IDToken, h.cfg.GoogleClientID)
	if err != nil {
		http.Error(w, `{"error":"invalid google token"}`, http.StatusUnauthorized)
		return
	}

	u, token, err := h.svc.GoogleAuth(r.Context(), info.Sub, info.Email, info.Name, info.Picture)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(authResponse{Token: token, User: u})
}
