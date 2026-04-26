package music

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"sphere-backend/internal/middleware"
	"sphere-backend/internal/provider"
)

type Handler struct {
	svc         *Service
	pool        *pgxpool.Pool
	geniusToken string
}

func NewHandler(svc *Service, geniusToken string) *Handler {
	return &Handler{svc: svc, geniusToken: geniusToken}
}

func NewHandlerWithDB(svc *Service, pool *pgxpool.Pool, geniusToken string) *Handler {
	return &Handler{svc: svc, pool: pool, geniusToken: geniusToken}
}

func (h *Handler) Search(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		http.Error(w, `{"error":"q parameter required"}`, http.StatusBadRequest)
		return
	}
	prov := r.URL.Query().Get("provider")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 {
		limit = 20
	}

	result := h.svc.Search(r.Context(), query, limit, prov)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (h *Handler) GetTrack(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	track, err := h.svc.GetTrack(r.Context(), prov, id)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusNotFound)
		return
	}

	// Always include stream URL when fetching single track
	streamURL, _ := h.svc.GetTrackStreamURL(r.Context(), prov, id)
	track.StreamURL = streamURL

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(track)
}

// GetTrackStream returns only the stream URL — lightweight endpoint for the player.
func (h *Handler) GetTrackStream(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	streamURL, err := h.svc.GetTrackStreamURL(r.Context(), prov, id)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"stream_url": streamURL})
}

// ProxyStream resolves the stream URL and redirects the client to the CDN.
// For providers with IP-locked URLs (YouTube), it proxies the audio data.
func (h *Handler) ProxyStream(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	streamURL, err := h.svc.GetTrackStreamURL(r.Context(), prov, id)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusNotFound)
		return
	}

	log.Printf("[proxy-stream] %s/%s → %s", prov, id, streamURL[:min(len(streamURL), 120)])

	if prov == "youtube" {
		h.proxyUpstream(w, r, streamURL)
		return
	}

	// SoundCloud (and others with a direct CDN URL): 302 so AVPlayer buffers from origin
	// instead of a byte-streaming proxy (fixes choppy playback on Simulator / some networks).
	http.Redirect(w, r, streamURL, http.StatusTemporaryRedirect)
}

