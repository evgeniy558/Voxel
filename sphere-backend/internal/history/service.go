package history

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Entry struct {
	Provider string   `json:"provider"`
	TrackID  string   `json:"track_id"`
	Title    string   `json:"title"`
	Artist   string   `json:"artist"`
	Genres   []string `json:"genres"`
	Skipped  bool     `json:"skipped,omitempty"`
}

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{db: db}
}

func (s *Service) Record(ctx context.Context, userID string, e Entry) error {
	if e.Genres == nil {
		e.Genres = []string{}
	}
	_, err := s.db.Exec(ctx,
		`INSERT INTO listen_history (user_id, provider, track_id, title, artist, genres, skipped)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		userID, e.Provider, e.TrackID, e.Title, e.Artist, e.Genres, e.Skipped,
	)
	if err != nil {
		return fmt.Errorf("record history: %w", err)
	}
	return nil
}

type HistoryEntry struct {
	ID         string `json:"id"`
	Provider   string `json:"provider"`
	TrackID    string `json:"track_id"`
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	ListenedAt string `json:"listened_at"`
}

func (s *Service) List(ctx context.Context, userID string, limit int) ([]HistoryEntry, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := s.db.Query(ctx,
		`SELECT id, provider, track_id, title, artist, listened_at
		 FROM listen_history WHERE user_id = $1
		 ORDER BY listened_at DESC LIMIT $2`,
		userID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []HistoryEntry
	for rows.Next() {
		var e HistoryEntry
		if err := rows.Scan(&e.ID, &e.Provider, &e.TrackID, &e.Title, &e.Artist, &e.ListenedAt); err != nil {
			continue
		}
		out = append(out, e)
	}
	if out == nil {
		out = []HistoryEntry{}
	}
	return out, nil
}

// TopGenres returns up to n most-listened genres for the user over the last 30 days.
func (s *Service) TopGenres(ctx context.Context, userID string, n int) ([]string, error) {
	rows, err := s.db.Query(ctx,
		`SELECT unnest(genres) AS g, COUNT(*) AS c
		   FROM listen_history
		  WHERE user_id = $1 AND listened_at > now() - interval '30 days'
		  GROUP BY g
		  ORDER BY c DESC
		  LIMIT $2`,
		userID, n,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var g string
		var c int
		if err := rows.Scan(&g, &c); err != nil {
			return nil, err
		}
		if g != "" {
			out = append(out, g)
		}
	}
	return out, nil
}

// TopArtists returns up to n most-listened artist names for the user over the last 30 days.
// TrackKey identifies a catalog track for recommendation engines.
type TrackKey struct {
	Provider string
	TrackID  string
	Title    string
	Artist   string
}

// LastSpotifyTrackID returns the most recently played Spotify track id, if any.
func (s *Service) LastSpotifyTrackID(ctx context.Context, userID string) (string, error) {
	var id string
	err := s.db.QueryRow(ctx,
		`SELECT track_id FROM listen_history
		  WHERE user_id = $1 AND provider = 'spotify'
		  ORDER BY listened_at DESC
		  LIMIT 1`,
		userID,
	).Scan(&id)
	if err != nil {
		if err == pgx.ErrNoRows {
			return "", nil
		}
		return "", err
	}
	return id, nil
}

// SkipProneTracks returns tracks the user frequently skips (high skip ratio).
func (s *Service) SkipProneTracks(ctx context.Context, userID string, days int, minPlays int, skipThreshold float64) ([]TrackKey, error) {
	if days <= 0 {
		days = 60
	}
	if minPlays < 1 {
		minPlays = 2
	}
	if skipThreshold <= 0 || skipThreshold > 1 {
		skipThreshold = 0.6
	}
	rows, err := s.db.Query(ctx,
		`SELECT provider, track_id, MAX(title), MAX(artist)
		   FROM listen_history
		  WHERE user_id = $1
		    AND listened_at > now() - ($2::int * interval '1 day')
		  GROUP BY provider, track_id
		 HAVING COUNT(*) > $3
		    AND AVG(CASE WHEN COALESCE(skipped, false) THEN 1.0 ELSE 0.0 END) > $4::double precision
		  ORDER BY COUNT(*) DESC
		  LIMIT 200`,
		userID, days, minPlays, skipThreshold,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TrackKey
	for rows.Next() {
		var k TrackKey
		if err := rows.Scan(&k.Provider, &k.TrackID, &k.Title, &k.Artist); err != nil {
			continue
		}
		out = append(out, k)
	}
	return out, nil
}

// PeerInfluencedTracks returns tracks that similar users (shared artists) play that this user has not played.
func (s *Service) PeerInfluencedTracks(ctx context.Context, userID string, limit int) ([]TrackKey, error) {
	if limit <= 0 {
		limit = 30
	}
	rows, err := s.db.Query(ctx,
		`SELECT h2.provider, h2.track_id, h2.title, h2.artist, COUNT(*) AS c
		   FROM listen_history h1
		   JOIN listen_history h2
		     ON h1.artist = h2.artist
		    AND h1.artist <> ''
		    AND h1.user_id = $1
		    AND h2.user_id <> $1
		    AND h1.listened_at > now() - interval '60 days'
		    AND h2.listened_at > now() - interval '60 days'
		  WHERE NOT EXISTS (
		      SELECT 1 FROM listen_history me
		      WHERE me.user_id = $1
		        AND me.provider = h2.provider
		        AND me.track_id = h2.track_id
		  )
		  GROUP BY h2.provider, h2.track_id, h2.title, h2.artist
		  ORDER BY c DESC
		  LIMIT $2`,
		userID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TrackKey
	for rows.Next() {
		var k TrackKey
		var c int
		if err := rows.Scan(&k.Provider, &k.TrackID, &k.Title, &k.Artist, &c); err != nil {
			continue
		}
		out = append(out, k)
	}
	return out, nil
}

func (s *Service) TopArtists(ctx context.Context, userID string, n int) ([]string, error) {
	rows, err := s.db.Query(ctx,
		`SELECT artist, COUNT(*) AS c
		   FROM listen_history
		  WHERE user_id = $1 AND listened_at > now() - interval '30 days' AND artist <> ''
		  GROUP BY artist
		  ORDER BY c DESC
		  LIMIT $2`,
		userID, n,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var a string
		var c int
		if err := rows.Scan(&a, &c); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}
