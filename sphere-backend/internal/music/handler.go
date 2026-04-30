package music

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"sphere-backend/internal/middleware"
	"sphere-backend/internal/model"
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
// For Deezer-with-ARL, it proxies AND decrypts BF_CBC_STRIPE on the fly.
//
// Optional `?quality=` query parameter:
//   - "flac"  → Deezer FLAC (16-bit/44.1kHz, true lossless; needs HiFi ARL)
//   - "high"  → Deezer MP3_320 (320 kbps; needs Premium ARL)
//   - "low" / unset → Deezer MP3_128 (works on free accounts)
//
// For non-Deezer providers the parameter is currently a no-op.
func (h *Handler) ProxyStream(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")
	quality := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("quality")))

	// Spotify special-case: full-track audio requires Connect credentials and
	// returns OGG that must be proxied (expiring CDN URLs + AES-CTR decrypt).
	if prov == "spotify" {
		if sp := h.svc.SpotifyProvider(); sp != nil && sp.HasFullTrackSession() {
			if h.proxySpotify(w, r, sp, id, quality) {
				return
			}
		}
	}

	// Deezer special-case: full-track audio comes back encrypted with
	// BF_CBC_STRIPE, so we MUST proxy + decrypt server-side. Falls through to
	// the normal stream resolver below if the ARL is not configured.
	if prov == "deezer" {
		if dz := h.svc.DeezerProvider(); dz != nil && dz.HasFullTrackSession() {
			if h.proxyDeezer(w, r, dz, id, quality) {
				return
			}
		}
	}

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

// proxySpotify streams a full-length Spotify track as decrypted OGG bytes.\n+// Returns true when the response was handled (success or definitive error).\n+func (h *Handler) proxySpotify(w http.ResponseWriter, r *http.Request, sp *provider.Spotify, trackID, quality string) bool {\n+\t// ladder in kbps\n+\tvar ladder []int\n+\tswitch quality {\n+\tcase \"high\", \"320\", \"ogg_320\":\n+\t\tladder = []int{320, 160, 96}\n+\tcase \"low\", \"96\", \"ogg_96\":\n+\t\tladder = []int{96}\n+\tdefault:\n+\t\tladder = []int{160, 320, 96}\n+\t}\n+\n+\tsess := sp.FullTrackSession()\n+\tif sess == nil {\n+\t\treturn false\n+\t}\n+\n+\tvar (\n+\t\treader io.ReadCloser\n+\t\tsize   int64\n+\t\tfmtStr string\n+\t\tlastErr error\n+\t)\n+\tfor _, br := range ladder {\n+\t\trc, sz, format, err := sess.ResolveDecryptedStream(r.Context(), trackID, br)\n+\t\tif err == nil && rc != nil {\n+\t\t\treader = rc\n+\t\t\tsize = sz\n+\t\t\tswitch format {\n+\t\t\tcase 0:\n+\t\t\t\tfmtStr = \"unknown\"\n+\t\t\tdefault:\n+\t\t\t\tfmtStr = format.String()\n+\t\t\t}\n+\t\t\tbreak\n+\t\t}\n+\t\tlastErr = err\n+\t}\n+\tif reader == nil {\n+\t\tlog.Printf(\"[spotify-stream] resolve %s ladder=%v failed: %v — falling back\", trackID, ladder, lastErr)\n+\t\treturn false\n+\t}\n+\tdefer reader.Close()\n+\n+\tw.Header().Set(\"Content-Type\", \"audio/ogg\")\n+\tw.Header().Set(\"Cache-Control\", \"private, max-age=3600\")\n+\tw.Header().Set(\"X-Sphere-Audio-Quality\", fmtStr)\n+\tif size > 0 {\n+\t\tw.Header().Set(\"Content-Length\", strconv.FormatInt(size, 10))\n+\t}\n+\tw.WriteHeader(http.StatusOK)\n+\tlog.Printf(\"[spotify-stream] %s ok format=%s size=%d requested=%q\", trackID, fmtStr, size, quality)\n+\n+\t_, _ = io.Copy(w, reader)\n+\treturn true\n+}\n+\n*** End Patch"}"}}
// proxySpotify streams a full-length Spotify track as decrypted OGG bytes.
// Returns true when the response was handled (success or definitive error).
func (h *Handler) proxySpotify(w http.ResponseWriter, r *http.Request, sp *provider.Spotify, trackID, quality string) bool {
	var ladder []int
	switch quality {
	case "high", "320", "ogg_320":
		ladder = []int{320, 160, 96}
	case "low", "96", "ogg_96":
		ladder = []int{96}
	default:
		ladder = []int{160, 320, 96}
	}

	sess := sp.FullTrackSession()
	if sess == nil {
		return false
	}

	var (
		reader  io.ReadCloser
		size    int64
		fmtStr  string
		lastErr error
	)
	for _, br := range ladder {
		rc, sz, format, err := sess.ResolveDecryptedStream(r.Context(), trackID, br)
		if err == nil && rc != nil {
			reader = rc
			size = sz
			fmtStr = format.String()
			break
		}
		lastErr = err
	}
	if reader == nil {
		log.Printf("[spotify-stream] resolve %s ladder=%v failed: %v — falling back", trackID, ladder, lastErr)
		return false
	}
	defer reader.Close()

	w.Header().Set("Content-Type", "audio/ogg")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("X-Sphere-Audio-Quality", fmtStr)
	if size > 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	}
	w.WriteHeader(http.StatusOK)
	log.Printf("[spotify-stream] %s ok format=%s size=%d requested=%q", trackID, fmtStr, size, quality)

	_, _ = io.Copy(w, reader)
	return true
}

