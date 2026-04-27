package chat

import (
	"context"
	"crypto/cipher"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"sphere-backend/internal/config"
	"sphere-backend/internal/crypto"
)

type Service struct {
	db  *pgxpool.Pool
	gcm cipher.AEAD
	hub *Hub
}

func NewService(db *pgxpool.Pool, cfg *config.Config, hub *Hub) (*Service, error) {
	gcm, err := crypto.NewGCMFromHexKey(cfg.ChatMessageKey)
	if err != nil {
		return nil, fmt.Errorf("CHAT_MESSAGE_KEY must be 64 hex chars (32 bytes)")
	}
	return &Service{db: db, gcm: gcm, hub: hub}, nil
}

func (s *Service) ListThreads(ctx context.Context, userID string) ([]Thread, error) {
	rows, err := s.db.Query(ctx, `
		SELECT c.id, c.dm_user1, c.dm_user2, c.last_message_at,
		       u.id, u.username, u.name, u.avatar_url, u.is_verified, u.badge_text, u.badge_color
		FROM chats c
		JOIN users u ON u.id = CASE WHEN c.dm_user1 = $1 THEN c.dm_user2 ELSE c.dm_user1 END
		WHERE c.kind = 'dm' AND (c.dm_user1 = $1 OR c.dm_user2 = $1)
		ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
		LIMIT 200
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]Thread, 0)
	for rows.Next() {
		var t Thread
		var dm1, dm2 string
		if err := rows.Scan(
			&t.ID, &dm1, &dm2, &t.LastMessageAt,
			&t.OtherUser.ID, &t.OtherUser.Username, &t.OtherUser.Name, &t.OtherUser.AvatarURL,
			&t.OtherUser.IsVerified, &t.OtherUser.BadgeText, &t.OtherUser.BadgeColor,
		); err != nil {
			continue
		}
		// Load last message (optional).
		msg, _ := s.getLastMessage(ctx, t.ID)
		if msg != nil {
			t.LastMessage = msg
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Service) getLastMessage(ctx context.Context, chatID string) (*Message, error) {
	var m Message
	var ct, nonce []byte
	var created time.Time
	err := s.db.QueryRow(ctx, `
		SELECT id, chat_id, sender_id, kind, encrypted_payload, nonce, created_at
		FROM chat_messages
		WHERE chat_id = $1 AND deleted_at IS NULL
		ORDER BY created_at DESC
		LIMIT 1
	`, chatID).Scan(&m.ID, &m.ChatID, &m.SenderID, &m.Kind, &ct, &nonce, &created)
	if err != nil {
		return nil, err
	}
	m.CreatedAt = created
	if err := s.fillDecrypted(&m, ct, nonce); err != nil {
		m.Text = "[encrypted]"
	}
	return &m, nil
}

func (s *Service) OpenOrCreateDM(ctx context.Context, viewerID, otherUserID string) (string, error) {
	if viewerID == otherUserID {
		return "", fmt.Errorf("invalid")
	}

	// Enforce messages_mutual_only: if otherUser requires it, they must have messaged viewer before.
	var mutualOnly bool
	if err := s.db.QueryRow(ctx, `SELECT messages_mutual_only FROM users WHERE id = $1 AND banned = false`, otherUserID).Scan(&mutualOnly); err != nil {
		return "", fmt.Errorf("not found")
	}
	if mutualOnly {
		var ok bool
		_ = s.db.QueryRow(ctx, `
			SELECT EXISTS(
			  SELECT 1
			  FROM chats c
			  JOIN chat_messages m ON m.chat_id = c.id
			  WHERE c.kind = 'dm'
			    AND ((c.dm_user1 = $1 AND c.dm_user2 = $2) OR (c.dm_user1 = $2 AND c.dm_user2 = $1))
			    AND m.sender_id = $2
			    AND m.deleted_at IS NULL
			)
		`, viewerID, otherUserID).Scan(&ok)
		if !ok {
			return "", fmt.Errorf("messaging not allowed")
		}
	}

	u1, u2 := viewerID, otherUserID
	if u2 < u1 {
		u1, u2 = u2, u1
	}

	// Try find existing.
	var chatID string
	err := s.db.QueryRow(ctx, `
		SELECT id FROM chats
		WHERE kind = 'dm' AND dm_user1 = $1 AND dm_user2 = $2
	`, u1, u2).Scan(&chatID)
	if err == nil {
		return chatID, nil
	}
	if err != pgx.ErrNoRows {
		return "", err
	}

	// Create new.
	err = s.db.QueryRow(ctx, `
		INSERT INTO chats (kind, dm_user1, dm_user2)
		VALUES ('dm', $1, $2)
		RETURNING id
	`, u1, u2).Scan(&chatID)
	if err != nil {
		return "", err
	}
	_, _ = s.db.Exec(ctx, `
		INSERT INTO chat_participants (chat_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING
	`, chatID, viewerID)
	_, _ = s.db.Exec(ctx, `
		INSERT INTO chat_participants (chat_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING
	`, chatID, otherUserID)
	return chatID, nil
}

func (s *Service) ListMessages(ctx context.Context, userID, chatID string, before time.Time, limit int) ([]Message, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if before.IsZero() {
		before = time.Now().Add(24 * time.Hour)
	}

	// Ensure participant.
	var ok bool
	_ = s.db.QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM chat_participants WHERE chat_id = $1 AND user_id = $2)
	`, chatID, userID).Scan(&ok)
	if !ok {
		return nil, fmt.Errorf("forbidden")
	}

	rows, err := s.db.Query(ctx, `
		SELECT id, chat_id, sender_id, kind, encrypted_payload, nonce, created_at
		FROM chat_messages
		WHERE chat_id = $1 AND deleted_at IS NULL AND created_at < $2
		ORDER BY created_at DESC
		LIMIT $3
	`, chatID, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]Message, 0)
	for rows.Next() {
		var m Message
		var ct, nonce []byte
		if err := rows.Scan(&m.ID, &m.ChatID, &m.SenderID, &m.Kind, &ct, &nonce, &m.CreatedAt); err != nil {
			continue
		}
		_ = s.fillDecrypted(&m, ct, nonce)
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Service) SendMessage(ctx context.Context, senderID, chatID string, req SendMessageRequest) (*Message, []string, error) {
	// Ensure participant and get participant ids.
	rows, err := s.db.Query(ctx, `
		SELECT user_id FROM chat_participants WHERE chat_id = $1
	`, chatID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	var participants []string
	isParticipant := false
	for rows.Next() {
		var uid string
		if err := rows.Scan(&uid); err != nil {
			continue
		}
		participants = append(participants, uid)
		if uid == senderID {
			isParticipant = true
		}
	}
	if !isParticipant {
		return nil, nil, fmt.Errorf("forbidden")
	}

	if req.Kind != "text" && req.Kind != "track_share" {
		return nil, nil, fmt.Errorf("invalid kind")
	}

	payloadStr := ""
	if req.Kind == "text" {
		payloadStr = req.Text
		if strings.TrimSpace(payloadStr) == "" {
			return nil, nil, fmt.Errorf("empty")
		}
	} else {
		b, _ := json.Marshal(req.Payload)
		payloadStr = string(b)
	}

	ct, nonce, err := crypto.EncryptString(s.gcm, payloadStr)
	if err != nil {
		return nil, nil, err
	}

	var id string
	var createdAt time.Time
	err = s.db.QueryRow(ctx, `
		INSERT INTO chat_messages (chat_id, sender_id, kind, encrypted_payload, nonce)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at
	`, chatID, senderID, req.Kind, ct, nonce).Scan(&id, &createdAt)
	if err != nil {
		return nil, nil, err
	}

	_, _ = s.db.Exec(ctx, `UPDATE chats SET last_message_at = $2 WHERE id = $1`, chatID, createdAt)

	m := &Message{
		ID:        id,
		ChatID:    chatID,
		SenderID:  senderID,
		Kind:      req.Kind,
		CreatedAt: createdAt,
	}
	if req.Kind == "text" {
		m.Text = payloadStr
	} else {
		var anyPayload any
		_ = json.Unmarshal([]byte(payloadStr), &anyPayload)
		m.Payload = anyPayload
	}

	return m, participants, nil
}

func (s *Service) fillDecrypted(m *Message, ct, nonce []byte) error {
	plain, err := crypto.DecryptToString(s.gcm, ct, nonce)
	if err != nil {
		return err
	}
	if m.Kind == "text" {
		m.Text = plain
		return nil
	}
	var p any
	if err := json.Unmarshal([]byte(plain), &p); err != nil {
		m.Text = plain
		return nil
	}
	m.Payload = p
	return nil
}

