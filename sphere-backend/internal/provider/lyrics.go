package provider

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

var lyricsHTTP = &http.Client{Timeout: 10 * time.Second}

// FetchLRCLIB fetches lyrics from lrclib.net (free, no API key needed).
// Used by EeveeSpotify as a lyrics source.
func FetchLRCLIB(ctx context.Context, artist, title string) (string, error) {
	u := fmt.Sprintf("https://lrclib.net/api/get?artist_name=%s&track_name=%s",
		url.QueryEscape(artist), url.QueryEscape(title))

	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	req.Header.Set("User-Agent", "Sphere v1.0")

	resp, err := lyricsHTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("lrclib: status %d", resp.StatusCode)
	}

	var result struct {
		SyncedLyrics string `json:"syncedLyrics"`
		PlainLyrics  string `json:"plainLyrics"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}

	// Prefer synced (timed) lyrics, fallback to plain
	if result.SyncedLyrics != "" {
		return result.SyncedLyrics, nil
	}
	if result.PlainLyrics != "" {
		return result.PlainLyrics, nil
	}
	return "", fmt.Errorf("no lyrics on lrclib")
}

func FetchGenius(ctx context.Context, query string, token string) (string, error) {
	searchURL := "https://api.genius.com/search?q=" + url.QueryEscape(query)
	req, _ := http.NewRequestWithContext(ctx, "GET", searchURL, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("User-Agent", "Sphere/1.0")

	resp, err := lyricsHTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("genius search: status %d", resp.StatusCode)
	}

	var searchResp struct {
		Response struct {
			Hits []struct {
				Result struct {
					ID  int    `json:"id"`
					URL string `json:"url"`
				} `json:"result"`
			} `json:"hits"`
		} `json:"response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&searchResp); err != nil {
		return "", err
	}

	var songURL string
	for _, hit := range searchResp.Response.Hits {
		if hit.Result.URL != "" {
			songURL = hit.Result.URL
			break
		}
	}
	if songURL == "" {
		return "", fmt.Errorf("no genius results")
	}

	// Fetch the page and extract lyrics from the HTML
	return scrapeGeniusLyrics(ctx, songURL)
}

// scrapeGeniusLyrics extracts lyrics text from a Genius song page.
func scrapeGeniusLyrics(ctx context.Context, songURL string) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", songURL, nil)
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

	resp, err := lyricsHTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	html := string(body)

	// Extract lyrics from Genius HTML
	// Lyrics are in <div data-lyrics-container="true">...</div>
	var lyrics strings.Builder
	for {
		idx := strings.Index(html, `data-lyrics-container="true"`)
		if idx == -1 {
			break
		}
		html = html[idx:]

		// Find the closing > of the opening tag
		start := strings.Index(html, ">")
		if start == -1 {
			break
		}
		html = html[start+1:]

		depth := 1
		pos := 0
		for depth > 0 && pos < len(html) {
			if pos+5 < len(html) && (html[pos:pos+5] == "<div " || html[pos:pos+5] == "<div>") {
				depth++
			}
			if pos+6 <= len(html) && html[pos:pos+6] == "</div>" {
				depth--
				if depth == 0 {
					break
				}
			}
			pos++
		}

		chunk := html[:pos]
		// Convert <br> to newlines, strip other tags
		chunk = strings.ReplaceAll(chunk, "<br>", "\n")
		chunk = strings.ReplaceAll(chunk, "<br/>", "\n")
		chunk = strings.ReplaceAll(chunk, "<br />", "\n")
		chunk = stripHTML(chunk)
		chunk = strings.TrimSpace(chunk)

		if chunk != "" {
			if lyrics.Len() > 0 {
				lyrics.WriteString("\n\n")
			}
			lyrics.WriteString(chunk)
		}

		html = html[pos:]
	}

	if lyrics.Len() == 0 {
		return "", fmt.Errorf("no lyrics in page")
	}
	return cleanGeniusLyrics(lyrics.String()), nil
}

func cleanGeniusLyrics(text string) string {
	if idx := strings.Index(text, "["); idx > 0 {
		text = text[idx:]
	}
	if idx := strings.LastIndex(text, "Embed"); idx != -1 {
		before := strings.TrimRight(text[:idx], "0123456789 \n\r\t")
		if before != "" {
			text = before
		}
	}
	return strings.TrimSpace(text)
}

// stripHTML removes all HTML tags from a string.
func stripHTML(s string) string {
	var b strings.Builder
	inTag := false
	for _, r := range s {
		if r == '<' {
			inTag = true
			continue
		}
		if r == '>' {
			inTag = false
			continue
		}
		if !inTag {
			b.WriteRune(r)
		}
	}
	return b.String()
}
