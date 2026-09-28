package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"
)

// TestRosterReplaceControls (027 T010 CONTROL, the multi-row roster insert):
// a 50-agent replace stores all 50, an empty list clears the box, tenant A's
// replace never touches tenant B's roster for the same box id, and the bot
// seat gate still refuses an over-seat roster without changing the old one.
func TestRosterReplaceControls(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC()
			a, b := newTenant(t, s), newTenant(t, s)
			var fifty []string
			for i := 1; i <= 50; i++ {
				fifty = append(fifty, fmt.Sprintf("CLE-%d", i))
			}
			if err := s.SetRoster(ctx, a, "box-a", fifty, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, b, "box-a", []string{"GRK-1"}, now); err != nil {
				t.Fatal(err)
			}
			if r, _ := s.Roster(ctx, a); len(r["box-a"]) != 50 {
				t.Fatalf("50-agent replace stored %d", len(r["box-a"]))
			}
			if err := s.SetRoster(ctx, a, "box-a", nil, now); err != nil {
				t.Fatal(err)
			}
			if r, _ := s.Roster(ctx, a); len(r["box-a"]) != 0 {
				t.Fatalf("empty list left %v", r)
			}
			if r, _ := s.Roster(ctx, b); fmt.Sprint(r) != "map[box-a:[GRK-1]]" {
				t.Fatalf("tenant A's replace changed tenant B: %v", r)
			}
			capped := uid("t-")
			if err := s.CreateTenant(ctx, Tenant{ID: capped, RootPubKey: pubkey(), SeatsBots: 2}); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, capped, "box-a", []string{"CLE-1", "CLE-2"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, capped, "box-a", []string{"CLE-1", "CLE-2", "CLE-3"}, now); !errors.Is(err, ErrSeatQuota) {
				t.Fatalf("over-seat roster: %v, want ErrSeatQuota", err)
			}
			if r, _ := s.Roster(ctx, capped); fmt.Sprint(r) != "map[box-a:[CLE-1 CLE-2]]" {
				t.Fatalf("a refused roster changed the stored one: %v", r)
			}
		})
	}
}
