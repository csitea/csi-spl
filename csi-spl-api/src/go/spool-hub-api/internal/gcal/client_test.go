package gcal_test

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// Spec 149 row B4 (SPL-3125): the Calendar API side, against fakegcal only.

var t0 = time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)

func timed(summary string, start time.Time) gcal.Event {
	return gcal.Event{Summary: summary, Start: gcal.EventTime{DateTime: start, TimeZone: "UTC"},
		End: gcal.EventTime{DateTime: start.Add(time.Hour), TimeZone: "UTC"}}
}

func ids(evs []gcal.Event) []string {
	out := make([]string, 0, len(evs))
	for _, e := range evs {
		out = append(out, e.ID)
	}
	return out
}

// TestC6 is spec 149 case C6: token exchange, refresh, revoke, events.list
// with a syncToken, and a 410 parsed as ErrSyncTokenGone.
func TestC6(t *testing.T) {
	g, f := newClient(t)
	now := t0
	f.Now = func() time.Time { return now }
	ctx := context.Background()

	// Token exchange: both tokens and the expiry.
	tok := connect(t, g, f, "m1@example.com", now)
	if tok.Access.Reveal() == "" || tok.Refresh.Reveal() == "" || !tok.ExpiresAt.Equal(now.Add(time.Hour)) {
		t.Fatalf("exchange: access %t refresh %t expires %v", tok.Access.Reveal() != "", tok.Refresh.Reveal() != "", tok.ExpiresAt)
	}

	cal, err := g.CreateCalendar(ctx, tok.Access, gcal.Calendar{Summary: "Spool Hub (spool)", TimeZone: "UTC"})
	if err != nil || cal.ID == "" {
		t.Fatalf("create calendar: %+v %v", cal, err)
	}

	// events.list in full, then with its syncToken: only what changed since.
	a, _ := f.AddEvent(cal.ID, timed("a", t0))
	b, _ := f.AddEvent(cal.ID, timed("b", t0.Add(2*time.Hour)))
	full, err := g.ListEvents(ctx, tok.Access, cal.ID, gcal.ListOptions{TimeMin: t0.Add(-30 * 24 * time.Hour)})
	if err != nil || !slices.Equal(ids(full.Items), []string{a.ID, b.ID}) || full.NextSyncToken == "" {
		t.Fatalf("full list: %v %+v", err, full)
	}
	if full.Items[0].Summary != "a" || !full.Items[0].Start.DateTime.Equal(t0) || full.Items[0].Etag == "" || full.Items[0].Updated.IsZero() {
		t.Fatalf("parsed item: %+v", full.Items[0])
	}
	same, err := g.ListEvents(ctx, tok.Access, cal.ID, gcal.ListOptions{SyncToken: full.NextSyncToken})
	if err != nil || len(same.Items) != 0 || same.NextSyncToken == "" {
		t.Fatalf("no change since the token: %v %+v", err, same)
	}
	_ = f.UpdateEvent(cal.ID, a.ID, func(e *gcal.Event) { e.Summary = "a2" })
	_ = f.CancelEvent(cal.ID, b.ID)
	inc, err := g.ListEvents(ctx, tok.Access, cal.ID, gcal.ListOptions{SyncToken: same.NextSyncToken})
	if err != nil || !slices.Equal(ids(inc.Items), []string{a.ID, b.ID}) {
		t.Fatalf("incremental list: %v %+v", err, inc)
	}
	if inc.Items[0].Summary != "a2" || inc.Items[1].Status != "cancelled" {
		t.Fatalf("incremental items: %+v", inc.Items)
	}

	// A 410 on a refused syncToken is ErrSyncTokenGone, and a full list recovers.
	f.ExpireSyncTokens(cal.ID)
	_, err = g.ListEvents(ctx, tok.Access, cal.ID, gcal.ListOptions{SyncToken: inc.NextSyncToken})
	var he *gcal.HTTPError
	if !errors.Is(err, gcal.ErrSyncTokenGone) || !errors.As(err, &he) || he.Status != 410 || he.Reason != "fullSyncRequired" {
		t.Fatalf("410: %v, want ErrSyncTokenGone", err)
	}
	if errors.Is(err, gcal.ErrNotFound) || errors.Is(err, gcal.ErrInvalidGrant) {
		t.Fatalf("410 also maps to another sentinel: %v", err)
	}
	if again, err := g.ListEvents(ctx, tok.Access, cal.ID, gcal.ListOptions{}); err != nil || !slices.Equal(ids(again.Items), []string{a.ID}) {
		t.Fatalf("full list after 410: %v %+v", err, again)
	}

	// Refresh: an expired access token is refused, the refreshed one works.
	f.ExpireAccessTokens()
	if _, err := g.ListEvents(ctx, tok.Access, cal.ID, gcal.ListOptions{}); !errors.Is(err, gcal.ErrUnauthorized) {
		t.Fatalf("expired access: %v, want ErrUnauthorized", err)
	}
	now = now.Add(2 * time.Hour)
	fresh, err := g.Refresh(ctx, tok.Refresh, now)
	if err != nil || fresh.Access.Reveal() == "" || fresh.Access.Reveal() == tok.Access.Reveal() ||
		fresh.Refresh.Reveal() != "" || !fresh.ExpiresAt.Equal(now.Add(time.Hour)) {
		t.Fatalf("refresh: %v new access %t refresh %q expires %v", err, fresh.Access.Reveal() != tok.Access.Reveal(), fresh.Refresh.Reveal(), fresh.ExpiresAt)
	}
	if _, err := g.GetCalendar(ctx, fresh.Access, cal.ID); err != nil {
		t.Fatalf("refreshed access: %v", err)
	}

	// Revoke: the grant is gone at the fake, a refresh is invalid_grant,
	// and revoking again is not an error.
	if err := g.Revoke(ctx, tok.Refresh); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if !f.Revoked(tok.Refresh.Reveal()) || f.Calls("revoke") != 1 {
		t.Fatalf("fake did not see the revoke (calls %d)", f.Calls("revoke"))
	}
	if _, err := g.Refresh(ctx, tok.Refresh, now); !errors.Is(err, gcal.ErrInvalidGrant) {
		t.Fatalf("refresh after revoke: %v, want ErrInvalidGrant", err)
	}
	if err := g.Revoke(ctx, tok.Refresh); err != nil {
		t.Fatalf("second revoke: %v", err)
	}
	if err := g.Revoke(ctx, marketing.NewPlaintext("never-issued")); err != nil {
		t.Fatalf("revoke of an unknown token: %v", err)
	}
}

