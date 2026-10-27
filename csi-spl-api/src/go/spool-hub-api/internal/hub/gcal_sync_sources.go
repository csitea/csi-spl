package hub

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The member's existing Google calendars, read into Spool (owner poll
// d93654e1 B, SPL-3852; spec 149 section 2.10). Besides the hub's own
// "Spool Hub" calendar (two ways, gcal_sync_in.go), every calendar the
// member shows in Google Calendar (calendarList: selected, not hidden or
// deleted: their primary one, a team calendar they made or subscribed to)
// comes in read-only, as the member's private events:
//
//   - kind other, audience private, creator the member (GcalSpoolOf), so no
//     other member ever reads them and the out half never sends them back
//     (an unmapped gcal: event is never pushed).
//   - source_key gcal:<connection>:src.<calendar hash>.<google id>, with
//     <calendar hash> the first 12 hex of SHA-256(calendar id): an upsert by
//     key, never a duplicate. No map row: nothing is ever written to those
//     calendars, and a map row would make the out half delete at Google.
//   - events.list with each calendar's own sync token (rdb 0233
//     source_sync); a 410 lists it in full from now - gcalInWindow; a
//     cancelled item trashes its import; a changed occurrence of a series
//     (recurringEventId) is skipped, as in the In half.
//   - a calendar the member stops showing (or unsubscribes from, or one of
//     another Google account after a reconnect) has its imports trashed.
//
// It runs only when the cnf scopes hold a read scope (GcalReadsCalendars):
// the hub's own calendar needs only calendar.app.created, the calendar list
// and other calendars need calendar.readonly. A grant made before the scope
// was added is refused by Google (403): the cycle still syncs the hub's own
// calendar and says "reconnect" in status_detail. A failure here never
// fails the two-way half; it is the status detail and is tried again next
// cycle.

// GcalReadScopes are the cnf scopes that let the hub read the member's
// calendar list and every calendar on it.
var GcalReadScopes = []string{
	"https://www.googleapis.com/auth/calendar.readonly",
	"https://www.googleapis.com/auth/calendar",
}

// GcalReadsCalendars: the space separated scopes hold a GcalReadScopes one.
func GcalReadsCalendars(scopes string) bool {
	for _, s := range strings.Fields(scopes) {
		for _, r := range GcalReadScopes {
			if s == r {
				return true
			}
		}
	}
	return false
}

// gcalSourceMark is the source_key infix of a read-only import.
const gcalSourceMark = "src."

// gcalSourcesDetail is the status detail of a grant without the read scope.
const gcalSourcesDetail = "reconnect google calendar to read your existing google calendars"

// gcalSourceHash is the calendar's part of the import key.
func gcalSourceHash(calendarID string) string {
	h := sha256.Sum256([]byte(calendarID))
	return hex.EncodeToString(h[:6])
}

// gcalSourceKey is the source_key of item googleID of calendarID; with
// googleID "" the calendar's key family, with calendarID "" too the
// connection's family of read-only imports.
func gcalSourceKey(connection, calendarID, googleID string) string {
	k := gcalSourcePrefix + connection + ":" + gcalSourceMark
	if calendarID == "" {
		return k
	}
	return k + gcalSourceHash(calendarID) + "." + googleID
}

// sources reads the member's existing calendars in. It answers only the
// errors that stop the cycle (a lost lease, a revoked grant); any other
// failure is cy.srcDetail. cy.srcSync is the token object to store.
func (cy *gcalCycle) sources(ctx context.Context) error {
	if !cy.g.ReadCalendars {
		return nil
	}
	imp, ok := cy.s.o.Store.(store.GcalImport)
	cal, ok2 := cy.s.o.Store.(store.Calendar)
	if !ok || !ok2 {
		return nil
	}
	ids, err := cy.sourceCalendars(ctx)
	if err != nil {
		return cy.sourceFailed(err)
	}
	next := make(map[string]string, len(ids))
	changed := len(ids) != len(cy.c.SourceSync)
	for _, id := range ids {
		if _, had := cy.c.SourceSync[id]; !had {
			changed = true
		}
		tok, err := cy.source(ctx, imp, cal, id, cy.c.SourceSync[id])
		if err != nil {
			if ferr := cy.sourceFailed(err); ferr != nil {
				return ferr
			}
			tok = cy.c.SourceSync[id] // keep the old token: the items are listed again
		}
		next[id] = tok
	}
	if changed {
		if err := cy.sweepSources(ctx, cal, ids); err != nil {
			return cy.sourceFailed(err)
		}
	}
	cy.srcSync = next
	return nil
}

// sourceFailed records a failure of the read-only half as the status
// detail; a lost lease or a revoked grant stops the cycle.
func (cy *gcalCycle) sourceFailed(err error) error {
	if errors.Is(err, store.ErrGcalLeaseLost) || errors.Is(err, gcal.ErrInvalidGrant) {
		return err
	}
	cy.s.o.Log.Warn().Str("tenant", cy.c.Tenant).Str("connection", cy.c.ID).Str("err", err.Error()).
		Msg("gcal: existing google calendars not read")
	var he *gcal.HTTPError
	if errors.As(err, &he) && he.Status == http.StatusForbidden {
		cy.srcDetail = gcalSourcesDetail
	} else if cy.srcDetail == "" {
		cy.srcDetail = gcalDetail(err)
	}
	return nil
}

