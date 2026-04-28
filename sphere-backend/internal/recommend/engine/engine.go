// Package engine implements Spotify-style recommendations (seeds, audio-features,
// collaborative and trending signals, Daily Mixes).
package engine

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"time"

	"sphere-backend/internal/history"
	"sphere-backend/internal/model"
	"sphere-backend/internal/music"
	"sphere-backend/internal/preferences"
	"sphere-backend/internal/provider"
)

// Deps is wired from cmd/server.
type Deps struct {
	Spotify *provider.Spotify
	Music   *music.Service
	History *history.Service
	Prefs   *preferences.Service
}

// spotifySafeGenre maps app genre labels to valid Spotify seed_genres.
var spotifySafeGenre = map[string]string{
	"Pop":         "pop",
	"Rock":        "rock",
	"Hip-Hop":     "hip-hop",
	"R&B":         "r-n-b",
	"Electronic":  "electronic",
	"Jazz":        "jazz",
	"Classical":   "classical",
	"Metal":       "metal",
	"Indie":       "indie",
	"K-Pop":       "k-pop",
	"Latin":       "latin",
	"Country":     "country",
	"Reggaeton":   "reggaeton",
	"Punk":        "punk",
	"Lo-Fi":       "sleep",
	"Dance":       "dance",
	"Soul":        "soul",
	"Folk":        "folk",
	"Blues":       "blues",
	"Русский рэп": "hip-hop",
	"Поп":         "pop",
	"Рок":         "rock",
}

