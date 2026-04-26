package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

type GoogleTokenInfo struct {
	Sub       string `json:"sub"`
	Email     string `json:"email"`
	Name      string `json:"name"`
	Picture   string `json:"picture"`
	Aud       string `json:"aud"`
}

func VerifyGoogleToken(ctx context.Context, idToken, clientID string) (*GoogleTokenInfo, error) {
	resp, err := http.Get("https://oauth2.googleapis.com/tokeninfo?id_token=" + idToken)
	if err != nil {
		return nil, fmt.Errorf("verify google token: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("invalid google token")
	}

	var info GoogleTokenInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("decode token info: %w", err)
	}

	if clientID != "" && info.Aud != clientID {
		return nil, fmt.Errorf("token audience mismatch")
	}

	return &info, nil
}
