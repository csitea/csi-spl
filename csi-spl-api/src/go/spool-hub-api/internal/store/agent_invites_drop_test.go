package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// SPL-6714 (spec 061 3.6): DropAgentInvites on memory and, with
// SPOOL_TEST_PG_DSN, Postgres. Both stores agree: the agent's seats on that
// box go to removed in every channel of the tenant, an archived one
// included; the same id on another box, another id on the box and another
// tenant keep theirs. CONTROLS: a second drop changes nothing; an announce
// does not put a dropped seat back; a new invite does; after unarchive the
// archived channel does not hold the retired seat.
func TestDropAgentInvites(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			ta, tb := newTenant(t, s), newTenant(t, s)
			for _, c := range []struct{ tid, ch string }{{ta, "ops"}, {ta, "old"}, {tb, "ops"}} {
				if err := s.CreateChannel(ctx, Channel{TenantID: c.tid, ChannelID: c.ch, Name: c.ch, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			for _, v := range []struct{ tid, ch, box, id string }{
				{ta, "ops", "box-a", "c-873"}, {ta, "lobby", "box-a", "c-873"}, {ta, "old", "box-a", "c-873"},
				{ta, "ops", "box-a", "c-874"}, {ta, "ops", "box-a2", "c-873"}, {tb, "ops", "box-a", "c-873"},
			} {
				if err := s.InviteChannelAgent(ctx, v.tid, v.ch, v.box, v.id, now); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := s.ArchiveChannel(ctx, ta, "old", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			members := func(tid, ch string) string {
				t.Helper()
				m, err := s.ChannelMembers(ctx, tid, ch)
				if err != nil {
					t.Fatal(err)
				}
				return fmt.Sprint(m)
			}
			ai, ok := s.(AgentInvites)
			if !ok {
				t.Fatalf("%s store does not implement AgentInvites", name)
			}
			got, err := ai.DropAgentInvites(ctx, ta, "box-a", "c-873", now)
			if err != nil || fmt.Sprint(got) != "[lobby old ops]" {
				t.Fatalf("drop: %v %v, want [lobby old ops]", got, err)
			}
			if got, want := members(ta, "ops"), "map[box-a:[c-874] box-a2:[c-873]]"; got != want {
				t.Fatalf("#ops = %s, want %s", got, want)
			}
			if got := members(ta, "lobby"); got != "map[]" {
				t.Fatalf("#lobby = %s, want map[]", got)
			}
			if got, want := members(tb, "ops"), "map[box-a:[c-873]]"; got != want {
				t.Fatalf("CONTROL: tenant B #ops = %s, want %s", got, want)
			}
			if got, err := ai.DropAgentInvites(ctx, ta, "box-a", "c-873", now); err != nil || got != nil {
				t.Fatalf("CONTROL: second drop = %v %v, want nil", got, err)
			}
			if _, err := s.UnarchiveChannel(ctx, ta, "old", "HUM-1"); err != nil {
				t.Fatal(err)
			}
			if got := members(ta, "old"); got != "map[]" {
				t.Fatalf("CONTROL: #old after unarchive = %s, want map[]", got)
			}
			if err := s.SetSubscriptions(ctx, ta, "box-a", []string{"c-873"}, []string{"ops"}, now); err != nil {
				t.Fatal(err)
			}
			if got, want := members(ta, "ops"), "map[box-a:[c-874] box-a2:[c-873]]"; got != want {
				t.Fatalf("CONTROL: #ops after an announce = %s, want %s", got, want)
			}
			if err := s.InviteChannelAgent(ctx, ta, "ops", "box-a", "c-873", now); err != nil {
				t.Fatal(err)
			}
			if got, want := members(ta, "ops"), "map[box-a:[c-873 c-874] box-a2:[c-873]]"; got != want {
				t.Fatalf("#ops after a new invite = %s, want %s", got, want)
			}
		})
	}
}