// proxyDeezer streams a full-length Deezer track, decrypting BF_CBC_STRIPE
// chunks as they arrive. Returns true when the response was handled (success
// or a definitive error written to w); false to let the caller fall back to
// the normal stream resolver path.
//
// `quality` controls the codec ladder we walk: "flac" → FLAC then 320/128
// fallbacks; "high" → 320 then 128; default → 128 only. We always degrade
// gracefully when an account lacks the Premium scope for the higher tier.
func (h *Handler) proxyDeezer(w http.ResponseWriter, r *http.Request, dz *provider.Deezer, sngID, quality string) bool {
	var ladder []string
	switch quality {
	case "flac", "lossless":
		ladder = []string{"FLAC", "MP3_320", "MP3_128"}
	case "high", "320", "mp3_320":
		ladder = []string{"MP3_320", "MP3_128"}
	default:
		ladder = []string{"MP3_128"}
	}

	var (
		encURL    string
		chosen    string
		lastErr   error
		sess      = dz.FullTrackSession()
	)
	for _, q := range ladder {
		u, _, err := sess.ResolveStreamURL(r.Context(), sngID, q)
		if err == nil && u != "" {
			encURL = u
			chosen = q
			break
		}
		lastErr = err
	}
	if encURL == "" {
		log.Printf("[deezer-stream] resolve %s ladder=%v failed: %v — falling back", sngID, ladder, lastErr)
		return false
	}
	upstreamReq, err := http.NewRequestWithContext(r.Context(), "GET", encURL, nil)
	if err != nil {
		http.Error(w, `{"error":"deezer request"}`, http.StatusInternalServerError)
		return true
	}
	if rng := r.Header.Get("Range"); rng != "" {
		// Deezer's encrypted CDN supports Range, but partial bytes mid-chunk
		// would break the stripe decryptor. We deliberately ignore client
		// Range and stream the whole file — AVPlayer handles this fine and
		// the file is typically a few MB. Future improvement: align Range to
		// 2048-byte boundaries, decrypt accordingly.
		_ = rng
	}
	upstreamReq.Header.Set("User-Agent", provider.DeezerUA)

	httpClient := &http.Client{Timeout: 0} // streaming; no overall deadline
	resp, err := httpClient.Do(upstreamReq)
	if err != nil {
		log.Printf("[deezer-stream] upstream %s: %v", sngID, err)
		http.Error(w, `{"error":"deezer upstream"}`, http.StatusBadGateway)
		return true
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		log.Printf("[deezer-stream] upstream %s: HTTP %d", sngID, resp.StatusCode)
		http.Error(w, `{"error":"deezer upstream status"}`, http.StatusBadGateway)
		return true
	}

	key := provider.DeezerBlowfishKey(sngID)
	plain, err := provider.NewDeezerStripeReader(resp.Body, key)
	if err != nil {
		log.Printf("[deezer-stream] cipher init %s: %v", sngID, err)
		http.Error(w, `{"error":"deezer cipher"}`, http.StatusInternalServerError)
		return true
	}

	contentType := "audio/mpeg"
	if chosen == "FLAC" {
		contentType = "audio/flac"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("X-Sphere-Audio-Quality", chosen) // surfaces actual quality to the client
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		// Stripe-decrypted stream has the same byte length as the encrypted one.
		w.Header().Set("Content-Length", cl)
	}
	w.WriteHeader(http.StatusOK)
	log.Printf("[deezer-stream] %s ok format=%s size=%s requested=%q", sngID, chosen, resp.Header.Get("Content-Length"), quality)

	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 32*1024)
	for {
		n, readErr := plain.Read(buf)
		if n > 0 {
			if _, wErr := w.Write(buf[:n]); wErr != nil {
				return true
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if readErr != nil {
			break
		}
	}
	return true
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

func (h *Handler) GetArtistAlbums(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	lang := strings.ToLower(r.Header.Get("Accept-Language"))
	market := "US"
	if strings.Contains(lang, "ru") {
		market = "RU"
	}
	albums, err := h.svc.GetArtistAlbums(r.Context(), prov, id, market, 50)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusNotFound)
		return
	}
	if albums == nil {
		albums = []model.Album{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"albums": albums})
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

type downloadManifestItem struct {
	Provider    string `json:"provider"`
	ID          string `json:"id"`
	Title       string `json:"title"`
	Artist      string `json:"artist"`
	CoverURL    string `json:"cover_url,omitempty"`
	DownloadURL string `json:"download_url"`
}

func (h *Handler) PlaylistDownloadManifest(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	pl, err := h.svc.GetPlaylist(r.Context(), prov, id)
	if err != nil || pl == nil {
		http.Error(w, `{"error":"`+fmt.Sprintf("playlist not found: %v", err)+`"}`, http.StatusNotFound)
		return
	}

	items := make([]downloadManifestItem, 0, len(pl.Tracks))
	for _, t := range pl.Tracks {
		if t.Provider == "" || t.ID == "" {
			continue
		}
		items = append(items, downloadManifestItem{
			Provider:    t.Provider,
			ID:          t.ID,
			Title:       t.Title,
			Artist:      t.Artist,
			CoverURL:    t.CoverURL,
			DownloadURL: "/tracks/" + t.Provider + "/" + t.ID + "/download",
		})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"tracks": items})
}

