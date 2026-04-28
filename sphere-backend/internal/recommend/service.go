package recommend

import (
	"context"
	"errors"
	"log"
	"math/rand"
	"sort"
	"strings"
	"sync"

	"sphere-backend/internal/history"
	"sphere-backend/internal/model"
	"sphere-backend/internal/music"
	"sphere-backend/internal/preferences"
	"sphere-backend/internal/provider"
	"sphere-backend/internal/recommend/engine"
)

// Cold-start queries avoid year-centric “hits” strings so the feed doesn’t look like generic charts.
var coldStartEN = []string{"trending pop", "indie rock", "chill vibes", "electronic beats", "alternative rock"}
var coldStartRU = []string{"русский рэп", "популярная музыка", "инди рок", "электронная музыка", "альтернативный рок"}

var genreRelated = map[string][]string{
	"Pop":         {"pop hits", "dance pop", "synth pop"},
	"Rock":        {"rock", "alternative rock", "indie rock"},
	"Hip-Hop":     {"hip hop", "rap", "trap"},
	"R&B":         {"r&b", "soul", "neo soul"},
	"Electronic":  {"electronic", "edm", "house music"},
	"Jazz":        {"jazz", "smooth jazz", "jazz fusion"},
	"Classical":   {"classical", "piano classical", "orchestra"},
	"Metal":       {"metal", "heavy metal", "metalcore"},
	"Indie":       {"indie", "indie pop", "indie folk"},
	"K-Pop":       {"k-pop", "korean pop", "kpop hits"},
	"Latin":       {"latin", "reggaeton", "latin pop"},
	"Country":     {"country", "country pop", "americana"},
	"Reggaeton":   {"reggaeton", "latin trap", "dembow"},
	"Lo-Fi":       {"lo-fi", "lofi hip hop", "chill beats"},
	"Punk":        {"punk rock", "pop punk", "punk"},
	"Русский рэп": {"русский рэп", "российский хип-хоп", "рэп"},
	"Поп":         {"русский поп", "популярная музыка", "поп хиты"},
	"Рок":         {"русский рок", "рок музыка", "рок хиты"},
}

// Response is the JSON for GET /recommendations.
type Response = model.RecommendationFeed

type Service struct {
	history *history.Service
	music   *music.Service
	prefs   *preferences.Service
	spotify *provider.Spotify
}

func NewService(h *history.Service, m *music.Service, p *preferences.Service, sp *provider.Spotify) *Service {
	return &Service{history: h, music: m, prefs: p, spotify: sp}
}

func (s *Service) GetRecommendations(ctx context.Context, userID, lang string) *Response {
	legacy := s.legacyGetRecommendations(ctx, userID, lang)
	if legacy == nil {
		legacy = &Response{Tracks: []model.Track{}, Albums: []model.Album{}, Artists: []model.Artist{}}
	}

	userOK := strings.TrimSpace(userID) != "" && s.spotify != nil
	if !userOK {
		return legacy
	}

	// Cold-start: if user hasn't completed onboarding and has no listening history,
	// the search-based feed looks better than sparse preference-driven recs.
	pref, _ := s.prefs.Get(ctx, userID)
	isOnboarded := pref != nil && pref.OnboardingCompleted && (len(pref.SelectedArtists) > 0 || len(pref.SelectedGenres) > 0)
	hist, _ := s.history.List(ctx, userID, 1)
	hasHistory := len(hist) > 0
	if !isOnboarded && !hasHistory {
		return legacy
	}

	deps := engine.Deps{Spotify: s.spotify, Music: s.music, History: s.history, Prefs: s.prefs}
	eng, err := engine.Run(ctx, &deps, userID, lang)
	if err != nil || eng == nil || len(eng.Tracks) == 0 {
		return legacy
	}
	return eng
}

// GetDailyMixes returns four personalized track bundles.
func (s *Service) GetDailyMixes(ctx context.Context, userID, lang string) ([]model.DailyMix, error) {
	if s.spotify == nil {
		return nil, errors.New("spotify not configured")
	}
	return engine.DailyMixes(ctx, &engine.Deps{
		Spotify: s.spotify,
		Music:   s.music,
		History: s.history,
		Prefs:   s.prefs,
	}, userID, lang)
}

// maxSearchQueries is how many Music.Search calls we run in parallel (after onboarding preferences).
// Higher cap = coverage across all selected artists/genres; each artist gets round-robin turns first.
const maxSearchQueries = 56

