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
}

func NewDeezer(geniusToken string) *Deezer {
	return &Deezer{httpClient: &http.Client{Timeout: 10 * time.Second}, geniusToken: geniusToken}
}

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

func (d *Deezer) GetTrackStreamURL(ctx context.Context, id string) (string, error) {
	track, err := d.GetTrack(ctx, id)
	if err != nil {
		return "", err
	}
	if track.PreviewURL != "" {
		return track.PreviewURL, nil
	}
	if track.StreamURL != "" {
		return track.StreamURL, nil
	}
	return "", fmt.Errorf("no preview available for deezer track %s", id)
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
	return model.Track{
		ID:         fmt.Sprint(dt.ID),
		Provider:   "deezer",
		Title:      dt.Title,
		Artist:     dt.Artist.Name,
		Album:      dt.Album.Title,
		CoverURL:   cover,
		Duration:   dt.Duration,
		PreviewURL: dt.Preview,
		StreamURL:  dt.Preview,
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
