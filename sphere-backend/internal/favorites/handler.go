package favorites

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"sphere-backend/internal/middleware"
	"sphere-backend/internal/model"
	"sphere-backend/internal/music"
)

type Handler struct {
	svc   *Service
	music *music.Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

func NewHandlerWithMusic(svc *Service, musicSvc *music.Service) *Handler {
	return &Handler{svc: svc, music: musicSvc}
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	itemType := r.URL.Query().Get("item_type")
	if itemType == "" {
		// Backward compatibility with older clients.
		itemType = r.URL.Query().Get("type")
	}

	favs, err := h.svc.List(r.Context(), userID, itemType)
	if err != nil {
		http.Error(w, `{"error":"failed to list favorites"}`, http.StatusInternalServerError)
		return
	}
	if favs == nil {
		favs = []Favorite{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(favs)
}

type addRequest struct {
	ItemType       string `json:"item_type"`
	Provider       string `json:"provider"`
	ProviderItemID string `json:"provider_item_id"`
	Title          string `json:"title"`
	ArtistName     string `json:"artist_name"`
	CoverURL       string `json:"cover_url"`
}

func (h *Handler) Add(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req addRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	fav, err := h.svc.Add(r.Context(), userID, &Favorite{
		ItemType: req.ItemType, Provider: req.Provider,
		ProviderItemID: req.ProviderItemID, Title: req.Title,
		ArtistName: req.ArtistName, CoverURL: req.CoverURL,
	})
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusConflict)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(fav)
}

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	id := chi.URLParam(r, "id")

	if err := h.svc.Delete(r.Context(), userID, id); err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// LikedPlaylist returns a virtual playlist that lists the user's liked (favorite) tracks.
func (h *Handler) LikedPlaylist(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	if h.music == nil {
		http.Error(w, `{"error":"music service not configured"}`, http.StatusInternalServerError)
		return
	}

	lang := strings.ToLower(r.Header.Get("Accept-Language"))
	title := "Liked"
	if strings.Contains(lang, "ru") {
		title = "Мне нравится"
	}

	favs, err := h.svc.List(r.Context(), userID, "track")
	if err != nil {
		http.Error(w, `{"error":"failed to list favorites"}`, http.StatusInternalServerError)
		return
	}

	tracks := make([]model.Track, 0, len(favs))
	for _, f := range favs {
		if strings.TrimSpace(f.Provider) == "" || strings.TrimSpace(f.ProviderItemID) == "" {
			continue
		}
		tr, err := h.music.GetTrack(r.Context(), f.Provider, f.ProviderItemID)
		if err != nil || tr == nil {
			continue
		}
		tracks = append(tracks, *tr)
		if len(tracks) >= 800 {
			break
		}
	}

	cover := ""
	if len(tracks) > 0 {
		cover = tracks[0].CoverURL
	}
	pl := model.Playlist{
		ID:       "liked",
		Provider: "sphere",
		Title:    title,
		CoverURL: cover,
		Tracks:   tracks,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(pl)
}
