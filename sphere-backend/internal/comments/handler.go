package comments

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"sphere-backend/internal/middleware"
)

type Handler struct {
	svc *Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")
	includeApp := strings.TrimSpace(middleware.GetUserID(r.Context())) != ""

	var comments []Comment
	if includeApp {
		var err error
		comments, err = h.svc.List(r.Context(), prov, id)
		if err != nil {
			http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			return
		}
		if comments == nil {
			comments = []Comment{}
		}
	} else {
		// In-app (encrypted) comments are only visible to authenticated Sphere users.
		if prov != "soundcloud" {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode([]Comment{})
			return
		}
	}

	if prov == "soundcloud" {
		scComments, err := h.svc.ListSoundCloud(r.Context(), id, 50)
		if err == nil && len(scComments) > 0 {
			if includeApp {
				comments = append(scComments, comments...)
			} else {
				comments = scComments
			}
		} else if !includeApp {
			if comments == nil {
				comments = []Comment{}
			}
		}
	}

	if comments == nil {
		comments = []Comment{}
	}
	if includeApp {
		log.Printf("[comments] list prov=%s id=%s app_count=%d", prov, id, countApp(comments))
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(comments)
}

func countApp(comments []Comment) int {
	var n int
	for _, c := range comments {
		if c.Source == "app" {
			n++
		}
		for _, r := range c.Replies {
			if r.Source == "app" {
				n++
			}
		}
	}
	return n
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	trackID := chi.URLParam(r, "id")
	userID := middleware.GetUserID(r.Context())

	var body struct {
		Text     string  `json:"text"`
		ParentID *string `json:"parent_id,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Text == "" {
		http.Error(w, `{"error":"text is required"}`, http.StatusBadRequest)
		return
	}

	userName := r.Header.Get("X-User-Name")
	if userName == "" {
		userName = "User"
	}
	avatarURL := r.Header.Get("X-User-Avatar")

	comment, err := h.svc.Create(r.Context(), prov, trackID, userID, userName, avatarURL, body.Text, body.ParentID)
	if err != nil {
		log.Printf("[comments] create err: %v", err)
		http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
		return
	}
	log.Printf("[comments] create prov=%s id=%s user=%s", prov, trackID, userID)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(comment)
}

func (h *Handler) Vote(w http.ResponseWriter, r *http.Request) {
	commentID := chi.URLParam(r, "id")
	userID := middleware.GetUserID(r.Context())

	var body struct {
		Type string `json:"type"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
		return
	}
	if body.Type != "like" && body.Type != "dislike" {
		http.Error(w, `{"error":"type must be like or dislike"}`, http.StatusBadRequest)
		return
	}

	if err := h.svc.Vote(r.Context(), userID, commentID, body.Type); err != nil {
		http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}
