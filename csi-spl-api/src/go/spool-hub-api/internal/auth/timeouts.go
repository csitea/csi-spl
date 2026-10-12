package auth

import "time"

// Timeouts for IdP and avatar fetches.
const (
	HTTPClientTimeout = 15 * time.Second  // Timeout for HTTP client requests
)

