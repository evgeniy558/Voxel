package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"os/exec"
	"strings"
	"sync"
	"time"

	ytclient "github.com/kkdai/youtube/v2"

	"sphere-backend/internal/model"
)

// User-Agent passed to yt-dlp; mimics a recent stable Chrome on macOS so
// YouTube is more likely to return non-throttled `googlevideo.com` URLs.
const ytdlpUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

// YouTube provider — full audio streaming without any API keys or cookies.
//   Search: yt-dlp --flat-playlist
//   Metadata: Deezer API (free)
//   Audio: kkdai/youtube Go library (direct stream URLs)
//   Lyrics: LRCLIB + Genius

type YouTube struct {
	ytdlpPath   string
	ytdlpCookies string
	ytClient    ytclient.Client
	cache       map[string]cacheEntry
	trackMeta   map[string]*model.Track
	mu          sync.RWMutex
	geniusToken string
}

// Limit concurrent yt-dlp runs to avoid OOM kills on small Render instances.
var ytdlpSem = make(chan struct{}, 2)

func NewYouTube(geniusToken string) *YouTube {
	path, _ := exec.LookPath("yt-dlp")
	if path == "" {
		path = "yt-dlp"
	}
	cookies := strings.TrimSpace(os.Getenv("YTDLP_COOKIES"))
	// Render can't mount a file easily; allow passing cookies.txt as base64 in env.
	if cookies == "" {
		if b64 := strings.TrimSpace(os.Getenv("YTDLP_COOKIES_B64")); b64 != "" {
			if decoded, err := decodeBase64Loose(b64); err == nil && len(decoded) > 0 {
				tmp := filepath.Join(os.TempDir(), "ytdlp-cookies.txt")
				// best-effort write; keep private permissions
				_ = os.WriteFile(tmp, decoded, 0o600)
				cookies = tmp
			} else if err != nil {
				log.Printf("[yt-dlp] cookies_b64 decode err=%v", err)
			}
		}
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp4", addr)
		},
	}
	return &YouTube{
		ytdlpPath:   path,
		ytdlpCookies: cookies,
		ytClient:    ytclient.Client{HTTPClient: &http.Client{Transport: transport, Timeout: 30 * time.Second}},
		cache:       make(map[string]cacheEntry),
		trackMeta:   make(map[string]*model.Track),
		geniusToken: geniusToken,
	}
}

func decodeBase64Loose(s string) ([]byte, error) {
	// accept both standard and URL-safe base64, with or without padding
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, "\n", "")
	s = strings.ReplaceAll(s, "\r", "")
	if s == "" {
		return nil, fmt.Errorf("empty")
	}
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.URLEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.RawURLEncoding.DecodeString(s)
}

func (y *YouTube) Name() string { return "youtube" }

func (y *YouTube) Search(ctx context.Context, query string, limit int) (*model.SearchResult, error) {
	if limit <= 0 {
		limit = 10
	}
	if limit > 20 {
		limit = 20
	}

	cmd := exec.CommandContext(ctx, y.ytdlpPath,
		"--default-search", fmt.Sprintf("ytsearch%d", limit),
		"--dump-json", "--no-download", "--no-warnings",
		"--no-check-certificates", "--flat-playlist",
		query,
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("search failed: %w", err)
	}

	type ytResult struct {
		ID        string  `json:"id"`
		Title     string  `json:"title"`
		Duration  float64 `json:"duration"`
		Channel   string  `json:"channel"`
		Thumbnail string  `json:"thumbnail"`
	}

	result := &model.SearchResult{}
	seen := make(map[string]bool)

	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		var info ytResult
		if json.Unmarshal([]byte(line), &info) != nil || info.ID == "" || seen[info.ID] || info.Duration > 600 {
			continue
		}
		seen[info.ID] = true

		artist, title := parseYTTitle(info.Title, info.Channel)
		track := model.Track{
			ID:       info.ID,
			Provider: "youtube",
			Title:    title,
			Artist:   artist,
			CoverURL: info.Thumbnail,
			Duration: int(info.Duration),
			ClipURL:  "https://www.youtube.com/watch?v=" + info.ID,
		}

		// Enrich with Deezer (covers, album name)
		if dz := MatchDeezerTrack(ctx, artist, title); dz != nil {
			track.Title = dz.Title
			track.Artist = dz.Artist.Name
			track.Album = dz.Album.Title
			track.CoverURL = dz.Album.Cover
			if dz.Duration > 0 {
				track.Duration = dz.Duration
			}
		}

		result.Tracks = append(result.Tracks, track)

		cached := track
		y.mu.Lock()
		y.trackMeta[track.ID] = &cached
		y.mu.Unlock()
	}

	return result, nil
}

