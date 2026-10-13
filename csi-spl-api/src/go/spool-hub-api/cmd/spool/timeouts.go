package main

import "spool-hub-api/internal/timeutil"
	"time"

// Timeouts and intervals for the hub process.
const (
	BlobCacheTTL      = 10 * timeutil.Minute  // Cache TTL for blob storage
	SweepInterval     = 10 * timeutil.Minute  // Interval for background sweeps
	BlockerInterval   = timeutil.Minute       // Interval for checking unanswered blockers
	ReadHeaderTimeout = 10 * timeutil.Second  // Timeout for reading HTTP headers
	IdleTimeout       = 120 * timeutil.Second // Timeout for idle connections
)
