package preferences

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Preferences struct {
	SelectedArtists     []string `json:"selected_artists"`
	SelectedGenres      []string `json:"selected_genres"`
	OnboardingCompleted bool     `json:"onboarding_completed"`
}

type Service struct {
	pool *pgxpool.Pool
}

func NewService(pool *pgxpool.Pool) *Service {
	return &Service{pool: pool}
}

func (s *Service) Get(ctx context.Context, userID string) (*Preferences, error) {
	p := &Preferences{}
	err := s.pool.QueryRow(ctx,
		`SELECT selected_artists, selected_genres, onboarding_completed FROM user_preferences WHERE user_id = $1`,
		userID,
	).Scan(&p.SelectedArtists, &p.SelectedGenres, &p.OnboardingCompleted)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Non-nil slices so JSON is [] not null (iOS and other clients expect arrays).
			return &Preferences{SelectedArtists: []string{}, SelectedGenres: []string{}, OnboardingCompleted: false}, nil
		}
		return nil, err
	}
	return p, nil
}

func (s *Service) Save(ctx context.Context, userID string, artists, genres []string) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO user_preferences (user_id, selected_artists, selected_genres, onboarding_completed, updated_at)
		 VALUES ($1, $2, $3, true, NOW())
		 ON CONFLICT (user_id) DO UPDATE SET
		   selected_artists = EXCLUDED.selected_artists,
		   selected_genres = EXCLUDED.selected_genres,
		   onboarding_completed = true,
		   updated_at = NOW()`,
		userID, artists, genres,
	)
	return err
}
