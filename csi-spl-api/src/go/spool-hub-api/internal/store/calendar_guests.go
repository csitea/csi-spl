package store

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// specs/097 T007 (spec 4.5, 3.2): guests and their answers, one
// calendar_guests row each (rdb 0139), shared by Memory and Postgres.
//
//   - An event row (single, series or exception) carries its own guests; an
//     occurrence without an exception row shows its series' guests, and an
//     exception row starts as a copy of them.
//   - Every guest id is also in mentions (normalizeCalendarGuests adds a
//     missing one), so 089's private filter serves guests unchanged; the hub
//     removes a dropped guest from both.
//   - A guest answers for themselves only (RespondCalendarEvent): on an
//     occurrence, scope this writes the exception row, all the series and
//     every exception row the guest is on. An answer leaves updated_at as
//     it is: answering is not editing, so it never trips an If-Match.

// Guest answers (rdb 0139 calendar_guests.response check).
const (
	CalendarNeedsAction = "needs_action"
	CalendarYes         = "yes"
	CalendarNo          = "no"
	CalendarMaybe       = "maybe"
)

const (
	calendarMaxGuests       = 50  // the same cap as mentions (spec 4.5)
	calendarGuestIDMax      = 64  // rdb 0139 guest_id / invited_by
	calendarGuestCommentMax = 500 // rdb 0139 comment
)

// ErrNotAGuest: the caller answers an event they are not a guest of (HTTP
// 403 not_a_guest).
var ErrNotAGuest = errors.New("store: the caller is not a guest of the calendar event")

// CalendarGuest is one calendar_guests row. The json names are the shape the
// Postgres read aggregates the rows into (calendarGuestsSQL).
type CalendarGuest struct {
	Type        string    `json:"type"` // human | agent
	ID          string    `json:"id"`
	Response    string    `json:"response"` // "" on a write is needs_action
	Comment     string    `json:"comment"`
	RespondedAt time.Time `json:"responded_at"` // zero: not answered
	InvitedBy   string    `json:"invited_by"`   // "" on a write is the event's creator
}

// CalendarRSVP is one answer: Response yes, no or maybe; Scope this or all
// on a series ("" is this for an occurrence id, all for a series id).
type CalendarRSVP struct {
	Response string
	Comment  string
	Scope    string
}

// CalendarGuests is the store side of POST /v1/calendar/events/{id}/rsvp.
type CalendarGuests interface {
	// RespondCalendarEvent stores viewer's answer on the event id (a single
	// event, a series or an occurrence) and answers the event as it reads
	// now; ErrNotAGuest when viewer is not one of its guests.
	RespondCalendarEvent(ctx context.Context, tenant, viewer, id string, a CalendarRSVP, now time.Time) (CalendarEvent, error)
}

var (
	_ CalendarGuests = (*Memory)(nil)
	_ CalendarGuests = (*Postgres)(nil)
)

// calendarGuestKey is a guest's identity in an event.
func calendarGuestKey(g CalendarGuest) string { return g.Type + ":" + g.ID }

// normalizeCalendarGuests applies rdb 0139's checks and the defaults, drops a
// repeated guest, sorts by type then id (both stores answer one order) and
// puts every guest id in mentions.
func normalizeCalendarGuests(e *CalendarEvent) error {
	bad := func(what string) error { return fmt.Errorf("%w: %s", ErrInvalidCalendarEvent, what) }
	out, seen := make([]CalendarGuest, 0, len(e.Guests)), map[string]bool{}
	for _, g := range e.Guests {
		if g.Response == "" {
			g.Response = CalendarNeedsAction
		}
		if g.InvitedBy == "" {
			g.InvitedBy = e.CreatorID
		}
		switch {
		case g.Type != "human" && g.Type != "agent":
			return bad("a guest's type must be human or agent")
		case g.ID == "" || utf8.RuneCountInString(g.ID) > calendarGuestIDMax:
			return bad("a guest's id must be 1..64 characters")
		case !slices.Contains([]string{CalendarNeedsAction, CalendarYes, CalendarNo, CalendarMaybe}, g.Response):
			return bad("a guest's response must be needs_action, yes, no or maybe")
		case utf8.RuneCountInString(g.Comment) > calendarGuestCommentMax:
			return bad("a guest's comment is at most 500 characters")
		case utf8.RuneCountInString(g.InvitedBy) > calendarGuestIDMax:
			return bad("invited_by must be 1..64 characters")
		case seen[calendarGuestKey(g)]:
			continue
		}
		if !g.RespondedAt.IsZero() {
			g.RespondedAt = calendarNow(g.RespondedAt)
		}
		seen[calendarGuestKey(g)] = true
		out = append(out, g)
	}
	if len(out) > calendarMaxGuests {
		return bad("an event has at most 50 guests")
	}
	sortCalendarGuests(out)
	e.Guests = out
	calendarGuestsInMentions(e)
	return nil
}

func sortCalendarGuests(gs []CalendarGuest) {
	sort.Slice(gs, func(i, j int) bool { return calendarGuestKey(gs[i]) < calendarGuestKey(gs[j]) })
}

