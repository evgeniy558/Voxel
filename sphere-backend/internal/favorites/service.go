package favorites

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Favorite struct {
	ID             string    `json:"id"`
	UserID         string    `json:"user_id"`
	ItemType       string    `json:"item_type"`
	Provider       string    `json:"provider"`
	ProviderItemID string    `json:"provider_item_id"`
	Title          string    `json:"title"`
	ArtistName     string    `json:"artist_name"`
	CoverURL       string    `json:"cover_url"`
	CreatedAt      time.Time `json:"created_at"`
}

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{db: db}
}

func (s *Service) List(ctx context.Context, userID, itemType string) ([]Favorite, error) {
	query := `SELECT id, user_id, item_type, provider, provider_item_id, title, artist_name, cover_url, created_at
		FROM favorites WHERE user_id = $1`
	args := []any{userID}

	if itemType != "" {
		query += " AND item_type = $2"
		args = append(args, itemType)
	}
	query += " ORDER BY created_at DESC"

	rows, err := s.db.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list favorites: %w", err)
	}
	defer rows.Close()

	var favs []Favorite
	for rows.Next() {
		var f Favorite
		if err := rows.Scan(&f.ID, &f.UserID, &f.ItemType, &f.Provider, &f.ProviderItemID, &f.Title, &f.ArtistName, &f.CoverURL, &f.CreatedAt); err != nil {
			return nil, err
		}
		favs = append(favs, f)
	}
	return favs, nil
}

func (s *Service) Add(ctx context.Context, userID string, f *Favorite) (*Favorite, error) {
	err := s.db.QueryRow(ctx,
		`INSERT INTO favorites (user_id, item_type, provider, provider_item_id, title, artist_name, cover_url)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)
		 RETURNING id, created_at`,
		userID, f.ItemType, f.Provider, f.ProviderItemID, f.Title, f.ArtistName, f.CoverURL,
	).Scan(&f.ID, &f.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("add favorite: %w", err)
	}
	f.UserID = userID
	return f, nil
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	tag, err := s.db.Exec(ctx, `DELETE FROM favorites WHERE id = $1 AND user_id = $2`, id, userID)
	if err != nil {
		return fmt.Errorf("delete favorite: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("not found")
	}
	return nil
}

// TopArtists returns the most-saved artist names for a user (any item type).
func (s *Service) TopArtists(ctx context.Context, userID string, n int) ([]string, error) {
	if n <= 0 {
		n = 5
	}
	rows, err := s.db.Query(ctx,
		`SELECT TRIM(artist_name) AS a, COUNT(*) AS c
		   FROM favorites
		  WHERE user_id = $1 AND COALESCE(TRIM(artist_name), '') <> ''
		  GROUP BY TRIM(artist_name)
		  ORDER BY c DESC
		  LIMIT $2`,
		userID, n,
	)
	if err != nil {
		return nil, fmt.Errorf("top favorite artists: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var a string
		var c int
		if err := rows.Scan(&a, &c); err != nil {
			return nil, err
		}
		if a != "" {
			out = append(out, a)
		}
	}
	return out, nil
}
