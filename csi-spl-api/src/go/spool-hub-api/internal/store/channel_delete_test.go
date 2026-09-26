package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-72 / rdb 0052: DeleteChannel is a soft delete. The channel vanishes
// from every read - the door lookups, the members, the list - while its rows
// stay, and RestoreChannel brings it back exactly as it was.
func TestDeleteChannelSoft(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			c := Channel{TenantID: tid, ChannelID: "doomed", Name: "Doomed", CreatedBy: "HUM-1", CreatedAt: now}
			if err := s.CreateChannel(ctx, c); err != nil {
				t.Fatal(err)
			}
			if err := s.AddChannelHumans(ctx, tid, "doomed", []string{"HUM-1", "HUM-2"}, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if err := s.PutPin(ctx, tid, "box-b", pubkey(), false, now, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-b", []string{"CLE-07"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.InviteChannelAgent(ctx, tid, "doomed", "box-b", "CLE-07", now); err != nil {
				t.Fatal(err)
			}
			m := msgFor(tid, uuid4(), "box-wui", now, now.Add(-time.Minute), "d1")
			m.Channel = "doomed"
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}

			// a default channel, and a channel no human created, are refused
			for _, d := range DefaultChannels {
				if err := s.DeleteChannel(ctx, tid, d, "HUM-1", now); !errors.Is(err, ErrConflict) {
					t.Fatalf("delete default %s: %v", d, err)
				}
			}
			if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: "by-wui", Name: "by-wui", CreatedBy: "wui", CreatedAt: now}); err != nil {
				t.Fatal(err)
			}
			if err := s.DeleteChannel(ctx, tid, "by-wui", "HUM-1", now); !errors.Is(err, ErrConflict) {
				t.Fatalf("delete a wui-created channel: %v", err)
			}
			if err := s.DeleteChannel(ctx, tid, "nosuch", "HUM-1", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("delete unknown: %v", err)
			}

			if err := s.DeleteChannel(ctx, tid, "doomed", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if err := s.DeleteChannel(ctx, tid, "doomed", "HUM-1", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second delete: %v", err)
			}
			gone := func(when string) {
				t.Helper()
				if ok, err := s.ChannelKnown(ctx, tid, "doomed"); err != nil || ok {
					t.Fatalf("%s: ChannelKnown %v %v", when, ok, err)
				}
				if _, err := s.Channel(ctx, tid, "doomed"); !errors.Is(err, ErrNotFound) {
					t.Fatalf("%s: Channel %v", when, err)
				}
				if err := s.SetMembersOpenInvite(ctx, tid, "doomed", true); !errors.Is(err, ErrNotFound) {
					t.Fatalf("%s: SetMembersOpenInvite %v", when, err)
				}
				if hs, err := s.ChannelHumanMembers(ctx, tid, "doomed"); err != nil || len(hs) != 0 {
					t.Fatalf("%s: ChannelHumanMembers %v %v", when, hs, err)
				}
				if cs, err := s.HumanChannels(ctx, tid, "HUM-2"); err != nil || len(cs) != 0 {
					t.Fatalf("%s: HumanChannels %v %v", when, cs, err)
				}
				if ms, err := s.ChannelMembers(ctx, tid, "doomed"); err != nil || len(ms) != 0 {
					t.Fatalf("%s: ChannelMembers %v %v", when, ms, err)
				}
				stats, err := s.ViewChannelStats(ctx, tid, now, nil)
				if err != nil {
					t.Fatal(err)
				}
				for _, st := range stats {
					if st.ChannelID == "doomed" {
						t.Fatalf("%s: listed %+v", when, st)
					}
				}
				// the slug stays taken so a restore cannot collide
				if err := s.CreateChannel(ctx, c); !errors.Is(err, ErrConflict) {
					t.Fatalf("%s: re-create %v", when, err)
				}
			}
			gone("deleted")

			if err := s.RestoreChannel(ctx, tid, "doomed"); err != nil {
				t.Fatal(err)
			}
			if err := s.RestoreChannel(ctx, tid, "doomed"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("restore a live channel: %v", err)
			}
			if got, err := s.Channel(ctx, tid, "doomed"); err != nil || got.Name != "Doomed" || got.CreatedBy != "HUM-1" {
				t.Fatalf("restored row: %+v %v", got, err)
			}
			if hs, _ := s.ChannelHumanMembers(ctx, tid, "doomed"); len(hs) != 2 {
				t.Fatalf("restored members: %v", hs)
			}
			if ms, _ := s.ChannelMembers(ctx, tid, "doomed"); len(ms["box-b"]) != 1 {
				t.Fatalf("restored agents: %v", ms)
			}
			stats, _ := s.ViewChannelStats(ctx, tid, now, nil)
			found := false
			for _, st := range stats {
				if st.ChannelID == "doomed" {
					found = st.Count == 1
				}
			}
			if !found {
				t.Fatalf("restored channel not listed with its message: %+v", stats)
			}
		})
	}
}