func (y *YouTube) GetTrack(ctx context.Context, id string) (*model.Track, error) {
	// Check search cache
	y.mu.RLock()
	if meta, ok := y.trackMeta[id]; ok {
		y.mu.RUnlock()
		return meta, nil
	}
	y.mu.RUnlock()

	// Go YouTube library
	video, err := y.ytClient.GetVideoContext(ctx, id)
	if err == nil {
		artist, title := parseYTTitle(video.Title, video.Author)
		track := &model.Track{
			ID: id, Provider: "youtube", Title: title,
			Artist: artist, Duration: int(video.Duration.Seconds()),
			ClipURL: "https://www.youtube.com/watch?v=" + id,
		}
		if len(video.Thumbnails) > 0 {
			track.CoverURL = video.Thumbnails[0].URL
		}
		if dz := MatchDeezerTrack(ctx, artist, title); dz != nil {
			track.Title = dz.Title
			track.Artist = dz.Artist.Name
			track.Album = dz.Album.Title
			track.CoverURL = dz.Album.Cover
		}
		y.mu.Lock()
		y.trackMeta[id] = track
		y.mu.Unlock()
		return track, nil
	}

	return nil, fmt.Errorf("track not found: %s", id)
}

func (y *YouTube) GetTrackStreamURL(ctx context.Context, id string) (string, error) {
	y.mu.RLock()
	if entry, ok := y.cache[id]; ok && time.Now().Before(entry.expiresAt) {
		y.mu.RUnlock()
		return entry.url, nil
	}
	y.mu.RUnlock()

	// Primary: yt-dlp (kept up-to-date via pip in Docker; handles YouTube cipher
	// changes much more reliably than the embedded Go library).
	streamURL, ytErr := y.getStreamViaYtdlp(ctx, id)
	if ytErr == nil && streamURL != "" {
		y.mu.Lock()
		y.cache[id] = cacheEntry{url: streamURL, expiresAt: time.Now().Add(2 * time.Hour)}
		y.mu.Unlock()
		return streamURL, nil
	}

	// Fallback: kkdai/youtube. Often broken on cipher changes, so it's the
	// safety net rather than the primary path.
	video, libErr := y.ytClient.GetVideoContext(ctx, id)
	if libErr == nil {
		formats := video.Formats.Type("audio")
		if len(formats) > 0 {
			if u, err := y.ytClient.GetStreamURL(video, &formats[0]); err == nil && u != "" {
				y.mu.Lock()
				y.cache[id] = cacheEntry{url: u, expiresAt: time.Now().Add(3 * time.Hour)}
				y.mu.Unlock()
				log.Printf("[yt-stream] id=%s via=go-lib (yt-dlp failed: %v)", id, ytErr)
				return u, nil
			}
		}
	}

	if ytErr != nil && libErr != nil {
		return "", fmt.Errorf("yt-dlp: %v; go-lib: %w", ytErr, libErr)
	}
	if ytErr != nil {
		return "", ytErr
	}
	return "", fmt.Errorf("no audio formats")
}

