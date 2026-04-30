package provider

import (
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"bytes"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	librespot "github.com/devgianlu/go-librespot"
	"github.com/devgianlu/go-librespot/ap"
	"github.com/devgianlu/go-librespot/apresolve"
	"github.com/devgianlu/go-librespot/audio"
	"github.com/devgianlu/go-librespot/login5"
	"github.com/devgianlu/go-librespot/mercury"
	extmetadatapb "github.com/devgianlu/go-librespot/proto/spotify/extendedmetadata"
	audiofilespb "github.com/devgianlu/go-librespot/proto/spotify/extendedmetadata/audiofiles"
	credentialspb "github.com/devgianlu/go-librespot/proto/spotify/login5/v3/credentials"
	metadatapb "github.com/devgianlu/go-librespot/proto/spotify/metadata"
	pbdata "github.com/devgianlu/go-librespot/proto/spotify/clienttoken/data/v0"
	pbhttp "github.com/devgianlu/go-librespot/proto/spotify/clienttoken/http/v0"
	"github.com/devgianlu/go-librespot/spclient"
	"google.golang.org/protobuf/proto"
)

type SpotifyStream struct {
	username  string
	password  string
	credsBlob string

	mu   sync.Mutex
	sess *spotifyConnectSession
}

func NewSpotifyStream(username, password, credsBlob string) *SpotifyStream {
	username = strings.TrimSpace(username)
	password = strings.TrimSpace(password)
	credsBlob = strings.TrimSpace(credsBlob)
	if username == "" && credsBlob == "" {
		return nil
	}
	return &SpotifyStream{username: username, password: password, credsBlob: credsBlob}
}

func (s *SpotifyStream) HasSession() bool {
	if s == nil {
		return false
	}
	return strings.TrimSpace(s.credsBlob) != "" || strings.TrimSpace(s.username) != ""
}

type spotifyCredsJSON struct {
	Username string `json:"username"`
	Data     []byte `json:"data"`
	Blob     []byte `json:"blob"`
}

func spotifyDeviceIDHex(seed string) string {
	sum := sha1.Sum([]byte(seed))
	return hex.EncodeToString(sum[:]) // 20 bytes → 40 hex chars
}

type spotifyConnectSession struct {
	log        librespot.Logger
	deviceID   string
	client     *http.Client
	ap         *ap.Accesspoint
	sp         *spclient.Spclient
	hg         *mercury.Client
	audioKey   *audio.KeyProvider
	username   string
	credsBytes []byte
}

func retrieveClientToken(c *http.Client, deviceId string) (string, error) {
	body, err := proto.Marshal(&pbhttp.ClientTokenRequest{
		RequestType: pbhttp.ClientTokenRequestType_REQUEST_CLIENT_DATA_REQUEST,
		Request: &pbhttp.ClientTokenRequest_ClientData{
			ClientData: &pbhttp.ClientDataRequest{
				ClientId:      librespot.ClientIdHex,
				ClientVersion: librespot.SpotifyLikeClientVersion(),
				Data: &pbhttp.ClientDataRequest_ConnectivitySdkData{
					ConnectivitySdkData: &pbdata.ConnectivitySdkData{
						DeviceId:             deviceId,
						PlatformSpecificData: librespot.GetPlatformSpecificData(),
					},
				},
			},
		},
	})
	if err != nil {
		return "", fmt.Errorf("clienttoken marshal: %w", err)
	}

	reqUrl, _ := url.Parse("https://clienttoken.spotify.com/v1/clienttoken")
	resp, err := c.Do(&http.Request{
		Method: "POST",
		URL:    reqUrl,
		Header: http.Header{
			"Accept":     []string{"application/x-protobuf"},
			"User-Agent": []string{librespot.UserAgent()},
		},
		Body: io.NopCloser(bytes.NewReader(body)),
	})
	if err != nil {
		return "", fmt.Errorf("clienttoken request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("clienttoken status %d", resp.StatusCode)
	}
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("clienttoken read: %w", err)
	}
	var protoResp pbhttp.ClientTokenResponse
	if err := proto.Unmarshal(respBody, &protoResp); err != nil {
		return "", fmt.Errorf("clienttoken unmarshal: %w", err)
	}
	switch protoResp.ResponseType {
	case pbhttp.ClientTokenResponseType_RESPONSE_GRANTED_TOKEN_RESPONSE:
		return protoResp.GetGrantedToken().Token, nil
	default:
		return "", fmt.Errorf("clienttoken response type: %v", protoResp.ResponseType)
	}
}

