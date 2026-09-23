package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// channels-v1 on memory and, with SPOOL_TEST_PG_DSN, Postgres: seeded
// defaults, create rules, subscriptions, members, stats with unread, and the
// topic filters of view-v1 §4.3/§4.5 (roots, children, DMs, peer, viewer).
func TestStoreChannels(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)

			for _, d := range DefaultChannels {
				if ok, err := s.ChannelKnown(ctx, tid, d); err != nil || !ok {
					t.Fatalf("default %s unknown: %v", d, err)
				}
			}
			if ok, _ := s.ChannelKnown(ctx, tid, "releases"); ok {
				t.Fatal("releases known before create")
			}
			for _, bad := range []string{"lobby", "general", "Bad", ""} {
				if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: bad, Name: bad, CreatedBy: "HUM-1", CreatedAt: now}); !errors.Is(err, ErrConflict) {
					t.Fatalf("create %q: %v", bad, err)
				}
			}
			rel := Channel{TenantID: tid, ChannelID: "releases", Name: "Releases", CreatedBy: "HUM-1", CreatedAt: now}
			if err := s.CreateChannel(ctx, rel); err != nil {
				t.Fatal(err)
			}
			if err := s.CreateChannel(ctx, rel); !errors.Is(err, ErrConflict) {
				t.Fatalf("duplicate create: %v", err)
			}
			if ok, _ := s.ChannelKnown(ctx, tid, "releases"); !ok {
				t.Fatal("releases unknown after create")
			}
			other := newTenant(t, s)
			if ok, _ := s.ChannelKnown(ctx, other, "releases"); ok {
				t.Fatal("channel leaked across tenants")
			}

			for _, b := range []string{"box-a", "box-b"} {
				if err := s.PutPin(ctx, tid, b, pubkey(), false, now, now); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.SetRoster(ctx, tid, "box-a", []string{"GRK-03"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-b", []string{"CLE-07", "CLE-08"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetSubscriptions(ctx, tid, "box-b", []string{"CLE-07", "CLE-08"}, []string{"tasks", "releases", "nosuch", "lobby"}, now); err != nil {
				t.Fatal(err)
			}
			m, err := s.ChannelMembers(ctx, tid, "tasks")
			if err != nil || len(m) != 1 || len(m["box-b"]) != 2 || m["box-b"][0] != "CLE-07" {
				t.Fatalf("tasks members: %v %+v", err, m)
			}
			if m, _ := s.ChannelMembers(ctx, tid, "nosuch"); len(m) != 0 {
				t.Fatalf("unknown channel got members: %+v", m)
			}
			if m, _ := s.ChannelMembers(ctx, tid, "lobby"); len(m) != 2 || len(m["box-a"]) != 1 {
				t.Fatalf("lobby members = roster: %+v", m)
			}
			// replace: box-b drops releases
			if err := s.SetSubscriptions(ctx, tid, "box-b", []string{"CLE-07"}, []string{"tasks"}, now); err != nil {
				t.Fatal(err)
			}
			if m, _ := s.ChannelMembers(ctx, tid, "releases"); len(m) != 0 {
				t.Fatalf("subscriptions not replaced: %+v", m)
			}

			// messages: two #tasks posts, one DM topic, a child topic, an expired #alerts
			root, child, dm := uuid4(), uuid4(), uuid4()
			a1 := msgFor(tid, root, "box-wui", now, now.Add(-5*time.Minute), "a1")
			a1.Channel = "tasks"
			a2 := msgFor(tid, root, "box-wui", now, now.Add(-4*time.Minute), "a2")
			a2.Channel, a2.FromID = "tasks", "HUM-1"
			c1 := msgFor(tid, child, "box-b", now, now.Add(-3*time.Minute), "c1")
			c1.Channel, c1.ParentTaskID = "tasks", root
			d1 := msgFor(tid, dm, "box-b", now, now.Add(-2*time.Minute), "d1")
			d1.FromID, d1.FromBox, d1.ToID, d1.ToBox = "HUM-1", "box-wui", "CLE-07", "box-b"
			old := msgFor(tid, uuid4(), "box-wui", now, now.Add(-time.Hour), "o1")
			old.Channel, old.ExpiresAt = "alerts", now.Add(-time.Minute)
			for _, x := range []Message{a1, a2, c1, d1, old} {
				if _, err := s.InsertMessage(ctx, x); err != nil {
					t.Fatal(err)
				}
			}

			stats, err := s.ViewChannelStats(ctx, tid, now, map[string]ReadMark{"tasks": {At: a1.ReceivedAt, MsgID: a1.MsgID}})
			if err != nil || len(stats) != 4 {
				t.Fatalf("stats: %v %+v", err, stats)
			}
			byID := map[string]ChannelStat{}
			for _, st := range stats {
				byID[st.ChannelID] = st
			}
			if st := byID["tasks"]; !st.Default || st.Count != 3 || st.Unread != 2 || st.Posters != 2 ||
				st.Agents != 1 || st.Boxes != 1 || st.LastMsgID != c1.MsgID || !st.LastAt.Equal(c1.ReceivedAt) {
				t.Fatalf("tasks stat: %+v", st)
			}
			if st := byID["alerts"]; st.Count != 0 || st.Unread != 0 || !st.LastAt.IsZero() {
				t.Fatalf("alerts stat (expired only): %+v", st)
			}
			if st := byID["lobby"]; st.Agents != 3 || st.Boxes != 2 {
				t.Fatalf("lobby stat: %+v", st)
			}
			if st := byID["releases"]; st.Default || st.Name != "Releases" || st.CreatedBy != "HUM-1" {
				t.Fatalf("releases stat: %+v", st)
			}

			ids := func(q TopicQuery) []string {
				q.Now = now
				rows, err := s.ViewTopics(ctx, tid, q)
				if err != nil {
					t.Fatal(err)
				}
				var out []string
				for _, r := range rows {
					out = append(out, r.TaskID)
				}
				return out
			}
			eq := func(what string, got []string, want ...string) {
				t.Helper()
				if len(got) != len(want) {
					t.Fatalf("%s: got %v want %v", what, got, want)
				}
				for i := range got {
					if got[i] != want[i] {
						t.Fatalf("%s: got %v want %v", what, got, want)
					}
				}
			}
			eq("all", ids(TopicQuery{}), dm, child, root)
			eq("roots", ids(TopicQuery{Roots: true}), dm, root)
			eq("children", ids(TopicQuery{Parent: root}), child)
			eq("dm", ids(TopicQuery{DM: true}), dm)
			eq("dm peer", ids(TopicQuery{DM: true, Agent: "CLE-07"}), dm)
			eq("dm peer@box", ids(TopicQuery{DM: true, Agent: "CLE-07", AgentBox: "box-b"}), dm)
			eq("dm peer wrong box", ids(TopicQuery{DM: true, Agent: "CLE-07", AgentBox: "box-a"}))
			eq("dm viewer party", ids(TopicQuery{DM: true, Viewer: "HUM-1"}), dm)
			eq("dm viewer not party", ids(TopicQuery{DM: true, Viewer: "HUM-2"}))
			eq("channel roots", ids(TopicQuery{Channel: "tasks", Roots: true}), root)
			rows, _ := s.ViewTopics(ctx, tid, TopicQuery{Now: now, Parent: root})
			if len(rows) != 1 || rows[0].Parent != root || rows[0].Channel != "tasks" {
				t.Fatalf("child row: %+v", rows)
			}
		})
	}
}
