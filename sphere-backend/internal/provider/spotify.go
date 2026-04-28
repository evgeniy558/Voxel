package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"sphere-backend/internal/model"
)

type Spotify struct {
	clientID     string
	clientSecret string
	token        string
	tokenExpiry  time.Time
	mu           sync.Mutex
	httpClient   *http.Client

	monthlyListenersCache sync.Map // map[string]spotifyMonthlyListenersCacheEntry
}

type spotifyMonthlyListenersCacheEntry struct {
	Listeners int64
	ExpiresAt time.Time
}

func NewSpotify(clientID, clientSecret string) *Spotify {
	return &Spotify{
		clientID:     clientID,
		clientSecret: clientSecret,
		httpClient:   &http.Client{Timeout: 10 * time.Second},
	}
}

func (s *Spotify) Name() string { return "spotify" }

func (s *Spotify) getToken(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.token != "" && time.Now().Before(s.tokenExpiry) {
		return s.token, nil
	}

	data := url.Values{"grant_type": {"client_credentials"}}
	req, _ := http.NewRequestWithContext(ctx, "POST", "https://accounts.spotify.com/api/token", strings.NewReader(data.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(s.clientID+":"+s.clientSecret)))

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("spotify auth: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("spotify auth failed (status %d)", resp.StatusCode)
	}
	var result struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	if result.AccessToken == "" {
		return "", fmt.Errorf("spotify auth: empty access token")
	}
	s.token = result.AccessToken
	s.tokenExpiry = time.Now().Add(time.Duration(result.ExpiresIn-60) * time.Second)
	return s.token, nil
}

func (s *Spotify) apiGet(ctx context.Context, path string) (*http.Response, error) {
	token, err := s.getToken(ctx)
	if err != nil {
		return nil, err
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.spotify.com/v1"+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == 401 {
		s.mu.Lock()
		s.token = ""
		s.mu.Unlock()
		resp.Body.Close()
		token, err = s.getToken(ctx)
		if err != nil {
			return nil, err
		}
		req, _ = http.NewRequestWithContext(ctx, "GET", "https://api.spotify.com/v1"+path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		return s.httpClient.Do(req)
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("spotify API %s: status %d", path, resp.StatusCode)
	}
	return resp, nil
}

func (s *Spotify) Search(ctx context.Context, query string, limit int) (*model.SearchResult, error) {
	if limit <= 0 {
		limit = 20
	}
	path := fmt.Sprintf("/search?q=%s&type=track,artist,album,playlist&limit=%d", url.QueryEscape(query), limit)
	resp, err := s.apiGet(ctx, path)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var sr spotifySearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&sr); err != nil {
		return nil, err
	}

	result := &model.SearchResult{}
	for _, t := range sr.Tracks.Items {
		result.Tracks = append(result.Tracks, t.toTrack())
	}
	for _, a := range sr.Artists.Items {
		result.Artists = append(result.Artists, a.toArtist())
	}
	for _, a := range sr.Albums.Items {
		result.Albums = append(result.Albums, a.toAlbum())
	}
	for _, p := range sr.Playlists.Items {
		result.Playlists = append(result.Playlists, p.toPlaylist())
	}
	return result, nil
}

func (s *Spotify) GetTrack(ctx context.Context, id string) (*model.Track, error) {
	resp, err := s.apiGet(ctx, "/tracks/"+id)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var t spotifyTrack
	if err := json.NewDecoder(resp.Body).Decode(&t); err != nil {
		return nil, err
	}
	track := t.toTrack()
	return &track, nil
}

func (s *Spotify) GetTrackStreamURL(ctx context.Context, id string) (string, error) {
	t, err := s.GetTrack(ctx, id)
	if err != nil {
		return "", err
	}
	return t.PreviewURL, nil
}

func (s *Spotify) GetLyrics(_ context.Context, _ string) (*model.Lyrics, error) {
	return nil, fmt.Errorf("lyrics not available via Spotify API")
}