func (s *SpotifyStream) ensureSession(ctx context.Context) (*spotifyConnectSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sess != nil {
		return s.sess, nil
	}
	if !s.HasSession() {
		return nil, errors.New("spotify stream not configured")
	}

	log := &librespot.NullLogger{}
	deviceID := spotifyDeviceIDHex("sphere|" + s.username)
	client := &http.Client{Timeout: 30 * time.Second}

	var (
		username string
		stored   []byte
		blob     []byte
	)
	// Prefer creds blob if present (most stable).
	if strings.TrimSpace(s.credsBlob) != "" {
		raw, err := base64.StdEncoding.DecodeString(s.credsBlob)
		if err != nil {
			return nil, fmt.Errorf("spotify creds blob base64: %w", err)
		}
		var parsed spotifyCredsJSON
		if json.Unmarshal(raw, &parsed) == nil && (len(parsed.Data) > 0 || len(parsed.Blob) > 0) {
			username = strings.TrimSpace(parsed.Username)
			if username == "" {
				username = s.username
			}
			stored = parsed.Data
			blob = parsed.Blob
		} else {
			username = s.username
			blob = raw
		}
	} else {
		// Password-based auth is intentionally not implemented here: Spotify often requires captcha.
		// Keep the option as a placeholder to satisfy configuration; caller will fall back.
		_ = s.password
		return nil, errors.New("spotify username/password auth not supported; provide SPOTIFY_CREDS_BLOB")
	}

	clientToken, err := retrieveClientToken(client, deviceID)
	if err != nil {
		return nil, fmt.Errorf("client token: %w", err)
	}

	resolver := apresolve.NewApResolver(log, client)
	apAddr, err := resolver.GetAccesspoint(ctx)
	if err != nil {
		return nil, fmt.Errorf("accesspoint resolve: %w", err)
	}
	apc := ap.NewAccesspoint(log, apAddr, deviceID)
	if len(stored) > 0 {
		if err := apc.ConnectStored(ctx, username, stored); err != nil {
			return nil, fmt.Errorf("accesspoint stored creds: %w", err)
		}
	} else {
		if err := apc.ConnectBlob(ctx, username, blob); err != nil {
			return nil, fmt.Errorf("accesspoint blob creds: %w", err)
		}
	}

	l5 := login5.NewLogin5(log, client, deviceID, clientToken)
	if err := l5.Login(ctx, &credentialspb.StoredCredential{
		Username: apc.Username(),
		Data:     apc.StoredCredentials(),
	}); err != nil {
		return nil, fmt.Errorf("login5: %w", err)
	}

	spAddr, err := resolver.GetSpclient(ctx)
	if err != nil {
		return nil, fmt.Errorf("spclient resolve: %w", err)
	}
	spc, err := spclient.NewSpclient(ctx, log, client, spAddr, l5.AccessToken(), deviceID, clientToken)
	if err != nil {
		return nil, fmt.Errorf("spclient init: %w", err)
	}

	hg := mercury.NewClient(log, apc)
	ak := audio.NewAudioKeyProvider(log, apc)

	s.sess = &spotifyConnectSession{
		log:      log,
		deviceID: deviceID,
		client:   client,
		ap:       apc,
		sp:       spc,
		hg:       hg,
		audioKey: ak,
		username: apc.Username(),
	}
	return s.sess, nil
}

func (s *SpotifyStream) ResolveDecryptedStream(ctx context.Context, trackID string, bitrate int) (r io.ReadCloser, size int64, format metadatapb.AudioFile_Format, err error) {
	sess, err := s.ensureSession(ctx)
	if err != nil {
		return nil, 0, 0, err
	}
	if bitrate <= 0 {
		bitrate = 160
	}

	spotId, err := librespot.SpotifyIdFromBase62(librespot.SpotifyIdTypeTrack, trackID)
	if err != nil {
		return nil, 0, 0, err
	}

	// Fetch audio files extension (contains file_id + format).
	var audioFilesResp audiofilespb.AudioFilesExtensionResponse
	if err := sess.sp.ExtendedMetadataSimple(ctx, *spotId, extmetadatapb.ExtensionKind_AUDIO_FILES, &audioFilesResp); err != nil {
		return nil, 0, 0, fmt.Errorf("spotify audio files meta: %w", err)
	}
	var audioFiles []*metadatapb.AudioFile
	for _, f := range audioFilesResp.Files {
		if f == nil || f.File == nil || f.File.FileId == nil || f.File.Format == nil {
			continue
		}
		audioFiles = append(audioFiles, f.File)
	}
	if len(audioFiles) == 0 {
		return nil, 0, 0, errors.New("spotify: no audio files")
	}

	// Select closest OGG bitrate.
	var best *metadatapb.AudioFile
	bestDist := 1<<31 - 1
	for _, f := range audioFiles {
		if f.Format == nil {
			continue
		}
		br := 0
		switch *f.Format {
		case metadatapb.AudioFile_OGG_VORBIS_96:
			br = 96
		case metadatapb.AudioFile_OGG_VORBIS_160:
			br = 160
		case metadatapb.AudioFile_OGG_VORBIS_320:
			br = 320
		default:
			continue
		}
		dist := br - bitrate
		if dist < 0 {
			dist = -dist
		}
		if best == nil || dist < bestDist {
			best = f
			bestDist = dist
		}
	}
	if best == nil || best.FileId == nil || best.Format == nil {
		return nil, 0, 0, errors.New("spotify: no supported OGG formats")
	}
	format = *best.Format

	// Resolve storage to get CDN URL.
	st, err := sess.sp.ResolveStorageInteractive(ctx, best.FileId, best.Format, true)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("spotify storage resolve: %w", err)
	}
	if st == nil || len(st.Cdnurl) == 0 {
		return nil, 0, 0, errors.New("spotify: empty cdn url")
	}
	cdnURL := st.Cdnurl[0]

	// Fetch AES key for the file.
	key, err := sess.audioKey.Request(ctx, spotId.Id(), best.FileId)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("spotify audio key: %w", err)
	}

	// Chunked download + AES-CTR decrypt, streaming OGG bytes.
	client := &http.Client{Timeout: 0}
	ch, err := audio.NewHttpChunkedReader(sess.log, client, cdnURL)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("spotify chunked reader: %w", err)
	}
	dec, err := audio.NewAesAudioDecryptor(ch, key)
	if err != nil {
		_ = ch.Close()
		return nil, 0, 0, fmt.Errorf("spotify decryptor: %w", err)
	}

	sr := io.NewSectionReader(dec, 0, ch.Size())
	return struct {
		io.Reader
		io.Closer
	}{Reader: sr, Closer: dec}, ch.Size(), format, nil
}