// getStreamViaYtdlp resolves a direct googlevideo.com URL using yt-dlp.
//
// We skip `--cookies-from-browser` entirely — on the Render Alpine container
// there is no Safari/Chrome/Firefox installed, so each attempt fails after a
// long timeout and just adds latency before the real (cookie-less) call.
//
// `extractor-args youtube:player_client=android,web,ios` works around the
// PoToken / cipher-throttling regressions YouTube ships periodically and is
// the most reliable client mix at the time of writing.
func (y *YouTube) getStreamViaYtdlp(ctx context.Context, id string) (string, error) {
	videoURL := "https://www.youtube.com/watch?v=" + id

	// Concurrency guard to avoid OOM (signal: killed) in small containers.
	select {
	case ytdlpSem <- struct{}{}:
		defer func() { <-ytdlpSem }()
	case <-ctx.Done():
		return "", ctx.Err()
	}

	// Bound yt-dlp wall-clock so a hung extraction never holds the request.
	cmdCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()

	args := []string{
		"-f", "bestaudio[ext=m4a]/bestaudio[acodec^=opus]/bestaudio/best",
		"--get-url",
		"--no-warnings", "--no-check-certificates", "--no-playlist",
		"--no-cache-dir",
		"--user-agent", ytdlpUserAgent,
		"--extractor-args", "youtube:player_client=android,web,ios",
		"--socket-timeout", "15",
		"--retries", "3",
		videoURL,
	}
	if y.ytdlpCookies != "" {
		// Use a Netscape cookies.txt file exported from a logged-in browser session.
		// This avoids the “confirm you’re not a bot” roadblock on cloud IP ranges.
		args = append([]string{"--cookies", y.ytdlpCookies}, args...)
	}
	cmd := exec.CommandContext(cmdCtx, y.ytdlpPath, args...)

	// Capture stderr separately so we can surface yt-dlp's diagnostic output
	// in Render logs (otherwise yt-dlp failures look like opaque exit codes).
	var stderr strings.Builder
	cmd.Stderr = &stderr

	out, err := cmd.Output()
	if err != nil {
		es := strings.TrimSpace(stderr.String())
		log.Printf("[yt-dlp] id=%s err=%v stderr=%q", id, err, truncate(es, 240))
		return "", fmt.Errorf("yt-dlp: %w (%s)", err, truncate(es, 120))
	}

	u := strings.TrimSpace(string(out))
	// `--get-url` can emit multiple URLs (one per format). Pick the first
	// non-empty line.
	if i := strings.IndexByte(u, '\n'); i > 0 {
		u = strings.TrimSpace(u[:i])
	}
	if u == "" {
		return "", fmt.Errorf("yt-dlp returned empty URL")
	}
	log.Printf("[yt-dlp] id=%s ok host=%s", id, hostOf(u))
	return u, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func hostOf(rawURL string) string {
	if i := strings.Index(rawURL, "://"); i >= 0 {
		rest := rawURL[i+3:]
		if j := strings.IndexAny(rest, "/?"); j > 0 {
			return rest[:j]
		}
		return rest
	}
	return ""
}

func (y *YouTube) GetLyrics(ctx context.Context, id string) (*model.Lyrics, error) {
	track, err := y.GetTrack(ctx, id)
	if err != nil {
		return nil, err
	}
	if lyrics, err := FetchLRCLIB(ctx, track.Artist, track.Title); err == nil && lyrics != "" {
		return &model.Lyrics{TrackID: id, Provider: "youtube", Text: lyrics}, nil
	}
	if lyrics, err := FetchGenius(ctx, track.Artist+" "+track.Title, y.geniusToken); err == nil && lyrics != "" {
		return &model.Lyrics{TrackID: id, Provider: "youtube", Text: lyrics}, nil
	}
	return nil, fmt.Errorf("lyrics not found")
}

func (y *YouTube) GetArtist(ctx context.Context, id string) (*model.Artist, error) {
	// Deezer for artist profiles
	da, err := DeezerSearchArtist(ctx, id)
	if err == nil {
		return DeezerGetArtist(ctx, fmt.Sprint(da.ID))
	}
	// YouTube fallback
	cmd := exec.CommandContext(ctx, y.ytdlpPath,
		"--default-search", "ytsearch10",
		"--dump-json", "--no-download", "--no-warnings",
		"--no-check-certificates", "--flat-playlist",
		id+" music",
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	result := &model.Artist{ID: id, Provider: "youtube", Name: id}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		var info struct {
			ID, Title, Channel, Thumbnail string
			Duration                       float64
		}
		if json.Unmarshal([]byte(line), &info) != nil || info.Duration > 600 {
			continue
		}
		a, title := parseYTTitle(info.Title, info.Channel)
		result.Tracks = append(result.Tracks, model.Track{
			ID: info.ID, Provider: "youtube", Title: title,
			Artist: a, CoverURL: info.Thumbnail, Duration: int(info.Duration),
		})
	}
	return result, nil
}

func (y *YouTube) GetAlbum(ctx context.Context, id string) (*model.Album, error) {
	return DeezerGetAlbum(ctx, id)
}

func (y *YouTube) GetPlaylist(ctx context.Context, id string) (*model.Playlist, error) {
	playlistURL := id
	if !strings.HasPrefix(id, "http") {
		playlistURL = "https://www.youtube.com/playlist?list=" + id
	}
	cmd := exec.CommandContext(ctx, y.ytdlpPath,
		"--dump-json", "--no-download", "--no-warnings",
		"--no-check-certificates", "--flat-playlist",
		playlistURL,
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	playlist := &model.Playlist{ID: id, Provider: "youtube"}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		var info struct {
			ID, Title, Channel, Thumbnail string
			Duration                       float64
		}
		if json.Unmarshal([]byte(line), &info) != nil {
			continue
		}
		a, title := parseYTTitle(info.Title, info.Channel)
		playlist.Tracks = append(playlist.Tracks, model.Track{
			ID: info.ID, Provider: "youtube", Title: title,
			Artist: a, CoverURL: info.Thumbnail, Duration: int(info.Duration),
		})
	}
	return playlist, nil
}

// --- helpers ---

func parseYTTitle(ytTitle, channel string) (artist, title string) {
	if parts := strings.SplitN(ytTitle, " - ", 2); len(parts) == 2 {
		artist = strings.TrimSpace(parts[0])
		title = strings.TrimSpace(parts[1])
		for _, suffix := range []string{
			"(Official Audio)", "(Official Video)", "(Audio)", "(Video)",
			"(Official Music Video)", "(Lyric Video)", "(Lyrics)",
			"[Official Audio]", "[Official Video]", "(Remastered)", "(HD)",
			"(4K Remaster)",
		} {
			title = strings.TrimSuffix(title, suffix)
			title = strings.TrimSpace(title)
		}
		return
	}
	title = ytTitle
	artist = strings.TrimSuffix(channel, " - Topic")
	if artist == "" {
		artist = "Unknown"
	}
	return
}
