package user

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{db: db}
}

func (s *Service) GetByID(ctx context.Context, id string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(ctx,
		`SELECT id, email, name, avatar_url, created_at, updated_at FROM users WHERE id = $1`, id,
	).Scan(&u.ID, &u.Email, &u.Name, &u.AvatarURL, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	return u, nil
}

func (s *Service) Update(ctx context.Context, id, name, avatarURL string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(ctx,
		`UPDATE users SET name = COALESCE(NULLIF($2, ''), name), avatar_url = COALESCE(NULLIF($3, ''), avatar_url), updated_at = now()
		 WHERE id = $1
		 RETURNING id, email, name, avatar_url, created_at, updated_at`,
		id, name, avatarURL,
	).Scan(&u.ID, &u.Email, &u.Name, &u.AvatarURL, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("update user: %w", err)
	}
	return u, nil
}