func (h *Handler) proxyUpstream(w http.ResponseWriter, r *http.Request, streamURL string) {
	transport := &http.Transport{ResponseHeaderTimeout: 15 * time.Second}
	client := &http.Client{Transport: transport}
	req, err := http.NewRequestWithContext(r.Context(), "GET", streamURL, nil)
	if err != nil {
		http.Error(w, `{"error":"failed to create request"}`, http.StatusInternalServerError)
		return
	}

	if rng := r.Header.Get("Range"); rng != "" {
		req.Header.Set("Range", rng)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("[proxy-stream] upstream error: %v", err)
		http.Error(w, `{"error":"upstream fetch failed"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	ct := resp.Header.Get("Content-Type")
	if ct == "" {
		ct = "audio/mpeg"
	}
	w.Header().Set("Content-Type", ct)
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		w.Header().Set("Content-Length", cl)
	}
	if cr := resp.Header.Get("Content-Range"); cr != "" {
		w.Header().Set("Content-Range", cr)
	}
	w.Header().Set("Accept-Ranges", "bytes")
	w.WriteHeader(resp.StatusCode)
	if f, ok := w.(http.Flusher); ok {
		buf := make([]byte, 32*1024)
		for {
			n, readErr := resp.Body.Read(buf)
			if n > 0 {
				w.Write(buf[:n])
				f.Flush()
			}
			if readErr != nil {
				break
			}
		}
	} else {
		io.Copy(w, resp.Body)
	}
}

func (h *Handler) GetLyrics(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	if h.pool != nil {
		var text, userName string
		err := h.pool.QueryRow(r.Context(),
			`SELECT text, user_name FROM user_lyrics WHERE track_provider = $1 AND track_id = $2`,
			prov, id,
		).Scan(&text, &userName)
		if err == nil && text != "" {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{
				"track_id":     id,
				"provider":     prov,
				"text":         text,
				"submitted_by": userName,
			})
			return
		}
	}

	lyrics, err := h.svc.GetLyrics(r.Context(), prov, id)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(lyrics)
}

func (h *Handler) GetArtist(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	artist, err := h.svc.GetArtist(r.Context(), prov, id)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(artist)
}

// GetUnifiedArtist merges artist profiles from all providers by name.
func (h *Handler) GetUnifiedArtist(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if name == "" {
		name = r.URL.Query().Get("name")
	}
	if name == "" {
		http.Error(w, `{"error":"artist name required"}`, http.StatusBadRequest)
		return
	}

	artist := h.svc.GetUnifiedArtist(r.Context(), name)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(artist)
}

func (h *Handler) GetAlbum(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	album, err := h.svc.GetAlbum(r.Context(), prov, id)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(album)
}

// GetLyricsByName looks up lyrics via LRCLIB then Genius using only title + artist.
// Used for local device tracks that have no provider/id.
func (h *Handler) GetLyricsByName(w http.ResponseWriter, r *http.Request) {
	title := r.URL.Query().Get("title")
	artist := r.URL.Query().Get("artist")
	if title == "" {
		http.Error(w, `{"error":"title required"}`, http.StatusBadRequest)
		return
	}
	ctx := r.Context()
	text, err := provider.FetchLRCLIB(ctx, artist, title)
	if err != nil || text == "" {
		text, _ = provider.FetchGenius(ctx, artist+" "+title, h.geniusToken)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"title":  title,
		"artist": artist,
		"text":   text,
	})
}

func (h *Handler) GetPlaylist(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	playlist, err := h.svc.GetPlaylist(r.Context(), prov, id)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(playlist)
}

func (h *Handler) ProxyStreamHQ(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	format := r.URL.Query().Get("format")
	if format == "" {
		format = "flac"
	}

	streamURL, err := h.svc.GetTrackStreamURL(r.Context(), prov, id)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusNotFound)
		return
	}

	log.Printf("[hq-stream] %s/%s → transcode to %s", prov, id, format)

	ffmpegPath, err := exec.LookPath("ffmpeg")
	if err != nil {
		http.Redirect(w, r, streamURL, http.StatusTemporaryRedirect)
		return
	}

	var contentType string
	var codecArgs []string
	switch format {
	case "flac":
		contentType = "audio/flac"
		codecArgs = []string{"-c:a", "flac", "-sample_fmt", "s16", "-ar", "44100"}
	case "wav":
		contentType = "audio/wav"
		codecArgs = []string{"-c:a", "pcm_s16le", "-ar", "44100"}
	case "alac":
		contentType = "audio/mp4"
		codecArgs = []string{"-c:a", "alac", "-ar", "44100"}
	default:
		contentType = "audio/flac"
		codecArgs = []string{"-c:a", "flac", "-sample_fmt", "s16", "-ar", "44100"}
		format = "flac"
	}

	args := []string{
		"-y",
		"-i", streamURL,
		"-vn",
	}
	args = append(args, codecArgs...)
	args = append(args, "-f", format, "pipe:1")

	cmd := exec.CommandContext(r.Context(), ffmpegPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		http.Error(w, `{"error":"transcode setup failed"}`, http.StatusInternalServerError)
		return
	}

	if err := cmd.Start(); err != nil {
		log.Printf("[hq-stream] ffmpeg start error: %v", err)
		http.Redirect(w, r, streamURL, http.StatusTemporaryRedirect)
		return
	}

	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", fmt.Sprintf("inline; filename=\"track.%s\"", format))
	w.Header().Set("Transfer-Encoding", "chunked")

	if f, ok := w.(http.Flusher); ok {
		buf := make([]byte, 32*1024)
		for {
			n, readErr := stdout.Read(buf)
			if n > 0 {
				w.Write(buf[:n])
				f.Flush()
			}
			if readErr != nil {
				break
			}
		}
	} else {
		io.Copy(w, stdout)
	}

	cmd.Wait()
}

func (h *Handler) SubmitLyrics(w http.ResponseWriter, r *http.Request) {
	if h.pool == nil {
		http.Error(w, `{"error":"not configured"}`, http.StatusInternalServerError)
		return
	}
	userID := middleware.GetUserID(r.Context())

	var body struct {
		Provider string `json:"provider"`
		TrackID  string `json:"track_id"`
		Text     string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Text == "" || body.TrackID == "" {
		http.Error(w, `{"error":"provider, track_id, and text required"}`, http.StatusBadRequest)
		return
	}

	userName := r.Header.Get("X-User-Name")
	if userName == "" {
		userName = "User"
	}

	_, err := h.pool.Exec(r.Context(),
		`INSERT INTO user_lyrics (track_provider, track_id, user_id, user_name, text)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (track_provider, track_id) DO UPDATE SET text = EXCLUDED.text, user_id = EXCLUDED.user_id, user_name = EXCLUDED.user_name`,
		body.Provider, body.TrackID, userID, userName, body.Text,
	)
	if err != nil {
		log.Printf("[submit-lyrics] error: %v", err)
		http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	w.Write([]byte(`{"ok":true}`))
}