// sourceCalendars lists the ids of the calendars the member shows in Google
// Calendar, the hub's own one left out.
func (cy *gcalCycle) sourceCalendars(ctx context.Context) ([]string, error) {
	var ids []string
	token := ""
	for {
		var page gcal.CalendarListPage
		err := cy.call(ctx, func(a marketing.Plaintext) error {
			var err error
			page, err = cy.g.Google.ListCalendars(ctx, a, token)
			return err
		})
		if err != nil {
			return nil, err
		}
		for _, c := range page.Items {
			if c.ID != "" && c.ID != cy.c.CalendarID && c.Selected && !c.Hidden && !c.Deleted {
				ids = append(ids, c.ID)
			}
		}
		if page.NextPageToken == "" {
			return ids, nil
		}
		token = page.NextPageToken
	}
}

// source reads one calendar's changes since token ("" = in full from now -
// gcalInWindow; a 410 is the same) and answers the next token, or token
// itself when an item was not written (they are listed again next cycle).
func (cy *gcalCycle) source(ctx context.Context, imp store.GcalImport, cal store.Calendar, id, token string) (string, error) {
	next, err := cy.sourceList(ctx, imp, cal, id, token)
	if errors.Is(err, gcal.ErrSyncTokenGone) {
		next, err = cy.sourceList(ctx, imp, cal, id, "")
	}
	return next, err
}

func (cy *gcalCycle) sourceList(ctx context.Context, imp store.GcalImport, cal store.Calendar, id, token string) (string, error) {
	o := gcal.ListOptions{SyncToken: token, MaxResults: gcalInPage}
	if token == "" {
		o.TimeMin = cy.now().Add(-gcalInWindow)
	}
	failed := false
	for {
		var page gcal.EventsPage
		err := cy.call(ctx, func(a marketing.Plaintext) error {
			var err error
			page, err = cy.g.Google.ListEvents(ctx, a, id, o)
			return err
		})
		if err != nil {
			return "", err
		}
		for _, it := range page.Items {
			err := cy.sourceTake(ctx, imp, cal, gcalSourceKey(cy.c.ID, id, it.ID), it)
			if errors.Is(err, store.ErrGcalLeaseLost) {
				return "", err
			}
			if err != nil && !errors.Is(err, store.ErrInvalidCalendarEvent) {
				failed = true
			}
			if err != nil {
				cy.s.o.Log.Warn().Str("tenant", cy.c.Tenant).Str("connection", cy.c.ID).Str("google_event", it.ID).
					Str("err", err.Error()).Msg("gcal: google event of an existing calendar not written to spool")
			}
		}
		if page.NextPageToken == "" {
			if failed {
				return token, nil
			}
			return page.NextSyncToken, nil
		}
		o.PageToken = page.NextPageToken
	}
}

// sourceTake imports one item, or trashes the import of a cancelled one.
func (cy *gcalCycle) sourceTake(ctx context.Context, imp store.GcalImport, cal store.Calendar, key string, it gcal.Event) error {
	if it.RecurringEventID != "" {
		return nil
	}
	if it.Status == gcalCancelled {
		return cy.trashSourced(ctx, cal, key, func(e store.CalendarEvent) bool { return e.SourceKey == key })
	}
	_, err := imp.PutGcalImported(ctx, cy.c.Tenant, key, GcalSpoolOf(it, cy.c.Human), cy.now())
	return err
}

// sweepSources trashes the read-only imports of calendars no longer read.
func (cy *gcalCycle) sweepSources(ctx context.Context, cal store.Calendar, ids []string) error {
	keep := make(map[string]bool, len(ids))
	for _, id := range ids {
		keep[gcalSourceKey(cy.c.ID, id, "")] = true
	}
	family := gcalSourceKey(cy.c.ID, "", "")
	return cy.trashSourced(ctx, cal, family, func(e store.CalendarEvent) bool {
		rest := strings.TrimPrefix(e.SourceKey, family)
		h, _, ok := strings.Cut(rest, ".")
		return ok && !keep[family+h+"."]
	})
}

// trashSourced trashes the member's live events under the key prefix that
// drop answers true for.
func (cy *gcalCycle) trashSourced(ctx context.Context, cal store.Calendar, prefix string, drop func(store.CalendarEvent) bool) error {
	src, ok := cy.s.o.Store.(store.CalendarSourced)
	if !ok {
		return nil
	}
	evs, err := src.CalendarBySourceKey(ctx, cy.c.Tenant, cy.c.Human, prefix)
	if err != nil {
		return err
	}
	for _, e := range evs {
		if e.CreatorID != cy.c.Human || !drop(e) {
			continue
		}
		if _, err := cal.TrashCalendarEvent(ctx, cy.c.Tenant, cy.c.Human, e.ID, time.Time{}, cy.now()); err != nil &&
			!errors.Is(err, store.ErrNotFound) {
			return err
		}
	}
	return nil
}
