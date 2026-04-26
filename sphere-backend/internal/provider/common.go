package provider

import "time"

type cacheEntry struct {
	url       string
	expiresAt time.Time
}
