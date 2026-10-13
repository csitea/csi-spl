package hub

import (
	"time"
	"spool-hub-api/internal/timeutil"
)

// Constants for embed abuse tracking.
const (
	EmbedIPPeriod    = 7 * timeutil.Day // Period for IP-based embed abuse tracking (salt rotation)
	EmbedDayDuration = timeutil.Day     // Duration of one day for embed abuse windows
)
