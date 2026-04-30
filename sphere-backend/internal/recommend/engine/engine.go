// Package engine implements preference-driven recommendations (seed builder,
// collaborative filter, per-provider quota, audio-features sequence scoring).
package engine

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"sync"
	"time"

	"sphere-backend/internal/favorites"
	"sphere-backend/internal/history"
	"sphere-backend/internal/model"
	"sphere-backend/internal/music"
	"sphere-backend/internal/preferences"
	"sphere-backend/internal/provider"
)

// Deps is wired from cmd/server.
type Deps struct {
	Spotify   *provider.Spotify
	Music     *music.Service
	History   *history.Service
	Prefs     *preferences.Service
	Favorites *favorites.Service
}

// providerOrder is used for round-robin quota filling across catalog sources.
var providerOrder = []string{"spotify", "deezer", "youtube", "soundcloud"}

// seedGenreExpand maps onboarding genre labels to neutral search terms (no “hits / trending”).
var seedGenreExpand = map[string][]string{
	"Pop":         {"dance pop", "synth pop", "indie pop"},
	"Rock":        {"rock", "alternative rock", "indie rock"},
	"Hip-Hop":     {"hip hop", "rap", "trap"},
	"R&B":         {"r&b", "soul", "neo soul"},
	"Electronic":  {"electronic", "edm", "house music"},
	"Jazz":        {"jazz", "smooth jazz", "jazz fusion"},
	"Classical":   {"classical", "piano classical", "orchestra"},
	"Metal":       {"metal", "heavy metal", "metalcore"},
	"Indie":       {"indie", "indie pop", "indie folk"},
	"K-Pop":       {"k-pop", "korean pop"},
	"Latin":       {"latin", "reggaeton", "latin pop"},
	"Country":     {"country", "country pop", "americana"},
	"Reggaeton":   {"reggaeton", "latin trap", "dembow"},
	"Lo-Fi":       {"lo-fi", "lofi hip hop", "chill beats"},
	"Punk":        {"punk rock", "pop punk", "punk"},
	"Русский рэп": {"русский рэп", "российский хип-хоп", "рэп"},
	"Поп":         {"русский поп", "поп музыка"},
	"Рок":         {"русский рок", "рок музыка"},
}

const (
	maxSeedQueries   = 48
	searchPerQuery   = 12
	searchTimeout    = 8 * time.Second
	targetTrackCount = 30
)

// Run builds personalized /recommendations using multi-provider search + collaborative filter.
func Run(ctx context.Context, d *Deps, userID, lang string) (*model.RecommendationFeed, error) {
	if d == nil || d.Music == nil {
		return nil, errors.New("no music service")
	}
	isRU := strings.Contains(strings.ToLower(lang), "ru")

	queries := buildSearchQueries(ctx, d, userID, isRU)
	if len(queries) == 0 {
		return nil, errors.New("no seed queries")
	}

	skipKeys, _ := d.History.SkipProneTracks(ctx, userID, 60, 2, 0.6)
	skipSet := make(map[string]struct{}, len(skipKeys))
	for _, k := range skipKeys {
		if k.Provider != "" && k.TrackID != "" {
			skipSet[k.Provider+":"+k.TrackID] = struct{}{}
		}
	}

	searchCtx, cancelSearch := context.WithTimeout(ctx, searchTimeout)
	defer cancelSearch()

	var mu sync.Mutex
	var wg sync.WaitGroup
	trackPool := make([]model.Track, 0, 256)

	for _, q := range queries {
		q := q
		wg.Add(1)
		go func() {
			defer wg.Done()
			res := d.Music.Search(searchCtx, q, searchPerQuery, "")
			if res == nil {
				return
			}
			mu.Lock()
			defer mu.Unlock()
			for _, t := range res.Tracks {
				if strings.TrimSpace(t.CoverURL) == "" {
					continue
				}
				key := t.Provider + ":" + t.ID
				if _, bad := skipSet[key]; bad {
					continue
				}
				trackPool = append(trackPool, t)
			}
		}()
	}
	wg.Wait()

	if peers, err := d.History.PeerInfluencedTracks(ctx, userID, 20); err == nil {
		trackPool = appendKeys(ctx, d.Music, trackPool, peers)
		for _, k := range peers {
			if k.Provider != "" && k.TrackID != "" {
				delete(skipSet, k.Provider+":"+k.TrackID)
			}
		}
	}

	trackPool = filterSkipSet(trackPool, skipSet)
	trackPool = uniqueTracks(trackPool)
	trackPool = dedupeByArtistTitle(trackPool)

	primaryGenre := "pop"
	if pref, _ := d.Prefs.Get(ctx, userID); pref != nil && len(pref.SelectedGenres) > 0 {
		if sg, ok := spotifySafeGenre[pref.SelectedGenres[0]]; ok {
			primaryGenre = sg
		}
	}

	if d.Spotify != nil {
		trackPool = sortBySpotifyAudioScore(ctx, d.Spotify, trackPool, primaryGenre)
	}
	trackPool = fillByProviderQuota(trackPool, targetTrackCount)

	// Final cover-dedupe cap (unique artwork rail)
	trackList := capAndDedupeCovers(trackPool, targetTrackCount)

	albums := buildAlbumArtistRails(ctx, d, queries[:minInt(12, len(queries))])

	return &model.RecommendationFeed{
		Tracks:  trackList,
		Albums:  albums.albums,
		Artists: albums.artists,
	}, nil
}