func (h *Handler) AlbumDownloadManifest(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")

	al, err := h.svc.GetAlbum(r.Context(), prov, id)
	if err != nil || al == nil {
		http.Error(w, `{"error":"`+fmt.Sprintf("album not found: %v", err)+`"}`, http.StatusNotFound)
		return
	}

	items := make([]downloadManifestItem, 0, len(al.Tracks))
	for _, t := range al.Tracks {
		if t.Provider == "" || t.ID == "" {
			continue
		}
		cover := t.CoverURL
		if cover == "" {
			cover = al.CoverURL
		}
		items = append(items, downloadManifestItem{
			Provider:    t.Provider,
			ID:          t.ID,
			Title:       t.Title,
			Artist:      t.Artist,
			CoverURL:    cover,
			DownloadURL: "/tracks/" + t.Provider + "/" + t.ID + "/download",
		})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"tracks": items})
}

func sanitizeFilenamePart(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	s = strings.ReplaceAll(s, "/", "-")
	s = strings.ReplaceAll(s, "\\", "-")
	s = strings.ReplaceAll(s, "\"", "'")
	return s
}

func (h *Handler) DownloadTrack(w http.ResponseWriter, r *http.Request) {
	prov := chi.URLParam(r, "provider")
	id := chi.URLParam(r, "id")
	quality := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("quality")))

	meta, _ := h.svc.GetTrack(r.Context(), prov, id)
	base := "track"
	if meta != nil {
		a := sanitizeFilenamePart(meta.Artist)
		t := sanitizeFilenamePart(meta.Title)
		if a != "" && t != "" {
			base = a + " - " + t
		} else if t != "" {
			base = t
		}
	}

	// Deezer + ARL: stream the decrypted bytes directly. The CDN already serves
	// the format (MP3 or FLAC) we need, so re-encoding through ffmpeg would only
	// add latency and (for FLAC→MP3) destroy the whole point of lossless.
	if prov == "deezer" {
		if dz := h.svc.DeezerProvider(); dz != nil && dz.HasFullTrackSession() {
			if h.downloadDeezer(w, r, dz, id, quality, base) {
				return
			}
		}
	}

	streamURL, err := h.svc.GetTrackStreamURL(r.Context(), prov, id)
	if err != nil || strings.TrimSpace(streamURL) == "" {
		if prov == "spotify" {
			http.Error(w, `{"error":"download_not_available"}`, http.StatusConflict)
			return
		}
		http.Error(w, `{"error":"stream not available"}`, http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "audio/mpeg")
	w.Header().Set("Content-Disposition", `attachment; filename="`+base+`.mp3"`)
	w.Header().Set("Cache-Control", "private, max-age=3600")

	cmd := exec.CommandContext(
		r.Context(),
		"ffmpeg",
		"-hide_banner",
		"-loglevel", "error",
		"-i", streamURL,
		"-vn",
		"-c:a", "libmp3lame",
		"-b:a", "192k",
		"-f", "mp3",
		"pipe:1",
	)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		http.Error(w, `{"error":"ffmpeg failed"}`, http.StatusInternalServerError)
		return
	}
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		http.Error(w, `{"error":"ffmpeg failed"}`, http.StatusInternalServerError)
		return
	}

	_, copyErr := io.Copy(w, stdout)
	_ = stdout.Close()
	_ = cmd.Wait()
	if copyErr != nil {
		if stderr != nil {
			b, _ := io.ReadAll(stderr)
			if len(b) > 0 {
				log.Printf("[download] ffmpeg copy error: %v stderr=%s", copyErr, string(b))
			}
		}
	}
}

