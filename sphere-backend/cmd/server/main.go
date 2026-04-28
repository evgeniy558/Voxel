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

	"sphere-backend/internal/admin"
	"sphere-backend/internal/auth"
	"sphere-backend/internal/comments"
	"sphere-backend/internal/chat"
	"sphere-backend/internal/config"
	"sphere-backend/internal/db"
	"sphere-backend/internal/favorites"
	"sphere-backend/internal/history"
	"sphere-backend/internal/middleware"
	"sphere-backend/internal/music"
	"sphere-backend/internal/preferences"
	"sphere-backend/internal/provider"
	"sphere-backend/internal/recommend"
	"sphere-backend/internal/social"
	"sphere-backend/internal/uploads"
	"sphere-backend/internal/user"
)

// gitCommit is overridden at build-time via `-ldflags "-X main.gitCommit=<sha>"`.
// Falls back to the `RENDER_GIT_COMMIT` env var that Render exposes to all builds.
var gitCommit = ""

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
	commentsSvc, err := comments.NewService(pool, cfg)
	if err != nil {
		log.Fatal("comments init: ", err)
	}

	chatHub := chat.NewHub()
	chatSvc, err := chat.NewService(pool, cfg, chatHub)
	if err != nil {
		log.Fatal("chat init: ", err)
	}
	socialSvc := social.NewService(pool)

	// Handlers
	authH := auth.NewHandler(authSvc, cfg)
	accountH := auth.NewAccountHandler(authSvc, userSvc, uploadSvc, cfg)
	userH := user.NewHandler(userSvc)
	musicH := music.NewHandlerWithDB(musicSvc, pool, cfg.GeniusToken)
	favH := favorites.NewHandler(favSvc)
	uploadH := uploads.NewHandler(uploadSvc)
	historyH := history.NewHandler(historySvc)
	recommendH := recommend.NewHandler(recommendSvc)
	prefsH := preferences.NewHandler(prefsSvc)
	commentsH := comments.NewHandler(commentsSvc)
	socialH := social.NewHandler(socialSvc, favSvc, historySvc)
	chatH := chat.NewHandler(chatSvc, chatHub, cfg.JWTSecret)
	adminH := admin.NewHandler(pool)

	// Router
	r := chi.NewRouter()
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)
	r.Use(chimw.RealIP)
	r.Use(middleware.CORS([]string{
		"http://localhost:3001",
		"http://127.0.0.1:3001",
		"https://spheremusic.space",
		"https://www.spheremusic.space",
	}))

	r.Get("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"status":"ok"}`))
	})

	// /version exposes the build's git commit (set via -ldflags '-X main.gitCommit=<sha>'
	// or via the `RENDER_GIT_COMMIT` env var that Render injects automatically).
	// Useful for verifying which revision is actually running in production.
	r.Get("/version", func(w http.ResponseWriter, _ *http.Request) {
		commit := strings.TrimSpace(gitCommit)
		if commit == "" {
			commit = strings.TrimSpace(os.Getenv("RENDER_GIT_COMMIT"))
		}
		if commit == "" {
			commit = "unknown"
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"commit":"` + commit + `"}`))
	})

	// Auth (public)
	r.Get("/auth/public-config", authH.PublicConfig)
	r.Get("/auth/recaptcha-embed", authH.RecaptchaEmbedPage)
	r.Post("/auth/signup-code", authH.SendSignupCode)
	r.Post("/auth/register", authH.Register)
	r.Post("/auth/login", authH.Login)
	r.Post("/auth/2fa/verify", authH.TwoFactorVerify)
	r.Post("/auth/google", authH.Google)

	r.Post("/auth/qr/start", authH.QRLoginStart)
	r.Get("/auth/qr/poll", authH.QRLoginPoll)

	r.Get("/public/avatar/{userID}/{filename}", accountH.PublicAvatar)

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

	// Chat WebSocket (auth via ?token=JWT)
	r.Get("/ws", chatH.WS)

	// Protected routes (require JWT)
	r.Group(func(r chi.Router) {
		r.Use(middleware.JWTAuth(cfg.JWTSecret))

		r.Get("/user/me", userH.GetMe)
		r.Put("/user/me", userH.UpdateMe)

		r.Post("/account/change-password", accountH.ChangePassword)
		r.Post("/account/change-email/start", accountH.ChangeEmailStart)
		r.Post("/account/change-email/confirm", accountH.ChangeEmailConfirm)
		r.Post("/account/avatar", accountH.UploadAvatar)

		r.Post("/account/2fa/totp/setup", accountH.TOTPSetup)
		r.Post("/account/2fa/totp/enable", accountH.TOTPEnable)
		r.Post("/account/2fa/totp/disable", accountH.TOTPDisable)
		r.Post("/account/2fa/email/enable", accountH.Email2FAEnable)
		r.Post("/account/2fa/email/disable", accountH.Email2FADisable)
		r.Patch("/account/privacy", accountH.UpdatePrivacy)

		r.Post("/auth/qr/approve", authH.QRApprove)

		r.With(middleware.AdminOnly(pool)).Get("/admin/users", adminH.ListUsers)
		r.With(middleware.AdminOnly(pool)).Get("/admin/users/{id}", adminH.GetUser)
		r.With(middleware.AdminOnly(pool)).Post("/admin/users/{id}/ban", adminH.Ban)
		r.With(middleware.AdminOnly(pool)).Post("/admin/users/{id}/unban", adminH.Unban)
		r.With(middleware.AdminOnly(pool)).Put("/admin/users/{id}/verified", adminH.SetVerified)
		r.With(middleware.AdminOnly(pool)).Put("/admin/users/{id}/badge", adminH.SetBadge)

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

		// Social/profile
		r.Get("/users/search", socialH.SearchUsers)
		r.Get("/users/{id}/profile", socialH.GetProfile)
		r.Get("/users/{id}/favorites", socialH.GetUserFavorites)
		r.Get("/users/{id}/history", socialH.GetUserHistory)
		r.Get("/users/{id}/subscriptions", socialH.ListSubscriptions)
		r.Get("/users/{id}/subscribers", socialH.ListSubscribers)
		r.Post("/users/{id}/subscribe", socialH.Subscribe)
		r.Delete("/users/{id}/subscribe", socialH.Unsubscribe)

		r.Get("/me/subscription-requests", socialH.ListIncomingRequests)
		r.Post("/me/subscription-requests/{requestID}/approve", socialH.ApproveRequest)
		r.Post("/me/subscription-requests/{requestID}/deny", socialH.DenyRequest)

		// Chat REST
		r.Get("/chats", chatH.ListChats)
		r.Post("/chats", chatH.OpenOrCreateDM)
		r.Get("/chats/{id}/messages", chatH.ListMessages)
		r.Post("/chats/{id}/messages", chatH.SendMessage)
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
