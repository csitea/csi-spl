package hub

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Google Calendar sync cycle, the Google -> Spool half (spec 149
// section 2.5 "In", build row B6b, SPL-3339; owner O1 = A: only the
// dedicated "Spool Hub" calendar comes in, never the member's other
// calendars). B6a's cycle calls inThenOut in place of out: In runs first, so
// a Google edit newer than Spool's is in Spool before the out half compares
// hashes, and the out half never writes it back over.
//
// events.list runs with the stored syncToken; a 410 clears it and lists in
// full from now - gcalInWindow. Each item:
//
//   - recurringEventId (a changed occurrence of a Google series): skipped in v1.
//   - mapped, and its etag or its sync hash is the map row's: our own write
//     coming back (echo), nothing written.
//   - unmapped: imported (store.GcalImport) as the member's private event,
//     kind other, source_key gcal:<connection>:<google id>, and a map row; a
//     cancelled one trashes the import of that key, if any.
//   - mapped to an imported event: Google wins (Spool never edits it).
//   - mapped to a Spool event: the newer side wins (Google updated vs Spool
//     updated_at, a tie goes to Spool); Google's cancel trashes the member's
//     own event (a delete beats an edit) and drops the map row of one the
//     member is only a guest on, which the out half then writes again.
//
// The next syncToken is kept only when every item was written; an item the
// store refuses (ErrInvalidCalendarEvent) is logged and skipped, so it never
// holds the token back.

// gcalInWindow is how far back a full list reaches (spec 149 2.5).
const gcalInWindow = 30 * 24 * time.Hour

// gcalInPage is the page size of events.list.
const gcalInPage = 250

// GcalUntitled is the title of a Google event with an empty summary: the
// WUI's i18n key (csi-spl-wui/i18n/locales/en.json gcal.untitled_event),
// because a Spool title is 1..200 characters (rdb 0125).
const GcalUntitled = "gcal.untitled_event"

// gcalCancelled is Google's status of a deleted event.
const gcalCancelled = "cancelled"

// inThenOut is the cycle's event work: the In half, then the out half.
func (cy *gcalCycle) inThenOut(ctx context.Context) (*time.Time, error) {
	if err := cy.in(ctx); err != nil {
		return nil, err
	}
	return cy.out(ctx)
}

// gcalIn is one In pass: the stores it writes and the member's map rows by
// Google id.
type gcalIn struct {
	cy  *gcalCycle
	cal store.Calendar
	imp store.GcalImport
	by  map[string]store.GcalEventMap
}

// in lists the target calendar's changes and writes them into Spool. A
// calendar gone at Google is errGcalCalendarGone (the cycle creates it
// again, with no sync token).
func (cy *gcalCycle) in(ctx context.Context) error {
	cal, ok := cy.s.o.Store.(store.Calendar)
	imp, ok2 := cy.s.o.Store.(store.GcalImport)
	if !ok || !ok2 {
		return nil
	}
	maps, err := cy.gs.GcalEventMaps(ctx, cy.c.Tenant, cy.c.Human)
	if err != nil {
		return err
	}
	pass := &gcalIn{cy: cy, cal: cal, imp: imp, by: make(map[string]store.GcalEventMap, len(maps))}
	for _, m := range maps {
		pass.by[m.GoogleID] = m
	}
	from := cy.c.SyncToken
	next, err := pass.list(ctx, from)
	if errors.Is(err, gcal.ErrSyncTokenGone) {
		cy.s.o.Log.Info().Str("tenant", cy.c.Tenant).Str("connection", cy.c.ID).Msg("gcal: sync token gone, listing in full")
		from = ""
		next, err = pass.list(ctx, from)
	}
	switch {
	case errors.Is(err, gcal.ErrNotFound):
		cy.c.SyncToken = ""
		return errGcalCalendarGone
	case err != nil:
		return err
	}
	cy.c.SyncToken = from
	if next != "" {
		cy.c.SyncToken = next
	}
	return nil
}

// list reads every page from token ("" = in full from now - gcalInWindow)
// and takes each item. It answers the next sync token, or "" when an item
// failed, so the next cycle lists those items again.
func (p *gcalIn) list(ctx context.Context, token string) (string, error) {
	cy := p.cy
	o := gcal.ListOptions{SyncToken: token, MaxResults: gcalInPage}
	if token == "" {
		o.TimeMin = cy.now().Add(-gcalInWindow)
	}
	failed := false
	for {
		var page gcal.EventsPage
		err := cy.call(ctx, func(a marketing.Plaintext) error {
			var err error
			page, err = cy.g.Google.ListEvents(ctx, a, cy.c.CalendarID, o)
			return err
		})
		if err != nil {
			return "", err
		}
		for _, it := range page.Items {
			err := p.take(ctx, it)
			if errors.Is(err, store.ErrGcalLeaseLost) || errors.Is(err, gcal.ErrInvalidGrant) {
				return "", err
			}
			if err != nil && !errors.Is(err, store.ErrInvalidCalendarEvent) {
				failed = true
			}
			if err != nil {
				cy.s.o.Log.Warn().Str("tenant", cy.c.Tenant).Str("connection", cy.c.ID).Str("google_event", it.ID).
					Str("err", err.Error()).Msg("gcal: google event not written to spool")
			}
		}
		if page.NextPageToken == "" {
			if failed {
				return "", nil
			}
			return page.NextSyncToken, nil
		}
		o.PageToken = page.NextPageToken
	}
}

// take writes one Google item into Spool (the rules at the top).
func (p *gcalIn) take(ctx context.Context, it gcal.Event) error {
	if it.RecurringEventID != "" {
		return nil
	}
	m, mapped := p.by[it.ID]
	if !mapped {
		if it.Status == gcalCancelled {
			return p.forget(ctx, p.key(it.ID))
		}
		return p.put(ctx, it)
	}
	if it.Etag != "" && it.Etag == m.ETag {
		return nil
	}
	if it.Status == gcalCancelled {
		return p.cancelled(ctx, m)
	}
	ev := GcalSpoolOf(it, p.cy.c.Human)
	if GcalSyncHash(ev) == m.SyncHash {
		return nil
	}
	cur, err := p.cal.GetCalendarEvent(ctx, p.cy.c.Tenant, p.cy.c.Human, m.EventID)
	switch {
	case errors.Is(err, store.ErrNotFound): // trashed in Spool: the out half deletes it at Google
		return nil
	case err != nil:
		return err
	case strings.HasPrefix(cur.SourceKey, p.key("")):
		return p.put(ctx, it)
	}
	return p.patch(ctx, it, ev, cur)
}

// key is the source_key of a Google event of this connection; with "" the
// connection's key family.
func (p *gcalIn) key(googleID string) string {
	return gcalSourcePrefix + p.cy.c.ID + ":" + googleID
}

// put imports it (insert or update by its key) and maps it.
func (p *gcalIn) put(ctx context.Context, it gcal.Event) error {
	cy := p.cy
	e, err := p.imp.PutGcalImported(ctx, cy.c.Tenant, p.key(it.ID), GcalSpoolOf(it, cy.c.Human), cy.now())
	if err != nil {
		return err
	}
	return p.mapTo(ctx, e, it)
}

// mapTo stores the map row of Spool event e and Google item it.
func (p *gcalIn) mapTo(ctx context.Context, e store.CalendarEvent, it gcal.Event) error {
	m := store.GcalEventMap{EventID: e.ID, GoogleID: it.ID, ETag: it.Etag, SyncHash: GcalSyncHash(e)}
	if err := p.cy.gs.PutGcalEventMap(ctx, p.cy.l, m, p.cy.now()); err != nil {
		return err
	}
	p.by[it.ID] = m
	return nil
}

// forget trashes the live import of key, when there is one (its map row
// was lost).
func (p *gcalIn) forget(ctx context.Context, key string) error {
	src, ok := p.cy.s.o.Store.(store.CalendarSourced)
	if !ok {
		return nil
	}
	evs, err := src.CalendarBySourceKey(ctx, p.cy.c.Tenant, p.cy.c.Human, key)
	if err != nil {
		return err
	}
	for _, e := range evs {
		if e.SourceKey != key {
			continue
		}
		if _, err := p.cal.TrashCalendarEvent(ctx, p.cy.c.Tenant, p.cy.c.Human, e.ID, time.Time{}, p.cy.now()); err != nil {
			return err
		}
	}
	return nil
}

// cancelled is a mapped item deleted at Google: the member's own event (or
// an import) goes to the trash, the map row goes.
func (p *gcalIn) cancelled(ctx context.Context, m store.GcalEventMap) error {
	cy := p.cy
	cur, err := p.cal.GetCalendarEvent(ctx, cy.c.Tenant, cy.c.Human, m.EventID)
	switch {
	case errors.Is(err, store.ErrNotFound):
	case err != nil:
		return err
	case cur.CreatorID == cy.c.Human:
		if _, err := p.cal.TrashCalendarEvent(ctx, cy.c.Tenant, cy.c.Human, cur.ID, time.Time{}, cy.now()); err != nil &&
			!errors.Is(err, store.ErrNotFound) {
			return err
		}
	}
	delete(p.by, m.GoogleID)
	return cy.gs.DeleteGcalEventMap(ctx, cy.l, m.EventID)
}

// patch writes Google's values onto the member's own Spool event when
// Google's edit is the newer one; a tie, an older Google edit, an event the
// member is only a guest on or one edited in Spool meanwhile keep Spool's
// values (the out half writes them).
func (p *gcalIn) patch(ctx context.Context, it gcal.Event, ev, cur store.CalendarEvent) error {
	cy := p.cy
	if cur.CreatorID != cy.c.Human || !it.Updated.After(cur.UpdatedAt) {
		return nil
	}
	pt := store.CalendarPatch{Title: &ev.Title, Description: &ev.Description, StartsAt: &ev.StartsAt,
		EndsAt: &ev.EndsAt, AllDay: &ev.AllDay, TimeZone: &ev.TimeZone, IfUpdatedAt: cur.UpdatedAt}
	if ev.RRule != cur.RRule {
		pt.RRule = &ev.RRule
	}
	upd, err := p.cal.UpdateCalendarEvent(ctx, cy.c.Tenant, cy.c.Human, cur.ID, pt, cy.now())
	if errors.Is(err, store.ErrEditConflict) {
		return nil
	}
	if err != nil {
		return err
	}
	upd.ID = cur.ID
	return p.mapTo(ctx, upd, it)
}

// GcalSpoolOf is the Spool event a Google item comes in as (spec 149 2.5,
// Mapping), the inverse of GcalEventOf: summary -> title (cut to 200
// characters, GcalUntitled when empty), description (cut to 4000), start and
// end (an all-day end date is exclusive at Google: a one-day event ends on
// its start), timeZone, the RRULE: line -> rrule. It is the member's private
// event of kind other.
func GcalSpoolOf(it gcal.Event, human string) store.CalendarEvent {
	e := store.CalendarEvent{
		Title: gcalCut(it.Summary, 200), Description: gcalCut(it.Description, 4000), Kind: "other",
		Audience: store.CalendarPrivate, CreatorType: "human", CreatorID: human,
		Status: store.CalendarConfirmed, TimeZone: store.CalendarUTC,
	}
	if strings.TrimSpace(e.Title) == "" {
		e.Title = GcalUntitled
	}
	for _, r := range it.Recurrence {
		if strings.HasPrefix(r, gcalRRulePrefix) {
			e.RRule = strings.TrimPrefix(r, gcalRRulePrefix)
			break
		}
	}
	if it.Start.Date != "" {
		start, _ := time.Parse(time.DateOnly, it.Start.Date)
		end, _ := time.Parse(time.DateOnly, it.End.Date)
		e.AllDay, e.StartsAt, e.EndsAt = true, start, end
		if !end.After(start.AddDate(0, 0, 1)) {
			e.EndsAt = start
		}
		return e
	}
	e.StartsAt, e.EndsAt = it.Start.DateTime.UTC(), it.End.DateTime.UTC()
	if it.Start.TimeZone != "" {
		e.TimeZone = it.Start.TimeZone
	}
	return e
}

// gcalCut is s cut to n characters.
func gcalCut(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
