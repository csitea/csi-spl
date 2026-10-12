package main

import "time"

// Timeouts and intervals for the hub process.
const (
	BlobCacheTTL      = 10 * time.Minute  // Cache TTL for blob storage
	SweepInterval     = 10 * time.Minute  // Interval for background sweeps
	BlockerInterval   = time.Minute       // Interval for checking unanswered blockers
	ReadHeaderTimeout = 10 * time.Second  // Timeout for reading HTTP headers
	IdleTimeout       = 120 * time.Second // Timeout for idle connections
)
