package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"

	ytclient "github.com/kkdai/youtube/v2"

	"sphere-backend/internal/model"
)

// YouTube provider — full audio streaming without any API keys or cookies.
//   Search: yt-dlp --flat-playlist
//   Metadata: Deezer API (free)
//   Audio: kkdai/youtube Go library (direct stream URLs)
//   Lyrics: LRCLIB + Genius

type YouTube struct {
	ytdlpPath   string
	ytClient    ytclient.Client
	cache       map[string]cacheEntry
	trackMeta   map[string]*model.Track
	mu          sync.RWMutex
	geniusToken string
}

func NewYouTube(geniusToken string) *YouTube {
	path, _ := exec.LookPath("yt-dlp")
	if path == "" {
		path = "yt-dlp"
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp4", addr)
		},
	}
	return &YouTube{
		ytdlpPath:   path,
		ytClient:    ytclient.Client{HTTPClient: &http.Client{Transport: transport, Timeout: 30 * time.Second}},
		cache:       make(map[string]cacheEntry),
		trackMeta:   make(map[string]*model.Track),
		geniusToken: geniusToken,
	}
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

	// Try Go library first
	video, err := y.ytClient.GetVideoContext(ctx, id)
	if err == nil {
		formats := video.Formats.Type("audio")
		if len(formats) > 0 {
			if streamURL, err := y.ytClient.GetStreamURL(video, &formats[0]); err == nil && streamURL != "" {
				y.mu.Lock()
				y.cache[id] = cacheEntry{url: streamURL, expiresAt: time.Now().Add(3 * time.Hour)}
				y.mu.Unlock()
				return streamURL, nil
			}
		}
	}

	// Fallback: yt-dlp
	streamURL, ytErr := y.getStreamViaYtdlp(ctx, id)
	if ytErr != nil {
		if err != nil {
			return "", fmt.Errorf("go-lib: %w; yt-dlp: %v", err, ytErr)
		}
		return "", ytErr
	}

	y.mu.Lock()
	y.cache[id] = cacheEntry{url: streamURL, expiresAt: time.Now().Add(2 * time.Hour)}
	y.mu.Unlock()
	return streamURL, nil
}

func (y *YouTube) getStreamViaYtdlp(ctx context.Context, id string) (string, error) {
	videoURL := "https://www.youtube.com/watch?v=" + id
	baseArgs := []string{
		"-f", "bestaudio[ext=m4a]/bestaudio/best",
		"--get-url", "--no-warnings", "--no-check-certificates",
		"--no-playlist",
	}

	// Try with browser cookies first
	for _, browser := range []string{"safari", "chrome", "firefox"} {
		args := append(baseArgs, "--cookies-from-browser", browser, videoURL)
		cmd := exec.CommandContext(ctx, y.ytdlpPath, args...)
		out, err := cmd.Output()
		if err == nil {
			u := strings.TrimSpace(string(out))
			if u != "" {
				return u, nil
			}
		}
	}

	// Try without cookies
	args := append(baseArgs, videoURL)
	cmd := exec.CommandContext(ctx, y.ytdlpPath, args...)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("yt-dlp stream: %w", err)
	}
	u := strings.TrimSpace(string(out))
	if u == "" {
		return "", fmt.Errorf("yt-dlp returned empty URL")
	}
	return u, nil
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
