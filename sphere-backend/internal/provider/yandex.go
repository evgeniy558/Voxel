package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"sphere-backend/internal/model"
)

type Yandex struct {
	token      string
	httpClient *http.Client
}

func NewYandex(token string) *Yandex {
	return &Yandex{
		token:      token,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

func (y *Yandex) Name() string { return "yandex" }

// yandexImageURL builds a fetchable https URL. API often returns a host path or protocol-relative //…;
// naïve "https://"+ would yield https:////… which breaks image loaders.
func yandexImageURL(coverURI string) string {
	u := strings.TrimSpace(coverURI)
	if u == "" {
		return ""
	}
	if strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		return u
	}
	if strings.HasPrefix(u, "//") {
		return "https:" + u
	}
	return "https://" + u
}

func (y *Yandex) apiGet(ctx context.Context, path string) (*http.Response, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.music.yandex.net"+path, nil)
	req.Header.Set("Authorization", "OAuth "+y.token)
	return y.httpClient.Do(req)
}

func (y *Yandex) Search(ctx context.Context, query string, limit int) (*model.SearchResult, error) {
	if limit <= 0 {
		limit = 20
	}
	resp, err := y.apiGet(ctx, fmt.Sprintf("/search?text=%s&type=all&page=0&pageSize=%d", url.QueryEscape(query), limit))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var yaResp struct {
		Result struct {
			Tracks struct {
				Results []yaTrack `json:"results"`
			} `json:"tracks"`
			Artists struct {
				Results []yaArtist `json:"results"`
			} `json:"artists"`
			Albums struct {
				Results []yaAlbum `json:"results"`
			} `json:"albums"`
			Playlists struct {
				Results []yaPlaylist `json:"results"`
			} `json:"playlists"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&yaResp); err != nil {
		return nil, err
	}

	result := &model.SearchResult{}
	for _, t := range yaResp.Result.Tracks.Results {
		result.Tracks = append(result.Tracks, t.toTrack())
	}
	for _, a := range yaResp.Result.Artists.Results {
		result.Artists = append(result.Artists, a.toArtist())
	}
	for _, a := range yaResp.Result.Albums.Results {
		result.Albums = append(result.Albums, a.toAlbum())
	}
	for _, p := range yaResp.Result.Playlists.Results {
		result.Playlists = append(result.Playlists, p.toPlaylist())
	}
	return result, nil
}

func (y *Yandex) GetTrack(ctx context.Context, id string) (*model.Track, error) {
	resp, err := y.apiGet(ctx, "/tracks/"+id)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var yaResp struct {
		Result []yaTrack `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&yaResp); err != nil {
		return nil, err
	}
	if len(yaResp.Result) == 0 {
		return nil, fmt.Errorf("track not found")
	}
	track := yaResp.Result[0].toTrack()
	return &track, nil
}

func (y *Yandex) GetTrackStreamURL(ctx context.Context, id string) (string, error) {
	resp, err := y.apiGet(ctx, "/tracks/"+id+"/download-info")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var yaResp struct {
		Result []struct {
			DownloadInfoURL string `json:"downloadInfoUrl"`
			Codec           string `json:"codec"`
			Bitrate         int    `json:"bitrateInKbps"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&yaResp); err != nil {
		return "", err
	}
	if len(yaResp.Result) == 0 {
		return "", fmt.Errorf("no download info")
	}
	return yaResp.Result[0].DownloadInfoURL, nil
}

func (y *Yandex) GetLyrics(ctx context.Context, id string) (*model.Lyrics, error) {
	resp, err := y.apiGet(ctx, "/tracks/"+id+"/lyrics")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var yaResp struct {
		Result struct {
			FullLyrics string `json:"fullLyrics"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&yaResp); err != nil {
		return nil, err
	}
	return &model.Lyrics{TrackID: id, Provider: "yandex", Text: yaResp.Result.FullLyrics}, nil
}

func (y *Yandex) GetArtist(ctx context.Context, id string) (*model.Artist, error) {
	resp, err := y.apiGet(ctx, "/artists/"+id+"/brief-info")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var yaResp struct {
		Result struct {
			Artist yaArtist  `json:"artist"`
			Tracks []yaTrack `json:"popularTracks"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&yaResp); err != nil {
		return nil, err
	}
	artist := yaResp.Result.Artist.toArtist()
	for _, t := range yaResp.Result.Tracks {
		artist.Tracks = append(artist.Tracks, t.toTrack())
	}
	return &artist, nil
}

func (y *Yandex) GetAlbum(ctx context.Context, id string) (*model.Album, error) {
	resp, err := y.apiGet(ctx, "/albums/"+id+"/with-tracks")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var yaResp struct {
		Result struct {
			yaAlbum
			Volumes [][]yaTrack `json:"volumes"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&yaResp); err != nil {
		return nil, err
	}
	album := yaResp.Result.yaAlbum.toAlbum()
	for _, vol := range yaResp.Result.Volumes {
		for _, t := range vol {
			album.Tracks = append(album.Tracks, t.toTrack())
		}
	}
	return &album, nil
}

func (y *Yandex) GetPlaylist(ctx context.Context, id string) (*model.Playlist, error) {
	resp, err := y.apiGet(ctx, "/playlists/"+id)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var yaResp struct {
		Result struct {
			yaPlaylist
			Tracks []struct {
				Track yaTrack `json:"track"`
			} `json:"tracks"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&yaResp); err != nil {
		return nil, err
	}
	playlist := yaResp.Result.yaPlaylist.toPlaylist()
	for _, item := range yaResp.Result.Tracks {
		playlist.Tracks = append(playlist.Tracks, item.Track.toTrack())
	}
	return &playlist, nil
}

type yaTrack struct {
	ID       string     `json:"id"`
	Title    string     `json:"title"`
	Artists  []yaArtist `json:"artists"`
	Albums   []yaAlbum  `json:"albums"`
	Duration int        `json:"durationMs"`
	CoverURI string     `json:"coverUri"`
}

func (t yaTrack) toTrack() model.Track {
	artist := ""
	if len(t.Artists) > 0 {
		artist = t.Artists[0].Name
	}
	albumName := ""
	if len(t.Albums) > 0 {
		albumName = t.Albums[0].Title
	}
	cover := yandexImageURL(t.CoverURI)
	return model.Track{
		ID: t.ID, Provider: "yandex", Title: t.Title, Artist: artist,
		Album: albumName, CoverURL: cover, Duration: t.Duration / 1000,
	}
}

type yaArtist struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Cover struct {
		URI string `json:"uri"`
	} `json:"cover"`
}

func (a yaArtist) toArtist() model.Artist {
	img := yandexImageURL(a.Cover.URI)
	return model.Artist{ID: fmt.Sprint(a.ID), Provider: "yandex", Name: a.Name, ImageURL: img}
}

type yaAlbum struct {
	ID       int    `json:"id"`
	Title    string `json:"title"`
	CoverURI string `json:"coverUri"`
	Artists  []yaArtist `json:"artists"`
}

func (a yaAlbum) toAlbum() model.Album {
	cover := yandexImageURL(a.CoverURI)
	artist := ""
	if len(a.Artists) > 0 {
		artist = a.Artists[0].Name
	}
	return model.Album{ID: fmt.Sprint(a.ID), Provider: "yandex", Title: a.Title, Artist: artist, CoverURL: cover}
}

type yaPlaylist struct {
	UID      int    `json:"uid"`
	Kind     int    `json:"kind"`
	Title    string `json:"title"`
	CoverURI string `json:"ogImage"`
}

func (p yaPlaylist) toPlaylist() model.Playlist {
	cover := yandexImageURL(p.CoverURI)
	return model.Playlist{
		ID:       fmt.Sprintf("%d:%d", p.UID, p.Kind),
		Provider: "yandex", Title: p.Title, CoverURL: cover,
	}
}