// Run builds personalized /recommendations when Spotify is configured.
func Run(ctx context.Context, d *Deps, userID, lang string) (*model.RecommendationFeed, error) {
	if d == nil || d.Spotify == nil {
		return nil, errors.New("no spotify")
	}
	isRU := strings.Contains(strings.ToLower(lang), "ru")
	pref, _ := d.Prefs.Get(ctx, userID)

	var artistNames []string
	if pref != nil && pref.OnboardingCompleted {
		artistNames = append(artistNames, pref.SelectedArtists...)
	}
	if len(artistNames) < 2 {
		top, _ := d.History.TopArtists(ctx, userID, 5)
		artistNames = append(artistNames, top...)
	}
	if len(artistNames) == 0 {
		if isRU {
			artistNames = []string{"Miyagi", "Scriptonite"}
		} else {
			artistNames = []string{"The Weeknd", "Taylor Swift"}
		}
	}

	const maxSpotifyRecBatches = 10
	const maxResolvedSeeds = 16

	seedArtists := make([]string, 0, maxResolvedSeeds)
	seenA := map[string]struct{}{}
	for _, name := range artistNames {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		if len(seedArtists) >= maxResolvedSeeds {
			break
		}
		id, err := d.Spotify.ResolveArtistID(ctx, name)
		if err != nil {
			continue
		}
		if _, ok := seenA[id]; ok {
			continue
		}
		seenA[id] = struct{}{}
		seedArtists = append(seedArtists, id)
	}
	if len(seedArtists) < 1 {
		return nil, errors.New("could not resolve artist seeds")
	}

	seedTrack, _ := d.History.LastSpotifyTrackID(ctx, userID)
	seedT := strings.TrimSpace(seedTrack)

	seedGenres := make([]string, 0, 16)
	seenG := map[string]struct{}{}
	if pref != nil {
		for _, g := range pref.SelectedGenres {
			sg, ok := spotifySafeGenre[g]
			if !ok {
				continue
			}
			if _, dup := seenG[sg]; dup {
				continue
			}
			seenG[sg] = struct{}{}
			seedGenres = append(seedGenres, sg)
		}
	}
	if len(seedGenres) < 1 {
		seedGenres = append(seedGenres, "pop", "dance")
	}

	trackList := make([]model.Track, 0, 120)
	ai, gi := 0, 0
	trackUsedInBatch := false
	for b := 0; b < maxSpotifyRecBatches; b++ {
		var a, g, st []string
		rem := 5
		if b == 0 && seedT != "" && !trackUsedInBatch {
			st = []string{seedT}
			rem = 4
			trackUsedInBatch = true
			for rem > 0 && ai < len(seedArtists) {
				if len(a) < 2 {
					a = append(a, seedArtists[ai])
					ai++
					rem--
					continue
				}
				break
			}
			for rem > 0 && gi < len(seedGenres) {
				if len(g) < 2 {
					g = append(g, seedGenres[gi])
					gi++
					rem--
					continue
				}
				break
			}
		} else {
			for rem > 0 && ai < len(seedArtists) {
				if len(a) < 3 {
					a = append(a, seedArtists[ai])
					ai++
					rem--
					continue
				}
				break
			}
			for rem > 0 && gi < len(seedGenres) {
				if len(g) < 2 {
					g = append(g, seedGenres[gi])
					gi++
					rem--
					continue
				}
				break
			}
			for rem > 0 && ai < len(seedArtists) {
				a = append(a, seedArtists[ai])
				ai++
				rem--
			}
			for rem > 0 && gi < len(seedGenres) {
				g = append(g, seedGenres[gi])
				gi++
				rem--
			}
		}
		if len(a)+len(g)+len(st) == 0 {
			break
		}
		part, err := d.Spotify.GetRecommendations(ctx, a, st, g, 25)
		if err != nil {
			if b == 0 {
				return nil, err
			}
			break
		}
		trackList = append(trackList, part...)
		if ai >= len(seedArtists) && gi >= len(seedGenres) {
			break
		}
	}

	// Related: take top tracks from a few related artists per seed (capped to limit Spotify calls).
	relN := 2
	if len(seedArtists) < relN {
		relN = len(seedArtists)
	}
	for si := 0; si < relN; si++ {
		if rel, err := d.Spotify.GetRelatedArtists(ctx, seedArtists[si]); err == nil {
			for i, a := range rel {
				if i >= 4 {
					break
				}
				appendArtistTop(ctx, d.Spotify, &trackList, a.ID, 2)
			}
		}
	}

	topN := 5
	if len(seedArtists) < topN {
		topN = len(seedArtists)
	}
	for i := 0; i < topN; i++ {
		n := 4
		if i == 0 {
			n = 5
		}
		appendArtistTop(ctx, d.Spotify, &trackList, seedArtists[i], n)
	}

	// Collaborative & trending
	if peers, err := d.History.PeerInfluencedTracks(ctx, userID, 15); err == nil {
		trackList = appendKeys(ctx, d.Music, trackList, peers)
	}
	if trends, err := d.History.TrendingTracks(ctx, 15); err == nil {
		trackList = appendKeys(ctx, d.Music, trackList, trends)
	}

	trackList = uniqueTracks(trackList)
	trackList = sortBySpotifyAudioScore(ctx, d.Spotify, trackList, seedGenres[0])
	trackList = capAndDedupeCovers(trackList, 30)

	// Albums: search per artist
	albums := make([]model.Album, 0, 15)
	albumSeen := map[string]struct{}{}
	for _, a := range artistNames {
		if len(albums) >= 15 {
			break
		}
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		res := d.Music.Search(ctx, a+" album", 4, "spotify")
		if res == nil {
			continue
		}
		for _, al := range res.Albums {
			k := al.Provider + ":" + al.ID
			if _, ok := albumSeen[k]; ok {
				continue
			}
			if al.CoverURL == "" {
				continue
			}
			albumSeen[k] = struct{}{}
			albums = append(albums, al)
			if len(albums) >= 15 {
				break
			}
		}
	}
	if len(albums) < 5 {
		query := fmt.Sprintf("album hits %d", time.Now().Year())
		res := d.Music.Search(ctx, query, 20, "spotify")
		if res != nil {
			for _, al := range res.Albums {
				k := al.Provider + ":" + al.ID
				if _, ok := albumSeen[k]; ok {
					continue
				}
				if al.CoverURL == "" {
					continue
				}
				albumSeen[k] = struct{}{}
				albums = append(albums, al)
				if len(albums) >= 15 {
					break
				}
			}
		}
	}

	// Artist rail: related from several seeds, then name search (not just the first pick).
	artists := make([]model.Artist, 0, 15)
	artistSeen := map[string]struct{}{}
	relSeedsN := 3
	if len(seedArtists) < relSeedsN {
		relSeedsN = len(seedArtists)
	}
	for si := 0; si < relSeedsN; si++ {
		if rel, err := d.Spotify.GetRelatedArtists(ctx, seedArtists[si]); err == nil {
			for i, a := range rel {
				if i >= 4 {
					break
				}
				k := a.Provider + ":" + a.ID
				if _, ok := artistSeen[k]; ok || a.ImageURL == "" {
					continue
				}
				artistSeen[k] = struct{}{}
				artists = append(artists, a)
				if len(artists) >= 15 {
					break
				}
			}
		}
		if len(artists) >= 12 {
			break
		}
	}
	if len(artists) < 5 {
		for _, an := range artistNames {
			an = strings.TrimSpace(an)
			if an == "" {
				continue
			}
			res := d.Music.Search(ctx, an, 5, "spotify")
			if res == nil {
				continue
			}
			for _, a := range res.Artists {
				k := a.Provider + ":" + a.ID
				if _, ok := artistSeen[k]; ok || a.ImageURL == "" {
					continue
				}
				artistSeen[k] = struct{}{}
				artists = append(artists, a)
				if len(artists) >= 15 {
					break
				}
			}
			if len(artists) >= 12 {
				break
			}
		}
	}
	artists = capSlice(artists, 15)

	return &model.RecommendationFeed{
		Tracks:  trackList,
		Albums:  albums,
		Artists: artists,
	}, nil
}

