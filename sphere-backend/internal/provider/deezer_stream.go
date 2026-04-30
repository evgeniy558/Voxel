package provider

// Deezer full-track streaming via the internal `gw-light` + `media.deezer.com`
// endpoints. Requires a `DEEZER_ARL` (long-lived `arl` cookie from a logged-in
// deezer.com session). Without it the public API only returns 30s previews.
//
// Pipeline:
//   1. POST /ajax/gw-light.php?method=deezer.getUserData
//        → checkForm (api_token), license_token, sid cookie
//   2. POST /ajax/gw-light.php?method=song.getListData&api_token=<checkForm>
//        body: {"sng_ids":["<id>"]}
//        → TRACK_TOKEN per track (also DURATION, MD5_ORIGIN, etc.)
//   3. POST https://media.deezer.com/v1/get_url
//        body: { license_token, track_tokens:[…], media:[{ type:"FULL",
//                formats:[{ cipher:"BF_CBC_STRIPE", format:"MP3_128"|"MP3_320"|"FLAC" }] }] }
//        → signed URL pointing at e-cdns-proxy-N.dzcdn.net
//   4. GET that URL → stream of BF_CBC_STRIPE-encrypted bytes.
//      Decryption: read 2048-byte chunks; every 3rd chunk (i%3==0) is BF-CBC
//      with IV \x00..\x07 and key derived from md5(sng_id) ^ "g4el58wc0zvf9na1".

import (
	"bytes"
	"context"
	"crypto/cipher"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"

	"golang.org/x/crypto/blowfish"
)

