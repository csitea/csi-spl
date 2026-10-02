package store

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// R2-4: ViewTopicsDMCounts counts the DM seed's page in the store - in SQL
// with one GROUP BY on Postgres, by DMPageCounts on memory - on memory and,
// with SPOOL_TEST_PG_DSN, Postgres. One topic per rule, each with its own
// written-down count, so a rule that drifts fails its own line.
func TestViewTopicsDMCountsRules(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tid := newTenant(t, s)
			base := time.Date(2026, 9, 19, 9, 0, 0, 0, time.UTC)
			line := func(task string, at time.Duration, from, to, typedBy, ch string) Message {
				m := msgFor(tid, task, "box-a", base, base.Add(at), "e")
				m.FromID, m.ToID, m.TypedBy, m.Channel = from, to, typedBy, ch
				m.FromBox, m.ToBox = "box-a", "box-a"
				if from == "HUM-1" {
					m.FromBox = "box-wui"
				}
				if to == "HUM-1" {
					m.ToBox = "box-wui"
				}
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			own, cur, str, place, empty := uuid4(), uuid4(), uuid4(), uuid4(), uuid4()
			// CLE-77889: our post and our terminal line are never new; a line
			// someone else typed, or nobody typed, is.
			line(own, 1*time.Second, "HUM-1", "CLE-07", "", "")
			line(own, 2*time.Second, "CLE-07", "HUM-1", "HUM-1", "")
			line(own, 3*time.Second, "CLE-07", "HUM-1", "HUM-2", "")
			line(own, 4*time.Second, "CLE-07", "HUM-1", "", "")
			// the cursor: older read, exact (ts, id) read, same ts other id new,
			// newer new.
			line(cur, 1*time.Second, "CLE-08", "HUM-1", "", "")
			mark := line(cur, 2*time.Second, "CLE-08", "HUM-1", "", "")
			line(cur, 2*time.Second, "CLE-08", "HUM-1", "", "")
			line(cur, 3*time.Second, "CLE-08", "HUM-1", "", "")
			// CLE-77873: times compare as strings - a whole second sorts after
			// its own .5 (new), .4 and .49 sort before it (read).
			line(str, 0, "CLE-09", "HUM-1", "", "")
			line(str, 400*time.Millisecond, "CLE-09", "HUM-1", "", "")
			line(str, 490*time.Millisecond, "CLE-09", "HUM-1", "", "")
			// CLE-77845: a channel row in a DM topic is on the page but no DM;
			// a broadcast end is never a peer.
			line(place, 1*time.Second, "CLE-10", "HUM-1", "", "")
			line(place, 2*time.Second, "CLE-10", "HUM-1", "", "feedback")
			line(place, 3*time.Second, "HUM-1", "ALL-0", "", "")
			// an empty cursor time: all new.
			line(empty, 1*time.Second, "CLE-11", "HUM-1", "", "")
			line(empty, 2*time.Second, "CLE-11", "HUM-1", "", "")

			reads := map[string]DMRead{
				"CLE-08@box-a": {TS: base.Add(2 * time.Second).Format(time.RFC3339Nano), MsgID: mark.MsgID},
				"CLE-09@box-a": {TS: "2026-09-19T09:00:00.5Z"},
				"CLE-11@box-a": {},
			}
			q := TopicsMsgQuery{TaskIDs: []string{own, cur, str, place, empty, uuid4()}, PerTopic: 50, Reader: "HUM-1",
				ReaderChannels: []string{"feedback"}, Now: base}
			got, err := s.(TopicsDMCounter).ViewTopicsDMCounts(ctx, tid, q, reads)
			if err != nil {
				t.Fatal(err)
			}
			want := map[string]TopicDMCounts{
				own:   {4, map[string]int{"CLE-07@box-a": 2}, map[string]int{"CLE-07@box-a": 4}},
				cur:   {4, map[string]int{"CLE-08@box-a": 2}, map[string]int{"CLE-08@box-a": 4}},
				str:   {3, map[string]int{"CLE-09@box-a": 1}, map[string]int{"CLE-09@box-a": 3}},
				place: {3, map[string]int{"CLE-10@box-a": 1}, map[string]int{"CLE-10@box-a": 1}},
				empty: {2, map[string]int{"CLE-11@box-a": 2}, map[string]int{"CLE-11@box-a": 2}},
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("counts\n got %v\nwant %v", got, want)
			}
			// the page: PerTopic 2 counts the newest 2 lines only.
			q.PerTopic = 2
			if got, err = s.(TopicsDMCounter).ViewTopicsDMCounts(ctx, tid, q, reads); err != nil {
				t.Fatal(err)
			}
			if c := got[own]; c.Page != 2 || c.Unread["CLE-07@box-a"] != 2 || c.Total["CLE-07@box-a"] != 2 {
				t.Fatalf("PerTopic 2: %+v, want page 2 unread 2 total 2", c)
			}
			// CONTROL: another reader sees our own lines as new.
			q.PerTopic, q.Reader = 50, "CLE-07"
			if got, err = s.(TopicsDMCounter).ViewTopicsDMCounts(ctx, tid, q, nil); err != nil {
				t.Fatal(err)
			}
			if c := got[own]; c.Unread["HUM-1@box-wui"] != 1 || len(c.Unread) != 1 {
				t.Fatalf("CLE-07 reading: %+v, want HUM-1@box-wui unread 1", c)
			}
		})
	}
}

