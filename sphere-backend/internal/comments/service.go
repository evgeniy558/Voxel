package comments

import (
	"context"
	"crypto/cipher"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"sphere-backend/internal/config"
	"sphere-backend/internal/crypto"
)

type Comment struct {
	ID            string    `json:"id"`
	TrackProvider string    `json:"track_provider"`
	TrackID       string    `json:"track_id"`
	UserID        string    `json:"user_id,omitempty"`
	UserName      string    `json:"user_name"`
	UserAvatarURL string    `json:"user_avatar_url"`
	Text          string    `json:"text"`
	ParentID      *string   `json:"parent_id,omitempty"`
	Likes         int       `json:"likes"`
	Dislikes      int       `json:"dislikes"`
	CreatedAt     time.Time `json:"created_at"`
	Source        string    `json:"source"`
	Replies       []Comment `json:"replies,omitempty"`
}

type Service struct {
	pool               *pgxpool.Pool
	gcm                cipher.AEAD
	soundCloudClientID string
	soundCloudBaseURL  string
	httpClient         *http.Client
	scResolver         *soundCloudIDResolver
}

func NewService(pool *pgxpool.Pool, cfg *config.Config) (*Service, error) {
	gcm, err := crypto.NewGCMFromHexKey(cfg.CommentEncryptionKey)
	if err != nil {
		return nil, fmt.Errorf("COMMENT_ENCRYPTION_KEY must be 64 hex chars (32 bytes)")
	}
	scClientID := strings.TrimSpace(cfg.SoundCloudID)
	httpClient := &http.Client{Timeout: 8 * time.Second}
	return &Service{
		pool:               pool,
		gcm:                gcm,
		soundCloudClientID: scClientID,
		soundCloudBaseURL:  "https://api-v2.soundcloud.com",
		httpClient:         httpClient,
		scResolver: &soundCloudIDResolver{
			fallback:   scClientID,
			httpClient: &http.Client{Timeout: 12 * time.Second},
			ttl:        12 * time.Hour,
		},
	}, nil
}

func (s *Service) encrypt(plaintext string) (ciphertext, nonce []byte, err error) {
	return crypto.EncryptString(s.gcm, plaintext)
}

func (s *Service) decrypt(ciphertext, nonce []byte) (string, error) {
	return crypto.DecryptToString(s.gcm, ciphertext, nonce)
}

func (s *Service) Create(ctx context.Context, trackProvider, trackID, userID, userName, avatarURL, text string, parentID *string) (*Comment, error) {
	ct, nonce, err := s.encrypt(text)
	if err != nil {
		return nil, err
	}

	var id string
	var createdAt time.Time
	err = s.pool.QueryRow(ctx,
		`INSERT INTO comments (track_provider, track_id, user_id, user_name, user_avatar_url, encrypted_text, nonce, parent_id)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		 RETURNING id, created_at`,
		trackProvider, trackID, userID, userName, avatarURL, ct, nonce, parentID,
	).Scan(&id, &createdAt)
	if err != nil {
		return nil, err
	}

	return &Comment{
		ID:            id,
		TrackProvider: trackProvider,
		TrackID:       trackID,
		UserID:        userID,
		UserName:      userName,
		UserAvatarURL: avatarURL,
		Text:          text,
		ParentID:      parentID,
		CreatedAt:     createdAt,
		Source:        "app",
	}, nil
}

