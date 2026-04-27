package admin

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Handler struct {
	pool *pgxpool.Pool
}

func NewHandler(pool *pgxpool.Pool) *Handler {
	return &Handler{pool: pool}
}

type userRow struct {
	ID           string `json:"id"`
	Email        string `json:"email"`
	Name         string `json:"name"`
	IsVerified   bool   `json:"is_verified"`
	BadgeText    string `json:"badge_text"`
	BadgeColor   string `json:"badge_color"`
	Banned       bool   `json:"banned"`
	BannedReason string `json:"banned_reason"`
	IsAdmin      bool   `json:"is_admin"`
}

// ListUsers GET /admin/users
func (h *Handler) ListUsers(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	limit := 30
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 100 {
			limit = n
		}
	}
	offset := 0
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			offset = n
		}
	}

	var (
		rows pgx.Rows
		err  error
	)
	if q != "" {
		rows, err = h.pool.Query(r.Context(),
			`SELECT id::text, email, name, is_verified, badge_text, badge_color, banned, banned_reason, is_admin
			 FROM users
			 WHERE email ILIKE '%' || $3 || '%' OR name ILIKE '%' || $3 || '%'
			 ORDER BY created_at DESC LIMIT $1 OFFSET $2`,
			limit, offset, q,
		)
	} else {
		rows, err = h.pool.Query(r.Context(),
			`SELECT id::text, email, name, is_verified, badge_text, badge_color, banned, banned_reason, is_admin
			 FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2`,
			limit, offset,
		)
	}
	if err != nil {
		http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var out []userRow
	for rows.Next() {
		var u userRow
		if err := rows.Scan(&u.ID, &u.Email, &u.Name, &u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.Banned, &u.BannedReason, &u.IsAdmin); err != nil {
			continue
		}
		out = append(out, u)
	}
	if out == nil {
		out = []userRow{}
	}
	if err := rows.Err(); err != nil {
		http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"users": out})
}

// GetUser GET /admin/users/{id}
func (h *Handler) GetUser(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if id == "" {
		http.Error(w, `{"error":"id required"}`, http.StatusBadRequest)
		return
	}
	var u userRow
	err := h.pool.QueryRow(r.Context(),
		`SELECT id::text, email, name, is_verified, badge_text, badge_color, banned, banned_reason, is_admin
		 FROM users WHERE id = $1::uuid`,
		id,
	).Scan(&u.ID, &u.Email, &u.Name, &u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.Banned, &u.BannedReason, &u.IsAdmin)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(u)
}

type banBody struct {
	Reason string `json:"reason"`
}

// Ban POST /admin/users/{id}/ban
func (h *Handler) Ban(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if id == "" {
		http.Error(w, `{"error":"id required"}`, http.StatusBadRequest)
		return
	}
	var body banBody
	_ = json.NewDecoder(r.Body).Decode(&body)
	if _, err := h.pool.Exec(r.Context(),
		`UPDATE users SET banned = true, banned_reason = $2, updated_at = now() WHERE id = $1::uuid`,
		id, strings.TrimSpace(body.Reason),
	); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Unban POST /admin/users/{id}/unban
func (h *Handler) Unban(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if id == "" {
		http.Error(w, `{"error":"id required"}`, http.StatusBadRequest)
		return
	}
	if _, err := h.pool.Exec(r.Context(),
		`UPDATE users SET banned = false, banned_reason = '', updated_at = now() WHERE id = $1::uuid`, id,
	); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type verifiedBody struct {
	Value bool `json:"value"`
}

// SetVerified PUT /admin/users/{id}/verified
func (h *Handler) SetVerified(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var body verifiedBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, `{"error":"invalid"}`, http.StatusBadRequest)
		return
	}
	if _, err := h.pool.Exec(r.Context(),
		`UPDATE users SET is_verified = $2, updated_at = now() WHERE id = $1::uuid`, id, body.Value,
	); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type badgeBody struct {
	Text  string `json:"text"`
	Color string `json:"color"`
}

// SetBadge PUT /admin/users/{id}/badge
func (h *Handler) SetBadge(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var body badgeBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, `{"error":"invalid"}`, http.StatusBadRequest)
		return
	}
	t := []rune(strings.TrimSpace(body.Text))
	if len(t) > 5 {
		http.Error(w, `{"error":"text max 5"}`, http.StatusBadRequest)
		return
	}
	if _, err := h.pool.Exec(r.Context(),
		`UPDATE users SET badge_text = $2, badge_color = $3, updated_at = now() WHERE id = $1::uuid`,
		id, string(t), strings.TrimSpace(body.Color),
	); err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