func appendArtistTop(ctx context.Context, sp *provider.Spotify, out *[]model.Track, artistID string, n int) []model.Track {
	top, err := sp.GetArtistTopTracks(ctx, artistID, "US")
	if err != nil {
		return *out
	}
	for i, t := range top {
		if i >= n {
			break
		}
		*out = append(*out, t)
	}
	return *out
}

func appendKeys(ctx context.Context, m *music.Service, cur []model.Track, keys []history.TrackKey) []model.Track {
	for _, k := range keys {
		if k.Provider == "" || k.TrackID == "" {
			continue
		}
		tr, err := m.GetTrack(ctx, k.Provider, k.TrackID)
		if err != nil || tr == nil {
			continue
		}
		if tr.CoverURL == "" {
			continue
		}
		cur = append(cur, *tr)
	}
	return cur
}

func uniqueTracks(in []model.Track) []model.Track {
	seen := map[string]struct{}{}
	var out []model.Track
	for _, t := range in {
		if t.ID == "" {
			continue
		}
		k := t.Provider + ":" + t.ID
		if _, ok := seen[k]; ok {
			continue
		}
		seen[k] = struct{}{}
		out = append(out, t)
	}
	if len(out) == 0 {
		return in
	}
	return out
}

func sortBySpotifyAudioScore(ctx context.Context, sp *provider.Spotify, tracks []model.Track, primaryGenre string) []model.Track {
	var spotifyIDs []string
	for _, t := range tracks {
		if t.Provider == "spotify" {
			spotifyIDs = append(spotifyIDs, t.ID)
		}
	}
	if len(spotifyIDs) == 0 {
		return tracks
	}
	ids := spotifyIDs
	if len(ids) > 100 {
		ids = ids[:100]
	}
	feat, err := sp.AudioFeatures(ctx, ids)
	if err != nil || len(feat) == 0 {
		return tracks
	}
	type pair struct {
		t model.Track
		s float64
	}
	var scored []pair
	for _, t := range tracks {
		if t.Provider != "spotify" {
			scored = append(scored, pair{t, 0.5})
			continue
		}
		f, ok := feat[t.ID]
		if !ok {
			scored = append(scored, pair{t, 0.3})
			continue
		}
		s := f.Valence*0.4 + f.Energy*0.4 + f.Danceability*0.2
		_ = primaryGenre
		scored = append(scored, pair{t, s})
	}
	sort.Slice(scored, func(i, j int) bool { return scored[i].s > scored[j].s })
	out := make([]model.Track, 0, len(scored))
	for _, x := range scored {
		out = append(out, x.t)
	}
	return out
}

