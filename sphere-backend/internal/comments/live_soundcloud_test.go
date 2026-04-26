package comments

import (
	"context"
	"net/http"
	"os"
	"testing"
	"time"
)

// Live integration test (opt-in):
// RUN_SC_LIVE=1 TRACK_ID=<numeric> go test ./internal/comments -run TestLiveSoundCloudComments -v
func TestLiveSoundCloudComments(t *testing.T) {
	if os.Getenv("RUN_SC_LIVE") != "1" {
		t.Skip("set RUN_SC_LIVE=1 to run")
	}
	trackID := os.Getenv("TRACK_ID")
	if trackID == "" {
		trackID = "308946187"
	}

	svc := &Service{
		soundCloudBaseURL: "https://api-v2.soundcloud.com",
		httpClient:        nil, // use default
		scResolver: &soundCloudIDResolver{
			httpClient: &http.Client{Timeout: 12 * time.Second},
			ttl:        12 * time.Hour,
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	clientID := svc.resolveSoundCloudClientID(ctx, true)
	if clientID == "" {
		t.Fatalf("could not resolve soundcloud client_id")
	}

	comments, status, err := svc.fetchSoundCloudComments(ctx, trackID, 10, clientID)
	if err != nil {
		t.Fatalf("fetchSoundCloudComments status=%d err=%v", status, err)
	}
	if len(comments) == 0 {
		t.Fatalf("0 comments returned for track %s (try another TRACK_ID)", trackID)
	}
	c := comments[0]
	t.Logf("first comment: user=%q avatar=%q text=%q created_at=%s",
		c.UserName, c.UserAvatarURL, c.Text, c.CreatedAt.Format(time.RFC3339))
	if c.UserName == "" || c.Text == "" {
		t.Fatalf("missing fields: %#v", c)
	}
}