func (s *Service) List(ctx context.Context, trackProvider, trackID string) ([]Comment, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, user_id, user_name, user_avatar_url, encrypted_text, nonce, parent_id, likes, dislikes, created_at
		 FROM comments WHERE track_provider = $1 AND track_id = $2
		 ORDER BY created_at ASC`,
		trackProvider, trackID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var all []Comment
	for rows.Next() {
		var c Comment
		var ct, nonce []byte
		var uid *string
		var parentID *string
		if err := rows.Scan(&c.ID, &uid, &c.UserName, &c.UserAvatarURL, &ct, &nonce, &parentID, &c.Likes, &c.Dislikes, &c.CreatedAt); err != nil {
			continue
		}
		if uid != nil {
			c.UserID = *uid
		}
		c.ParentID = parentID
		c.TrackProvider = trackProvider
		c.TrackID = trackID
		c.Source = "app"
		text, err := s.decrypt(ct, nonce)
		if err != nil {
			c.Text = "[encrypted]"
		} else {
			c.Text = text
		}
		all = append(all, c)
	}

	return nestReplies(all), nil
}

func (s *Service) ListSoundCloud(ctx context.Context, trackID string, limit int) ([]Comment, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}

	clientID := strings.TrimSpace(s.resolveSoundCloudClientID(ctx, false))
	if clientID == "" {
		log.Printf("[soundcloud-comments] no client_id available")
		return []Comment{}, nil
	}

	comments, status, err := s.fetchSoundCloudComments(ctx, trackID, limit, clientID)
	if err == nil {
		return comments, nil
	}

	// 401/403 — client_id протух. Форсим скрейп заново и пробуем ещё раз.
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		log.Printf("[soundcloud-comments] status=%d, refreshing client_id", status)
		fresh := strings.TrimSpace(s.resolveSoundCloudClientID(ctx, true))
		if fresh != "" && fresh != clientID {
			comments, status, err = s.fetchSoundCloudComments(ctx, trackID, limit, fresh)
			if err == nil {
				return comments, nil
			}
		}
	}

	if status != 0 {
		log.Printf("[soundcloud-comments] track=%s status=%d err=%v", trackID, status, err)
	} else {
		log.Printf("[soundcloud-comments] track=%s err=%v", trackID, err)
	}
	// На уровне API не возвращаем 5xx наружу — просто пусто, у iOS есть свой fallback.
	return []Comment{}, nil
}

func (s *Service) fetchSoundCloudComments(ctx context.Context, trackID string, limit int, clientID string) ([]Comment, int, error) {
	baseURL := strings.TrimRight(s.soundCloudBaseURL, "/")
	u, err := url.Parse(baseURL + "/tracks/" + url.PathEscape(trackID) + "/comments")
	if err != nil {
		return nil, 0, err
	}
	q := u.Query()
	q.Set("client_id", clientID)
	q.Set("limit", strconv.Itoa(limit))
	q.Set("offset", "0")
	q.Set("threaded", "0")
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Accept", "application/json, text/javascript, */*; q=0.01")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("Origin", "https://soundcloud.com")
	req.Header.Set("Referer", "https://soundcloud.com/")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

	client := s.httpClient
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, resp.StatusCode, fmt.Errorf("soundcloud comments status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var result struct {
		Collection []soundCloudComment `json:"collection"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, resp.StatusCode, err
	}

	comments := make([]Comment, 0, len(result.Collection))
	for _, sc := range result.Collection {
		createdAt := parseSoundCloudTime(sc.CreatedAt)
		if createdAt.IsZero() {
			createdAt = time.Now().UTC()
		}
		userName := strings.TrimSpace(sc.User.Username)
		if userName == "" {
			userName = "SoundCloud User"
		}
		comments = append(comments, Comment{
			ID:            fmt.Sprintf("sc-%d", sc.ID),
			TrackProvider: "soundcloud",
			TrackID:       trackID,
			UserName:      userName,
			UserAvatarURL: highResSoundCloudImage(sc.User.AvatarURL),
			Text:          sc.Body,
			CreatedAt:     createdAt,
			Source:        "soundcloud",
		})
	}
	return comments, resp.StatusCode, nil
}

// resolveSoundCloudClientID использует динамический resolver если он есть,
// иначе откатывается на статический soundCloudClientID (тесты конструируют Service без resolver).
func (s *Service) resolveSoundCloudClientID(ctx context.Context, forceRefresh bool) string {
	if s.scResolver != nil {
		return s.scResolver.Get(ctx, forceRefresh)
	}
	return strings.TrimSpace(s.soundCloudClientID)
}

// soundCloudIDResolver скрейпит реальный client_id со страницы soundcloud.com,
// потому что серверный SOUNDCLOUD_CLIENT_ID протухает (401/403) и DataDome душит отдельные ID.
type soundCloudIDResolver struct {
	mu         sync.Mutex
	clientID   string
	expiresAt  time.Time
	fallback   string // SOUNDCLOUD_CLIENT_ID из окружения, используется если скрейп ещё не успел
	httpClient *http.Client
	ttl        time.Duration
}

var (
	scScriptRe   = regexp.MustCompile(`<script[^>]+src="(https://[^"]+sndcdn\.com/[^"]+\.js)"`)
	scClientIDRe = regexp.MustCompile(`client_id\s*[:=]\s*"([0-9A-Za-z]{20,40})"`)
)

func (r *soundCloudIDResolver) Get(ctx context.Context, forceRefresh bool) string {
	r.mu.Lock()
	now := time.Now()
	if !forceRefresh && r.clientID != "" && now.Before(r.expiresAt) {
		id := r.clientID
		r.mu.Unlock()
		return id
	}
	cached := r.clientID
	r.mu.Unlock()

	scraped, err := r.scrape(ctx)
	if err == nil && scraped != "" {
		r.mu.Lock()
		r.clientID = scraped
		r.expiresAt = time.Now().Add(r.ttl)
		r.mu.Unlock()
		log.Printf("[soundcloud-comments] resolved fresh client_id (len=%d)", len(scraped))
		return scraped
	}
	if err != nil {
		log.Printf("[soundcloud-comments] client_id resolve failed: %v", err)
	}
	if cached != "" {
		return cached
	}
	return strings.TrimSpace(r.fallback)
}

