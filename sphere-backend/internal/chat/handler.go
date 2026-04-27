package chat

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/gorilla/websocket"

	"sphere-backend/internal/middleware"
)

type Handler struct {
	svc       *Service
	hub       *Hub
	jwtSecret string
}

func NewHandler(svc *Service, hub *Hub, jwtSecret string) *Handler {
	return &Handler{svc: svc, hub: hub, jwtSecret: jwtSecret}
}

func (h *Handler) ListChats(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	threads, err := h.svc.ListThreads(r.Context(), userID)
	if err != nil {
		http.Error(w, `{"error":"failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(threads)
}

type openDMRequest struct {
	UserID string `json:"user_id"`
}

func (h *Handler) OpenOrCreateDM(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req openDMRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}
	chatID, err := h.svc.OpenOrCreateDM(r.Context(), userID, req.UserID)
	if err != nil {
		http.Error(w, `{"error":"not allowed"}`, http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"chat_id": chatID})
}

func (h *Handler) ListMessages(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	chatID := chi.URLParam(r, "id")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))

	var before time.Time
	if raw := r.URL.Query().Get("before"); raw != "" {
		if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
			before = t
		} else if t, err := time.Parse(time.RFC3339, raw); err == nil {
			before = t
		}
	}

	msgs, err := h.svc.ListMessages(r.Context(), userID, chatID, before, limit)
	if err != nil {
		http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(msgs)
}

func (h *Handler) SendMessage(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	chatID := chi.URLParam(r, "id")

	var req SendMessageRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	msg, participants, err := h.svc.SendMessage(r.Context(), userID, chatID, req)
	if err != nil {
		http.Error(w, `{"error":"failed"}`, http.StatusBadRequest)
		return
	}

	h.hub.Broadcast(participants, WSMessageEvent{Type: "chat.message", Message: *msg})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(msg)
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func (h *Handler) WS(w http.ResponseWriter, r *http.Request) {
	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	userID, ok := h.parseJWTSubject(r.Context(), tokenStr)
	if !ok {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	c := NewWSConn(conn)
	h.hub.Register(userID, c)
	defer h.hub.Unregister(userID, c)

	// Read loop: keep connection alive; ignore payloads (client is write-only via REST).
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			return
		}
	}
}

func (h *Handler) parseJWTSubject(ctx context.Context, tokenStr string) (string, bool) {
	tok, err := jwt.Parse(tokenStr, func(t *jwt.Token) (any, error) {
		return []byte(h.jwtSecret), nil
	}, jwt.WithValidMethods([]string{"HS256"}))
	if err != nil || !tok.Valid {
		return "", false
	}
	claims, ok := tok.Claims.(jwt.MapClaims)
	if !ok {
		return "", false
	}
	sub, _ := claims["sub"].(string)
	if sub == "" {
		return "", false
	}
	return sub, true
}

