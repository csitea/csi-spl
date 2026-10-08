package store

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"strings"
	"testing"
	"time"
)

// The probe asks the catalogue once, again only after seatsRecheck while the
// table is missing, and never again once it is there; an error reads absent.
func TestSeatsProbe(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 3, 9, 0, 0, 0, time.UTC)
	calls, there, fail := 0, false, false
	lookup := func(context.Context) (bool, error) {
		calls++
		if fail {
			return false, errors.New("down")
		}
		return there, nil
	}
	var p seatsProbe
	if p.present(ctx, lookup, t0) || calls != 1 {
		t.Fatalf("absent table: want false after 1 lookup, got %d", calls)
	}
	there = true
	if p.present(ctx, lookup, t0.Add(seatsRecheck-time.Second)) || calls != 1 {
		t.Fatalf("inside the recheck window: want no lookup, got %d", calls)
	}
	if !p.present(ctx, lookup, t0.Add(seatsRecheck)) || calls != 2 {
		t.Fatalf("after the window: want true after 2 lookups, got %d", calls)
	}
	there, fail = false, true
	if !p.present(ctx, lookup, t0.Add(10*seatsRecheck)) || calls != 2 {
		t.Fatalf("once seen: want sticky true with no lookup, got %d", calls)
	}
	var q seatsProbe
	if q.present(ctx, lookup, t0) {
		t.Fatal("a failed lookup reads present")
	}
}

// Without the table the roster read never names it (a hub rolled before rdb
// 0107 reached its database must not 500 on GET /v1/view/roster).
func TestViewBoxesSQLWithoutSeats(t *testing.T) {
	if strings.Contains(viewBoxesSQL(false, false), "agent_seats") {
		t.Fatal("the no-seats roster read names agent_seats")
	}
	if !strings.Contains(viewBoxesSQL(true, false), "agent_seats") {
		t.Fatal("the seats roster read does not read agent_seats")
	}
}

// On Postgres with the probe saying "absent": SetRoster and ViewRoster work
// and write / read no seat; once the table is seen, a new agent is seated.
func TestRosterWithoutAgentSeatsTable(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	tid := newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := pg.PutPin(ctx, tid, "box-a", pub, false, now, now); err != nil {
		t.Fatal(err)
	}
	there := false
	pg.seats.check = func(context.Context) (bool, error) { return there, nil }
	if err := pg.SetRoster(ctx, tid, "box-a", []string{"c-004"}, now); err != nil {
		t.Fatalf("SetRoster without the table: %v", err)
	}
	rs, err := pg.ViewRoster(ctx, tid)
	if err != nil || len(rs.Boxes) != 1 || len(rs.Boxes[0].Agents) != 1 || rs.Boxes[0].SeatedAt != nil {
		t.Fatalf("ViewRoster without the table: %+v %v", rs.Boxes, err)
	}
	var n int
	if err := pg.queryRowTenant(ctx, tid, `SELECT count(*) FROM agent_seats WHERE tenant_id = $1`, []any{tid}, &n); err != nil || n != 0 {
		t.Fatalf("a seat was written while the probe said absent: %d %v", n, err)
	}
	there = true
	pg.seats.checked = time.Time{}
	later := now.Add(time.Minute)
	if err := pg.SetRoster(ctx, tid, "box-a", []string{"c-004", "c-005"}, later); err != nil {
		t.Fatal(err)
	}
	rs, err = pg.ViewRoster(ctx, tid)
	if err != nil || len(rs.Boxes) != 1 {
		t.Fatalf("%+v %v", rs.Boxes, err)
	}
	s := rs.Boxes[0].SeatedAt
	if _, old := s["c-004"]; old || !s["c-005"].Equal(later) {
		t.Fatalf("seats once the table is seen: %v, want only c-005 at %v", s, later)
	}
}
