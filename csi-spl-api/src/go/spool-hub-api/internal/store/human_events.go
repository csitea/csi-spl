package store

import (
	"context"
	"errors"
	"regexp"
	"time"
	"unicode/utf8"
)

// A human's personal event log (specs/005 FR-WUI-EVLOG, contracts/events-v1.md;
// rdb 0045_human_events.sql). Every error the WUI showed the signed-in human,
// already redacted by the WUI's error journal. Hub-wide like humans: keyed by
// HUM-*, no tenant, no RLS.

// HumanEventsKeep is how many rows a human keeps; older ones are deleted on
// insert.
const HumanEventsKeep = 500

// HumanEventKindError is the only kind today (human_events.kind).
const HumanEventKindError = "error"

// HumanEvent is one row.
type HumanEvent struct {
	ID         int64
	HumanID    string
	Kind       string
	ErrorID    string
	OccurredAt *time.Time // the browser's clock; nil = not sent
	ReceivedAt time.Time
	Source     string
	Method     string
	Origin     string
	Path       string
	Status     int
	Code       string
	Message    string
	Name       string
	Route      string
}

// HumanEvents is the store side of events-v1. Memory and Postgres implement it.
type HumanEvents interface {
	// AddHumanEvents stores evs for the human (stamping ReceivedAt = now and
	// Kind = error) and trims the log to the newest HumanEventsKeep rows, in
	// one transaction. An unknown human is ErrNotFound. It returns how many
	// rows were stored.
	AddHumanEvents(ctx context.Context, humanID string, evs []HumanEvent, now time.Time) (int, error)
	// HumanEventsPage lists the human's rows newest first: at most limit,
	// only ids below before when before > 0.
	HumanEventsPage(ctx context.Context, humanID string, before int64, limit int) ([]HumanEvent, error)
	// ClearHumanEvents deletes every row of the human; returns how many.
	ClearHumanEvents(ctx context.Context, humanID string) (int, error)
}

// HumanEventErrorIDRe is the WUI's ERROR_ID_RE (errorJournal.mjs).
var HumanEventErrorIDRe = regexp.MustCompile(`^ERR(-CLIENT)?-[0-9]{8}-[0-9]{6}-[0-9A-F]{4}$`)

// humanEventCaps are rdb 0045's length checks, in characters.
var humanEventCaps = []struct {
	name string
	max  int
	get  func(*HumanEvent) string
}{
	{"source", 80, func(e *HumanEvent) string { return e.Source }},
	{"method", 12, func(e *HumanEvent) string { return e.Method }},
	{"origin", 120, func(e *HumanEvent) string { return e.Origin }},
	{"path", 200, func(e *HumanEvent) string { return e.Path }},
	{"code", 120, func(e *HumanEvent) string { return e.Code }},
	{"message", 800, func(e *HumanEvent) string { return e.Message }},
	{"name", 80, func(e *HumanEvent) string { return e.Name }},
	{"route", 200, func(e *HumanEvent) string { return e.Route }},
}

// CheckHumanEvent is rdb 0045's row checks, so a bad row is refused before
// the database sees it (and the memory store matches Postgres).
func CheckHumanEvent(e HumanEvent) error {
	if e.ErrorID != "" && !HumanEventErrorIDRe.MatchString(e.ErrorID) {
		return errors.New("human event: error_id must be ERR-YYYYMMDD-HHMMSS-XXXX or ERR-CLIENT-…")
	}
	if e.Status < 0 || e.Status > 999 {
		return errors.New("human event: status must be 0..999")
	}
	for _, c := range humanEventCaps {
		v := c.get(&e)
		if !utf8.ValidString(v) || utf8.RuneCountInString(v) > c.max {
			return errors.New("human event: " + c.name + " is not valid UTF-8 or longer than its cap")
		}
	}
	return nil
}

var (
	_ HumanEvents = (*Memory)(nil)
	_ HumanEvents = (*Postgres)(nil)
)
