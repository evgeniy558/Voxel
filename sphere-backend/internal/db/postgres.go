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
    UNIQUE(user_id, item_type, provider, provider_item_id)
);

-- favorites: enforce allowed item types + upgrade unique key
-- (PostgreSQL has no "ADD CONSTRAINT IF NOT EXISTS"; use DO blocks for idempotency)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON c.conrelid = t.oid
        WHERE t.relname = 'favorites' AND c.conname = 'favorites_item_type_check'
    ) THEN
        ALTER TABLE favorites ADD CONSTRAINT favorites_item_type_check
            CHECK (item_type IN ('track','album','playlist','artist'));
    END IF;
END $$;
ALTER TABLE favorites DROP CONSTRAINT IF EXISTS favorites_user_id_provider_provider_item_id_key;
DO $$
DECLARE
    has_new_unique boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON c.conrelid = t.oid
        WHERE t.relname = 'favorites'
          AND c.contype = 'u'
          AND pg_get_constraintdef(c.oid) LIKE '%(user_id, item_type, provider, provider_item_id)%'
    ) INTO has_new_unique;
    IF NOT has_new_unique THEN
        ALTER TABLE favorites ADD CONSTRAINT favorites_user_item_unique
            UNIQUE (user_id, item_type, provider, provider_item_id);
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS favorites_user_type_time_idx ON favorites(user_id, item_type, created_at DESC);

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

ALTER TABLE users ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS badge_text TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS badge_color TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS banned BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS banned_reason TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_secret TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_pending_secret TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_2fa_enabled BOOLEAN NOT NULL DEFAULT false;

-- Social/privacy
ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT NOT NULL DEFAULT '';
CREATE UNIQUE INDEX IF NOT EXISTS users_username_unique_idx ON users (lower(username)) WHERE username <> '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS hide_subscriptions BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS messages_mutual_only BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS private_profile BOOLEAN NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS subscriptions (
    follower_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    followee_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followee_id)
);
CREATE INDEX IF NOT EXISTS subscriptions_followee_idx ON subscriptions(followee_id, created_at DESC);
CREATE INDEX IF NOT EXISTS subscriptions_follower_idx ON subscriptions(follower_id, created_at DESC);

CREATE TABLE IF NOT EXISTS subscription_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied', 'cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS subscription_requests_target_idx ON subscription_requests(target_id, created_at DESC);
CREATE INDEX IF NOT EXISTS subscription_requests_target_status_idx ON subscription_requests(target_id, status);
CREATE INDEX IF NOT EXISTS subscription_requests_requester_idx ON subscription_requests(requester_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS subscription_requests_one_pending_idx
    ON subscription_requests(requester_id, target_id)
    WHERE status = 'pending';

-- Chat
CREATE TABLE IF NOT EXISTS chats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind TEXT NOT NULL DEFAULT 'dm' CHECK (kind IN ('dm')),
    dm_user1 UUID REFERENCES users(id) ON DELETE CASCADE,
    dm_user2 UUID REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_message_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS chats_dm_pair_unique_idx
    ON chats(dm_user1, dm_user2)
    WHERE kind = 'dm' AND dm_user1 IS NOT NULL AND dm_user2 IS NOT NULL;
CREATE INDEX IF NOT EXISTS chats_last_message_idx ON chats(last_message_at DESC);

CREATE TABLE IF NOT EXISTS chat_participants (
    chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_read_at TIMESTAMPTZ,
    PRIMARY KEY (chat_id, user_id)
);
CREATE INDEX IF NOT EXISTS chat_participants_user_idx ON chat_participants(user_id);

CREATE TABLE IF NOT EXISTS chat_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text', 'track_share')),
    encrypted_payload BYTEA NOT NULL,
    nonce BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS chat_messages_chat_time_idx ON chat_messages(chat_id, created_at DESC);

CREATE TABLE IF NOT EXISTS email_change_codes (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    new_email TEXT NOT NULL,
    code_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS qr_login_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nonce TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'pending',
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    token TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    client_ip TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS qr_login_sessions_nonce_idx ON qr_login_sessions(nonce);

CREATE TABLE IF NOT EXISTS login_2fa_challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    email_sent BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS login_2fa_challenges_user_idx ON login_2fa_challenges(user_id);
`
