package model

type Track struct {
	ID         string   `json:"id"`
	Provider   string   `json:"provider"`
	Title      string   `json:"title"`
	Artist     string   `json:"artist"`
	Album      string   `json:"album,omitempty"`
	CoverURL   string   `json:"cover_url,omitempty"`
	Duration   int      `json:"duration"`
	StreamURL  string   `json:"stream_url,omitempty"`
	PreviewURL string   `json:"preview_url,omitempty"`
	ClipURL    string   `json:"clip_url,omitempty"`
	Genres     []string `json:"genres,omitempty"`
	PlayCount  int64    `json:"play_count,omitempty"`
}

type Artist struct {
	ID               string   `json:"id"`
	Provider         string   `json:"provider"`
	Name             string   `json:"name"`
	ImageURL         string   `json:"image_url,omitempty"`
	MonthlyListeners int64    `json:"monthly_listeners,omitempty"`
	Followers        int64    `json:"followers,omitempty"`
	Genres           []string `json:"genres,omitempty"`
	Tracks           []Track  `json:"tracks,omitempty"`
	Albums           []Album  `json:"albums,omitempty"`
}

type Album struct {
	ID       string  `json:"id"`
	Provider string  `json:"provider"`
	Title    string  `json:"title"`
	Artist   string  `json:"artist"`
	CoverURL string  `json:"cover_url,omitempty"`
	Tracks   []Track `json:"tracks,omitempty"`
}

type Playlist struct {
	ID       string  `json:"id"`
	Provider string  `json:"provider"`
	Title    string  `json:"title"`
	CoverURL string  `json:"cover_url,omitempty"`
	Tracks   []Track `json:"tracks,omitempty"`
}

type Lyrics struct {
	TrackID  string `json:"track_id"`
	Provider string `json:"provider"`
	Text     string `json:"text"`
}

type SearchResult struct {
	Tracks    []Track    `json:"tracks"`
	Artists   []Artist   `json:"artists"`
	Albums    []Album    `json:"albums"`
	Playlists []Playlist `json:"playlists"`
}

// AudioFeatures mirrors Spotify /v1/audio-features (subset used for scoring).
type AudioFeatures struct {
	ID            string  `json:"id"`
	Danceability  float64 `json:"danceability"`
	Energy        float64 `json:"energy"`
	Speechiness   float64 `json:"speechiness"`
	Acousticness  float64 `json:"acousticness"`
	Instrumentalness float64 `json:"instrumentalness"`
	Valence       float64 `json:"valence"`
	Tempo         float64 `json:"tempo"`
}

// DailyMix is a named bundle of tracks (e.g. “Daily Mix 1”).
type DailyMix struct {
	Name     string  `json:"name"`
	Seed     string  `json:"seed,omitempty"`
	CoverURL string  `json:"cover_url,omitempty"`
	Tracks   []Track `json:"tracks"`
}

// RecommendationFeed is the /recommendations JSON payload.
type RecommendationFeed struct {
	Tracks  []Track  `json:"tracks"`
	Albums  []Album  `json:"albums"`
	Artists []Artist `json:"artists"`
}