type albumArtistRails struct {
	albums  []model.Album
	artists []model.Artist
}

func buildAlbumArtistRails(ctx context.Context, d *Deps, queries []string) albumArtistRails {
	out := albumArtistRails{
		albums:  make([]model.Album, 0, 20),
		artists: make([]model.Artist, 0, 20),
	}
	albumSeen := map[string]struct{}{}
	artistSeen := map[string]struct{}{}

	sctx, cancel := context.WithTimeout(ctx, searchTimeout)
	defer cancel()

	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, q := range queries {
		q := q
		wg.Add(1)
		go func() {
			defer wg.Done()
			res := d.Music.Search(sctx, q, 10, "")
			if res == nil {
				return
			}
			mu.Lock()
			defer mu.Unlock()
			for _, al := range res.Albums {
				k := al.Provider + ":" + al.ID
				if _, ok := albumSeen[k]; ok || al.CoverURL == "" {
					continue
				}
				albumSeen[k] = struct{}{}
				out.albums = append(out.albums, al)
			}
			for _, a := range res.Artists {
				k := a.Provider + ":" + a.ID
				if _, ok := artistSeen[k]; ok || a.ImageURL == "" {
					continue
				}
				artistSeen[k] = struct{}{}
				out.artists = append(out.artists, a)
			}
		}()
	}
	wg.Wait()

	out.albums = fillByProviderQuotaGeneric(out.albums, func(a model.Album) string { return a.Provider }, 15)
	out.artists = fillByProviderQuotaGeneric(out.artists, func(a model.Artist) string { return a.Provider }, 15)
	return out
}

func buildSearchQueries(ctx context.Context, d *Deps, userID string, isRU bool) []string {
	seen := map[string]struct{}{}
	var out []string
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" {
			return
		}
		key := strings.ToLower(s)
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		out = append(out, s)
	}

	pref, _ := d.Prefs.Get(ctx, userID)
	if pref != nil && pref.OnboardingCompleted {
		for _, a := range pref.SelectedArtists {
			a = strings.TrimSpace(a)
			if a == "" {
				continue
			}
			add(a)
			add(a + " album")
		}
		for _, g := range pref.SelectedGenres {
			if terms, ok := seedGenreExpand[g]; ok {
				for _, t := range terms {
					add(t)
				}
			} else {
				add(g)
			}
		}
	}

	if tops, _ := d.History.TopArtists(ctx, userID, 6); len(tops) > 0 {
		for _, a := range tops {
			add(a)
		}
	}
	if tg, _ := d.History.TopGenres(ctx, userID, 5); len(tg) > 0 {
		for _, g := range tg {
			add(g)
		}
	}
	if d.Favorites != nil {
		if favs, _ := d.Favorites.TopArtists(ctx, userID, 6); len(favs) > 0 {
			for _, a := range favs {
				add(a)
			}
		}
	}

	// Expand seeds with related artist names only (metadata), not “Spotify recommendations” tracks.
	if d.Spotify != nil && pref != nil && len(pref.SelectedArtists) > 0 {
		for i, name := range pref.SelectedArtists {
			if i >= 2 || len(out) >= maxSeedQueries {
				break
			}
			name = strings.TrimSpace(name)
			if name == "" {
				continue
			}
			id, err := d.Spotify.ResolveArtistID(ctx, name)
			if err != nil {
				continue
			}
			rel, err := d.Spotify.GetRelatedArtists(ctx, id)
			if err != nil {
				continue
			}
			for j, a := range rel {
				if j >= 4 || len(out) >= maxSeedQueries {
					break
				}
				add(a.Name)
			}
		}
	}

	if len(out) == 0 {
		neutralEN := []string{"indie rock", "electronic music", "jazz", "hip hop", "synth pop", "alternative rock", "soul music", "neo soul"}
		neutralRU := []string{"инди рок", "электронная музыка", "джаз", "хип-хоп", "синт-поп", "альтернативный рок", "русский рэп", "соул"}
		list := neutralEN
		if isRU {
			list = neutralRU
		}
		for _, q := range list {
			add(q)
		}
	}

	if len(out) > maxSeedQueries {
		out = out[:maxSeedQueries]
	}
	return out
}

