package uploads

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

type Upload struct {
	ID         string    `json:"id"`
	UserID     string    `json:"user_id"`
	Title      string    `json:"title"`
	ArtistName string    `json:"artist_name"`
	Duration   int       `json:"duration"`
	FileURL    string    `json:"file_url"`
	CoverURL   string    `json:"cover_url"`
	FileSize   int64     `json:"file_size"`
	CreatedAt  time.Time `json:"created_at"`
}

type Service struct {
	db     *pgxpool.Pool
	s3     *minio.Client
	bucket string
}

func NewService(db *pgxpool.Pool, s3Endpoint, accessKey, secretKey, bucket string) (*Service, error) {
	// S3 not configured — allow server to boot without uploads support.
	if s3Endpoint == "" || accessKey == "" || secretKey == "" {
		log.Printf("uploads: S3 not configured — upload endpoints will return errors")
		return &Service{db: db, s3: nil, bucket: bucket}, nil
	}

	client, err := minio.New(s3Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: false,
	})
	if err != nil {
		return nil, fmt.Errorf("init s3: %w", err)
	}

	ctx := context.Background()
	exists, err := client.BucketExists(ctx, bucket)
	if err != nil {
		log.Printf("uploads: bucket check failed (%v) — continuing without uploads", err)
		return &Service{db: db, s3: nil, bucket: bucket}, nil
	}
	if !exists {
		if err := client.MakeBucket(ctx, bucket, minio.MakeBucketOptions{}); err != nil {
			log.Printf("uploads: bucket create failed (%v) — continuing without uploads", err)
			return &Service{db: db, s3: nil, bucket: bucket}, nil
		}
	}

	return &Service{db: db, s3: client, bucket: bucket}, nil
}

func (s *Service) s3Required() error {
	if s.s3 == nil {
		return fmt.Errorf("uploads disabled: S3 not configured")
	}
	return nil
}

func (s *Service) Upload(ctx context.Context, userID, title, artistName, filename string, fileSize int64, reader io.Reader) (*Upload, error) {
	if err := s.s3Required(); err != nil {
		return nil, err
	}
	objectKey := fmt.Sprintf("%s/%d_%s", userID, time.Now().UnixMilli(), filename)

	_, err := s.s3.PutObject(ctx, s.bucket, objectKey, reader, fileSize, minio.PutObjectOptions{
		ContentType: "audio/mpeg",
	})
	if err != nil {
		return nil, fmt.Errorf("upload to s3: %w", err)
	}

	u := &Upload{}
	err = s.db.QueryRow(ctx,
		`INSERT INTO uploads (user_id, title, artist_name, file_url, file_size)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, user_id, title, artist_name, duration, file_url, cover_url, file_size, created_at`,
		userID, title, artistName, objectKey, fileSize,
	).Scan(&u.ID, &u.UserID, &u.Title, &u.ArtistName, &u.Duration, &u.FileURL, &u.CoverURL, &u.FileSize, &u.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("save upload: %w", err)
	}
	return u, nil
}

// UploadAvatar stores a profile image under avatars/{userID}/… and returns the object key.
func (s *Service) UploadAvatar(ctx context.Context, userID string, data []byte, contentType string) (string, error) {
	if err := s.s3Required(); err != nil {
		return "", err
	}
	contentType = strings.TrimSpace(strings.ToLower(contentType))
	ext := ".jpg"
	if strings.Contains(contentType, "png") {
		ext = ".png"
	} else if strings.Contains(contentType, "webp") {
		ext = ".webp"
	}
	objectKey := fmt.Sprintf("avatars/%s/%d%s", userID, time.Now().UnixMilli(), ext)
	ct := contentType
	if ct == "" {
		ct = "image/jpeg"
	}
	_, err := s.s3.PutObject(ctx, s.bucket, objectKey, bytes.NewReader(data), int64(len(data)), minio.PutObjectOptions{
		ContentType: ct,
	})
	if err != nil {
		return "", fmt.Errorf("upload avatar: %w", err)
	}
	return objectKey, nil
}

func (s *Service) GetObjectReader(ctx context.Context, objectKey string) (io.ReadCloser, string, error) {
	if err := s.s3Required(); err != nil {
		return nil, "", err
	}
	obj, err := s.s3.GetObject(ctx, s.bucket, objectKey, minio.GetObjectOptions{})
	if err != nil {
		return nil, "", err
	}
	return obj, objectKey, nil
}

func (s *Service) List(ctx context.Context, userID string) ([]Upload, error) {
	rows, err := s.db.Query(ctx,
		`SELECT id, user_id, title, artist_name, duration, file_url, cover_url, file_size, created_at
		 FROM uploads WHERE user_id = $1 ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var uploads []Upload
	for rows.Next() {
		var u Upload
		if err := rows.Scan(&u.ID, &u.UserID, &u.Title, &u.ArtistName, &u.Duration, &u.FileURL, &u.CoverURL, &u.FileSize, &u.CreatedAt); err != nil {
			return nil, err
		}
		uploads = append(uploads, u)
	}
	return uploads, nil
}

func (s *Service) Stream(ctx context.Context, userID, id string) (io.ReadCloser, string, error) {
	if err := s.s3Required(); err != nil {
		return nil, "", err
	}
	var fileURL string
	err := s.db.QueryRow(ctx,
		`SELECT file_url FROM uploads WHERE id = $1 AND user_id = $2`, id, userID,
	).Scan(&fileURL)
	if err != nil {
		return nil, "", fmt.Errorf("upload not found")
	}

	obj, err := s.s3.GetObject(ctx, s.bucket, fileURL, minio.GetObjectOptions{})
	if err != nil {
		return nil, "", fmt.Errorf("get object: %w", err)
	}
	return obj, fileURL, nil
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	var fileURL string
	err := s.db.QueryRow(ctx,
		`DELETE FROM uploads WHERE id = $1 AND user_id = $2 RETURNING file_url`, id, userID,
	).Scan(&fileURL)
	if err != nil {
		return fmt.Errorf("not found")
	}

	if s.s3 != nil {
		_ = s.s3.RemoveObject(ctx, s.bucket, fileURL, minio.RemoveObjectOptions{})
	}
	return nil
}
