package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Google Calendar sync cycle, the Spool -> Google half (spec 149
// section 2.5, build row B6a, SPL-3226). RunSweeper starts runGcalSync: every
// gcalSyncEvery it syncs the connections that are due, one at a time.
//
// A connection is claimed with a lease (store.Gcal ClaimGcalConnection),
// never a row lock: every store call is its own short statement and the
// Google calls run outside any transaction. The claimed lease end is the
// fencing token: each write of the cycle carries it, and one that matches no
// row (store.ErrGcalLeaseLost: another instance took the lease after
// gcalLease, or the member disconnected) stops the cycle at once. The lease
// is renewed while a long cycle runs, and cleared by FinishGcalSync.
//
// Out: every live event of the workspace the member reads (owner poll
// d93654e1 A, SPL-3852: the workspace's events, not only the member's own;
// the private filter still keeps another member's private event out) goes
// to the target calendar, inserted when unmapped, patched when its sync hash
// changed; a mapped event that is no longer among them (trashed, or turned
// private by another member) is deleted at Google. The map, not the out_cursor, finds a delete: a
// trash leaves updated_at as it was. Exception rows of a series
// (recurring_event_id) are skipped in v1.
//
// The kill switch is GcalConnect.Workspaces: with the list empty nothing is
// claimed at all, and a connection of a workspace not on it is put back
// untouched at Google. The Google -> Spool half (B6b) and the push channel
// (B7) each add one call to gcalCycle.run.

// gcalSyncEvery is the ticker and the interval between two syncs of one
// connection.
const gcalSyncEvery = 60 * time.Second

// gcalLease is how long a claim holds a connection (spec 149 2.5).
const gcalLease = 5 * time.Minute

// gcalRefreshAhead: the access token is refreshed when it expires within it.
const gcalRefreshAhead = 5 * time.Minute

// gcalPerTick caps the connections one tick syncs; the rest wait a tick.
const gcalPerTick = 50

// gcalRetryAfter is when a cycle that failed is due again.
const gcalRetryAfter = 5 * time.Minute

// gcalOffRecheck is when a connection of a workspace off the list is looked
// at again.
const gcalOffRecheck = time.Hour

// gcalSourcePrefix is the source_key family of an event that came from
// Google (2.5, In): B6b maps it; the out half never inserts it.
const gcalSourcePrefix = "gcal:"

// gcalPage is how many events one store read of the out half answers.
const gcalPage = 500

// errGcalCalendarGone: Google answered 404 for the target calendar.
var errGcalCalendarGone = errors.New("gcal: the target calendar is gone")

// gcalAllTime is the range of the out half's reads: every event.
var gcalAllTime = store.CalendarRange{
	Start: time.Date(1, time.January, 1, 0, 0, 0, 0, time.UTC),
	End:   time.Date(9999, time.December, 31, 0, 0, 0, 0, time.UTC),
}

// runGcalSync syncs due connections every gcalSyncEvery until ctx ends.
func (s *Server) runGcalSync(ctx context.Context) {
	t := time.NewTicker(gcalSyncEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for range gcalPerTick {
				claimed, err := s.GcalSyncOnce(ctx)
				if err != nil {
					s.o.Log.Warn().Str("err", err.Error()).Msg("gcal: sync cycle")
				}
				if !claimed {
					break
				}
			}
		}
	}
}

// GcalSyncOnce claims the connection due longest and syncs it. It answers
// whether it claimed one; nothing is claimed while the workspace list is
// empty, the store keeps no connections or Google is not configured.
func (s *Server) GcalSyncOnce(ctx context.Context) (bool, error) {
	g := s.o.Gcal
	gs, has := s.o.Store.(store.Gcal)
	if g == nil || len(g.Workspaces) == 0 || !has || !g.configured() {
		return false, nil
	}
	c, l, err := gs.ClaimGcalConnection(ctx, s.o.Now(), gcalLease)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	cy := &gcalCycle{s: s, g: g, gs: gs, c: c, l: l}
	return true, cy.run(ctx)
}

