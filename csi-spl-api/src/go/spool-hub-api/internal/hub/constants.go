package hub

import "time"

// Constants for embed abuse tracking.
const (
	EmbedIPPeriod    = 7 * 24 * time.Hour  // Period for IP-based embed abuse tracking (salt rotation)
	EmbedDayDuration = 24 * time.Hour      // Duration of one day for embed abuse windows
)