package favorites

import (
	"encoding/json"
	"net/http"

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
	userID := middleware.GetUserID(r.Context())
	itemType := r.URL.Query().Get("type")

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
