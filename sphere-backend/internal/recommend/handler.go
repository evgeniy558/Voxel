package recommend

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"sphere-backend/internal/middleware"
	"sphere-backend/internal/model"
)

type Handler struct {
	svc *Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	lang := r.Header.Get("Accept-Language")
	resp := h.svc.GetRecommendations(r.Context(), userID, lang)
	if resp.Tracks == nil {
		resp.Tracks = []model.Track{}
	}
	if resp.Albums == nil {
		resp.Albums = []model.Album{}
	}
	if resp.Artists == nil {
		resp.Artists = []model.Artist{}
	}

	emptyTracks := 0
	for _, t := range resp.Tracks {
		if strings.TrimSpace(t.CoverURL) == "" {
			emptyTracks++
		}
	}
	emptyAlbums := 0
	for _, a := range resp.Albums {
		if strings.TrimSpace(a.CoverURL) == "" {
			emptyAlbums++
		}
	}
	emptyArtists := 0
	for _, a := range resp.Artists {
		if strings.TrimSpace(a.ImageURL) == "" {
			emptyArtists++
		}
	}
	log.Printf("[recommend] user=%s tracks=%d (empty_cover=%d) albums=%d (empty_cover=%d) artists=%d (empty_image=%d)",
		userID, len(resp.Tracks), emptyTracks, len(resp.Albums), emptyAlbums, len(resp.Artists), emptyArtists)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// DailyMixes returns four pre-ordered track bundles.
func (h *Handler) DailyMixes(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	lang := r.Header.Get("Accept-Language")
	mixes, err := h.svc.GetDailyMixes(r.Context(), userID, lang)
	if err != nil {
		log.Printf("[daily-mixes] %v", err)
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusInternalServerError)
		return
	}
	if mixes == nil {
		mixes = []model.DailyMix{}
	}
	w.Header().Set("Content-Type", "application/json")
	out := struct {
		Mixes []model.DailyMix `json:"mixes"`
	}{Mixes: mixes}
	json.NewEncoder(w).Encode(out)
}
