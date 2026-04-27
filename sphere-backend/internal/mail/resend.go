package mail

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// SendSignupCode sends a one-time code via Resend (https://resend.com) when API key is set.
func SendSignupCode(ctx context.Context, apiKey, from, to, code string) error {
	apiKey = strings.TrimSpace(apiKey)
	if apiKey == "" {
		return ErrMailNotConfigured
	}
	body := map[string]any{
		"from":    from,
		"to":      []string{to},
		"subject": "Sphere: код для регистрации",
		"html":    fmt.Sprintf(`<p>Ваш код подтверждения: <b style="font-size:22px;letter-spacing:4px">%s</b></p><p>Код действителен 10 минут.</p>`, code),
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.resend.com/emails", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("resend: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		msg := strings.TrimSpace(string(b))
		if msg != "" {
			return fmt.Errorf("resend: status %d: %s", resp.StatusCode, msg)
		}
		return fmt.Errorf("resend: status %d", resp.StatusCode)
	}
	return nil
}

// SendEmailChangeCode emails a verification code when the user adds a new address.
func SendEmailChangeCode(ctx context.Context, apiKey, from, to, code string) error {
	apiKey = strings.TrimSpace(apiKey)
	if apiKey == "" {
		return ErrMailNotConfigured
	}
	body := map[string]any{
		"from":    from,
		"to":      []string{to},
		"subject": "Sphere: подтверждение новой почты",
		"html":    fmt.Sprintf(`<p>Код для привязки этого адреса: <b style="font-size:22px;letter-spacing:4px">%s</b></p><p>Действителен 10 минут.</p>`, code),
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.resend.com/emails", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("resend: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		msg := strings.TrimSpace(string(b))
		if msg != "" {
			return fmt.Errorf("resend: status %d: %s", resp.StatusCode, msg)
		}
		return fmt.Errorf("resend: status %d", resp.StatusCode)
	}
	return nil
}

// SendLoginOTP emails a short-lived login code when email 2FA is enabled.
func SendLoginOTP(ctx context.Context, apiKey, from, to, code string) error {
	apiKey = strings.TrimSpace(apiKey)
	if apiKey == "" {
		return ErrMailNotConfigured
	}
	body := map[string]any{
		"from":    from,
		"to":      []string{to},
		"subject": "Sphere: код для входа",
		"html":    fmt.Sprintf(`<p>Код для входа: <b style="font-size:22px;letter-spacing:4px">%s</b></p><p>Действителен 15 минут.</p>`, code),
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.resend.com/emails", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("resend: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		msg := strings.TrimSpace(string(b))
		if msg != "" {
			return fmt.Errorf("resend: status %d: %s", resp.StatusCode, msg)
		}
		return fmt.Errorf("resend: status %d", resp.StatusCode)
	}
	return nil
}

// ErrMailNotConfigured means RESEND_API_KEY is empty; caller can log the code instead.
var ErrMailNotConfigured = fmt.Errorf("mail not configured")
