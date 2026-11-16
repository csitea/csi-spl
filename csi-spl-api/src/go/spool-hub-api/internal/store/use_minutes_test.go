package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// rdb 0289 (SPL-5709): hub_use_minutes is the estate's, operator scope only.
// A workspace scope reads none of it, not even its own member's row; the
// operator scope (CONTROL) reads it. Postgres only.
// RED CONTROL (run 2026-11-16): the upserts without their last_minute
// guard fail here with "same minute again: {Workspace:true Hub:true}".
func TestUseMinutesHubRowsOperatorOnly(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	hum := uid("HUM-")
	at := time.Date(2031, 3, 4, 5, 6, 7, 0, time.UTC)
	c, err := pg.RecordUseMinute(ctx, tenant, hum, at)
	if err != nil || !c.Workspace || !c.Hub {
		t.Fatalf("first minute: %+v %v", c, err)
	}
	if c, err := pg.RecordUseMinute(ctx, tenant, hum, at.Add(20*time.Second)); err != nil || c.Workspace || c.Hub {
		t.Fatalf("same minute again: %+v %v, want counted nowhere", c, err)
	}
	var n int
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM hub_use_minutes WHERE human_id = $1`, hum).Scan(&n)
	}); err != nil || n != 0 {
		t.Fatalf("workspace scope reads %d hub_use_minutes row(s) (%v), want 0", n, err)
	}
	got, err := pg.HubUseMinutesOf(ctx, []string{hum}, "2031-03-04", "2031-03-04")
	if err != nil || got[hum] != 1 {
		t.Fatalf("CONTROL operator read: %v %v, want 1", got, err)
	}
	here, err := pg.WorkspaceUseMinutes(ctx, tenant, "2031-03-04", "2031-03-04")
	if err != nil || here[hum] != 1 {
		t.Fatalf("workspace read: %v %v, want 1", here, err)
	}
}