func TestEventsWriteAndPatch(t *testing.T) {
	g, f := newClient(t)
	ctx := context.Background()
	tok := connect(t, g, f, "m1@example.com", time.Now())
	cal, err := g.CreateCalendar(ctx, tok.Access, gcal.Calendar{Summary: "Spool Hub (spool)"})
	if err != nil {
		t.Fatal(err)
	}
	in := timed("standup", t0)
	in.Description = "daily"
	in.Recurrence = []string{"RRULE:FREQ=DAILY;COUNT=5"}
	in.Visibility = "private"
	ev, err := g.InsertEvent(ctx, tok.Access, cal.ID, in)
	if err != nil || ev.ID == "" || ev.Etag == "" || ev.Status != "confirmed" {
		t.Fatalf("insert: %+v %v", ev, err)
	}
	got, _ := f.Event(cal.ID, ev.ID)
	if got.Summary != "standup" || got.Description != "daily" || !slices.Equal(got.Recurrence, in.Recurrence) ||
		got.Visibility != "private" || !got.Start.DateTime.Equal(t0) {
		t.Fatalf("stored: %+v", got)
	}

	// A patch sends the mapped fields: an emptied description and rrule clear.
	p := timed("standup v2", t0.Add(time.Hour))
	pt, err := g.PatchEvent(ctx, tok.Access, cal.ID, ev.ID, p)
	if err != nil || pt.Summary != "standup v2" || pt.Etag == ev.Etag {
		t.Fatalf("patch: %+v %v", pt, err)
	}
	got, _ = f.Event(cal.ID, ev.ID)
	if got.Description != "" || len(got.Recurrence) != 0 || !got.Start.DateTime.Equal(t0.Add(time.Hour)) || got.ID != ev.ID {
		t.Fatalf("after patch: %+v", got)
	}

	// All-day events travel as dates.
	day, err := g.InsertEvent(ctx, tok.Access, cal.ID, gcal.Event{Summary: "offsite",
		Start: gcal.EventTime{Date: "2026-11-02"}, End: gcal.EventTime{Date: "2026-11-03"}})
	if err != nil || day.Start.Date != "2026-11-02" || !day.Start.DateTime.IsZero() {
		t.Fatalf("all-day: %+v %v", day, err)
	}

	if err := g.DeleteEvent(ctx, tok.Access, cal.ID, ev.ID); err != nil {
		t.Fatal(err)
	}
	if err := g.DeleteEvent(ctx, tok.Access, cal.ID, ev.ID); err != nil {
		t.Fatalf("delete of a deleted event (410) is done: %v", err)
	}
	if err := g.DeleteEvent(ctx, tok.Access, cal.ID, "never"); err != nil {
		t.Fatalf("delete of an unknown event (404) is done: %v", err)
	}
	if _, err := g.PatchEvent(ctx, tok.Access, cal.ID, "never", p); !errors.Is(err, gcal.ErrNotFound) {
		t.Fatalf("patch unknown: %v", err)
	}
	if live := f.Events(cal.ID); !slices.Equal(ids(live), []string{day.ID}) {
		t.Fatalf("live events %v", ids(live))
	}
	if f.Calls("events.insert") != 2 || f.Calls("events.patch") != 2 || f.Calls("events.delete") != 3 {
		t.Fatalf("calls insert %d patch %d delete %d", f.Calls("events.insert"), f.Calls("events.patch"), f.Calls("events.delete"))
	}
}

