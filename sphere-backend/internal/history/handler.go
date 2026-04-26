package history

import (
	"encoding/json"
	"net/http"

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
	entries, err := h.svc.List(r.Context(), userID, 50)
	if err != nil {
		http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(entries)
}

func (h *Handler) Record(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var entry Entry
	if err := json.NewDecoder(r.Body).Decode(&entry); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	if entry.Provider == "" || entry.TrackID == "" {
		http.Error(w, `{"error":"provider and track_id required"}`, http.StatusBadRequest)
		return
	}
	if err := h.svc.Record(r.Context(), userID, entry); err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
}