// calendarGuestsInMentions appends each guest id mentions lacks (spec 3.2).
func calendarGuestsInMentions(e *CalendarEvent) {
	for _, g := range e.Guests {
		if !slices.Contains(e.Mentions, g.ID) {
			e.Mentions = append(e.Mentions, g.ID)
		}
	}
}

// mergeCalendarGuests is the guest list next on an event that has cur: a
// guest of both keeps cur's row (its answer and who invited it), a new one
// is next's entry.
func mergeCalendarGuests(cur, next []CalendarGuest) []CalendarGuest {
	out := make([]CalendarGuest, 0, len(next))
	for _, g := range next {
		if i := slices.IndexFunc(cur, func(c CalendarGuest) bool { return calendarGuestKey(c) == calendarGuestKey(g) }); i >= 0 {
			g = cur[i]
		}
		out = append(out, g)
	}
	return out
}

// calendarSameGuests: a and b invite the same guests (answers aside).
func calendarSameGuests(a, b []CalendarGuest) bool {
	keys := func(gs []CalendarGuest) []string {
		out := make([]string, 0, len(gs))
		for _, g := range gs {
			out = append(out, calendarGuestKey(g))
		}
		slices.Sort(out)
		return out
	}
	return slices.Equal(keys(a), keys(b))
}

// calendarFollowGuests: an exception that invites its old series' guests
// takes the new series' list, keeping its own answers (spec 4.4, all).
func calendarFollowGuests(ex, old, nu *CalendarEvent) {
	if calendarSameGuests(ex.Guests, old.Guests) {
		ex.Guests = mergeCalendarGuests(ex.Guests, nu.Guests)
		sortCalendarGuests(ex.Guests)
	}
	calendarGuestsInMentions(ex)
}

// checkCalendarRSVP refuses an answer rdb 0139 or the scope rule would.
func checkCalendarRSVP(a CalendarRSVP) error {
	switch {
	case a.Response != CalendarYes && a.Response != CalendarNo && a.Response != CalendarMaybe:
		return fmt.Errorf("%w: response must be yes, no or maybe", ErrInvalidCalendarEvent)
	case utf8.RuneCountInString(a.Comment) > calendarGuestCommentMax:
		return fmt.Errorf("%w: a comment is at most 500 characters", ErrInvalidCalendarEvent)
	case a.Scope != "" && a.Scope != CalendarScopeThis && a.Scope != CalendarScopeAll:
		return errCalendarScope("an answer's scope must be this or all")
	}
	return nil
}

// calendarAnswer writes viewer's answer on e; ErrNotAGuest when viewer is
// not one of e's guests.
func calendarAnswer(e *CalendarEvent, viewer string, a CalendarRSVP, now time.Time) error {
	for i := range e.Guests {
		if viewer != "" && e.Guests[i].ID == viewer {
			e.Guests[i].Response, e.Guests[i].Comment, e.Guests[i].RespondedAt = a.Response, a.Comment, calendarNow(now)
			return nil
		}
	}
	return ErrNotAGuest
}

// planCalendarRSVP is an answer on series b: at the occurrence orig (scope
// this, its default, writes its exception row), or on the whole series
// (scope all, the default for a series id; planCalendarRSVPAll).
func planCalendarRSVP(b *calendarBundle, orig time.Time, viewer string, a CalendarRSVP, now time.Time) (calendarPlan, error) {
	if orig.IsZero() {
		if a.Scope == CalendarScopeThis {
			return calendarPlan{}, errCalendarScope("scope this needs an occurrence id")
		}
		return planCalendarRSVPAll(b, orig, viewer, a, now)
	}
	occ, ex, err := b.occurrence(orig)
	if err != nil {
		return calendarPlan{}, err
	}
	if a.Scope == CalendarScopeAll {
		return planCalendarRSVPAll(b, orig, viewer, a, now)
	}
	row := calendarExceptionRow(occ, ex, now)
	if err := calendarAnswer(&row, viewer, a, now); err != nil {
		return calendarPlan{}, err
	}
	return calendarPlan{writes: []CalendarEvent{row}, out: calendarOccurrence(&b.series, &row, orig)}, nil
}

// planCalendarRSVPAll answers on the series and on every exception row the
// viewer is a guest of; ErrNotAGuest when they are on none. The answer is
// the series, or the occurrence orig when it is set.
func planCalendarRSVPAll(b *calendarBundle, orig time.Time, viewer string, a CalendarRSVP, now time.Time) (calendarPlan, error) {
	series := cloneCalendarEvent(&b.series)
	var plan calendarPlan
	if calendarAnswer(&series, viewer, a, now) == nil {
		plan.writes = append(plan.writes, series)
	}
	exAt := -1
	for i := range b.excs {
		x := cloneCalendarEvent(&b.excs[i])
		if calendarAnswer(&x, viewer, a, now) != nil {
			continue
		}
		plan.writes = append(plan.writes, x)
		if !orig.IsZero() && x.OriginalStart.Equal(orig) {
			exAt = len(plan.writes) - 1
		}
	}
	if len(plan.writes) == 0 {
		return calendarPlan{}, ErrNotAGuest
	}
	plan.out = series
	if !orig.IsZero() {
		ex := b.exceptionAt(orig)
		if exAt >= 0 {
			ex = &plan.writes[exAt]
		}
		plan.out = calendarOccurrence(&series, ex, orig)
	}
	return plan, nil
}

