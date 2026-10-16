package hubclient

// SPL-2165 (repo review suggestion 9): the box's local fallback queue - the
// pending-flush dir a send falls back to while the hub is unreachable - says
// how deep it is and how its last flush went. Before, its only trace was the
// one-shot `hub-sync` count and a WARN when the dir could not be scanned:
// a sidecar that had been queueing for an hour looked exactly like an idle one.
//
//   - every Flush leaves its result in <hub dir>/flush-last.json and, when it
//     moved something or failed, one log line;
//   - `spool hub-queue` prints QueueHealth (depth, oldest age, rejected, the
//     last flush), read from disk, so it works with the sidecar up or down;
//   - hub-run logs QueueHealth every Client.QueueLogEvery, at WARN once the
//     oldest entry is Client.QueueWarnAfter old - also while the hub is down,
//     which is when the queue grows.
//
// Both durations come from cnf (env.box.fallback_queue, passed by
// do_spl_desk_up); unset = no periodic line / no WARN. No default lives here.

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// FlushResult is what the last Flush on this box did.
type FlushResult struct {
	At      string `json:"at"`
	Flushed int    `json:"flushed"`
	// Left is the pending depth right after it, -1 when the dir could not be scanned.
	Left  int    `json:"left"`
	Error string `json:"error,omitempty"`
}

// QueueHealth is the fallback queue as `spool hub-queue` prints it.
type QueueHealth struct {
	Box   string `json:"box"`
	At    string `json:"at"`
	Depth int    `json:"depth"`
	// OldestAt is when the oldest pending envelope was queued (its file time).
	OldestAt   string `json:"oldest_at,omitempty"`
	OldestAgeS int64  `json:"oldest_age_s"`
	// Rejected counts the envelopes moved to rejected/: never delivered.
	Rejected int `json:"rejected"`
	// WarnAfterS is the cnf threshold in seconds, 0 = no WARN configured.
	WarnAfterS int64        `json:"warn_after_s"`
	Warn       bool         `json:"warn"`
	LastFlush  *FlushResult `json:"last_flush"`
}

func (c *Client) flushLastPath() string { return filepath.Join(c.Cfg.HubDir(), "flush-last.json") }

// ParseMinutes reads a cnf duration: whole minutes ("15", what cnf renders)
// or a Go duration ("90s"). Empty or 0 = off.
func ParseMinutes(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}
	if m, err := strconv.Atoi(s); err == nil {
		return time.Duration(m) * time.Minute, nil
	}
	return time.ParseDuration(s)
}

// recordFlush stores the result of one Flush and logs it when it moved
// something or failed; an empty flush on an empty queue stays quiet.
func (c *Client) recordFlush(n int, ferr error) {
	r := FlushResult{At: c.now().UTC().Format(time.RFC3339), Flushed: n, Left: c.pendingCount()}
	if ferr != nil {
		r.Error = ferr.Error()
	}
	if raw, err := json.Marshal(r); err == nil {
		if err := writeAtomic(c.flushLastPath(), append(raw, '\n')); err != nil {
			c.Log.Debug().Err(err).Msg("fallback queue: flush result not stored")
		}
	}
	switch {
	case ferr != nil:
		c.Log.Warn().Err(ferr).Str("box", c.Cfg.BoxID).Int("flushed", n).Int("left", r.Left).
			Msg("fallback queue flush stopped")
	case n > 0:
		c.Log.Info().Str("box", c.Cfg.BoxID).Int("flushed", n).Int("left", r.Left).
			Msg("fallback queue flushed")
	}
}

// QueueHealth reads the fallback queue's state from disk.
func (c *Client) QueueHealth() (QueueHealth, error) {
	now := c.now().UTC()
	h := QueueHealth{Box: c.Cfg.BoxID, At: now.Format(time.RFC3339), WarnAfterS: int64(c.QueueWarnAfter / time.Second)}
	list, err := c.Pending()
	if err != nil {
		return h, err
	}
	h.Depth = len(list)
	if len(list) > 0 {
		// Pending is oldest first by name (the message ts); the file time is
		// when this box queued it, which is the age ops care about.
		fi, err := os.Stat(list[0])
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return h, err
		}
		if err == nil {
			h.OldestAt = fi.ModTime().UTC().Format(time.RFC3339)
			if age := now.Sub(fi.ModTime()); age > 0 {
				h.OldestAgeS = int64(age / time.Second)
			}
		}
	}
	if ents, err := os.ReadDir(c.rejectedDir()); err == nil {
		for _, e := range ents {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") {
				h.Rejected++
			}
		}
	}
	if raw, err := os.ReadFile(c.flushLastPath()); err == nil {
		var r FlushResult
		if json.Unmarshal(raw, &r) == nil {
			h.LastFlush = &r
		}
	}
	h.Warn = c.QueueWarnAfter > 0 && h.Depth > 0 && h.OldestAgeS >= h.WarnAfterS
	return h, nil
}

// logQueue writes one QueueHealth line: WARN when Warn, else INFO.
func (c *Client) logQueue() {
	h, err := c.QueueHealth()
	if err != nil {
		c.Log.Warn().Err(err).Str("box", c.Cfg.BoxID).Msg("fallback queue: scan failed; depth unknown")
		return
	}
	ev := c.Log.Info()
	msg := "fallback queue"
	if h.Warn {
		ev = c.Log.Warn()
		msg = "fallback queue: the oldest pending envelope is older than the cnf threshold; the hub has not taken it"
	}
	ev = ev.Str("box", h.Box).Int("depth", h.Depth).Int64("oldest_age_s", h.OldestAgeS).
		Int("rejected", h.Rejected).Int64("warn_after_s", h.WarnAfterS)
	if f := h.LastFlush; f != nil {
		ev = ev.Str("last_flush_at", f.At).Int("last_flush_flushed", f.Flushed).Str("last_flush_error", f.Error)
	}
	ev.Msg(msg)
}

// watchQueue logs the queue every QueueLogEvery until ctx ends; 0 = never.
func (c *Client) watchQueue(ctx context.Context) {
	if c.QueueLogEvery <= 0 {
		return
	}
	t := time.NewTicker(c.QueueLogEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c.logQueue()
		}
	}
}