// POST /v1/me/google-calendar/sync: "Sync now" (spec 149 2.5 and section
// 4). It claims the member's own connection with the ticker's lease, due or
// not, and runs one cycle of the ticker's code in the background: 202 once
// the lease is taken. A live lease (the ticker's or an earlier click) is 409
// sync_in_progress; a revoked connection is 409 gcal_revoked (reconnect); no
// connection is 404 not_found.
func (s *Server) handleGcalSyncNow(w http.ResponseWriter, r *http.Request) {
	t, hum, gs, ok := s.gcalMember(w, r, rbac.SelfKeys)
	if !ok {
		return
	}
	if !s.o.Gcal.configured() {
		writeGcalNotConfigured(w)
		return
	}
	ctx := r.Context()
	c, err := gs.GcalConnection(ctx, t.ID, hum)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no google calendar connection")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "google calendar connection unavailable")
		return
	case c.Status == store.GcalRevoked:
		writeErr(w, http.StatusConflict, "gcal_revoked", "google refused the grant: reconnect google calendar")
		return
	}
	c, l, err := gs.ClaimGcalMember(ctx, t.ID, hum, s.o.Now(), gcalLease)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusConflict, "sync_in_progress", "a google calendar sync is running")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "google calendar sync not started")
		return
	}
	cy := &gcalCycle{s: s, g: s.o.Gcal, gs: gs, c: c, l: l}
	// the cycle outlives the request; it renews and clears its own lease
	go func(ctx context.Context) {
		if err := cy.run(ctx); err != nil {
			s.o.Log.Warn().Str("tenant", c.Tenant).Str("connection", c.ID).Str("err", err.Error()).Msg("gcal: sync now")
		}
	}(context.WithoutCancel(ctx))
	s.o.Log.Info().Str("tenant", t.ID).Str("member", hum).Str("connection", c.ID).Msg("gcal: sync now started")
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "started"})
}

// gcalCycle is one claimed sync of one connection.
type gcalCycle struct {
	s      *Server
	g      *GcalConnect
	gs     store.Gcal
	c      store.GcalConnection
	l      store.GcalLease
	access marketing.Plaintext
	// the read-only half (gcal_sync_sources.go): the token object to store
	// (nil = keep) and the status detail of its failure
	srcSync   map[string]string
	srcDetail string
}

func (cy *gcalCycle) now() time.Time { return cy.s.o.Now() }

// run syncs and finishes the cycle. A lost lease returns at once, writing
// nothing more; invalid_grant revokes the connection; any other failure
// keeps it connected with the reason and due again after gcalRetryAfter.
func (cy *gcalCycle) run(ctx context.Context) error {
	if !cy.g.listed(cy.c.Tenant) {
		return cy.finish(ctx, nil, cy.now().Add(gcalOffRecheck))
	}
	cursor, err := cy.sync(ctx)
	switch {
	case errors.Is(err, store.ErrGcalLeaseLost):
		return err
	case errors.Is(err, gcal.ErrInvalidGrant):
		cy.s.o.Log.Warn().Str("tenant", cy.c.Tenant).Str("connection", cy.c.ID).Msg("gcal: grant revoked at google")
		if err := cy.gs.SetGcalStatus(ctx, cy.l, store.GcalRevoked,
			"google refused the refresh token (invalid_grant): reconnect", cy.now()); err != nil {
			return err
		}
		return cy.finish(ctx, nil, cy.now())
	case err != nil:
		if serr := cy.gs.SetGcalStatus(ctx, cy.l, store.GcalConnected, gcalDetail(err), cy.now()); serr != nil {
			return serr
		}
		if ferr := cy.finish(ctx, nil, cy.now().Add(gcalRetryAfter)); ferr != nil {
			return ferr
		}
		return err
	}
	if cy.c.StatusDetail != cy.srcDetail {
		if err := cy.gs.SetGcalStatus(ctx, cy.l, store.GcalConnected, cy.srcDetail, cy.now()); err != nil {
			return err
		}
	}
	return cy.finish(ctx, cursor, cy.now().Add(gcalSyncEvery))
}

// sync is the cycle's Google work: a valid access token, the target
// calendar, the In and out halves, then the member's existing calendars
// (read-only, gcal_sync_sources.go). A target calendar deleted at Google is
// created again once, and every event written to it anew.
func (cy *gcalCycle) sync(ctx context.Context) (*time.Time, error) {
	cursor, err := cy.twoWay(ctx)
	if err != nil {
		return cursor, err
	}
	return cursor, cy.sources(ctx)
}

// twoWay is the hub's own calendar: In, then out.
func (cy *gcalCycle) twoWay(ctx context.Context) (*time.Time, error) {
	if err := cy.token(ctx, false); err != nil {
		return nil, err
	}
	if err := cy.calendar(ctx); err != nil {
		return nil, err
	}
	cursor, err := cy.inThenOut(ctx)
	if !errors.Is(err, errGcalCalendarGone) {
		return cursor, err
	}
	cy.s.o.Log.Info().Str("tenant", cy.c.Tenant).Str("connection", cy.c.ID).Msg("gcal: target calendar gone, creating it again")
	if err := cy.forgetCalendar(ctx); err != nil {
		return nil, err
	}
	if err := cy.calendar(ctx); err != nil {
		return nil, err
	}
	return cy.out(ctx)
}