// The WUI's parity fixture (csi-spl-wui/tests/unit/dm-counts-parity.json)
// through every driver: the store's counts equal DMPageCounts over the rows
// the read door lets in, so the SQL and the Go rules are one set.
func TestViewTopicsDMCountsMatchWUIFixture(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-wui", "tests", "unit", "dm-counts-parity.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Name    string
			Self    string
			Cursors map[string]struct{ TS, ID string }
			Topics  []struct {
				Messages []struct {
					MsgID      string `json:"msg_id"`
					From       string
					FromBox    string `json:"from_box"`
					To         string
					ToBox      string `json:"to_box"`
					TypedBy    string `json:"typed_by"`
					Channel    string
					ReceivedAt string `json:"received_at"`
				}
			}
		}
	}
	if err := json.Unmarshal(src, &fx); err != nil {
		t.Fatal(err)
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			for _, c := range fx.Cases {
				tid := newTenant(t, s)
				ids := map[string]string{}
				var tasks, chans []string
				oracle := map[string][]TopicMsgMeta{}
				now := time.Now()
				for _, tp := range c.Topics {
					task := uuid4()
					tasks = append(tasks, task)
					for _, fm := range tp.Messages {
						at, err := time.Parse(time.RFC3339Nano, fm.ReceivedAt)
						if err != nil {
							t.Fatal(err)
						}
						if at.Before(now) {
							now = at
						}
						m := msgFor(tid, task, fm.ToBox, at, at, "e")
						ids[fm.MsgID] = m.MsgID
						m.FromID, m.FromBox, m.ToID, m.TypedBy, m.Channel = fm.From, fm.FromBox, fm.To, fm.TypedBy, fm.Channel
						if fm.Channel != "" {
							chans = append(chans, fm.Channel)
						}
						if _, err := s.InsertMessage(ctx, m); err != nil {
							t.Fatal(err)
						}
						oracle[task] = append(oracle[task], TopicMsgMeta{MsgID: m.MsgID, ReceivedAt: at, FromID: m.FromID,
							FromBox: m.FromBox, ToID: m.ToID, ToBox: m.ToBox, TypedBy: m.TypedBy, Channel: m.Channel})
					}
				}
				reads := map[string]DMRead{}
				for k, v := range c.Cursors {
					if len(k) > 3 && k[:3] == "dm:" {
						id := v.ID
						if u, ok := ids[id]; ok {
							id = u
						}
						reads[k[3:]] = DMRead{TS: v.TS, MsgID: id}
					}
				}
				got, err := s.(TopicsDMCounter).ViewTopicsDMCounts(ctx, tid, TopicsMsgQuery{TaskIDs: tasks, PerTopic: 50,
					Reader: c.Self, ReaderChannels: chans, Now: now.Add(-time.Hour)}, reads)
				if err != nil {
					t.Fatal(err)
				}
				for _, task := range tasks {
					var seen []TopicMsgMeta
					for _, m := range oracle[task] {
						if readableBy(m.Channel, m.FromID, m.ToID, c.Self, chans) {
							seen = append(seen, m)
						}
					}
					want := DMPageCounts(seen, c.Self, reads)
					g := got[task]
					if len(seen) == 0 {
						want = TopicDMCounts{}
					}
					if !reflect.DeepEqual(g, want) {
						t.Errorf("%s: topic counts\n got %+v\nwant %+v", c.Name, g, want)
					}
				}
			}
		})
	}
}
