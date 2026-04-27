package social

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{db: db}
}

func normalizeQuery(q string) string {
	q = strings.TrimSpace(q)
	q = strings.ToLower(q)
	return q
}

func (s *Service) SearchUsers(ctx context.Context, q string, limit int) ([]UserListItem, error) {
	q = normalizeQuery(q)
	if q == "" {
		return []UserListItem{}, nil
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}

	like := "%" + q + "%"
	rows, err := s.db.Query(ctx, `
		SELECT id, username, name, avatar_url, is_verified, badge_text, badge_color, private_profile
		FROM users
		WHERE banned = false
		  AND (
			lower(username) LIKE $1
			OR lower(name) LIKE $1
		  )
		ORDER BY
		  (lower(username) = $2) DESC,
		  (lower(name) = $2) DESC,
		  length(username) ASC,
		  length(name) ASC,
		  created_at DESC
		LIMIT $3
	`, like, q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []UserListItem
	for rows.Next() {
		var u UserListItem
		if err := rows.Scan(&u.ID, &u.Username, &u.Name, &u.AvatarURL, &u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.PrivateProfile); err != nil {
			continue
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Service) GetProfile(ctx context.Context, viewerID, targetID string) (*ProfileResponse, error) {
	// Fetch target basics + privacy flags.
	var u UserListItem
	var hideSubs bool
	var messagesMutualOnly bool
	var privateProfile bool

	err := s.db.QueryRow(ctx, `
		SELECT id, username, name, avatar_url, is_verified, badge_text, badge_color,
		       hide_subscriptions, messages_mutual_only, private_profile
		FROM users
		WHERE id = $1 AND banned = false
	`, targetID).Scan(
		&u.ID, &u.Username, &u.Name, &u.AvatarURL, &u.IsVerified, &u.BadgeText, &u.BadgeColor,
		&hideSubs, &messagesMutualOnly, &privateProfile,
	)
	if err != nil {
		return nil, fmt.Errorf("user not found")
	}
	u.PrivateProfile = privateProfile

	// Subscription status.
	var isSubscribed bool
	_ = s.db.QueryRow(ctx, `
		SELECT EXISTS(
		  SELECT 1 FROM subscriptions WHERE follower_id = $1 AND followee_id = $2
		)
	`, viewerID, targetID).Scan(&isSubscribed)

	// Request status (if any).
	var reqStatus string
	err = s.db.QueryRow(ctx, `
		SELECT status
		FROM subscription_requests
		WHERE requester_id = $1 AND target_id = $2
		ORDER BY created_at DESC
		LIMIT 1
	`, viewerID, targetID).Scan(&reqStatus)
	if err == pgx.ErrNoRows {
		reqStatus = "none"
	} else if err != nil {
		reqStatus = "none"
	}

	// Privacy gate.
	hasAccess := true
	if privateProfile && viewerID != targetID {
		// Access only if already subscribed (approved) or request was approved.
		hasAccess = isSubscribed || reqStatus == "approved"
	}

	stats := ProfileStats{}
	if hasAccess {
		// Monthly listens (last 30 days).
		_ = s.db.QueryRow(ctx, `
			SELECT COUNT(*) FROM listen_history
			WHERE user_id = $1 AND listened_at > (now() - interval '30 days')
		`, targetID).Scan(&stats.MonthlyListens)

		_ = s.db.QueryRow(ctx, `SELECT COUNT(*) FROM subscriptions WHERE followee_id = $1`, targetID).Scan(&stats.SubscribersCount)
		_ = s.db.QueryRow(ctx, `SELECT COUNT(*) FROM subscriptions WHERE follower_id = $1`, targetID).Scan(&stats.SubscriptionsCount)
	}

	canMessage := !messagesMutualOnly
	if messagesMutualOnly && viewerID != targetID {
		// Allow messaging only if target has messaged viewer before in their DM.
		var hasMsg bool
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
		`, viewerID, targetID).Scan(&hasMsg)
		canMessage = hasMsg
	}

	resp := &ProfileResponse{
		User:              u,
		Stats:             stats,
		IsSubscribed:      isSubscribed,
		RequestStatus:     reqStatus,
		HideSubscriptions: hideSubs,
		PrivateProfile:    privateProfile,
		RequiresApproval:  privateProfile && viewerID != targetID && !hasAccess,
		CanMessage:        canMessage && !respRequiresApproval(privateProfile, viewerID, targetID, hasAccess),
	}

	// If private and no access: return minimal profile (keep CTA + flags).
	if resp.RequiresApproval {
		resp.Stats = ProfileStats{}
	}

	return resp, nil
}

func respRequiresApproval(privateProfile bool, viewerID, targetID string, hasAccess bool) bool {
	return privateProfile && viewerID != targetID && !hasAccess
}

func (s *Service) ListSubscriptions(ctx context.Context, viewerID, targetID string) (any, error) {
	var hidden bool
	if err := s.db.QueryRow(ctx, `SELECT hide_subscriptions FROM users WHERE id = $1`, targetID).Scan(&hidden); err != nil {
		return nil, fmt.Errorf("not found")
	}
	if hidden && viewerID != targetID {
		return HiddenListResponse{Hidden: true}, nil
	}

	rows, err := s.db.Query(ctx, `
		SELECT u.id, u.username, u.name, u.avatar_url, u.is_verified, u.badge_text, u.badge_color, u.private_profile
		FROM subscriptions s
		JOIN users u ON u.id = s.followee_id
		WHERE s.follower_id = $1
		ORDER BY s.created_at DESC
		LIMIT 200
	`, targetID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []UserListItem
	for rows.Next() {
		var u UserListItem
		if err := rows.Scan(&u.ID, &u.Username, &u.Name, &u.AvatarURL, &u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.PrivateProfile); err != nil {
			continue
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Service) ListSubscribers(ctx context.Context, viewerID, targetID string) (any, error) {
	var hidden bool
	if err := s.db.QueryRow(ctx, `SELECT hide_subscriptions FROM users WHERE id = $1`, targetID).Scan(&hidden); err != nil {
		return nil, fmt.Errorf("not found")
	}
	if hidden && viewerID != targetID {
		return HiddenListResponse{Hidden: true}, nil
	}

	rows, err := s.db.Query(ctx, `
		SELECT u.id, u.username, u.name, u.avatar_url, u.is_verified, u.badge_text, u.badge_color, u.private_profile
		FROM subscriptions s
		JOIN users u ON u.id = s.follower_id
		WHERE s.followee_id = $1
		ORDER BY s.created_at DESC
		LIMIT 200
	`, targetID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []UserListItem
	for rows.Next() {
		var u UserListItem
		if err := rows.Scan(&u.ID, &u.Username, &u.Name, &u.AvatarURL, &u.IsVerified, &u.BadgeText, &u.BadgeColor, &u.PrivateProfile); err != nil {
			continue
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Service) Subscribe(ctx context.Context, viewerID, targetID string) (string, error) {
	if viewerID == targetID {
		return "ok", nil
	}

	var privateProfile bool
	if err := s.db.QueryRow(ctx, `SELECT private_profile FROM users WHERE id = $1 AND banned = false`, targetID).Scan(&privateProfile); err != nil {
		return "", fmt.Errorf("not found")
	}

	if privateProfile {
		// Create (or reuse) a pending request.
		var id string
		err := s.db.QueryRow(ctx, `
			INSERT INTO subscription_requests (requester_id, target_id, status)
			VALUES ($1, $2, 'pending')
			ON CONFLICT DO NOTHING
			RETURNING id
		`, viewerID, targetID).Scan(&id)
		if err == pgx.ErrNoRows {
			return "pending", nil
		}
		if err != nil {
			return "", err
		}
		return "pending", nil
	}

	_, err := s.db.Exec(ctx, `
		INSERT INTO subscriptions (follower_id, followee_id)
		VALUES ($1, $2)
		ON CONFLICT DO NOTHING
	`, viewerID, targetID)
	if err != nil {
		return "", err
	}
	return "subscribed", nil
}

func (s *Service) Unsubscribe(ctx context.Context, viewerID, targetID string) error {
	_, _ = s.db.Exec(ctx, `DELETE FROM subscriptions WHERE follower_id = $1 AND followee_id = $2`, viewerID, targetID)
	_, _ = s.db.Exec(ctx, `
		UPDATE subscription_requests
		SET status = 'cancelled'
		WHERE requester_id = $1 AND target_id = $2 AND status = 'pending'
	`, viewerID, targetID)
	return nil
}

func (s *Service) ListIncomingRequests(ctx context.Context, userID string) ([]SubscriptionRequestItem, error) {
	rows, err := s.db.Query(ctx, `
		SELECT r.id, r.status, r.created_at,
		       u.id, u.username, u.name, u.avatar_url, u.is_verified, u.badge_text, u.badge_color, u.private_profile
		FROM subscription_requests r
		JOIN users u ON u.id = r.requester_id
		WHERE r.target_id = $1 AND r.status = 'pending'
		ORDER BY r.created_at DESC
		LIMIT 200
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]SubscriptionRequestItem, 0)
	for rows.Next() {
		var it SubscriptionRequestItem
		if err := rows.Scan(
			&it.ID, &it.Status, &it.CreatedAt,
			&it.Requester.ID, &it.Requester.Username, &it.Requester.Name, &it.Requester.AvatarURL,
			&it.Requester.IsVerified, &it.Requester.BadgeText, &it.Requester.BadgeColor, &it.Requester.PrivateProfile,
		); err != nil {
			continue
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

func (s *Service) ApproveRequest(ctx context.Context, userID, requestID string) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var requesterID string
	var targetID string
	var status string
	err = tx.QueryRow(ctx, `
		SELECT requester_id, target_id, status
		FROM subscription_requests
		WHERE id = $1
	`, requestID).Scan(&requesterID, &targetID, &status)
	if err != nil {
		return fmt.Errorf("not found")
	}
	if targetID != userID {
		return fmt.Errorf("forbidden")
	}
	if status != "pending" {
		return nil
	}

	_, err = tx.Exec(ctx, `UPDATE subscription_requests SET status = 'approved' WHERE id = $1`, requestID)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO subscriptions (follower_id, followee_id)
		VALUES ($1, $2)
		ON CONFLICT DO NOTHING
	`, requesterID, targetID)
	if err != nil {
		return err
	}

	return tx.Commit(ctx)
}

func (s *Service) DenyRequest(ctx context.Context, userID, requestID string) error {
	ct, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var targetID string
	var status string
	err := s.db.QueryRow(ct, `
		SELECT target_id, status
		FROM subscription_requests
		WHERE id = $1
	`, requestID).Scan(&targetID, &status)
	if err != nil {
		return fmt.Errorf("not found")
	}
	if targetID != userID {
		return fmt.Errorf("forbidden")
	}
	if status != "pending" {
		return nil
	}
	_, err = s.db.Exec(ct, `UPDATE subscription_requests SET status = 'denied' WHERE id = $1`, requestID)
	return err
}