// interleaveOnlyArtistRounds round-robins each artist’s queries (name → album → playlist) with a cap.
func interleaveOnlyArtistRounds(artistGroups [][]string, cap int) []string {
	if cap <= 0 || len(artistGroups) == 0 {
		return nil
	}
	out := make([]string, 0, cap)
	maxRounds := 0
	for _, g := range artistGroups {
		if len(g) > maxRounds {
			maxRounds = len(g)
		}
	}
	for r := 0; r < maxRounds && len(out) < cap; r++ {
		for _, g := range artistGroups {
			if r < len(g) && len(out) < cap {
				out = append(out, g[r])
			}
		}
	}
	return out
}

// zipAlternate merges two query lists (a then b) until max, then appends the remainder of the longer list.
func zipAlternate(a, b []string, max int) []string {
	out := make([]string, 0, max)
	ia, ib := 0, 0
	for len(out) < max {
		if ia < len(a) {
			out = append(out, a[ia])
			ia++
		}
		if len(out) >= max {
			break
		}
		if ib < len(b) {
			out = append(out, b[ib])
			ib++
		}
		if ia >= len(a) && ib >= len(b) {
			break
		}
	}
	for len(out) < max && ia < len(a) {
		out = append(out, a[ia])
		ia++
	}
	for len(out) < max && ib < len(b) {
		out = append(out, b[ib])
		ib++
	}
	return out
}

// interleaveArtistGenreQueries mixes artist round-robin and genre terms so a long artist list
// does not starve genre queries. When only one side is set, the other is unused.
func interleaveArtistGenreQueries(artistGroups [][]string, genreTerms []string, maxQ int) []string {
	if maxQ <= 0 {
		return nil
	}
	ha, hg := len(artistGroups) > 0, len(genreTerms) > 0
	if !ha && !hg {
		return nil
	}
	if !ha {
		if len(genreTerms) > maxQ {
			return append([]string(nil), genreTerms[:maxQ]...)
		}
		return append([]string(nil), genreTerms...)
	}
	if !hg {
		return interleaveOnlyArtistRounds(artistGroups, maxQ)
	}
	// ~2/3 budget for name/album/playlist, ~1/3 for genres (both sides stay visible in the mix).
	artCap := (maxQ * 2) / 3
	genCap := maxQ - artCap
	if genCap < 1 {
		genCap = 1
		artCap = maxQ - genCap
	}
	artPart := interleaveOnlyArtistRounds(artistGroups, artCap)
	genPart := make([]string, 0, genCap)
	for _, g := range genreTerms {
		if len(genPart) >= genCap {
			break
		}
		if strings.TrimSpace(g) == "" {
			continue
		}
		genPart = append(genPart, g)
	}
	return zipAlternate(artPart, genPart, maxQ)
}

// defaultGenreDiscoveryQueries builds neutral genre/search terms (no “hits YEAR”) for onboarding edge cases.
func defaultGenreDiscoveryQueries(maxQ int) []string {
	if maxQ <= 0 {
		return nil
	}
	labels := []string{"Pop", "Rock", "Hip-Hop", "Electronic", "Indie", "Latin", "R&B"}
	var terms []string
	for _, label := range labels {
		if related, ok := genreRelated[label]; ok {
			terms = append(terms, related...)
		}
	}
	if len(terms) > maxQ {
		return append([]string(nil), terms[:maxQ]...)
	}
	return terms
}

