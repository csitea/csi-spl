package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// HUM-10 bug (topic ee21db20), rdb 0092: DeleteChannel is a HARD delete. The
// channel and everything under it (members, agent seats, messages) are gone,
// and the slug is FREE again - a new channel of the same name succeeds and
// inherits nothing.
func TestDeleteChannelHardFreesTheName(t *testing.T) {
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
			if ok, err := s.ChannelKnown(ctx, tid, "doomed"); err != nil || ok {
				t.Fatalf("ChannelKnown after delete: %v %v", ok, err)
			}
			if _, err := s.Channel(ctx, tid, "doomed"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("Channel after delete: %v", err)
			}

			// THE FIX: the name is free - a new channel of the same slug works,
			// and inherits no member, agent or message.
			fresh := Channel{TenantID: tid, ChannelID: "doomed", Name: "Doomed Again", CreatedBy: "HUM-2", CreatedAt: now}
			if err := s.CreateChannel(ctx, fresh); err != nil {
				t.Fatalf("re-create a deleted slug must succeed, got: %v", err)
			}
			if got, err := s.Channel(ctx, tid, "doomed"); err != nil || got.Name != "Doomed Again" || got.CreatedBy != "HUM-2" {
				t.Fatalf("re-created row: %+v %v", got, err)
			}
			if hs, err := s.ChannelHumanMembers(ctx, tid, "doomed"); err != nil || len(hs) != 0 {
				t.Fatalf("re-created channel inherited members: %v %v", hs, err)
			}
			if ms, err := s.ChannelMembers(ctx, tid, "doomed"); err != nil || len(ms) != 0 {
				t.Fatalf("re-created channel inherited agents: %v %v", ms, err)
			}
			stats, err := s.ViewChannelStats(ctx, tid, now, nil, "", "")
			if err != nil {
				t.Fatal(err)
			}
			for _, st := range stats {
				if st.ChannelID == "doomed" && st.Count != 0 {
					t.Fatalf("re-created channel inherited messages: %+v", st)
				}
			}
		})
	}
}

// rdb 0092: ArchiveChannel hides a channel and reserves its slug while its
// topic cards move to the Archive view; UnarchiveChannel brings it all back,
// but a card archived on its own before the channel archive stays archived.
func TestArchiveChannelReservesNameAndCards(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			c := Channel{TenantID: tid, ChannelID: "arch", Name: "Arch", CreatedBy: "HUM-1", CreatedAt: now}
			if err := s.CreateChannel(ctx, c); err != nil {
				t.Fatal(err)
			}
			if err := s.AddChannelHumans(ctx, tid, "arch", []string{"HUM-1", "HUM-2"}, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if err := s.PutPin(ctx, tid, "box-b", pubkey(), false, now, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-b", []string{"CLE-07"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.InviteChannelAgent(ctx, tid, "arch", "box-b", "CLE-07", now); err != nil {
				t.Fatal(err)
			}
			// a topic card of the channel, and one archived on its own earlier
			card := msgFor(tid, uuid4(), "box-wui", now, now, "card")
			card.Channel, card.IsParent = "arch", 1
			if _, err := s.InsertMessage(ctx, card); err != nil {
				t.Fatal(err)
			}
			pre := msgFor(tid, uuid4(), "box-wui", now, now.Add(time.Second), "pre")
			pre.Channel, pre.IsParent = "arch", 1
			if _, err := s.InsertMessage(ctx, pre); err != nil {
				t.Fatal(err)
			}
			preAt := now.Add(-time.Hour)
			if _, err := s.SetArchived(ctx, tid, pre.MsgID, "HUM-2", preAt, true); err != nil {
				t.Fatal(err)
			}

			// refusals: default, wui-created, unknown
			for _, d := range DefaultChannels {
				if err := s.ArchiveChannel(ctx, tid, d, "HUM-1", now); !errors.Is(err, ErrConflict) {
					t.Fatalf("archive default %s: %v", d, err)
				}
			}
			if err := s.ArchiveChannel(ctx, tid, "nosuch", "HUM-1", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("archive unknown: %v", err)
			}

			at := now.Add(time.Minute)
			if err := s.ArchiveChannel(ctx, tid, "arch", "HUM-1", at); err != nil {
				t.Fatal(err)
			}
			if err := s.ArchiveChannel(ctx, tid, "arch", "HUM-1", at); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second archive: %v", err)
			}
			// hidden everywhere
			if ok, _ := s.ChannelKnown(ctx, tid, "arch"); ok {
				t.Fatal("archived channel still ChannelKnown")
			}
			if _, err := s.Channel(ctx, tid, "arch"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("archived channel still Channel: %v", err)
			}
			stats, _ := s.ViewChannelStats(ctx, tid, now, nil, "", "")
			for _, st := range stats {
				if st.ChannelID == "arch" {
					t.Fatalf("archived channel listed: %+v", st)
				}
			}
			// slug reserved, and ArchivedChannel sees past the flag
			if err := s.CreateChannel(ctx, c); !errors.Is(err, ErrConflict) {
				t.Fatalf("re-create an archived slug: %v", err)
			}
			if got, found, err := s.ArchivedChannel(ctx, tid, "arch"); err != nil || !found || got.ArchivedBy != "HUM-1" || !got.ArchivedAt.Equal(at) {
				t.Fatalf("ArchivedChannel: %+v %v %v", got, found, err)
			}
			// the channel's card is archived; the individually-archived one keeps its own stamp
			if cs, err := s.CardState(ctx, tid, card.MsgID, now); err != nil || cs.ArchivedAt.IsZero() || cs.ArchivedBy != "HUM-1" {
				t.Fatalf("channel card not archived: %+v %v", cs, err)
			}
			if cs, err := s.CardState(ctx, tid, pre.MsgID, now); err != nil || !cs.ArchivedAt.Equal(preAt) || cs.ArchivedBy != "HUM-2" {
				t.Fatalf("pre-archived card changed: %+v %v", cs, err)
			}

			// unarchive: the channel and only the cards this archive stamped come back
			if err := s.UnarchiveChannel(ctx, tid, "arch"); err != nil {
				t.Fatal(err)
			}
			if err := s.UnarchiveChannel(ctx, tid, "arch"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unarchive a live channel: %v", err)
			}
			if got, err := s.Channel(ctx, tid, "arch"); err != nil || got.Name != "Arch" {
				t.Fatalf("unarchived row: %+v %v", got, err)
			}
			if hs, _ := s.ChannelHumanMembers(ctx, tid, "arch"); len(hs) != 2 {
				t.Fatalf("unarchived members: %v", hs)
			}
			if ms, _ := s.ChannelMembers(ctx, tid, "arch"); len(ms["box-b"]) != 1 {
				t.Fatalf("unarchived agents: %v", ms)
			}
			if cs, err := s.CardState(ctx, tid, card.MsgID, now); err != nil || !cs.ArchivedAt.IsZero() {
				t.Fatalf("channel card still archived after unarchive: %+v %v", cs, err)
			}
			if cs, err := s.CardState(ctx, tid, pre.MsgID, now); err != nil || !cs.ArchivedAt.Equal(preAt) {
				t.Fatalf("individually-archived card was unarchived too: %+v %v", cs, err)
			}
		})
	}
}
