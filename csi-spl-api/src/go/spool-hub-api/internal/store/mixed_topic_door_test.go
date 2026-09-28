package store

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"
)

// the read door on a MIXED topic - one task holding a #lobby post
// and a DM between two other ends. The door decided whether the topic was
// listed and the per-message filter what ViewTopic returned, but the topic
// LIST summary (Postgres) and search aggregated every message of the task:
// the DM's ends reached a third member as parties, its count and kind, and
// search matched another member's DM that shared a task with one of theirs.
// Memory and Postgres must agree; with SPOOL_TEST_PG_DSN this runs on both.
// CONTROL: the DM's own end sees all of it.
func TestMixedTopicHidesTheDMHalf(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid, task := newTenant(t, s), uuid4()
			pub := msgFor(tid, task, "box-wui", now.Add(-2*time.Minute), now.Add(-2*time.Minute), "env-"+uuid4())
			pub.Channel, pub.Body, pub.FromID, pub.FromBox, pub.ToID = ChannelLobby, "lobby hello", "CLE-01", "box-a", "ALL-0"
			dm := msgFor(tid, task, "box-a", now.Add(-time.Minute), now.Add(-time.Minute), "env-"+uuid4())
			dm.Channel, dm.Body, dm.Kind, dm.FromID, dm.FromBox, dm.ToID = "", "salary figures", "note", "HUM-2", "box-wui", "CLE-01"
			for _, m := range []Message{pub, dm} {
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}

			list := func(reader string) TopicRow {
				t.Helper()
				rows, err := s.ViewTopics(ctx, tid, TopicQuery{Now: now, Reader: reader, Limit: 50})
				if err != nil || len(rows) != 1 {
					t.Fatalf("%s: list %v %+v", reader, err, rows)
				}
				return rows[0]
			}
			hasParty := func(r []string, who string) bool {
				return slices.ContainsFunc(r, func(p string) bool { return strings.HasPrefix(p, who+"@") })
			}
			if r := list("HUM-1"); r.Count != 1 || hasParty(r.Parties, "HUM-2") || slices.Contains(r.Kinds, "note") {
				t.Fatalf("HUM-1 sees the DM half in the list summary: count=%d parties=%v kinds=%v", r.Count, r.Parties, r.Kinds)
			}
			if r := list("HUM-2"); r.Count != 2 || !hasParty(r.Parties, "HUM-2") {
				t.Fatalf("CONTROL: HUM-2 list summary count=%d parties=%v", r.Count, r.Parties)
			}

			se, ok := s.(Searcher)
			if !ok {
				return
			}
			q := func(text, viewer string) SearchQuery {
				v := sq(t, text, now)
				v.Viewer = viewer
				return v
			}
			if rs, err := se.SearchMessages(ctx, tid, q("salary", "HUM-1")); err != nil || len(rs) != 0 {
				t.Fatalf("HUM-1 searched another member's DM: %v %d row(s)", err, len(rs))
			}
			if rs, _ := se.SearchMessages(ctx, tid, q("salary", "HUM-2")); len(rs) != 1 {
				t.Fatalf("CONTROL: HUM-2 finds their own DM: %d row(s)", len(rs))
			}
			// HUM-1 is an end of a message in the task; the DM is still not theirs.
			mine := msgFor(tid, task, "box-a", now.Add(-30*time.Second), now.Add(-30*time.Second), "env-"+uuid4())
			mine.Channel, mine.Body, mine.FromID, mine.FromBox, mine.ToID = "", "my own line", "HUM-1", "box-wui", "CLE-01"
			if _, err := s.InsertMessage(ctx, mine); err != nil {
				t.Fatal(err)
			}
			if rs, _ := se.SearchMessages(ctx, tid, q("salary", "HUM-1")); len(rs) != 0 {
				t.Fatalf("a shared task opened another member's DM to search: %d row(s)", len(rs))
			}
			ts, err := se.SearchTopics(ctx, tid, q("hello", "HUM-1"))
			if err != nil || len(ts) != 1 || hasParty(ts[0].Parties, "HUM-2") || ts[0].Count != 2 {
				t.Fatalf("HUM-1 topic search: %v %+v", err, ts)
			}
		})
	}
}
