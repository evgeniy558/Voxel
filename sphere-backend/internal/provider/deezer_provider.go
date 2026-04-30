package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"sphere-backend/internal/model"
)

type Deezer struct {
	httpClient  *http.Client
	geniusToken string
	session     *DeezerSession // optional; nil → only previews available
}

func NewDeezer(geniusToken string) *Deezer {
	return &Deezer{httpClient: &http.Client{Timeout: 10 * time.Second}, geniusToken: geniusToken}
}

// NewDeezerWithARL wires the Deezer GW session that unlocks full-track
// streaming. When `arl` is empty, full audio falls back to YouTube/SoundCloud.
func NewDeezerWithARL(geniusToken, arl string) *Deezer {
	return &Deezer{
		httpClient:  &http.Client{Timeout: 10 * time.Second},
		geniusToken: geniusToken,
		session:     NewDeezerSession(arl),
	}
}

// HasFullTrackSession reports whether this provider can serve real audio
// (encrypted CDN URL + Blowfish key) rather than the 30s public preview.
func (d *Deezer) HasFullTrackSession() bool { return d.session != nil }

// FullTrackSession exposes the underlying session so the music handler can
// do the streaming + Blowfish decryption itself.
func (d *Deezer) FullTrackSession() *DeezerSession { return d.session }

func (d *Deezer) Name() string { return "deezer" }

func (d *Deezer) Search(ctx context.Context, query string, limit int) (*model.SearchResult, error) {
	if limit <= 0 {
		limit = 20
	}
	result := &model.SearchResult{}

	u := fmt.Sprintf("https://api.deezer.com/search?q=%s&limit=%d", url.QueryEscape(query), limit)
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	resp, err := d.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var trackResp struct {
		Data []deezerTrack `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&trackResp); err != nil {
		return nil, err
	}
	for _, dt := range trackResp.Data {
		result.Tracks = append(result.Tracks, dt.toModelTrack())
		result.Artists = appendArtistIfNew(result.Artists, dt.Artist.ID, dt.Artist.Name, firstNonEmpty(dt.Artist.PictureXL, dt.Artist.PictureBig, dt.Artist.Picture))
	}
	if albums, err := DeezerSearchAlbums(ctx, query, limit); err == nil {
		for _, album := range albums {
			result.Albums = append(result.Albums, album.toModelAlbum())
		}
	}
	if artists, err := DeezerSearchArtists(ctx, query, limit); err == nil {
		for _, artist := range artists {
			result.Artists = appendArtistIfNew(result.Artists, artist.ID, artist.Name, firstNonEmpty(artist.Picture, artist.PictureMed))
		}
	}
	return result, nil
}

func (d *Deezer) GetTrack(ctx context.Context, id string) (*model.Track, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.deezer.com/track/"+id, nil)
	resp, err := d.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var dt deezerTrack
	if err := json.NewDecoder(resp.Body).Decode(&dt); err != nil {
		return nil, err
	}
	t := dt.toModelTrack()
	return &t, nil
}

// GetTrackStreamURL returns the encrypted Deezer CDN URL when a `DEEZER_ARL`
// session is configured. The music handler is responsible for fetching the
// bytes, running them through `NewDeezerStripeReader` and serving plaintext
// audio to the client.
//
// Without an ARL, the public Deezer API only ships 30-second previews, so we
// return an error and let the music service fall back to YouTube/SoundCloud.
func (d *Deezer) GetTrackStreamURL(ctx context.Context, id string) (string, error) {
	if d.session == nil {
		return "", fmt.Errorf("deezer: DEEZER_ARL not configured (full track unavailable; using fallback)")
	}
	encryptedURL, _, err := d.session.ResolveStreamURL(ctx, id, "MP3_128")
	if err != nil {
		return "", fmt.Errorf("deezer full-track: %w", err)
	}
	return encryptedURL, nil
}

func (d *Deezer) GetLyrics(ctx context.Context, id string) (*model.Lyrics, error) {
	track, err := d.GetTrack(ctx, id)
	if err != nil {
		return nil, err
	}
	text, err := FetchLRCLIB(ctx, track.Artist, track.Title)
	if err != nil || text == "" {
		text, _ = FetchGenius(ctx, track.Artist+" "+track.Title, d.geniusToken)
	}
	if text == "" {
		return nil, fmt.Errorf("lyrics not found")
	}
	return &model.Lyrics{TrackID: id, Provider: "deezer", Text: text}, nil
}

func (d *Deezer) GetArtist(ctx context.Context, id string) (*model.Artist, error) {
	return DeezerGetArtist(ctx, id)
}

func (d *Deezer) GetAlbum(ctx context.Context, id string) (*model.Album, error) {
	return DeezerGetAlbum(ctx, id)
}

func (d *Deezer) GetPlaylist(ctx context.Context, id string) (*model.Playlist, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.deezer.com/playlist/"+id, nil)
	resp, err := d.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var dp struct {
		ID      int    `json:"id"`
		Title   string `json:"title"`
		Picture string `json:"picture_medium"`
		Tracks  struct {
			Data []deezerTrack `json:"data"`
		} `json:"tracks"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&dp); err != nil {
		return nil, err
	}

	playlist := &model.Playlist{
		ID:       fmt.Sprint(dp.ID),
		Provider: "deezer",
		Title:    dp.Title,
		CoverURL: dp.Picture,
	}
	for _, dt := range dp.Tracks.Data {
		playlist.Tracks = append(playlist.Tracks, dt.toModelTrack())
	}
	return playlist, nil
}

func (dt deezerTrack) toModelTrack() model.Track {
	cover := dt.coverURL()
	// IMPORTANT: leave StreamURL empty — Deezer's API only exposes 30s previews.
	// iOS resolves the full track via /tracks/deezer/{id}/stream (which falls back
	// to YouTube/SoundCloud). PreviewURL is kept for short-form preview UI only.
	return model.Track{
		ID:         fmt.Sprint(dt.ID),
		Provider:   "deezer",
		Title:      dt.Title,
		Artist:     dt.Artist.Name,
		Album:      dt.Album.Title,
		CoverURL:   cover,
		Duration:   dt.Duration,
		PreviewURL: dt.Preview,
	}
}

func appendArtistIfNew(artists []model.Artist, id int, name, picture string) []model.Artist {
	sid := fmt.Sprint(id)
	for _, a := range artists {
		if a.ID == sid {
			return artists
		}
	}
	return append(artists, model.Artist{
		ID:       sid,
		Provider: "deezer",
		Name:     name,
		ImageURL: picture,
	})
}