func (s *Service) legacyGetRecommendations(ctx context.Context, userID, lang string) *Response {
	isRU := strings.Contains(strings.ToLower(lang), "ru")

	pref, _ := s.prefs.Get(ctx, userID)

	var queries []string
	var fromOnboarding bool

	if pref != nil && pref.OnboardingCompleted {
		fromOnboarding = true
		artistGroups := make([][]string, 0, len(pref.SelectedArtists))
		for _, artist := range pref.SelectedArtists {
			artist = strings.TrimSpace(artist)
			if artist == "" {
				continue
			}
			artistGroups = append(artistGroups, []string{
				artist,
				artist + " album",
				artist + " playlist",
			})
		}
		var genreTerms []string
		for _, genre := range pref.SelectedGenres {
			if related, ok := genreRelated[genre]; ok {
				genreTerms = append(genreTerms, related...)
			} else {
				g := strings.TrimSpace(genre)
				if g != "" {
					genreTerms = append(genreTerms, g)
				}
			}
		}
		queries = interleaveArtistGenreQueries(artistGroups, genreTerms, maxSearchQueries)
	}

	hasOnboardingPrefs := pref != nil && pref.OnboardingCompleted &&
		len(pref.SelectedArtists)+len(pref.SelectedGenres) > 0

	if len(queries) == 0 && hasOnboardingPrefs {
		queries = defaultGenreDiscoveryQueries(maxSearchQueries)
	}

	if len(queries) == 0 {
		genres, _ := s.history.TopGenres(ctx, userID, 3)
		artists, _ := s.history.TopArtists(ctx, userID, 3)
		queries = append(queries, genres...)
		queries = append(queries, artists...)
	}

	if len(queries) == 0 && pref != nil && pref.OnboardingCompleted {
		queries = defaultGenreDiscoveryQueries(maxSearchQueries)
	}

	if len(queries) == 0 {
		if isRU {
			queries = coldStartRU
		} else {
			queries = coldStartEN
		}
	}

	nArt, nGen := 0, 0
	if pref != nil {
		nArt, nGen = len(pref.SelectedArtists), len(pref.SelectedGenres)
	}
	log.Printf("[recommend] legacy user=%s onboarding=%v artists=%d genres=%d queries=%d",
		userID, pref != nil && pref.OnboardingCompleted, nArt, nGen, len(queries))

	// Onboarding: no shuffle — interleave already gives each artist/ genre fair coverage; shuffle would only reorder.
	if !fromOnboarding {
		rand.Shuffle(len(queries), func(i, j int) { queries[i], queries[j] = queries[j], queries[i] })
	}
	if len(queries) > maxSearchQueries {
		queries = queries[:maxSearchQueries]
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	resp := &Response{}
	seenTrack := map[string]bool{}
	seenAlbum := map[string]bool{}
	seenArtist := map[string]bool{}

	for _, q := range queries {
		wg.Add(1)
		go func(query string) {
			defer wg.Done()
			res := s.music.Search(ctx, query, 10, "")
			if res == nil {
				return
			}
			mu.Lock()
			defer mu.Unlock()
			for _, t := range res.Tracks {
				key := t.Provider + ":" + t.ID
				if seenTrack[key] {
					continue
				}
				seenTrack[key] = true
				resp.Tracks = append(resp.Tracks, t)
			}
			for _, a := range res.Albums {
				key := a.Provider + ":" + a.ID
				if seenAlbum[key] {
					continue
				}
				seenAlbum[key] = true
				resp.Albums = append(resp.Albums, a)
			}
			for _, a := range res.Artists {
				key := a.Provider + ":" + a.ID
				if seenArtist[key] {
					continue
				}
				seenArtist[key] = true
				resp.Artists = append(resp.Artists, a)
			}
		}(q)
	}
	wg.Wait()

	sort.SliceStable(resp.Tracks, func(i, j int) bool {
		return hasText(resp.Tracks[i].CoverURL) && !hasText(resp.Tracks[j].CoverURL)
	})
	sort.SliceStable(resp.Albums, func(i, j int) bool {
		return hasText(resp.Albums[i].CoverURL) && !hasText(resp.Albums[j].CoverURL)
	})
	sort.SliceStable(resp.Artists, func(i, j int) bool {
		return hasText(resp.Artists[i].ImageURL) && !hasText(resp.Artists[j].ImageURL)
	})

	resp.Tracks = filterWithCover(resp.Tracks, func(t model.Track) string { return t.CoverURL })
	resp.Albums = filterWithCover(resp.Albums, func(a model.Album) string { return a.CoverURL })
	resp.Artists = filterWithCover(resp.Artists, func(a model.Artist) string { return a.ImageURL })

	resp.Tracks = dedupeTracksByCoverURL(resp.Tracks)

	resp.Tracks = capSlice(resp.Tracks, 30)
	resp.Albums = capSlice(resp.Albums, 15)
	resp.Artists = capSlice(resp.Artists, 15)
	return resp
}

// filterWithCover removes items with empty cover/image. Falls back to the
// original slice if every item is empty (better empty cards than no cards).
func filterWithCover[T any](in []T, getURL func(T) string) []T {
	if len(in) == 0 {
		return in
	}
	out := in[:0:0]
	for _, item := range in {
		if hasText(getURL(item)) {
			out = append(out, item)
		}
	}
	if len(out) == 0 {
		return in
	}
	return out
}

func capSlice[T any](in []T, max int) []T {
	if len(in) > max {
		return in[:max]
	}
	return in
}

func hasText(value string) bool {
	return strings.TrimSpace(value) != ""
}

// dedupeTracksByCoverURL keeps the first track for each non-empty cover URL.
func dedupeTracksByCoverURL(in []model.Track) []model.Track {
	if len(in) == 0 {
		return in
	}
	seen := make(map[string]struct{}, len(in))
	out := in[:0:0]
	for _, t := range in {
		u := strings.TrimSpace(t.CoverURL)
		if u == "" {
			out = append(out, t)
			continue
		}
		if _, ok := seen[u]; ok {
			continue
		}
		seen[u] = struct{}{}
		out = append(out, t)
	}
	if len(out) == 0 {
		return in
	}
	return out
}