// downloadDeezer streams a decrypted Deezer track (MP3 or FLAC) as an
// attachment. Returns true when the response was handled.
func (h *Handler) downloadDeezer(w http.ResponseWriter, r *http.Request, dz *provider.Deezer, sngID, quality, basename string) bool {
	var ladder []string
	switch quality {
	case "flac", "lossless":
		ladder = []string{"FLAC", "MP3_320", "MP3_128"}
	case "high", "320", "mp3_320":
		ladder = []string{"MP3_320", "MP3_128"}
	default:
		ladder = []string{"MP3_320", "MP3_128"}
	}

	var (
		encURL  string
		chosen  string
		lastErr error
		sess    = dz.FullTrackSession()
	)
	for _, q := range ladder {
		u, _, err := sess.ResolveStreamURL(r.Context(), sngID, q)
		if err == nil && u != "" {
			encURL = u
			chosen = q
			break
		}
		lastErr = err
	}
	if encURL == "" {
		log.Printf("[deezer-download] resolve %s ladder=%v failed: %v", sngID, ladder, lastErr)
		return false
	}

	upstreamReq, err := http.NewRequestWithContext(r.Context(), "GET", encURL, nil)
	if err != nil {
		http.Error(w, `{"error":"deezer request"}`, http.StatusInternalServerError)
		return true
	}
	upstreamReq.Header.Set("User-Agent", provider.DeezerUA)

	httpClient := &http.Client{Timeout: 0}
	resp, err := httpClient.Do(upstreamReq)
	if err != nil {
		log.Printf("[deezer-download] upstream %s: %v", sngID, err)
		http.Error(w, `{"error":"deezer upstream"}`, http.StatusBadGateway)
		return true
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		log.Printf("[deezer-download] upstream %s: HTTP %d", sngID, resp.StatusCode)
		http.Error(w, `{"error":"deezer upstream status"}`, http.StatusBadGateway)
		return true
	}

	key := provider.DeezerBlowfishKey(sngID)
	plain, err := provider.NewDeezerStripeReader(resp.Body, key)
	if err != nil {
		http.Error(w, `{"error":"deezer cipher"}`, http.StatusInternalServerError)
		return true
	}

	ext := "mp3"
	contentType := "audio/mpeg"
	if chosen == "FLAC" {
		ext = "flac"
		contentType = "audio/flac"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+basename+"."+ext+`"`)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		w.Header().Set("Content-Length", cl)
	}
	w.WriteHeader(http.StatusOK)
	log.Printf("[deezer-download] %s ok format=%s requested=%q", sngID, chosen, quality)

	_, copyErr := io.Copy(w, plain)
	if copyErr != nil {
		log.Printf("[deezer-download] copy error %s: %v", sngID, copyErr)
	}
	return true
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
