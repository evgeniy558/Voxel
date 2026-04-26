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

type VKMusic struct {
	token      string
	httpClient *http.Client
}

func NewVKMusic(token string) *VKMusic {
	return &VKMusic{
		token:      token,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

func (v *VKMusic) Name() string { return "vk" }

func (v *VKMusic) apiGet(ctx context.Context, method string, params url.Values) (*http.Response, error) {
	params.Set("access_token", v.token)
	params.Set("v", "5.199")
	u := "https://api.vk.com/method/" + method + "?" + params.Encode()
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	return v.httpClient.Do(req)
}

func (v *VKMusic) Search(ctx context.Context, query string, limit int) (*model.SearchResult, error) {
	if limit <= 0 {
		limit = 20
	}
	params := url.Values{"q": {query}, "count": {fmt.Sprint(limit)}}
	resp, err := v.apiGet(ctx, "audio.search", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var vkResp struct {
		Response struct {
			Items []vkAudio `json:"items"`
		} `json:"response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&vkResp); err != nil {
		return nil, err
	}

	result := &model.SearchResult{}
	for _, a := range vkResp.Response.Items {
		result.Tracks = append(result.Tracks, a.toTrack())
	}
	return result, nil
}

func (v *VKMusic) GetTrack(ctx context.Context, id string) (*model.Track, error) {
	params := url.Values{"audios": {id}}
	resp, err := v.apiGet(ctx, "audio.getById", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var vkResp struct {
		Response []vkAudio `json:"response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&vkResp); err != nil {
		return nil, err
	}
	if len(vkResp.Response) == 0 {
		return nil, fmt.Errorf("track not found")
	}
	track := vkResp.Response[0].toTrack()
	return &track, nil
}

func (v *VKMusic) GetTrackStreamURL(ctx context.Context, id string) (string, error) {
	t, err := v.GetTrack(ctx, id)
	if err != nil {
		return "", err
	}
	return t.StreamURL, nil
}

func (v *VKMusic) GetLyrics(ctx context.Context, id string) (*model.Lyrics, error) {
	params := url.Values{"lyrics_id": {id}}
	resp, err := v.apiGet(ctx, "audio.getLyrics", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var vkResp struct {
		Response struct {
			Text string `json:"text"`
		} `json:"response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&vkResp); err != nil {
		return nil, err
	}
	return &model.Lyrics{TrackID: id, Provider: "vk", Text: vkResp.Response.Text}, nil
}

func (v *VKMusic) GetArtist(ctx context.Context, id string) (*model.Artist, error) {
	params := url.Values{"artist_id": {id}}
	resp, err := v.apiGet(ctx, "audio.getArtistById", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var vkResp struct {
		Response struct {
			Name  string `json:"name"`
			Photo []struct {
				URL string `json:"url"`
			} `json:"photo"`
		} `json:"response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&vkResp); err != nil {
		return nil, err
	}
	img := ""
	if len(vkResp.Response.Photo) > 0 {
		img = vkResp.Response.Photo[0].URL
	}
	return &model.Artist{ID: id, Provider: "vk", Name: vkResp.Response.Name, ImageURL: img}, nil
}

func (v *VKMusic) GetAlbum(ctx context.Context, id string) (*model.Album, error) {
	params := url.Values{"playlist_id": {id}, "count": {"100"}}
	resp, err := v.apiGet(ctx, "audio.get", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var vkResp struct {
		Response struct {
			Items []vkAudio `json:"items"`
		} `json:"response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&vkResp); err != nil {
		return nil, err
	}
	album := &model.Album{ID: id, Provider: "vk"}
	for _, a := range vkResp.Response.Items {
		album.Tracks = append(album.Tracks, a.toTrack())
	}
	return album, nil
}

func (v *VKMusic) GetPlaylist(ctx context.Context, id string) (*model.Playlist, error) {
	album, err := v.GetAlbum(ctx, id)
	if err != nil {
		return nil, err
	}
	return &model.Playlist{
		ID: album.ID, Provider: "vk", Title: album.Title,
		CoverURL: album.CoverURL, Tracks: album.Tracks,
	}, nil
}

type vkAudio struct {
	ID       int    `json:"id"`
	OwnerID  int    `json:"owner_id"`
	Title    string `json:"title"`
	Artist   string `json:"artist"`
	Duration int    `json:"duration"`
	URL      string `json:"url"`
}

func (a vkAudio) toTrack() model.Track {
	return model.Track{
		ID:        fmt.Sprintf("%d_%d", a.OwnerID, a.ID),
		Provider:  "vk",
		Title:     a.Title,
		Artist:    a.Artist,
		Duration:  a.Duration,
		StreamURL: a.URL,
	}
}
