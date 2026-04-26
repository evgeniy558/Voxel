package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// VerifyRecaptchaV3 calls Google siteverify. See https://developers.google.com/recaptcha/docs/v3
func VerifyRecaptchaV3(ctx context.Context, secret, token, remoteIP string, minScore float64) error {
	secret = strings.TrimSpace(secret)
	if secret == "" {
		return nil
	}
	if strings.TrimSpace(token) == "" {
		return fmt.Errorf("recaptcha token required")
	}
	form := url.Values{}
	form.Set("secret", secret)
	form.Set("response", token)
	if remoteIP != "" {
		form.Set("remoteip", remoteIP)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://www.google.com/recaptcha/api/siteverify", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("recaptcha request: %w", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var out struct {
		Success    bool     `json:"success"`
		Score      float64  `json:"score"`
		Action     string   `json:"action"`
		ErrorCodes []string `json:"error-codes"`
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return fmt.Errorf("recaptcha decode: %w", err)
	}
	if !out.Success {
		return fmt.Errorf("recaptcha failed: %v", out.ErrorCodes)
	}
	if out.Score < minScore {
		return fmt.Errorf("recaptcha score too low: %.2f (min %.2f)", out.Score, minScore)
	}
	return nil
}