// finish ends the cycle: cursors, next due, the lease cleared. The sync
// token is the inbound half's and is kept as stored.
func (cy *gcalCycle) finish(ctx context.Context, cursor *time.Time, next time.Time) error {
	return cy.gs.FinishGcalSync(ctx, cy.l, store.GcalSyncDone{SyncToken: cy.c.SyncToken, OutCursor: cursor,
		SourceSync: cy.srcSync, NextDue: next}, cy.now())
}

// gcalDetail is an error as status_detail: short, never a token (gcal
// errors carry Google's status and message only).
func gcalDetail(err error) string {
	d := err.Error()
	if len(d) > 300 {
		d = d[:300]
	}
	return d
}

// token holds a valid access token: the stored one while it lives longer
// than gcalRefreshAhead, else (or with force) a refreshed one, sealed and
// stored under the lease.
func (cy *gcalCycle) token(ctx context.Context, force bool) error {
	tok, err := cy.gs.GcalTokens(ctx, cy.c.Tenant, cy.c.Human)
	if err != nil {
		return err
	}
	now := cy.now()
	if !force && tok.AccessExpiry.After(now.Add(gcalRefreshAhead)) {
		cy.access, err = cy.g.Sealer.Open(ctx, tok.AccessSealed)
		return err
	}
	ref, err := cy.g.Sealer.Open(ctx, tok.RefreshSealed)
	if err != nil {
		return err
	}
	fresh, err := cy.g.Google.Refresh(ctx, ref, now)
	if err != nil {
		return err
	}
	next := store.GcalTokens{RefreshSealed: tok.RefreshSealed, AccessExpiry: fresh.ExpiresAt}
	if next.AccessSealed, next.KMSKeyID, err = cy.g.Sealer.Seal(ctx, fresh.Access); err != nil {
		return err
	}
	if fresh.Refresh.Reveal() != "" { // Google may rotate the refresh token
		if next.RefreshSealed, _, err = cy.g.Sealer.Seal(ctx, fresh.Refresh); err != nil {
			return err
		}
	}
	if err := cy.gs.SetGcalTokens(ctx, cy.l, next, now); err != nil {
		return err
	}
	cy.access = fresh.Access
	return nil
}

// call runs one Google call; an access token Google refuses (401) is
// refreshed once and the call made again. Before it the lease is renewed
// once half of it has passed, so a long cycle keeps it.
func (cy *gcalCycle) call(ctx context.Context, fn func(marketing.Plaintext) error) error {
	if cy.now().After(cy.l.Until.Add(-gcalLease / 2)) {
		l, err := cy.gs.RenewGcalLease(ctx, cy.l, cy.now(), gcalLease)
		if err != nil {
			return err
		}
		cy.l = l
	}
	err := fn(cy.access)
	if !errors.Is(err, gcal.ErrUnauthorized) {
		return err
	}
	if err := cy.token(ctx, true); err != nil {
		return err
	}
	return fn(cy.access)
}

// calendar creates the target calendar when the connection has none
// (section 2.3) and stores its id.
func (cy *gcalCycle) calendar(ctx context.Context) error {
	if cy.c.CalendarID != "" {
		return nil
	}
	t, err := cy.s.o.Store.GetTenant(ctx, cy.c.Tenant)
	if err != nil {
		return err
	}
	var cal gcal.Calendar
	err = cy.call(ctx, func(a marketing.Plaintext) error {
		var err error
		cal, err = cy.g.Google.CreateCalendar(ctx, a, gcal.Calendar{Summary: GcalCalendarTitle(t)})
		return err
	})
	if err != nil {
		return err
	}
	if err := cy.gs.SetGcalCalendar(ctx, cy.l, cal.ID, cy.now()); err != nil {
		return err
	}
	cy.c.CalendarID = cal.ID
	return nil
}

// forgetCalendar drops the gone calendar and every map row into it.
func (cy *gcalCycle) forgetCalendar(ctx context.Context) error {
	maps, err := cy.gs.GcalEventMaps(ctx, cy.c.Tenant, cy.c.Human)
	if err != nil {
		return err
	}
	for _, m := range maps {
		if err := cy.gs.DeleteGcalEventMap(ctx, cy.l, m.EventID); err != nil {
			return err
		}
	}
	cy.c.CalendarID, cy.c.OutCursor = "", nil
	return nil
}

