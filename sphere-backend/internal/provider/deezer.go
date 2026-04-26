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

// Deezer provides free metadata API — no auth required.
// Used to enrich search results with proper covers, album names, artist profiles.

var deezerHTTP = &http.Client{Timeout: 10 * time.Second}

type deezerTrack struct {
	ID       int    `json:"id"`
	Title    string `json:"title"`
	Duration int    `json:"duration"`
	Preview  string `json:"preview"`
	Artist   struct {
		ID         int    `json:"id"`
		Name       string `json:"name"`
		Picture    string `json:"picture_medium"`
		PictureBig string `json:"picture_big"`
		PictureXL  string `json:"picture_xl"`
	} `json:"artist"`
	Album struct {
		ID       int    `json:"id"`
		Title    string `json:"title"`
		Cover    string `json:"cover_medium"`
		CoverBig string `json:"cover_big"`
		CoverXL  string `json:"cover_xl"`
	} `json:"album"`
}

type deezerArtist struct {
	ID         int    `json:"id"`
	Name       string `json:"name"`
	Picture    string `json:"picture_xl"`
	PictureMed string `json:"picture_medium"`
	NbFan      int    `json:"nb_fan"`
}

type deezerAlbum struct {
	ID       int          `json:"id"`
	Title    string       `json:"title"`
	Cover    string       `json:"cover_medium"`
	CoverBig string       `json:"cover_big"`
	CoverXL  string       `json:"cover_xl"`
	Artist   deezerArtist `json:"artist"`
	NbTracks int          `json:"nb_tracks"`
}

// DeezerSearchTracks searches Deezer for track metadata.
func DeezerSearchTracks(ctx context.Context, query string, limit int) ([]deezerTrack, error) {
	u := fmt.Sprintf("https://api.deezer.com/search?q=%s&limit=%d", url.QueryEscape(query), limit)
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	resp, err := deezerHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Data []deezerTrack `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result.Data, nil
}

func DeezerSearchAlbums(ctx context.Context, query string, limit int) ([]deezerAlbum, error) {
	u := fmt.Sprintf("https://api.deezer.com/search/album?q=%s&limit=%d", url.QueryEscape(query), limit)
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	resp, err := deezerHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Data []deezerAlbum `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result.Data, nil
}

func DeezerSearchArtists(ctx context.Context, query string, limit int) ([]deezerArtist, error) {
	u := fmt.Sprintf("https://api.deezer.com/search/artist?q=%s&limit=%d", url.QueryEscape(query), limit)
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	resp, err := deezerHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Data []deezerArtist `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result.Data, nil
}

// DeezerGetArtist returns full artist info with top tracks.
func DeezerGetArtist(ctx context.Context, id string) (*model.Artist, error) {
	// Get artist info
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.deezer.com/artist/"+id, nil)
	resp, err := deezerHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var da deezerArtist
	if err := json.NewDecoder(resp.Body).Decode(&da); err != nil {
		return nil, err
	}

	artist := &model.Artist{
		ID:       fmt.Sprint(da.ID),
		Provider: "deezer",
		Name:     da.Name,
		ImageURL: firstNonEmpty(da.Picture, da.PictureMed),
	}

	// Get top tracks
	req2, _ := http.NewRequestWithContext(ctx, "GET", "https://api.deezer.com/artist/"+id+"/top?limit=20", nil)
	resp2, err := deezerHTTP.Do(req2)
	if err != nil {
		return artist, nil
	}
	defer resp2.Body.Close()

	var topResp struct {
		Data []deezerTrack `json:"data"`
	}
	if json.NewDecoder(resp2.Body).Decode(&topResp) == nil {
		for _, dt := range topResp.Data {
			artist.Tracks = append(artist.Tracks, model.Track{
				ID:         fmt.Sprint(dt.ID),
				Provider:   "deezer",
				Title:      dt.Title,
				Artist:     dt.Artist.Name,
				Album:      dt.Album.Title,
				CoverURL:   dt.coverURL(),
				Duration:   dt.Duration,
				PreviewURL: dt.Preview,
				StreamURL:  dt.Preview,
			})
		}
	}

	return artist, nil
}

// DeezerSearchArtist finds an artist by name.
func DeezerSearchArtist(ctx context.Context, name string) (*deezerArtist, error) {
	u := fmt.Sprintf("https://api.deezer.com/search/artist?q=%s&limit=1", url.QueryEscape(name))
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	resp, err := deezerHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Data []deezerArtist `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	if len(result.Data) == 0 {
		return nil, fmt.Errorf("artist not found: %s", name)
	}
	return &result.Data[0], nil
}

// DeezerGetAlbum returns album with tracks.
func DeezerGetAlbum(ctx context.Context, id string) (*model.Album, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.deezer.com/album/"+id, nil)
	resp, err := deezerHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var da struct {
		deezerAlbum
		Tracks struct {
			Data []deezerTrack `json:"data"`
		} `json:"tracks"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&da); err != nil {
		return nil, err
	}

	album := &model.Album{
		ID:       fmt.Sprint(da.ID),
		Provider: "deezer",
		Title:    da.Title,
		Artist:   da.Artist.Name,
		CoverURL: da.CoverXL,
	}
	for _, dt := range da.Tracks.Data {
		album.Tracks = append(album.Tracks, model.Track{
			ID:         fmt.Sprint(dt.ID),
			Provider:   "deezer",
			Title:      dt.Title,
			Artist:     dt.Artist.Name,
			Album:      da.Title,
			CoverURL:   firstNonEmpty(da.CoverXL, da.CoverBig, da.Cover, dt.coverURL()),
			Duration:   dt.Duration,
			PreviewURL: dt.Preview,
			StreamURL:  dt.Preview,
		})
	}
	return album, nil
}

// MatchDeezerTrack finds the best Deezer match for an artist+title combo.
func MatchDeezerTrack(ctx context.Context, artist, title string) *deezerTrack {
	tracks, err := DeezerSearchTracks(ctx, artist+" "+title, 5)
	if err != nil || len(tracks) == 0 {
		return nil
	}
	// Return best match (first result is usually correct)
	return &tracks[0]
}

func (dt deezerTrack) coverURL() string {
	// Album art only — avoid many tracks collapsing to the same artist picture.
	return firstNonEmpty(
		dt.Album.CoverXL,
		dt.Album.CoverBig,
		dt.Album.Cover,
	)
}

func (a deezerAlbum) toModelAlbum() model.Album {
	return model.Album{
		ID:       fmt.Sprint(a.ID),
		Provider: "deezer",
		Title:    a.Title,
		Artist:   a.Artist.Name,
		CoverURL: firstNonEmpty(a.CoverXL, a.CoverBig, a.Cover),
	}
}

func (a deezerArtist) toModelArtist() model.Artist {
	return model.Artist{
		ID:        fmt.Sprint(a.ID),
		Provider:  "deezer",
		Name:      a.Name,
		ImageURL:  firstNonEmpty(a.Picture, a.PictureMed),
		Followers: int64(a.NbFan),
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
