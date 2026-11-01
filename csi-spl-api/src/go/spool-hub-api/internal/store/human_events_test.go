package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// events-v1 store (rdb 0045) on memory and, with SPOOL_TEST_PG_DSN,
// Postgres: own rows only, newest first, paging, the 500-row trim, clear, and
// the row checks the table enforces.
func TestHumanEvents(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			h := s.(Humans)
			es := s.(HumanEvents)
			a, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("ev-a-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			b, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("ev-b-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			at := now.Add(-time.Second)
			if _, err := es.AddHumanEvents(ctx, "HUM-999999999", []HumanEvent{{Message: "x"}}, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown human: %v", err)
			}
			for _, bad := range []HumanEvent{{ErrorID: "ERR-nope"}, {Status: 1000}, {Message: strings.Repeat("m", 801)}, {Method: "\xff"}} {
				if _, err := es.AddHumanEvents(ctx, a, []HumanEvent{bad}, now); err == nil {
					t.Fatalf("bad row accepted: %+v", bad)
				}
			}
			n, err := es.AddHumanEvents(ctx, a, []HumanEvent{
				{ErrorID: "ERR-20260925-190000-9B2F", OccurredAt: &at, Source: "api", Status: 502, Message: "one", Route: "/lobby"},
				{Message: "two"},
			}, now)
			if err != nil || n != 2 {
				t.Fatalf("add: %d %v", n, err)
			}
			if _, err := es.AddHumanEvents(ctx, b, []HumanEvent{{Message: "bob"}}, now); err != nil {
				t.Fatal(err)
			}
			got, err := es.HumanEventsPage(ctx, a, 0, 10)
			if err != nil || len(got) != 2 || got[0].Message != "two" || got[1].Message != "one" {
				t.Fatalf("page: %v %+v", err, got)
			}
			one := got[1]
			if one.Kind != HumanEventKindError || one.HumanID != a || one.Status != 502 || one.OccurredAt == nil ||
				!one.OccurredAt.Equal(at) || !one.ReceivedAt.Equal(now) || one.ErrorID != "ERR-20260925-190000-9B2F" {
				t.Fatalf("row: %+v", one)
			}
			if p, _ := es.HumanEventsPage(ctx, a, got[0].ID, 10); len(p) != 1 || p[0].Message != "one" {
				t.Fatalf("before: %+v", p)
			}
			// Trim to the newest HumanEventsKeep.
			batch := make([]HumanEvent, 0, HumanEventsKeep+5)
			for i := 0; i < HumanEventsKeep+5; i++ {
				batch = append(batch, HumanEvent{Message: fmt.Sprintf("m%03d", i)})
			}
			if _, err := es.AddHumanEvents(ctx, a, batch, now); err != nil {
				t.Fatal(err)
			}
			all, _ := es.HumanEventsPage(ctx, a, 0, HumanEventsKeep+50)
			if len(all) != HumanEventsKeep || all[0].Message != fmt.Sprintf("m%03d", HumanEventsKeep+4) || all[len(all)-1].Message != "m005" {
				t.Fatalf("trim: %d rows, newest %q oldest %q", len(all), all[0].Message, all[len(all)-1].Message)
			}
			if bob, _ := es.HumanEventsPage(ctx, b, 0, 10); len(bob) != 1 {
				t.Fatalf("trim touched bob: %+v", bob)
			}
			c, err := es.ClearHumanEvents(ctx, a)
			if err != nil || c != HumanEventsKeep {
				t.Fatalf("clear: %d %v", c, err)
			}
			if p, _ := es.HumanEventsPage(ctx, a, 0, 10); len(p) != 0 {
				t.Fatalf("after clear: %+v", p)
			}
			if bob, _ := es.HumanEventsPage(ctx, b, 0, 10); len(bob) != 1 {
				t.Fatalf("clear touched bob: %+v", bob)
			}
		})
	}
}

// spec 162 C7/C8: DeleteHumanEvents deletes only the named rows of the
// human, never another human's row named by id.
func TestHumanEventsDeleteOwnOnly(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			h := s.(Humans)
			es := s.(HumanEvents)
			a, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("evd-a-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			b, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("evd-b-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := es.AddHumanEvents(ctx, a, []HumanEvent{{Message: "a1"}, {Message: "a2"}, {Message: "a3"}, {Message: "a4"}}, now); err != nil {
				t.Fatal(err)
			}
			if _, err := es.AddHumanEvents(ctx, b, []HumanEvent{{Message: "b1"}, {Message: "b2"}}, now); err != nil {
				t.Fatal(err)
			}
			mine, _ := es.HumanEventsPage(ctx, a, 0, 10)
			bobs, _ := es.HumanEventsPage(ctx, b, 0, 10)
			ids := []int64{mine[0].ID, mine[1].ID, mine[2].ID, bobs[0].ID, bobs[1].ID}
			n, err := es.DeleteHumanEvents(ctx, a, ids)
			if err != nil || n != 3 {
				t.Fatalf("delete: %d %v, want 3", n, err)
			}
			if left, _ := es.HumanEventsPage(ctx, a, 0, 10); len(left) != 1 || left[0].ID != mine[3].ID {
				t.Fatalf("alice left %+v, want only %d", left, mine[3].ID)
			}
			if left, _ := es.HumanEventsPage(ctx, b, 0, 10); len(left) != 2 {
				t.Fatalf("bob left %d rows, want 2: the delete crossed humans", len(left))
			}
			if n, err := es.DeleteHumanEvents(ctx, a, []int64{mine[0].ID}); err != nil || n != 0 {
				t.Fatalf("delete again: %d %v, want 0", n, err)
			}
		})
	}
}