func capAndDedupeCovers(in []model.Track, max int) []model.Track {
	seen := map[string]struct{}{}
	var out []model.Track
	for _, t := range in {
		u := strings.TrimSpace(t.CoverURL)
		if u == "" {
			continue
		}
		if _, ok := seen[u]; ok {
			continue
		}
		seen[u] = struct{}{}
		out = append(out, t)
		if len(out) >= max {
			break
		}
	}
	if len(out) < max/2 && len(in) > 0 {
		// not enough unique covers — return deduped by id only
		seen2 := map[string]struct{}{}
		out2 := in[:0:0]
		for _, t := range in {
			k := t.Provider + ":" + t.ID
			if _, ok := seen2[k]; ok {
				continue
			}
			seen2[k] = struct{}{}
			out2 = append(out2, t)
			if len(out2) >= max {
				break
			}
		}
		return out2
	}
	return out
}

func capSlice[T any](in []T, max int) []T {
	if len(in) > max {
		return in[:max]
	}
	return in
}

// DailyMixes returns four scored sequence variants (30 tracks each).
func DailyMixes(ctx context.Context, d *Deps, userID, lang string) ([]model.DailyMix, error) {
	if d == nil || d.Spotify == nil {
		return nil, errors.New("no spotify")
	}
	feed, err := Run(ctx, d, userID, lang)
	if err != nil {
		return nil, err
	}
	if len(feed.Tracks) < 10 {
		return nil, fmt.Errorf("not enough tracks for daily mixes: %d", len(feed.Tracks))
	}
	pool := feed.Tracks
	if len(pool) > 50 {
		pool = pool[:50]
	}
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	ids := make([]string, 0, 30)
	for _, t := range pool {
		if t.Provider == "spotify" {
			ids = append(ids, t.ID)
		}
	}
	if len(ids) < 5 {
		return nil, errors.New("not enough spotify tracks for mixes")
	}
	feat, _ := d.Spotify.AudioFeatures(ctx, ids)

	mixes := make([]model.DailyMix, 0, 4)
	for m := 0; m < 4; m++ {
		seedName := pool[(m*3)%len(pool)].Title
		variant := make([]model.Track, len(pool))
		copy(variant, pool)
		// small shuffle for diversity
		rng.Shuffle(len(variant), func(i, j int) { variant[i], variant[j] = variant[j], variant[i] })
		ordered := orderForContinuity(variant, feat)
		if len(ordered) > 30 {
			ordered = ordered[:30]
		}
		if len(ordered) < 20 {
			ordered = pool
			if len(ordered) > 30 {
				ordered = ordered[:30]
			}
		}
		cover := ""
		if len(ordered) > 0 {
			cover = ordered[0].CoverURL
		}
		mixes = append(mixes, model.DailyMix{
			Name:     fmt.Sprintf("Daily Mix %d", m+1),
			Seed:     seedName,
			CoverURL: cover,
			Tracks:   ordered,
		})
	}
	return mixes, nil
}

func orderForContinuity(tracks []model.Track, feat map[string]model.AudioFeatures) []model.Track {
	if len(tracks) <= 1 {
		return tracks
	}
	// Greedy TSP on first track: always pick next with closest energy+tempo
	remaining := append([]model.Track(nil), tracks...)
	out := make([]model.Track, 0, len(tracks))
	out = append(out, remaining[0])
	remaining = remaining[1:]

	for len(remaining) > 0 && len(out) < 35 {
		last := out[len(out)-1]
		bestI := 0
		bestScore := 1e9
		for i, t := range remaining {
			if last.Provider != "spotify" || t.Provider != "spotify" {
				bestI = i
				break
			}
			fl, oka := feat[last.ID]
			ft, okb := feat[t.ID]
			if !oka || !okb {
				bestI = i
				break
			}
			d := absf(fl.Energy-ft.Energy) + absf((fl.Tempo-ft.Tempo)/40)
			if d < bestScore {
				bestScore = d
				bestI = i
			}
		}
		out = append(out, remaining[bestI])
		remaining = append(remaining[:bestI], remaining[bestI+1:]...)
	}
	return out
}

func absf(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}
