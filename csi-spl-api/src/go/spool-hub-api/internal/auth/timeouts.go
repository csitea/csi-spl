package auth

import "spool-hub-api/internal/timeutil"
	"time"

// Timeouts for IdP and avatar fetches.
const (
	HTTPClientTimeout = 15 * timeutil.Second // Timeout for HTTP client requests
)