// events answers every live event of the workspace the member reads (the
// private filter: no Guest filter, poll d93654e1 A), every page.
func (cy *gcalCycle) events(ctx context.Context) ([]store.CalendarEvent, error) {
	cs, ok := cy.s.o.Store.(store.CalendarSearch)
	if !ok {
		return nil, nil
	}
	var out []store.CalendarEvent
	q := store.CalendarQuery{Range: gcalAllTime, Limit: gcalPage}
	for {
		page, err := cs.SearchCalendarEvents(ctx, cy.c.Tenant, cy.c.Human, q)
		if err != nil {
			return nil, err
		}
		out = append(out, page...)
		if len(page) < gcalPage {
			return out, nil
		}
		last := page[len(page)-1]
		q.AfterStart, q.AfterID = last.StartsAt, last.ID
	}
}

// out is the Spool -> Google half. It answers the next out_cursor: the
// newest updated_at it read, or nil (keep the stored one) when a write
// failed, so the next cycle looks at those events again.
func (cy *gcalCycle) out(ctx context.Context) (*time.Time, error) {
	evs, err := cy.events(ctx)
	if err != nil {
		return nil, err
	}
	maps, err := cy.gs.GcalEventMaps(ctx, cy.c.Tenant, cy.c.Human)
	if err != nil {
		return nil, err
	}
	mapped := make(map[string]store.GcalEventMap, len(maps))
	for _, m := range maps {
		mapped[m.EventID] = m
	}
	live := make(map[string]bool, len(evs))
	newest, failed := cy.c.OutCursor, false
	for _, e := range evs {
		if e.RecurringEventID != "" { // an occurrence exception: out of v1
			continue
		}
		live[e.ID] = true
		if newest == nil || e.UpdatedAt.After(*newest) {
			newest = &e.UpdatedAt
		}
		err := cy.push(ctx, e, mapped)
		if errors.Is(err, store.ErrGcalLeaseLost) || errors.Is(err, errGcalCalendarGone) || errors.Is(err, gcal.ErrInvalidGrant) {
			return nil, err
		}
		if err != nil {
			failed = true
			cy.s.o.Log.Warn().Str("tenant", cy.c.Tenant).Str("connection", cy.c.ID).Str("event", e.ID).
				Str("err", err.Error()).Msg("gcal: event not written to google")
		}
	}
	for _, m := range maps {
		if live[m.EventID] {
			continue
		}
		if err := cy.remove(ctx, m); err != nil {
			return nil, err
		}
	}
	if failed {
		return nil, nil
	}
	return newest, nil
}

// push writes one event when it is new to Google or its hash changed.
func (cy *gcalCycle) push(ctx context.Context, e store.CalendarEvent, mapped map[string]store.GcalEventMap) error {
	m, has := mapped[e.ID]
	if !has && strings.HasPrefix(e.SourceKey, gcalSourcePrefix) {
		return nil
	}
	if has && cy.c.OutCursor != nil && !e.UpdatedAt.After(*cy.c.OutCursor) {
		return nil
	}
	hash := GcalSyncHash(e)
	if has && m.SyncHash == hash {
		return nil
	}
	ge := GcalEventOf(e)
	var out gcal.Event
	var err error
	if has {
		err = cy.call(ctx, func(a marketing.Plaintext) error {
			out, err = cy.g.Google.PatchEvent(ctx, a, cy.c.CalendarID, m.GoogleID, ge)
			return err
		})
		if errors.Is(err, gcal.ErrNotFound) { // deleted at Google: write it again
			has = false
		}
	}
	if !has {
		err = cy.call(ctx, func(a marketing.Plaintext) error {
			out, err = cy.g.Google.InsertEvent(ctx, a, cy.c.CalendarID, ge)
			return err
		})
		if errors.Is(err, gcal.ErrNotFound) {
			return errGcalCalendarGone
		}
	}
	if err != nil {
		return err
	}
	err = cy.gs.PutGcalEventMap(ctx, cy.l, store.GcalEventMap{EventID: e.ID, GoogleID: out.ID, ETag: out.Etag, SyncHash: hash}, cy.now())
	if errors.Is(err, store.ErrNotFound) { // the event was deleted meanwhile; the next cycle sees it
		return nil
	}
	return err
}

// remove deletes a mapped event at Google (gone there already is no error)
// and its map row.
func (cy *gcalCycle) remove(ctx context.Context, m store.GcalEventMap) error {
	err := cy.call(ctx, func(a marketing.Plaintext) error {
		return cy.g.Google.DeleteEvent(ctx, a, cy.c.CalendarID, m.GoogleID)
	})
	if err != nil {
		return err
	}
	return cy.gs.DeleteGcalEventMap(ctx, cy.l, m.EventID)
}
