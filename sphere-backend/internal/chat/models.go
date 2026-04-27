package chat

import "time"

type ThreadUser struct {
	ID        string `json:"id"`
	Username  string `json:"username"`
	Name      string `json:"name"`
	AvatarURL string `json:"avatar_url"`

	IsVerified bool   `json:"is_verified"`
	BadgeText  string `json:"badge_text"`
	BadgeColor string `json:"badge_color"`
}

type Message struct {
	ID        string    `json:"id"`
	ChatID    string    `json:"chat_id"`
	SenderID  string    `json:"sender_id"`
	Kind      string    `json:"kind"` // text | track_share
	Text      string    `json:"text,omitempty"`
	Payload   any       `json:"payload,omitempty"` // for track_share
	CreatedAt time.Time `json:"created_at"`
}

type Thread struct {
	ID            string     `json:"id"`
	OtherUser     ThreadUser `json:"other_user"`
	LastMessage   *Message   `json:"last_message,omitempty"`
	LastMessageAt *time.Time `json:"last_message_at,omitempty"`
}

type SendMessageRequest struct {
	Kind    string          `json:"kind"`
	Text    string          `json:"text,omitempty"`
	Payload any             `json:"payload,omitempty"`
}

type WSMessageEvent struct {
	Type    string  `json:"type"`
	Message Message `json:"message"`
}