func TestListPagesAndTimeMin(t *testing.T) {
	g, f := newClient(t)
	ctx := context.Background()
	tok := connect(t, g, f, "m1@example.com", time.Now())
	cal, _ := g.CreateCalendar(ctx, tok.Access, gcal.Calendar{Summary: "Spool Hub (spool)"})
	old, _ := f.AddEvent(cal.ID, timed("old", t0.Add(-60*24*time.Hour)))
	var want []string
	for i := range 5 {
		e, _ := f.AddEvent(cal.ID, timed("e", t0.Add(time.Duration(i)*time.Hour)))
		want = append(want, e.ID)
	}
	var got []string
	o := gcal.ListOptions{TimeMin: t0.Add(-30 * 24 * time.Hour), MaxResults: 2}
	pages := 0
	for {
		p, err := g.ListEvents(ctx, tok.Access, cal.ID, o)
		if err != nil {
			t.Fatal(err)
		}
		pages++
		got = append(got, ids(p.Items)...)
		if p.NextPageToken == "" {
			if p.NextSyncToken == "" {
				t.Fatal("last page carries no sync token")
			}
			break
		}
		if p.NextSyncToken != "" {
			t.Fatal("a middle page carries a sync token")
		}
		o.PageToken = p.NextPageToken
	}
	if pages != 3 || !slices.Equal(got, want) || slices.Contains(got, old.ID) {
		t.Fatalf("pages %d got %v want %v", pages, got, want)
	}
}

func TestCalendarsPerAccount(t *testing.T) {
	g, f := newClient(t)
	ctx := context.Background()
	m1 := connect(t, g, f, "m1@example.com", time.Now())
	m2 := connect(t, g, f, "m2@example.com", time.Now())
	cal, _ := g.CreateCalendar(ctx, m1.Access, gcal.Calendar{Summary: "Spool Hub (spool)"})
	if got, err := g.GetCalendar(ctx, m1.Access, cal.ID); err != nil || got.Summary != "Spool Hub (spool)" {
		t.Fatalf("owner reads: %+v %v", got, err)
	}
	if _, err := g.GetCalendar(ctx, m2.Access, cal.ID); !errors.Is(err, gcal.ErrNotFound) {
		t.Fatalf("another account reads it: %v", err)
	}
	if _, err := g.ListEvents(ctx, m2.Access, cal.ID, gcal.ListOptions{}); !errors.Is(err, gcal.ErrNotFound) {
		t.Fatalf("another account lists it: %v", err)
	}
	f.DeleteCalendar(cal.ID)
	if _, err := g.GetCalendar(ctx, m1.Access, cal.ID); !errors.Is(err, gcal.ErrNotFound) {
		t.Fatalf("deleted calendar: %v", err)
	}
	if n := len(f.Calendars("m1@example.com")); n != 0 {
		t.Fatalf("calendars left %d", n)
	}
}

func TestWatchAndStop(t *testing.T) {
	g, f := newClient(t)
	now := t0
	f.Now = func() time.Time { return now }
	ctx := context.Background()
	tok := connect(t, g, f, "m1@example.com", now)
	cal, _ := g.CreateCalendar(ctx, tok.Access, gcal.Calendar{Summary: "Spool Hub (spool)"})
	in := gcal.Channel{ID: "9b2f3c1e-0000-4000-8000-000000000001", Address: "https://hub.example.com/api/v1/webhooks/google-calendar",
		Token: marketing.NewPlaintext("hmac-of-the-connection")}
	ch, err := g.Watch(ctx, tok.Access, cal.ID, in)
	if err != nil || ch.ID != in.ID || ch.ResourceID == "" || !ch.Expiration.Equal(now.Add(7*24*time.Hour)) {
		t.Fatalf("watch: %+v %v", ch, err)
	}
	calID, echo, _, ok := f.Channel(ch.ID)
	if !ok || calID != cal.ID || echo != "hmac-of-the-connection" {
		t.Fatalf("fake channel %q %q %t", calID, echo, ok)
	}
	in2 := in
	in2.ID = "9b2f3c1e-0000-4000-8000-000000000002"
	in2.Expiration = now.Add(time.Hour)
	ch2, err := g.Watch(ctx, tok.Access, cal.ID, in2)
	if err != nil || !ch2.Expiration.Equal(now.Add(time.Hour)) {
		t.Fatalf("watch with an earlier expiration: %+v %v", ch2, err)
	}
	if err := g.StopChannel(ctx, tok.Access, ch.ID, ch.ResourceID); err != nil {
		t.Fatal(err)
	}
	if _, _, _, ok := f.Channel(ch.ID); ok {
		t.Fatal("channel still live after stop")
	}
	if err := g.StopChannel(ctx, tok.Access, ch.ID, ch.ResourceID); err != nil {
		t.Fatalf("stop of a stopped channel is done: %v", err)
	}
	if _, err := g.Watch(ctx, tok.Access, "nope", in); !errors.Is(err, gcal.ErrNotFound) {
		t.Fatalf("watch an unknown calendar: %v", err)
	}
}