func (r *soundCloudIDResolver) scrape(ctx context.Context) (string, error) {
	homeReq, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://soundcloud.com/", nil)
	if err != nil {
		return "", err
	}
	scBrowserHeaders(homeReq)
	resp, err := r.httpClient.Do(homeReq)
	if err != nil {
		return "", fmt.Errorf("home: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("home status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 5*1024*1024))
	if err != nil {
		return "", fmt.Errorf("home body: %w", err)
	}

	matches := scScriptRe.FindAllStringSubmatch(string(body), -1)
	if len(matches) == 0 {
		return "", fmt.Errorf("no SC bundle script tags found")
	}
	// client_id обычно в одном из последних бандлов (`app-*.js`) — идём с конца.
	seen := make(map[string]struct{}, len(matches))
	for i := len(matches) - 1; i >= 0; i-- {
		scriptURL := matches[i][1]
		if _, ok := seen[scriptURL]; ok {
			continue
		}
		seen[scriptURL] = struct{}{}
		id, err := r.fetchClientIDFromScript(ctx, scriptURL)
		if err != nil {
			continue
		}
		if id != "" {
			return id, nil
		}
	}
	return "", fmt.Errorf("client_id not found in %d SC bundle scripts", len(seen))
}

func (r *soundCloudIDResolver) fetchClientIDFromScript(ctx context.Context, src string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
	if err != nil {
		return "", err
	}
	scBrowserHeaders(req)
	resp, err := r.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("script status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024))
	if err != nil {
		return "", err
	}
	m := scClientIDRe.FindSubmatch(body)
	if m == nil {
		return "", nil
	}
	return string(m[1]), nil
}

func scBrowserHeaders(req *http.Request) {
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("Pragma", "no-cache")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
	req.Header.Set("Sec-Fetch-Dest", "document")
	req.Header.Set("Sec-Fetch-Mode", "navigate")
	req.Header.Set("Sec-Fetch-Site", "none")
	req.Header.Set("Upgrade-Insecure-Requests", "1")
}

type soundCloudComment struct {
	ID        int    `json:"id"`
	Body      string `json:"body"`
	Timestamp int    `json:"timestamp"`
	User      struct {
		Username  string `json:"username"`
		AvatarURL string `json:"avatar_url"`
	} `json:"user"`
	CreatedAt string `json:"created_at"`
}

func parseSoundCloudTime(raw string) time.Time {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006/01/02 15:04:05 +0000"} {
		t, err := time.Parse(layout, raw)
		if err == nil {
			return t
		}
	}
	return time.Time{}
}

func highResSoundCloudImage(raw string) string {
	if raw == "" {
		return ""
	}
	return strings.Replace(raw, "-large", "-t500x500", 1)
}

func nestReplies(flat []Comment) []Comment {
	byID := map[string]*Comment{}
	roots := make([]Comment, 0)
	for i := range flat {
		byID[flat[i].ID] = &flat[i]
	}
	for i := range flat {
		if flat[i].ParentID != nil {
			if parent, ok := byID[*flat[i].ParentID]; ok {
				parent.Replies = append(parent.Replies, flat[i])
				continue
			}
		}
		roots = append(roots, flat[i])
	}
	return roots
}

func (s *Service) Vote(ctx context.Context, userID, commentID, voteType string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var existing string
	err = tx.QueryRow(ctx,
		`SELECT vote_type FROM comment_votes WHERE user_id = $1 AND comment_id = $2`,
		userID, commentID,
	).Scan(&existing)

	if err == nil && existing == voteType {
		return nil
	}

	if err == nil {
		if existing == "like" {
			tx.Exec(ctx, `UPDATE comments SET likes = likes - 1 WHERE id = $1`, commentID)
		} else {
			tx.Exec(ctx, `UPDATE comments SET dislikes = dislikes - 1 WHERE id = $1`, commentID)
		}
		tx.Exec(ctx, `DELETE FROM comment_votes WHERE user_id = $1 AND comment_id = $2`, userID, commentID)
	}

	tx.Exec(ctx,
		`INSERT INTO comment_votes (user_id, comment_id, vote_type) VALUES ($1, $2, $3)`,
		userID, commentID, voteType,
	)
	if voteType == "like" {
		tx.Exec(ctx, `UPDATE comments SET likes = likes + 1 WHERE id = $1`, commentID)
	} else {
		tx.Exec(ctx, `UPDATE comments SET dislikes = dislikes + 1 WHERE id = $1`, commentID)
	}

	return tx.Commit(ctx)
}