// SPL-4559: the WUI re-sends a batch whose answer it lost (event-log.mjs), so
// the same event (human, error_id, occurred_at) arrives twice; it is stored
// once (rdb 0248). An event with no error_id or no occurred_at is never a
// re-send match and is stored every time.
func TestHumanEventsResendStoredOnce(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			es := s.(HumanEvents)
			a, err := s.(Humans).Admit(ctx, Identity{Provider: "google", Subject: uid("evr-a-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			b, err := s.(Humans).Admit(ctx, Identity{Provider: "google", Subject: uid("evr-b-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			at := now.Add(-22 * time.Second)
			ev := HumanEvent{ErrorID: "ERR-CLIENT-20261031-120000-AB12", OccurredAt: &at, Source: "omnibox-send", Code: "hub_down"}
			if n, err := es.AddHumanEvents(ctx, a, []HumanEvent{ev, ev}, now); err != nil || n != 1 {
				t.Fatalf("first send: %d %v, want 1 stored", n, err)
			}
			if n, err := es.AddHumanEvents(ctx, a, []HumanEvent{ev}, now.Add(22*time.Second)); err != nil || n != 0 {
				t.Fatalf("re-send: %d %v, want 0 stored", n, err)
			}
			if n, err := es.AddHumanEvents(ctx, b, []HumanEvent{ev}, now); err != nil || n != 1 {
				t.Fatalf("other human, same event: %d %v, want 1 stored", n, err)
			}
			later := at.Add(time.Millisecond)
			blank := []HumanEvent{{Message: "no id", OccurredAt: &at}, {Message: "no id", OccurredAt: &at},
				{ErrorID: ev.ErrorID}, {ErrorID: ev.ErrorID}, {ErrorID: ev.ErrorID, OccurredAt: &later}}
			if n, err := es.AddHumanEvents(ctx, a, blank, now); err != nil || n != len(blank) {
				t.Fatalf("non-matching rows: %d %v, want %d stored", n, err, len(blank))
			}
			got, err := es.HumanEventsPage(ctx, a, 0, 20)
			if err != nil || len(got) != 1+len(blank) {
				t.Fatalf("rows: %d %v, want %d: the re-sent event was stored twice", len(got), err, 1+len(blank))
			}
			if bob, _ := es.HumanEventsPage(ctx, b, 0, 10); len(bob) != 1 {
				t.Fatalf("bob rows: %+v, want 1", bob)
			}
		})
	}
}

// SPL-4559 rdb 0248 on stored duplicates: prd already held a re-sent pair
// (events 1195 + 1197), and the file deletes rows. Seeded with the index
// dropped (one rolled-back transaction), 0248 applied twice keeps the lowest
// event_id of each (human, error_id, occurred_at), every row with an empty error_id
// or no occurred_at, the other human's copy, and leaves the index in place.
func TestHumanEventsResendOnceMigration(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0248_human_events_resend_once.sql"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	a, err := pg.Admit(ctx, Identity{Provider: "google", Subject: uid("evm-a-")}, "", AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := pg.Admit(ctx, Identity{Provider: "google", Subject: uid("evm-b-")}, "", AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	at := now.Add(-22 * time.Second)
	const errID = "ERR-CLIENT-20261031-120000-AB12"
	var keep, gone, blank []int64
	err = pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DROP INDEX human_events_resend_once`); err != nil {
			return err
		}
		add := func(human, errorID string, occurred *time.Time) int64 {
			t.Helper()
			var id int64
			if err := tx.QueryRow(ctx, `INSERT INTO human_events (human_id, kind, error_id, occurred_at, received_at)
				VALUES ($1, 'error', $2, $3, $4) RETURNING event_id`, human, errorID, occurred, now).Scan(&id); err != nil {
				t.Fatal(err)
			}
			return id
		}
		keep = append(keep, add(a, errID, &at))
		gone = append(gone, add(a, errID, &at), add(a, errID, &at))
		keep = append(keep, add(b, errID, &at))
		blank = append(blank, add(a, "", &at), add(a, "", &at), add(a, errID, nil), add(a, errID, nil))
		for i := 0; i < 2; i++ {
			if _, err := tx.Exec(ctx, string(raw)); err != nil {
				return fmt.Errorf("apply %d: %w", i+1, err)
			}
		}
		var idx int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM pg_indexes WHERE tablename = 'human_events'
			AND indexname = 'human_events_resend_once'`).Scan(&idx); err != nil {
			return err
		}
		if idx != 1 {
			t.Errorf("index human_events_resend_once: %d, want 1", idx)
		}
		rows, err := tx.Query(ctx, `SELECT event_id FROM human_events WHERE human_id = ANY($1) ORDER BY event_id`, []string{a, b})
		if err != nil {
			return err
		}
		got, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		want := append(append([]int64{}, keep...), blank...)
		slices.Sort(want)
		if !slices.Equal(got, want) {
			t.Errorf("rows after 0248 x2: %v, want %v (lowest kept; deleted %v)", got, want, gone)
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatal(err)
	}
}