// ---- Memory ------------------------------------------------------------------------

func (s *Memory) RespondCalendarEvent(_ context.Context, tenant, viewer, id string, a CalendarRSVP, now time.Time) (CalendarEvent, error) {
	if err := checkCalendarRSVP(a); err != nil {
		return CalendarEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out, series, err := s.calendarSeriesWriteLocked(tenant, viewer, id, func(b *calendarBundle, orig time.Time) (calendarPlan, error) {
		return planCalendarRSVP(b, orig, viewer, a, now)
	})
	if series || err != nil {
		return out, err
	}
	e, err := s.calendarEventLocked(tenant, viewer, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	next := cloneCalendarEvent(e)
	if err := calendarAnswer(&next, viewer, a, now); err != nil {
		return CalendarEvent{}, err
	}
	*e = next
	return cloneCalendarEvent(e), nil
}

// ---- Postgres ----------------------------------------------------------------------

// calendarGuestsSQL is an event row's guests as one jsonb array (the select
// list's last column with rdb 0139), by type then id.
const calendarGuestsSQL = `, COALESCE((SELECT jsonb_agg(jsonb_build_object('type', g.guest_type, 'id', g.guest_id,
		'response', g.response, 'comment', g.comment, 'responded_at', g.responded_at, 'invited_by', g.invited_by)
		ORDER BY g.guest_type, g.guest_id) FROM calendar_guests g
	WHERE g.tenant_id = calendar_events.tenant_id AND g.event_id = calendar_events.event_id), '[]'::jsonb)`

// syncCalendarGuests makes event id's calendar_guests rows exactly gs: the
// rows of guests no longer listed go, the others are written as gs holds them.
func syncCalendarGuests(ctx context.Context, tx pgx.Tx, tenant, id string, gs []CalendarGuest) error {
	keys := make([]string, 0, len(gs))
	types, ids, resps, comments, invited := []string{}, []string{}, []string{}, []string{}, []string{}
	answered := []*time.Time{}
	for _, g := range gs {
		keys = append(keys, calendarGuestKey(g))
		types, ids, resps = append(types, g.Type), append(ids, g.ID), append(resps, g.Response)
		comments, invited = append(comments, g.Comment), append(invited, g.InvitedBy)
		var at *time.Time
		if !g.RespondedAt.IsZero() {
			t := g.RespondedAt
			at = &t
		}
		answered = append(answered, at)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM calendar_guests WHERE tenant_id = $1 AND event_id = $2::uuid
		AND guest_type || ':' || guest_id <> ALL ($3::text[])`, tenant, id, keys); err != nil {
		return err
	}
	if len(gs) == 0 {
		return nil
	}
	_, err := tx.Exec(ctx, `INSERT INTO calendar_guests (tenant_id, event_id, guest_type, guest_id, response, comment,
			responded_at, invited_by)
		SELECT $1, $2::uuid, g.t, g.i, g.r, g.c, g.a, g.b
		FROM unnest($3::text[], $4::text[], $5::text[], $6::text[], $7::timestamptz[], $8::text[]) AS g (t, i, r, c, a, b)
		ON CONFLICT (event_id, guest_type, guest_id) DO UPDATE SET response = EXCLUDED.response,
			comment = EXCLUDED.comment, responded_at = EXCLUDED.responded_at, invited_by = EXCLUDED.invited_by`,
		tenant, id, types, ids, resps, comments, answered, invited)
	return err
}

// RespondCalendarEvent locks the event the viewer can read (a series through
// its plan) and writes the answer's guest rows. Without rdb 0139 nobody is a
// guest.
func (s *Postgres) RespondCalendarEvent(ctx context.Context, tenant, viewer, id string, a CalendarRSVP, now time.Time) (CalendarEvent, error) {
	if err := checkCalendarRSVP(a); err != nil {
		return CalendarEvent{}, err
	}
	series, orig := calendarRef(id)
	q, err := s.calendarWritable(ctx, tenant, series)
	if err != nil {
		return CalendarEvent{}, err
	}
	var out CalendarEvent
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		e, err := lockCalendarEvent(ctx, tx, q, tenant, viewer, series, time.Time{})
		if err == nil && (e.RRule != "" || !orig.IsZero()) {
			out, err = writeCalendarSeries(ctx, tx, q, tenant, e, func(b *calendarBundle) (calendarPlan, error) {
				return planCalendarRSVP(b, orig, viewer, a, now)
			})
			return err
		}
		if err == nil {
			err = calendarAnswer(&e, viewer, a, now)
		}
		if err != nil {
			return err
		}
		out = e
		return syncCalendarGuests(ctx, tx, tenant, e.ID, e.Guests)
	})
	return out, err
}
