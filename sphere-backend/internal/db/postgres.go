package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

func Connect(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("connect to db: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping db: %w", err)
	}
	return pool, nil
}

func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, migrationSQL)
	return err
}

const migrationSQL = `
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT,
    name TEXT NOT NULL DEFAULT '',
    avatar_url TEXT NOT NULL DEFAULT '',
    google_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS favorites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_type TEXT NOT NULL,
    provider TEXT NOT NULL,
    provider_item_id TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    artist_name TEXT NOT NULL DEFAULT '',
    cover_url TEXT NOT NULL DEFAULT '',
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(user_id, provider, provider_item_id)
);

CREATE TABLE IF NOT EXISTS uploads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',
    artist_name TEXT NOT NULL DEFAULT '',
    duration INT NOT NULL DEFAULT 0,
    file_url TEXT NOT NULL,
    cover_url TEXT NOT NULL DEFAULT '',
    file_size BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS listen_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    track_id TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    genres TEXT[] NOT NULL DEFAULT '{}',
    listened_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS listen_history_user_time_idx ON listen_history(user_id, listened_at DESC);

CREATE TABLE IF NOT EXISTS user_preferences (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    selected_artists TEXT[] DEFAULT '{}',
    selected_genres TEXT[] DEFAULT '{}',
    onboarding_completed BOOLEAN DEFAULT false,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_lyrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    track_provider TEXT NOT NULL,
    track_id TEXT NOT NULL,
    text TEXT NOT NULL,
    user_id UUID REFERENCES users(id),
    user_name TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(track_provider, track_id)
);

CREATE TABLE IF NOT EXISTS comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    track_provider TEXT NOT NULL,
    track_id TEXT NOT NULL,
    user_id UUID REFERENCES users(id),
    user_name TEXT NOT NULL,
    user_avatar_url TEXT DEFAULT '',
    encrypted_text BYTEA NOT NULL,
    nonce BYTEA NOT NULL,
    parent_id UUID REFERENCES comments(id) ON DELETE CASCADE,
    likes INT DEFAULT 0,
    dislikes INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_comments_track ON comments(track_provider, track_id);

CREATE TABLE IF NOT EXISTS comment_votes (
    user_id UUID REFERENCES users(id),
    comment_id UUID REFERENCES comments(id) ON DELETE CASCADE,
    vote_type TEXT NOT NULL CHECK (vote_type IN ('like', 'dislike')),
    PRIMARY KEY (user_id, comment_id)
);

ALTER TABLE listen_history ADD COLUMN IF NOT EXISTS skipped BOOLEAN NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS signup_email_codes (
    email TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
`