const (
	deezerGwBase    = "https://www.deezer.com/ajax/gw-light.php"
	deezerMediaBase = "https://media.deezer.com/v1/get_url"
	// DeezerUA — User-Agent expected by both gw-light and the e-cdns CDN.
	DeezerUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

// deezerBfSecret is the well-known Deezer key-derivation secret.
var deezerBfSecret = []byte("g4el58wc0zvf9na1")

// deezerBfIV is the fixed Blowfish CBC IV used for BF_CBC_STRIPE chunks.
var deezerBfIV = []byte{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07}

// DeezerSession holds a logged-in Deezer GW session: api_token + license_token
// and the underlying http.Client (which carries the `sid`/`arl` cookies).
type DeezerSession struct {
	httpClient   *http.Client
	arl          string
	mu           sync.Mutex
	apiToken     string
	licenseToken string
	expiresAt    time.Time
}

// NewDeezerSession constructs a session that lazily logs in on first use.
// Returns nil when arl is empty so callers can no-op the full-track path.
func NewDeezerSession(arl string) *DeezerSession {
	if arl == "" {
		return nil
	}
	jar := &simpleCookieJar{cookies: map[string][]*http.Cookie{}}
	jar.Set(".deezer.com", &http.Cookie{Name: "arl", Value: arl, Path: "/", Domain: ".deezer.com"})
	return &DeezerSession{
		httpClient: &http.Client{
			Timeout: 15 * time.Second,
			Jar:     jar,
		},
		arl: arl,
	}
}

// ensureLogin refreshes api_token/license_token when missing or near-expired.
// Deezer's `checkForm` token rotates roughly every hour.
func (s *DeezerSession) ensureLogin(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.apiToken != "" && time.Now().Before(s.expiresAt) {
		return nil
	}
	body, err := s.gwCall(ctx, "deezer.getUserData", "", nil)
	if err != nil {
		return fmt.Errorf("deezer getUserData: %w", err)
	}
	var resp struct {
		Error   any `json:"error"`
		Results struct {
			CheckForm string `json:"checkForm"`
			User      struct {
				Options struct {
					LicenseToken string `json:"license_token"`
				} `json:"OPTIONS"`
				UserID json.Number `json:"USER_ID"`
			} `json:"USER"`
		} `json:"results"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return fmt.Errorf("deezer getUserData decode: %w", err)
	}
	if resp.Results.CheckForm == "" {
		return errors.New("deezer getUserData: empty checkForm (ARL invalid?)")
	}
	if resp.Results.User.UserID.String() == "0" || resp.Results.User.UserID.String() == "" {
		return errors.New("deezer getUserData: user_id=0 (ARL not logged in)")
	}
	s.apiToken = resp.Results.CheckForm
	s.licenseToken = resp.Results.User.Options.LicenseToken
	s.expiresAt = time.Now().Add(45 * time.Minute)
	return nil
}

// gwCall issues a JSON POST against the gw-light endpoint.
func (s *DeezerSession) gwCall(ctx context.Context, method, apiToken string, payload any) ([]byte, error) {
	q := url.Values{}
	q.Set("api_version", "1.0")
	q.Set("api_token", "null")
	if apiToken != "" {
		q.Set("api_token", apiToken)
	}
	q.Set("input", "3")
	q.Set("method", method)

	var body io.Reader = bytes.NewReader([]byte("{}"))
	if payload != nil {
		raw, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, "POST", deezerGwBase+"?"+q.Encode(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", DeezerUA)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Origin", "https://www.deezer.com")
	req.Header.Set("Referer", "https://www.deezer.com/")
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("deezer %s: HTTP %d", method, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// trackInfo holds the bits we need from `song.getListData`.
type deezerTrackInfo struct {
	SngID      string
	TrackToken string
	Duration   int
}

func (s *DeezerSession) getTrackInfo(ctx context.Context, sngID string) (*deezerTrackInfo, error) {
	if err := s.ensureLogin(ctx); err != nil {
		return nil, err
	}
	s.mu.Lock()
	apiTok := s.apiToken
	s.mu.Unlock()
	body, err := s.gwCall(ctx, "song.getListData", apiTok, map[string]any{
		"sng_ids": []string{sngID},
	})
	if err != nil {
		return nil, err
	}
	var resp struct {
		Results struct {
			Data []struct {
				SngID      string      `json:"SNG_ID"`
				TrackToken string      `json:"TRACK_TOKEN"`
				Duration   json.Number `json:"DURATION"`
			} `json:"data"`
		} `json:"results"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("song.getListData decode: %w", err)
	}
	if len(resp.Results.Data) == 0 || resp.Results.Data[0].TrackToken == "" {
		return nil, fmt.Errorf("song.getListData: no track token for %s", sngID)
	}
	d, _ := resp.Results.Data[0].Duration.Int64()
	return &deezerTrackInfo{
		SngID:      resp.Results.Data[0].SngID,
		TrackToken: resp.Results.Data[0].TrackToken,
		Duration:   int(d),
	}, nil
}

// ResolveStreamURL returns the BF_CBC_STRIPE-encrypted CDN URL for the given
// Deezer track id. Caller must wrap response body with NewDeezerStripeReader.
//
// `quality` is one of "MP3_128", "MP3_320", "FLAC". MP3_320 / FLAC require a
// Deezer Premium account on the ARL.
func (s *DeezerSession) ResolveStreamURL(ctx context.Context, sngID, quality string) (encryptedURL string, info *deezerTrackInfo, err error) {
	if quality == "" {
		quality = "MP3_128"
	}
	tinfo, err := s.getTrackInfo(ctx, sngID)
	if err != nil {
		return "", nil, err
	}

	s.mu.Lock()
	licTok := s.licenseToken
	s.mu.Unlock()

	payload := map[string]any{
		"license_token": licTok,
		"media": []map[string]any{{
			"type": "FULL",
			"formats": []map[string]string{
				{"cipher": "BF_CBC_STRIPE", "format": quality},
			},
		}},
		"track_tokens": []string{tinfo.TrackToken},
	}
	raw, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, "POST", deezerMediaBase, bytes.NewReader(raw))
	req.Header.Set("User-Agent", DeezerUA)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", nil, fmt.Errorf("media.deezer get_url: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		return "", nil, fmt.Errorf("media.deezer get_url: HTTP %d %s", resp.StatusCode, truncateString(string(body), 160))
	}
	var out struct {
		Data []struct {
			Media []struct {
				Sources []struct {
					URL      string `json:"url"`
					Provider string `json:"provider"`
				} `json:"sources"`
			} `json:"media"`
			Errors []struct {
				Code    int    `json:"code"`
				Message string `json:"message"`
			} `json:"errors"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", nil, fmt.Errorf("media.deezer decode: %w", err)
	}
	if len(out.Data) == 0 {
		return "", nil, errors.New("media.deezer: empty data")
	}
	if len(out.Data[0].Errors) > 0 {
		e := out.Data[0].Errors[0]
		return "", nil, fmt.Errorf("media.deezer error %d: %s", e.Code, e.Message)
	}
	if len(out.Data[0].Media) == 0 || len(out.Data[0].Media[0].Sources) == 0 {
		return "", nil, errors.New("media.deezer: no sources (track not available in this quality?)")
	}
	return out.Data[0].Media[0].Sources[0].URL, tinfo, nil
}

// DeezerBlowfishKey derives the per-track key from the song id.
func DeezerBlowfishKey(sngID string) []byte {
	sum := md5.Sum([]byte(sngID))
	hexStr := hex.EncodeToString(sum[:]) // 32 hex chars
	key := make([]byte, 16)
	for i := 0; i < 16; i++ {
		key[i] = hexStr[i] ^ hexStr[i+16] ^ deezerBfSecret[i]
	}
	return key
}

// stripeReader implements BF_CBC_STRIPE decryption: every 3rd 2048-byte chunk
// (chunkIdx % 3 == 0) is BF-CBC encrypted; the rest are plaintext. The final
// short chunk is never encrypted (Deezer's stripe rule).
//
// Important: every encrypted chunk uses the SAME fixed IV (\x00..\x07), so the
// CBC decrypter is recreated per chunk (Go's `cipher.BlockMode` updates its
// internal IV between calls).
type stripeReader struct {
	src      io.Reader
	bf       cipher.Block
	chunkIdx int
	buf      []byte // pending decrypted output
	eof      bool
}

const deezerChunkSize = 2048

// NewDeezerStripeReader wraps an encrypted Deezer audio stream and yields
// plaintext MP3/FLAC bytes.
func NewDeezerStripeReader(src io.Reader, key []byte) (io.Reader, error) {
	bf, err := blowfish.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("blowfish init: %w", err)
	}
	return &stripeReader{src: src, bf: bf}, nil
}

func (s *stripeReader) Read(p []byte) (int, error) {
	if len(s.buf) > 0 {
		n := copy(p, s.buf)
		s.buf = s.buf[n:]
		return n, nil
	}
	if s.eof {
		return 0, io.EOF
	}
	chunk := make([]byte, deezerChunkSize)
	read := 0
	for read < deezerChunkSize {
		n, err := s.src.Read(chunk[read:])
		read += n
		if err != nil {
			if err == io.EOF {
				s.eof = true
				break
			}
			return 0, err
		}
	}
	if read == 0 {
		return 0, io.EOF
	}
	chunk = chunk[:read]

	// Decrypt only full 2048-byte chunks at every 3rd position.
	if s.chunkIdx%3 == 0 && read == deezerChunkSize {
		// Fresh CBC decrypter per chunk (Deezer reuses the same IV every time).
		dec := cipher.NewCBCDecrypter(s.bf, deezerBfIV)
		dec.CryptBlocks(chunk, chunk)
	}
	s.chunkIdx++
	s.buf = chunk
	if len(s.buf) == 0 {
		return 0, io.EOF
	}
	n := copy(p, s.buf)
	s.buf = s.buf[n:]
	return n, nil
}

// simpleCookieJar is a minimum-viable cookie jar for the gw-light flow. We
// avoid `net/http/cookiejar` because it requires a `publicsuffix` import and
// only adds noise here.
type simpleCookieJar struct {
	mu      sync.Mutex
	cookies map[string][]*http.Cookie
}

func (j *simpleCookieJar) Set(host string, c *http.Cookie) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.cookies[host] = append(j.cookies[host], c)
}

func (j *simpleCookieJar) SetCookies(u *url.URL, cookies []*http.Cookie) {
	j.mu.Lock()
	defer j.mu.Unlock()
	host := "." + topDomain(u.Host)
	j.cookies[host] = mergeCookies(j.cookies[host], cookies)
}

func (j *simpleCookieJar) Cookies(u *url.URL) []*http.Cookie {
	j.mu.Lock()
	defer j.mu.Unlock()
	host := "." + topDomain(u.Host)
	return append([]*http.Cookie(nil), j.cookies[host]...)
}

func mergeCookies(existing, incoming []*http.Cookie) []*http.Cookie {
	idx := map[string]int{}
	for i, c := range existing {
		idx[c.Name] = i
	}
	for _, c := range incoming {
		if pos, ok := idx[c.Name]; ok {
			existing[pos] = c
			continue
		}
		existing = append(existing, c)
	}
	return existing
}

func topDomain(host string) string {
	// Deezer uses `.deezer.com` for everything we care about.
	if i := indexLastDot(host); i > 0 {
		if j := indexLastDotBefore(host, i); j >= 0 {
			return host[j+1:]
		}
	}
	return host
}

func indexLastDot(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '.' {
			return i
		}
	}
	return -1
}

func indexLastDotBefore(s string, before int) int {
	for i := before - 1; i >= 0; i-- {
		if s[i] == '.' {
			return i
		}
	}
	return -1
}

func truncateString(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
