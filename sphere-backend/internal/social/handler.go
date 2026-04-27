package social

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"sphere-backend/internal/favorites"
	"sphere-backend/internal/history"
	"sphere-backend/internal/middleware"
)

type Handler struct {
	svc        *Service
	favorites  *favorites.Service
	history    *history.Service
}

func NewHandler(svc *Service, favSvc *favorites.Service, historySvc *history.Service) *Handler {
	return &Handler{svc: svc, favorites: favSvc, history: historySvc}
}

func (h *Handler) SearchUsers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))

	res, err := h.svc.SearchUsers(r.Context(), q, limit)
	if err != nil {
		http.Error(w, `{"error":"search failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

func (h *Handler) GetProfile(w http.ResponseWriter, r *http.Request) {
	viewerID := middleware.GetUserID(r.Context())
	targetID := chi.URLParam(r, "id")

	res, err := h.svc.GetProfile(r.Context(), viewerID, targetID)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

func (h *Handler) GetUserFavorites(w http.ResponseWriter, r *http.Request) {
	viewerID := middleware.GetUserID(r.Context())
	targetID := chi.URLParam(r, "id")

	prof, err := h.svc.GetProfile(r.Context(), viewerID, targetID)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	if prof.RequiresApproval {
		http.Error(w, `{"error":"private profile"}`, http.StatusForbidden)
		return
	}

	itemType := r.URL.Query().Get("type")
	favs, err := h.favorites.List(r.Context(), targetID, itemType)
	if err != nil {
		http.Error(w, `{"error":"failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(favs)
}

func (h *Handler) GetUserHistory(w http.ResponseWriter, r *http.Request) {
	viewerID := middleware.GetUserID(r.Context())
	targetID := chi.URLParam(r, "id")

	prof, err := h.svc.GetProfile(r.Context(), viewerID, targetID)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	if prof.RequiresApproval {
		http.Error(w, `{"error":"private profile"}`, http.StatusForbidden)
		return
	}

	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	items, err := h.history.List(r.Context(), targetID, limit)
	if err != nil {
		http.Error(w, `{"error":"failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(items)
}

func (h *Handler) ListSubscriptions(w http.ResponseWriter, r *http.Request) {
	viewerID := middleware.GetUserID(r.Context())
	targetID := chi.URLParam(r, "id")

	res, err := h.svc.ListSubscriptions(r.Context(), viewerID, targetID)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

func (h *Handler) ListSubscribers(w http.ResponseWriter, r *http.Request) {
	viewerID := middleware.GetUserID(r.Context())
	targetID := chi.URLParam(r, "id")

	res, err := h.svc.ListSubscribers(r.Context(), viewerID, targetID)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

func (h *Handler) Subscribe(w http.ResponseWriter, r *http.Request) {
	viewerID := middleware.GetUserID(r.Context())
	targetID := chi.URLParam(r, "id")

	status, err := h.svc.Subscribe(r.Context(), viewerID, targetID)
	if err != nil {
		http.Error(w, `{"error":"subscribe failed"}`, http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"status": status})
}

func (h *Handler) Unsubscribe(w http.ResponseWriter, r *http.Request) {
	viewerID := middleware.GetUserID(r.Context())
	targetID := chi.URLParam(r, "id")

	_ = h.svc.Unsubscribe(r.Context(), viewerID, targetID)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"status": "ok"})
}

func (h *Handler) ListIncomingRequests(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	items, err := h.svc.ListIncomingRequests(r.Context(), userID)
	if err != nil {
		http.Error(w, `{"error":"failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(items)
}

func (h *Handler) ApproveRequest(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	reqID := chi.URLParam(r, "requestID")
	if err := h.svc.ApproveRequest(r.Context(), userID, reqID); err != nil {
		http.Error(w, `{"error":"failed"}`, http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"status": "ok"})
}

func (h *Handler) DenyRequest(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	reqID := chi.URLParam(r, "requestID")
	if err := h.svc.DenyRequest(r.Context(), userID, reqID); err != nil {
		http.Error(w, `{"error":"failed"}`, http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"status": "ok"})
}