func (s *Spotify) GetArtist(ctx context.Context, id string) (*model.Artist, error) {
	resp, err := s.apiGet(ctx, "/artists/"+id)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var a spotifyArtistFull
	if err := json.NewDecoder(resp.Body).Decode(&a); err != nil {
		return nil, err
	}
	artist := a.toArtist()

	// Enrichment (best-effort): top tracks, albums (discography), monthly listeners.
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		topResp, err := s.apiGet(ctx, "/artists/"+id+"/top-tracks?market=US")
		if err != nil {
			return
		}
		defer topResp.Body.Close()
		var top struct {
			Tracks []spotifyTrack `json:"tracks"`
		}
		if json.NewDecoder(topResp.Body).Decode(&top) != nil {
			return
		}
		for _, t := range top.Tracks {
			tr := t.toTrack()
			tr.Genres = artist.Genres
			artist.Tracks = append(artist.Tracks, tr)
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		if ml, err := s.GetArtistMonthlyListeners(ctx, id); err == nil && ml > 0 {
			artist.MonthlyListeners = ml
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		al, err := s.GetArtistAlbums(ctx, id, "US", 20)
		if err != nil {
			return
		}
		if len(al) > 5 {
			al = al[:5]
		}
		artist.Albums = al
	}()

	wg.Wait()
	return &artist, nil
}

var spotifyMonthlyListenersRe = regexp.MustCompile(`monthlyListeners\"\\s*:\\s*([0-9]+)`)

// GetArtistMonthlyListeners scrapes open.spotify.com embedded JSON for monthlyListeners.
// This is unofficial, so it is best-effort with caching and safe fallback.
func (s *Spotify) GetArtistMonthlyListeners(ctx context.Context, artistID string) (int64, error) {
	if strings.TrimSpace(artistID) == "" {
		return 0, fmt.Errorf("empty artist id")
	}
	if v, ok := s.monthlyListenersCache.Load(artistID); ok {
		if e, ok2 := v.(spotifyMonthlyListenersCacheEntry); ok2 && time.Now().Before(e.ExpiresAt) {
			return e.Listeners, nil
		}
	}

	req, err := http.NewRequestWithContext(ctx, "GET", "https://open.spotify.com/artist/"+url.PathEscape(artistID), nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36")
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("open.spotify.com status %d", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, err
	}
	m := spotifyMonthlyListenersRe.FindSubmatch(b)
	if len(m) < 2 {
		// Cache the miss briefly to avoid hammering.
		s.monthlyListenersCache.Store(artistID, spotifyMonthlyListenersCacheEntry{Listeners: 0, ExpiresAt: time.Now().Add(15 * time.Minute)})
		return 0, nil
	}
	n, err := strconv.ParseInt(string(m[1]), 10, 64)
	if err != nil {
		return 0, err
	}
	s.monthlyListenersCache.Store(artistID, spotifyMonthlyListenersCacheEntry{Listeners: n, ExpiresAt: time.Now().Add(1 * time.Hour)})
	return n, nil
}

// GetArtistAlbums returns a simple discography list (no tracks) for a Spotify artist.
func (s *Spotify) GetArtistAlbums(ctx context.Context, artistID, market string, limit int) ([]model.Album, error) {
	if strings.TrimSpace(artistID) == "" {
		return nil, fmt.Errorf("empty artist id")
	}
	if market == "" {
		market = "US"
	}
	if limit <= 0 || limit > 50 {
		limit = 50
	}
	path := fmt.Sprintf("/artists/%s/albums?include_groups=album,single&limit=%d&market=%s",
		url.PathEscape(artistID),
		limit,
		url.QueryEscape(market),
	)
	resp, err := s.apiGet(ctx, path)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var r struct {
		Items []spotifyAlbum `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, err
	}
	seen := make(map[string]struct{})
	out := make([]model.Album, 0, len(r.Items))
	for _, it := range r.Items {
		al := it.toAlbum()
		if al.ID == "" {
			continue
		}
		k := al.Provider + ":" + al.ID
		if _, ok := seen[k]; ok {
			continue
		}
		seen[k] = struct{}{}
		out = append(out, al)
	}
	return out, nil
}

func (s *Spotify) GetAlbum(ctx context.Context, id string) (*model.Album, error) {
	resp, err := s.apiGet(ctx, "/albums/"+id)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var a spotifyAlbumFull
	if err := json.NewDecoder(resp.Body).Decode(&a); err != nil {
		return nil, err
	}
	album := a.toAlbum()
	for _, t := range a.Tracks.Items {
		track := t.toTrack()
		track.Album = album.Title
		if track.CoverURL == "" {
			track.CoverURL = album.CoverURL
		}
		album.Tracks = append(album.Tracks, track)
	}
	return &album, nil
}

func (s *Spotify) GetPlaylist(ctx context.Context, id string) (*model.Playlist, error) {
	resp, err := s.apiGet(ctx, "/playlists/"+id)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var p spotifyPlaylistFull
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		return nil, err
	}
	playlist := p.toPlaylist()
	for _, item := range p.Tracks.Items {
		if item.Track.ID != "" {
			playlist.Tracks = append(playlist.Tracks, item.Track.toTrack())
		}
	}
	return &playlist, nil
}

// --- Spotify types ---

type spotifyImage struct {
	URL string `json:"url"`
}

type spotifyArtistFull struct {
	ID        string         `json:"id"`
	Name      string         `json:"name"`
	Images    []spotifyImage `json:"images"`
	Genres    []string       `json:"genres"`
	Followers struct {
		Total int64 `json:"total"`
	} `json:"followers"`
}

func (a spotifyArtistFull) toArtist() model.Artist {
	img := ""
	if len(a.Images) > 0 {
		img = a.Images[0].URL
	}
	return model.Artist{
		ID: a.ID, Provider: "spotify", Name: a.Name,
		ImageURL: img, Followers: a.Followers.Total,
		Genres: a.Genres,
	}
}

type spotifyTrack struct {
	ID         string              `json:"id"`
	Name       string              `json:"name"`
	Artists    []spotifyArtistFull `json:"artists"`
	Album      *spotifyAlbum       `json:"album"`
	Duration   int                 `json:"duration_ms"`
	PreviewURL string              `json:"preview_url"`
}

func (t spotifyTrack) toTrack() model.Track {
	artist := ""
	if len(t.Artists) > 0 {
		artist = t.Artists[0].Name
	}
	albumName, cover := "", ""
	if t.Album != nil {
		albumName = t.Album.Name
		if len(t.Album.Images) > 0 {
			cover = t.Album.Images[0].URL
		}
	}
	return model.Track{
		ID: t.ID, Provider: "spotify", Title: t.Name, Artist: artist,
		Album: albumName, CoverURL: cover, Duration: t.Duration / 1000,
		PreviewURL: t.PreviewURL, StreamURL: t.PreviewURL,
	}
}

type spotifyAlbum struct {
	ID      string              `json:"id"`
	Name    string              `json:"name"`
	Images  []spotifyImage      `json:"images"`
	Artists []spotifyArtistFull `json:"artists"`
}

func (a spotifyAlbum) toAlbum() model.Album {
	cover, artist := "", ""
	if len(a.Images) > 0 {
		cover = a.Images[0].URL
	}
	if len(a.Artists) > 0 {
		artist = a.Artists[0].Name
	}
	return model.Album{ID: a.ID, Provider: "spotify", Title: a.Name, Artist: artist, CoverURL: cover}
}

type spotifyAlbumFull struct {
	spotifyAlbum
	Tracks struct {
		Items []spotifyTrack `json:"items"`
	} `json:"tracks"`
}

type spotifyPlaylist struct {
	ID     string         `json:"id"`
	Name   string         `json:"name"`
	Images []spotifyImage `json:"images"`
}

func (p spotifyPlaylist) toPlaylist() model.Playlist {
	cover := ""
	if len(p.Images) > 0 {
		cover = p.Images[0].URL
	}
	return model.Playlist{ID: p.ID, Provider: "spotify", Title: p.Name, CoverURL: cover}
}

type spotifyPlaylistFull struct {
	spotifyPlaylist
	Tracks struct {
		Items []struct {
			Track spotifyTrack `json:"track"`
		} `json:"items"`
	} `json:"tracks"`
}

type spotifySearchResponse struct {
	Tracks    struct{ Items []spotifyTrack }      `json:"tracks"`
	Artists   struct{ Items []spotifyArtistFull } `json:"artists"`
	Albums    struct{ Items []spotifyAlbum }      `json:"albums"`
	Playlists struct{ Items []spotifyPlaylist }   `json:"playlists"`
}

// GetArtistTopTracks returns top tracks for a Spotify artist.
func (s *Spotify) GetArtistTopTracks(ctx context.Context, artistID, market string) ([]model.Track, error) {
	if market == "" {
		market = "US"
	}
	resp, err := s.apiGet(ctx, "/artists/"+url.PathEscape(artistID)+"/top-tracks?market="+url.QueryEscape(market))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var top struct {
		Tracks []spotifyTrack `json:"tracks"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&top); err != nil {
		return nil, err
	}
	var out []model.Track
	for _, t := range top.Tracks {
		out = append(out, t.toTrack())
	}
	return out, nil
}

// GetRelatedArtists returns related Spotify artists.
func (s *Spotify) GetRelatedArtists(ctx context.Context, artistID string) ([]model.Artist, error) {
	resp, err := s.apiGet(ctx, "/artists/"+url.PathEscape(artistID)+"/related-artists")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var rel struct {
		Artists []spotifyArtistFull `json:"artists"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return nil, err
	}
	var out []model.Artist
	for _, a := range rel.Artists {
		out = append(out, a.toArtist())
	}
	return out, nil
}

// ResolveArtistID returns the first Spotify artist id for a free-text name.
func (s *Spotify) ResolveArtistID(ctx context.Context, name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("empty artist name")
	}
	path := fmt.Sprintf("/search?q=%s&type=artist&limit=1", url.QueryEscape(name))
	resp, err := s.apiGet(ctx, path)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var sr spotifySearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&sr); err != nil {
		return "", err
	}
	if len(sr.Artists.Items) == 0 {
		return "", fmt.Errorf("no artist for %q", name)
	}
	return sr.Artists.Items[0].ID, nil
}

// GetRecommendations calls Spotify /v1/recommendations. At most 5 seed values in total.
func (s *Spotify) GetRecommendations(ctx context.Context, seedArtists, seedTracks, seedGenres []string, limit int) ([]model.Track, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	// Truncate to 5 seeds total: prefer artists, then tracks, then genres.
	var sa, st, sg []string
	remaining := 5
	for _, a := range seedArtists {
		if a == "" || remaining == 0 {
			continue
		}
		sa = append(sa, a)
		remaining--
	}
	for _, t := range seedTracks {
		if t == "" || remaining == 0 {
			continue
		}
		st = append(st, t)
		remaining--
	}
	for _, g := range seedGenres {
		if g == "" || remaining == 0 {
			continue
		}
		sg = append(sg, g)
		remaining--
	}
	if len(sa)+len(st)+len(sg) == 0 {
		return nil, fmt.Errorf("no seeds for spotify recommendations")
	}
	q := url.Values{}
	q.Set("limit", fmt.Sprintf("%d", limit))
	if len(sa) > 0 {
		q.Set("seed_artists", strings.Join(sa, ","))
	}
	if len(st) > 0 {
		q.Set("seed_tracks", strings.Join(st, ","))
	}
	if len(sg) > 0 {
		q.Set("seed_genres", strings.Join(sg, ","))
	}
	q.Set("min_popularity", "20")
	q.Set("market", "US")
	path := "/recommendations?" + q.Encode()
	resp, err := s.apiGet(ctx, path)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out struct {
		Tracks []spotifyTrack `json:"tracks"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	var tracks []model.Track
	for _, t := range out.Tracks {
		tracks = append(tracks, t.toTrack())
	}
	return tracks, nil
}

type spotifyAudioFeatureRow struct {
	ID              string  `json:"id"`
	Danceability    float64 `json:"danceability"`
	Energy          float64 `json:"energy"`
	Speechiness     float64 `json:"speechiness"`
	Acousticness    float64 `json:"acousticness"`
	Instrumentalness float64 `json:"instrumentalness"`
	Valence         float64 `json:"valence"`
	Tempo           float64 `json:"tempo"`
}

// AudioFeatures fetches features for up to 100 track IDs (batched by caller).
func (s *Spotify) AudioFeatures(ctx context.Context, trackIDs []string) (map[string]model.AudioFeatures, error) {
	if len(trackIDs) == 0 {
		return map[string]model.AudioFeatures{}, nil
	}
	if len(trackIDs) > 100 {
		trackIDs = trackIDs[:100]
	}
	q := url.Values{}
	q.Set("ids", strings.Join(trackIDs, ","))
	resp, err := s.apiGet(ctx, "/audio-features?"+q.Encode())
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var body struct {
		AudioFeatures []spotifyAudioFeatureRow `json:"audio_features"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	out := make(map[string]model.AudioFeatures, len(body.AudioFeatures))
	for _, f := range body.AudioFeatures {
		if f.ID == "" {
			continue
		}
		out[f.ID] = model.AudioFeatures{
			ID:                f.ID,
			Danceability:      f.Danceability,
			Energy:            f.Energy,
			Speechiness:       f.Speechiness,
			Acousticness:      f.Acousticness,
			Instrumentalness:  f.Instrumentalness,
			Valence:           f.Valence,
			Tempo:             f.Tempo,
		}
	}
	return out, nil
}
