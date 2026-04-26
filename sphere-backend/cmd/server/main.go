package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"

	"sphere-backend/internal/auth"
	"sphere-backend/internal/comments"
	"sphere-backend/internal/config"
	"sphere-backend/internal/db"
	"sphere-backend/internal/favorites"
	"sphere-backend/internal/history"
	"sphere-backend/internal/middleware"
	"sphere-backend/internal/music"
	"sphere-backend/internal/preferences"
	"sphere-backend/internal/provider"
	"sphere-backend/internal/recommend"
	"sphere-backend/internal/uploads"
	"sphere-backend/internal/user"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}

	ctx := context.Background()
	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatal("db connect: ", err)
	}
	defer pool.Close()

	if err := db.Migrate(ctx, pool); err != nil {
		log.Fatal("migrate: ", err)
	}

	// Services
	authSvc := auth.NewService(pool, cfg)
	userSvc := user.NewService(pool)
	favSvc := favorites.NewService(pool)
	historySvc := history.NewService(pool)

	s3Host := strings.TrimPrefix(strings.TrimPrefix(cfg.S3Endpoint, "https://"), "http://")
	uploadSvc, err := uploads.NewService(pool, s3Host, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket)
	if err != nil {
		log.Fatal("uploads init: ", err)
	}

	// Providers
	// VK and Yandex are intentionally disabled:
	//   - VK service-tokens don't grant the audio scope; the API returns a
	//     "Аудио доступно на vk.com" stub instead of real tracks.
	//   - Yandex Music geoblocks non-RU IPs (HTTP 451), so Render workers
	//     in the US/EU can never reach it.
	var spotifyRef *provider.Spotify
	var providers []provider.MusicProvider
	if cfg.SpotifyClientID != "" {
		sp := provider.NewSpotify(cfg.SpotifyClientID, cfg.SpotifySecret)
		spotifyRef = sp
		providers = append(providers, sp)
	}
	providers = append(providers, provider.NewYouTube(cfg.GeniusToken))
	if cfg.SoundCloudID != "" {
		providers = append(providers, provider.NewSoundCloud(cfg.SoundCloudID, cfg.SoundCloudSecret))
	}
	providers = append(providers, provider.NewDeezer(cfg.GeniusToken))
	musicSvc := music.NewService(providers...)
	music.SetGeniusToken(cfg.GeniusToken)
	prefsSvc := preferences.NewService(pool)
	recommendSvc := recommend.NewService(historySvc, musicSvc, prefsSvc, spotifyRef)
	commentsSvc, err := comments.NewService(pool, cfg.SoundCloudID)
	if err != nil {
		log.Fatal("comments init: ", err)
	}

	// Handlers
	authH := auth.NewHandler(authSvc, cfg)
	userH := user.NewHandler(userSvc)
	musicH := music.NewHandlerWithDB(musicSvc, pool, cfg.GeniusToken)
	favH := favorites.NewHandler(favSvc)
	uploadH := uploads.NewHandler(uploadSvc)
	historyH := history.NewHandler(historySvc)
	recommendH := recommend.NewHandler(recommendSvc)
	prefsH := preferences.NewHandler(prefsSvc)
	commentsH := comments.NewHandler(commentsSvc)

	// Router
	r := chi.NewRouter()
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)
	r.Use(chimw.RealIP)

	r.Get("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"status":"ok"}`))
	})

	// Auth (public)
	r.Get("/auth/public-config", authH.PublicConfig)
	r.Get("/auth/recaptcha-embed", authH.RecaptchaEmbedPage)
	r.Post("/auth/signup-code", authH.SendSignupCode)
	r.Post("/auth/register", authH.Register)
	r.Post("/auth/login", authH.Login)
	r.Post("/auth/google", authH.Google)

	// Music endpoints (public — no auth required for testing)
	r.Get("/search", musicH.Search)
	r.Get("/tracks/{provider}/{id}", musicH.GetTrack)
	r.Get("/tracks/{provider}/{id}/stream", musicH.GetTrackStream)
	r.Get("/tracks/{provider}/{id}/audio", musicH.ProxyStream)
	r.Get("/tracks/{provider}/{id}/audio/hq", musicH.ProxyStreamHQ)
	r.Get("/tracks/{provider}/{id}/lyrics", musicH.GetLyrics)
	r.With(middleware.OptionalJWTAuth(cfg.JWTSecret)).Get("/tracks/{provider}/{id}/comments", commentsH.List)
	r.Get("/lyrics", musicH.GetLyricsByName)
	r.Get("/artists/{provider}/{id}", musicH.GetArtist)
	r.Get("/artists/unified/{name}", musicH.GetUnifiedArtist)
	r.Get("/albums/{provider}/{id}", musicH.GetAlbum)
	r.Get("/playlists/{provider}/{id}", musicH.GetPlaylist)

	// Protected routes (require JWT)
	r.Group(func(r chi.Router) {
		r.Use(middleware.JWTAuth(cfg.JWTSecret))

		r.Get("/user/me", userH.GetMe)
		r.Put("/user/me", userH.UpdateMe)

		r.Get("/user/preferences", prefsH.Get)
		r.Post("/user/preferences", prefsH.Save)

		r.Get("/recommendations", recommendH.Get)
		r.Get("/daily-mixes", recommendH.DailyMixes)
		r.Get("/history", historyH.List)
		r.Post("/history", historyH.Record)

		r.Get("/favorites", favH.List)
		r.Post("/favorites", favH.Add)
		r.Delete("/favorites/{id}", favH.Delete)

		r.Post("/tracks/{provider}/{id}/comments", commentsH.Create)
		r.Post("/comments/{id}/vote", commentsH.Vote)
		r.Post("/lyrics", musicH.SubmitLyrics)

		r.Post("/uploads", uploadH.Upload)
		r.Get("/uploads", uploadH.List)
		r.Get("/uploads/{id}/stream", uploadH.Stream)
		r.Delete("/uploads/{id}", uploadH.Delete)
	})

	// Server
	srv := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: r,
	}

	go func() {
		log.Printf("Sphere API listening on :%s", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
	log.Println("Server stopped")
}
