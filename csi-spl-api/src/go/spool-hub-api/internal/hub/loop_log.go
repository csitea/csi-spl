package hub

import (
	"sync"

	"github.com/rs/zerolog"
)

// A relay-loop call that keeps failing (a DB restart of a minute is 12 ticks)
// logs its first failure at ERROR, every repeat at WARN while it keeps
// failing, and one INFO when it works again (alerts fix round row 02,
// SPL-3194): the error_logs policy counts ERROR lines, so one outage is one
// line, not one per tick and call site.

// loopLog is the failing state of each relay-loop call, by site, tenant and
// box ("" for a tenant-wide call).
type loopLog struct {
	mu      sync.Mutex
	failing map[[3]string]int // failures in a row
}

// fail counts one failure and logs it, the site as the message: ERROR the
// first time, WARN after.
func (l *loopLog) fail(log *zerolog.Logger, site, tenant, box string, err error) {
	k := [3]string{site, tenant, box}
	l.mu.Lock()
	if l.failing == nil {
		l.failing = map[[3]string]int{}
	}
	l.failing[k]++
	n := l.failing[k]
	l.mu.Unlock()
	ev := log.Warn()
	if n == 1 {
		ev = log.Error()
	}
	withBox(ev.Err(err).Int("failures", n).Str("tenant", tenant), box).Msg(site)
}

// ok records a working call; after failures it logs one INFO line, the
// site's message with recovered=true.
func (l *loopLog) ok(log *zerolog.Logger, site, tenant, box string) {
	k := [3]string{site, tenant, box}
	l.mu.Lock()
	n, was := l.failing[k]
	delete(l.failing, k)
	l.mu.Unlock()
	if was {
		withBox(log.Info().Bool("recovered", true).Int("failures", n).Str("tenant", tenant), box).Msg(site)
	}
}

func withBox(ev *zerolog.Event, box string) *zerolog.Event {
	if box == "" {
		return ev
	}
	return ev.Str("box", box)
}
