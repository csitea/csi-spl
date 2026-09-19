package auth

import (
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
)

// limiter is the per-key sliding-window counter of spec 015 FR-006b; it is
// edge.Window, shared with the hub's edge limits (017 FR-SEC-004).
type limiter = edge.Window

func newLimiter(window time.Duration, now func() time.Time) *limiter {
	return edge.NewWindow(window, now)
}

// clientIP is edge.ClientIP: one derivation of the caller's address for every
// per-IP limit in the hub (017 FR-SEC-006).
func clientIP(r *http.Request, hops int) string { return edge.ClientIP(r, hops) }
