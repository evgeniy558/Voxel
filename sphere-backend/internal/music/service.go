package music

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"sphere-backend/internal/model"
	"sphere-backend/internal/provider"
)

var geniusToken string

func SetGeniusToken(token string) { geniusToken = token }

type Service struct {
	providers map[string]provider.MusicProvider
}

func NewService(providers ...provider.MusicProvider) *Service {
	m := make(map[string]provider.MusicProvider)
	for _, p := range providers {
		m[p.Name()] = p
	}
	return &Service{providers: m}
}

func (s *Service) Search(ctx context.Context, query string, limit int, providerFilter string) *model.SearchResult {
	if providerFilter != "" && providerFilter != "all" {
		if p, ok := s.providers[providerFilter]; ok {
			result, err := p.Search(ctx, query, limit)
			if err != nil {
				return &model.SearchResult{}
			}
			return result
		}
		return &model.SearchResult{}
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	merged := &model.SearchResult{}

	for _, p := range s.providers {
		wg.Add(1)
		go func(prov provider.MusicProvider) {
			defer wg.Done()
			res, err := prov.Search(ctx, query, limit)
			if err != nil || res == nil {
				return
			}
			mu.Lock()
			merged.Tracks = append(merged.Tracks, res.Tracks...)
			merged.Artists = append(merged.Artists, res.Artists...)
			merged.Albums = append(merged.Albums, res.Albums...)
			merged.Playlists = append(merged.Playlists, res.Playlists...)
			mu.Unlock()
		}(p)
	}
	wg.Wait()
	return merged
}

func (s *Service) GetTrack(ctx context.Context, providerName, id string) (*model.Track, error) {
	return s.providers[providerName].GetTrack(ctx, id)
}

func (s *Service) GetTrackStreamURL(ctx context.Context, providerName, id string) (string, error) {
	p, ok := s.providers[providerName]
	if !ok {
		return "", fmt.Errorf("unknown provider: %s", providerName)
	}
	url, err := p.GetTrackStreamURL(ctx, id)
	if err == nil && url != "" {
		return url, nil
	}

	// Fallback: get track metadata, search on SoundCloud/YouTube for same track
	track, tErr := p.GetTrack(ctx, id)
	if tErr != nil || track == nil {
		return "", err
	}
	query := track.Artist + " " + track.Title
	for _, fallbackName := range []string{"soundcloud", "youtube"} {
		if fallbackName == providerName {
			continue
		}
		fp, ok := s.providers[fallbackName]
		if !ok {
			continue
		}
		sr, sErr := fp.Search(ctx, query, 3)
		if sErr != nil || sr == nil || len(sr.Tracks) == 0 {
			continue
		}
		for _, t := range sr.Tracks {
			streamURL, sErr := fp.GetTrackStreamURL(ctx, t.ID)
			if sErr == nil && streamURL != "" {
				return streamURL, nil
			}
		}
	}
	return "", err
}

func (s *Service) GetLyrics(ctx context.Context, providerName, id string) (*model.Lyrics, error) {
	p, ok := s.providers[providerName]
	if !ok {
		return nil, fmt.Errorf("unknown provider: %s", providerName)
	}
	lyrics, err := p.GetLyrics(ctx, id)
	if err == nil && lyrics != nil && lyrics.Text != "" {
		return lyrics, nil
	}
	track, tErr := p.GetTrack(ctx, id)
	if tErr != nil || track == nil {
		return nil, err
	}
	if text, lErr := provider.FetchLRCLIB(ctx, track.Artist, track.Title); lErr == nil && text != "" {
		return &model.Lyrics{TrackID: id, Provider: providerName, Text: text}, nil
	}
	if geniusToken != "" {
		if text, gErr := provider.FetchGenius(ctx, track.Artist+" "+track.Title, geniusToken); gErr == nil && text != "" {
			return &model.Lyrics{TrackID: id, Provider: providerName, Text: text}, nil
		}
	}
	return nil, fmt.Errorf("lyrics not found for %s:%s", providerName, id)
}

func (s *Service) GetArtist(ctx context.Context, providerName, id string) (*model.Artist, error) {
	return s.providers[providerName].GetArtist(ctx, id)
}

// GetUnifiedArtist builds a merged artist profile:
//   - canonical metadata (image, followers, genres) comes from Spotify when available
//   - top tracks from Spotify are included
//   - other providers contribute their tracks where the track artist fuzzy-matches
//     the requested name; if no match, fall back to top-3 search hits so that
//     services with different handles (e.g. SoundCloud "octobersveryown" for Drake)
//     still surface content.
func (s *Service) GetUnifiedArtist(ctx context.Context, name string) *model.Artist {
	unified := &model.Artist{
		ID:       name,
		Provider: "all",
		Name:     name,
	}

	var mu sync.Mutex
	var wg sync.WaitGroup

	if sp, ok := s.providers["spotify"]; ok {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sr, err := sp.Search(ctx, name, 10)
			if err != nil || sr == nil || len(sr.Artists) == 0 {
				return
			}
			match := sr.Artists[0]
			for _, a := range sr.Artists {
				if strings.EqualFold(a.Name, name) {
					match = a
					break
				}
			}
			full, err := sp.GetArtist(ctx, match.ID)
			if err != nil || full == nil {
				return
			}
			mu.Lock()
			unified.Name = full.Name
			unified.ImageURL = full.ImageURL
			unified.Followers = full.Followers
			unified.MonthlyListeners = full.MonthlyListeners
			unified.Genres = full.Genres
			unified.Tracks = append(unified.Tracks, full.Tracks...)
			mu.Unlock()
		}()
	}

	for key, p := range s.providers {
		if key == "spotify" {
			continue
		}
		wg.Add(1)
		go func(prov provider.MusicProvider) {
			defer wg.Done()
			sr, err := prov.Search(ctx, name, 15)
			if err != nil || sr == nil || len(sr.Tracks) == 0 {
				return
			}
			lower := strings.ToLower(name)
			var matched []model.Track
			for _, t := range sr.Tracks {
				if strings.Contains(strings.ToLower(t.Artist), lower) ||
					strings.Contains(strings.ToLower(t.Title), lower) {
					matched = append(matched, t)
				}
			}
			if len(matched) == 0 {
				take := 3
				if len(sr.Tracks) < take {
					take = len(sr.Tracks)
				}
				matched = sr.Tracks[:take]
			}
			mu.Lock()
			unified.Tracks = append(unified.Tracks, matched...)
			mu.Unlock()
		}(p)
	}
	wg.Wait()
	return unified
}

func (s *Service) GetAlbum(ctx context.Context, providerName, id string) (*model.Album, error) {
	return s.providers[providerName].GetAlbum(ctx, id)
}

func (s *Service) GetPlaylist(ctx context.Context, providerName, id string) (*model.Playlist, error) {
	return s.providers[providerName].GetPlaylist(ctx, id)
}
