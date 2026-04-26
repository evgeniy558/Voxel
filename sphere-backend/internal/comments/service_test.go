package comments

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestListSoundCloudAddsThreadedParamAndMapsComments(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/tracks/257461491/comments" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		q := r.URL.Query()
		if q.Get("client_id") != "test-client" {
			t.Fatalf("client_id = %q", q.Get("client_id"))
		}
		if q.Get("threaded") != "0" {
			t.Fatalf("threaded = %q", q.Get("threaded"))
		}
		if q.Get("limit") != "3" {
			t.Fatalf("limit = %q", q.Get("limit"))
		}

		_ = json.NewEncoder(w).Encode(map[string]any{
			"collection": []map[string]any{
				{
					"id":         2528804948,
					"body":       "great track",
					"created_at": "2026-04-25T01:45:10Z",
					"user": map[string]any{
						"username":   "listener",
						"avatar_url": "https://i1.sndcdn.com/avatars-test-large.jpg",
					},
				},
			},
		})
	}))
	defer server.Close()

	svc := &Service{
		soundCloudClientID: "test-client",
		soundCloudBaseURL:  server.URL,
		httpClient:         server.Client(),
	}

	got, err := svc.ListSoundCloud(context.Background(), "257461491", 3)
	if err != nil {
		t.Fatalf("ListSoundCloud returned error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d comments, want 1", len(got))
	}
	comment := got[0]
	if comment.ID != "sc-2528804948" || comment.TrackProvider != "soundcloud" || comment.TrackID != "257461491" {
		t.Fatalf("unexpected comment identity: %#v", comment)
	}
	if comment.UserName != "listener" || comment.Text != "great track" || comment.Source != "soundcloud" {
		t.Fatalf("unexpected comment body: %#v", comment)
	}
	if comment.UserAvatarURL != "https://i1.sndcdn.com/avatars-test-t500x500.jpg" {
		t.Fatalf("avatar url = %q", comment.UserAvatarURL)
	}
}
