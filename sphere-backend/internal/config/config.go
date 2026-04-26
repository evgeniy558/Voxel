package config

import (
	"fmt"
	"os"
)

type Config struct {
	Port           string
	DatabaseURL    string
	JWTSecret      string
	GoogleClientID string
	// reCAPTCHA v3: https://developers.google.com/recaptcha/docs/v3
	RecaptchaSecret   string
	RecaptchaSiteKey  string
	RecaptchaMinScore float64
	// Resend: https://resend.com (signup verification email)
	ResendAPIKey     string
	MailFrom         string
	SignupLogCode    bool
	S3Endpoint       string
	S3AccessKey      string
	S3SecretKey      string
	S3Bucket         string
	SpotifyClientID  string
	SpotifySecret    string
	SoundCloudID     string
	SoundCloudSecret string
	VKToken          string
	YandexToken      string
	GeniusToken      string
}

func Load() (*Config, error) {
	cfg := &Config{
		Port:             getEnv("PORT", "8080"),
		DatabaseURL:      getEnv("DATABASE_URL", ""),
		JWTSecret:        getEnv("JWT_SECRET", ""),
		GoogleClientID:   getEnv("GOOGLE_CLIENT_ID", ""),
		S3Endpoint:       getEnv("S3_ENDPOINT", "http://localhost:9000"),
		S3AccessKey:      getEnv("S3_ACCESS_KEY", ""),
		S3SecretKey:      getEnv("S3_SECRET_KEY", ""),
		S3Bucket:         getEnv("S3_BUCKET", "sphere-uploads"),
		SpotifyClientID:  getEnv("SPOTIFY_CLIENT_ID", "57bb83e1ba584118ab3b8970e817dee4"),
		SpotifySecret:    getEnv("SPOTIFY_CLIENT_SECRET", "7073d08c99a34fc1abe3bcb5b2c08c1f"),
		SoundCloudID:     getEnv("SOUNDCLOUD_CLIENT_ID", "iuspDvaXDbD3AnFwLWK56Fk69q56xsKu"),
		SoundCloudSecret: getEnv("SOUNDCLOUD_CLIENT_SECRET", ""),
		VKToken:          getEnv("VK_SERVICE_TOKEN", "vk1.a.lm-8un_JtuwYfdPCboRYr_ZNPTisJlaSDrM4bDy_BAB_x_e5B8ytHmJxslmsTro0fgcz3DaiWOz_WzjlTAEdY0cwh2G4ybY9pda1-MDYEPzvu2XWUAqOR7vWwM7cFPGb7oCbSr-0jJih5Jx2BJQilc5yrEy5MuHcqNvdMo9TZMh_R0e9W7k60IQP-Cl2g9dIJHTJjvY69hox6lqx8_7nYg"),
		YandexToken:      getEnv("YANDEX_SERVICE_TOKEN", "y0__xCnx4f-Bhje-AYg19WehxcdBrdHfqxPPx2v5vOjqAxuTyubHA"),
		GeniusToken:      getEnv("GENIUS_TOKEN", "zTGbOmZjiWvldeVVVOMWAmmmAp0Aont38WMELq2DPqpihhThnVnj2o0FsZs9N30m"),
		RecaptchaSecret:  getEnv("RECAPTCHA_SECRET", "6LfytsssAAAAAKgi5g2SL6wU3B6qeUglw9YKJ6J9"),
		RecaptchaSiteKey: getEnv("RECAPTCHA_SITE_KEY", "6LfytsssAAAAAITYZm3exkx5ODWZ8c8Nd_nysOBj"),
		ResendAPIKey:     getEnv("RESEND_API_KEY", "re_u4Yu3Sqg_Md9pqwsAV6hufnKA2y73mMue"),
		MailFrom:         getEnv("MAIL_FROM", "Sphere <noreply@spheremusic.space>"),
	}

	rms := getEnv("RECAPTCHA_MIN_SCORE", "0.5")
	if _, err := fmt.Sscanf(rms, "%f", &cfg.RecaptchaMinScore); err != nil || cfg.RecaptchaMinScore <= 0 {
		cfg.RecaptchaMinScore = 0.5
	}
	if getEnv("SIGNUP_LOG_CODE", "false") == "true" {
		cfg.SignupLogCode = true
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSecret == "" {
		return nil, fmt.Errorf("JWT_SECRET is required")
	}

	return cfg, nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
