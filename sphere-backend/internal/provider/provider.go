package provider

import (
	"context"
	"sphere-backend/internal/model"
)

type MusicProvider interface {
	Name() string
	Search(ctx context.Context, query string, limit int) (*model.SearchResult, error)
	GetTrack(ctx context.Context, id string) (*model.Track, error)
	GetTrackStreamURL(ctx context.Context, id string) (string, error)
	GetLyrics(ctx context.Context, id string) (*model.Lyrics, error)
	GetArtist(ctx context.Context, id string) (*model.Artist, error)
	GetAlbum(ctx context.Context, id string) (*model.Album, error)
	GetPlaylist(ctx context.Context, id string) (*model.Playlist, error)
}
