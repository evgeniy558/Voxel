package uploads

import (
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"

	"github.com/go-chi/chi/v5"

	"sphere-backend/internal/middleware"
)

type Handler struct {
	svc *Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) Upload(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	r.Body = http.MaxBytesReader(w, r.Body, 50<<20) // 50MB max
	if err := r.ParseMultipartForm(50 << 20); err != nil {
		http.Error(w, `{"error":"file too large"}`, http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, `{"error":"file required"}`, http.StatusBadRequest)
		return
	}
	defer file.Close()

	title := r.FormValue("title")
	if title == "" {
		title = header.Filename
	}
	artistName := r.FormValue("artist_name")

	upload, err := h.svc.Upload(r.Context(), userID, title, artistName, header.Filename, header.Size, file)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(upload)
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	uploads, err := h.svc.List(r.Context(), userID)
	if err != nil {
		http.Error(w, `{"error":"failed to list uploads"}`, http.StatusInternalServerError)
		return
	}
	if uploads == nil {
		uploads = []Upload{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(uploads)
}

func (h *Handler) Stream(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	id := chi.URLParam(r, "id")

	reader, fileURL, err := h.svc.Stream(r.Context(), userID, id)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	defer reader.Close()

	ext := filepath.Ext(fileURL)
	contentType := "audio/mpeg"
	switch ext {
	case ".m4a":
		contentType = "audio/mp4"
	case ".wav":
		contentType = "audio/wav"
	case ".flac":
		contentType = "audio/flac"
	}

	w.Header().Set("Content-Type", contentType)
	io.Copy(w, reader)
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
