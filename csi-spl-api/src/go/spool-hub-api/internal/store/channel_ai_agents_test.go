package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-1684 (rdb 0189): the channel's own AI agents switch, on Memory and
// Postgres. Unset reads nil (follow the workspace default); a value is
// stored and cleared; an unknown channel is ErrNotFound; another workspace's
// channel of the same id is untouched (the RLS tenant policy of channels);
// the workspace default is true until set.
func TestChannelAIAgentsSwitch(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 9, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ca, ok := st.(ChannelAIAgents)
			if !ok {
				t.Fatalf("%s keeps no AI agents switch", name)
			}
			tid, other := newTenant(t, st), newTenant(t, st)
			for _, tn := range []string{tid, other} {
				if err := st.CreateChannel(ctx, Channel{TenantID: tn, ChannelID: "drivers", Name: "drivers",
					CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			read := func(tn string) *bool {
				t.Helper()
				on, err := ca.ChannelAIAgents(ctx, tn, "drivers")
				if err != nil {
					t.Fatal(err)
				}
				return on
			}
			if on := read(tid); on != nil {
				t.Fatalf("unset switch reads %v, want nil", *on)
			}
			off := false
			if err := ca.SetChannelAIAgents(ctx, tid, "drivers", &off, now); err != nil {
				t.Fatal(err)
			}
			if on := read(tid); on == nil || *on {
				t.Fatalf("switch after off: %v", on)
			}
			if on := read(other); on != nil {
				t.Fatalf("another workspace's #drivers changed: %v", *on)
			}
			if err := ca.SetChannelAIAgents(ctx, tid, "no-such", &off, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown channel: %v, want ErrNotFound", err)
			}
			if err := ca.SetChannelAIAgents(ctx, tid, "drivers", nil, now); err != nil {
				t.Fatal(err)
			}
			if on := read(tid); on != nil {
				t.Fatalf("cleared switch reads %v", *on)
			}
			tn, err := st.GetTenant(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			if !tn.ChannelAIAgentsDefault() {
				t.Fatal("a workspace without the setting defaults to off")
			}
		})
	}
}