func filterSkipSet(in []model.Track, skip map[string]struct{}) []model.Track {
	if len(skip) == 0 {
		return in
	}
	out := in[:0]
	for _, t := range in {
		k := t.Provider + ":" + t.ID
		if _, bad := skip[k]; bad {
			continue
		}
		out = append(out, t)
	}
	return out
}

func dedupeByArtistTitle(in []model.Track) []model.Track {
	seen := map[string]struct{}{}
	out := make([]model.Track, 0, len(in))
	for _, t := range in {
		ka := strings.ToLower(strings.TrimSpace(t.Artist))
		kt := strings.ToLower(strings.TrimSpace(t.Title))
		if ka == "" || kt == "" {
			out = append(out, t)
			continue
		}
		key := ka + "|" + kt
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, t)
	}
	return out
}

func fillByProviderQuota(tracks []model.Track, target int) []model.Track {
	return fillByProviderQuotaGeneric(tracks, func(t model.Track) string { return t.Provider }, target)
}

func fillByProviderQuotaGeneric[T any](items []T, providerFn func(T) string, target int) []T {
	if len(items) == 0 || target <= 0 {
		return nil
	}
	buckets := make(map[string][]T)
	for _, it := range items {
		p := strings.TrimSpace(providerFn(it))
		if p == "" {
			p = "_"
		}
		buckets[p] = append(buckets[p], it)
	}

	out := make([]T, 0, target)
	for len(out) < target {
		progress := false
		for _, p := range providerOrder {
			if len(buckets[p]) > 0 {
				out = append(out, buckets[p][0])
				buckets[p] = buckets[p][1:]
				progress = true
				if len(out) >= target {
					break
				}
			}
		}
		if !progress {
			break
		}
	}
	// Deterministic pass: known providers, then any extra provider keys.
	if len(out) < target {
		for _, p := range providerOrder {
			for len(buckets[p]) > 0 && len(out) < target {
				out = append(out, buckets[p][0])
				buckets[p] = buckets[p][1:]
			}
		}
	}
	if len(out) < target {
		for p, b := range buckets {
			_ = p
			for len(b) > 0 && len(out) < target {
				out = append(out, b[0])
				b = b[1:]
			}
			buckets[p] = b
		}
	}
	return out
}

// spotifySafeGenre maps app genre labels to Spotify seed_genres (audio-features only).
var spotifySafeGenre = map[string]string{
	"Pop": "pop", "Rock": "rock", "Hip-Hop": "hip-hop", "R&B": "r-n-b",
	"Electronic": "electronic", "Jazz": "jazz", "Classical": "classical", "Metal": "metal",
	"Indie": "indie", "K-Pop": "k-pop", "Latin": "latin", "Country": "country",
	"Reggaeton": "reggaeton", "Punk": "punk", "Lo-Fi": "sleep", "Dance": "dance",
	"Soul": "soul", "Folk": "folk", "Blues": "blues",
	"Русский рэп": "hip-hop", "Поп": "pop", "Рок": "rock",
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

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// DailyMixes returns four scored sequence variants (30 tracks each).
func DailyMixes(ctx context.Context, d *Deps, userID, lang string) ([]model.DailyMix, error) {
	if d == nil {
		return nil, errors.New("no deps")
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

	var feat map[string]model.AudioFeatures
	if d.Spotify != nil {
		ids := make([]string, 0, 30)
		for _, t := range pool {
			if t.Provider == "spotify" {
				ids = append(ids, t.ID)
			}
		}
		if len(ids) > 0 {
			if len(ids) > 100 {
				ids = ids[:100]
			}
			feat, _ = d.Spotify.AudioFeatures(ctx, ids)
		}
	}

	mixes := make([]model.DailyMix, 0, 4)
	for m := 0; m < 4; m++ {
		seedName := pool[(m*3)%len(pool)].Title
		variant := make([]model.Track, len(pool))
		copy(variant, pool)
		rng.Shuffle(len(variant), func(i, j int) { variant[i], variant[j] = variant[j], variant[i] })
		ordered := orderForContinuity(variant, feat, rng)
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

func orderForContinuity(tracks []model.Track, feat map[string]model.AudioFeatures, rng *rand.Rand) []model.Track {
	if len(tracks) <= 1 {
		return tracks
	}
	if feat == nil || len(feat) == 0 {
		out := append([]model.Track(nil), tracks...)
		rng.Shuffle(len(out), func(i, j int) { out[i], out[j] = out[j], out[i] })
		return out
	}
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
				bestI = rng.Intn(len(remaining))
				break
			}
			fl, oka := feat[last.ID]
			ft, okb := feat[t.ID]
			if !oka || !okb {
				bestI = rng.Intn(len(remaining))
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
