package store

import (
	"context"
	"fmt"
	"os"
	"slices"
	"testing"
	"time"
)

// Owner, t1 c9beaa77 (msg 25e9d4bc): a search for "type:msg SPAWN REQUEST"
// listed the fleet's relayed agent-to-agent mail (n=158 of 160 on a
// desk mirror of t1, 2026-10-12). HideRelay leaves a DM whose two ends are agents
// out of messages, files and topics; a member's DM and an agent's channel
// post stay. On memory, Postgres and, with SPOOL_TEST_PG_RUNTIME_DSN, as the
// runtime login under RLS (the hub's own search path).
func TestSearchHideRelay(t *testing.T) {
	stores := drivers(t)
	if dsn := os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN"); dsn != "" && stores["postgres"] != nil {
		rt, err := OpenPostgres(context.Background(), dsn)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(rt.Close)
		stores["runtime"] = rt
	}
	for _, name := range []string{"memory", "postgres", "runtime"} {
		s, ok := stores[name]
		if !ok {
			continue
		}
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			writer := s
			if name == "runtime" {
				writer = stores["postgres"]
			}
			ta := newTenant(t, writer)
			word := zqWord()
			put := func(channel, from, to, body string, ago time.Duration, files string) Message {
				m := msgFor(ta, uuid4(), "box-b", now.Add(-ago), now.Add(-ago), "env-"+uuid4())
				m.Channel, m.FromID, m.ToID, m.Body = channel, from, to, "SPAWN REQUEST "+word+" "+body
				if files != "" {
					m.Files = []byte(files)
				}
				if _, err := writer.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			pdf := `[{"mode":"blob","kind":"file","file_id":"` + fmt.Sprintf("%064x", 7) + `","name":"` + word + `.pdf","bytes":10}]`
			relay := put("", "c-001", "c-001", "from_agent: c-001@box-a", 5*time.Minute, pdf)
			relay2 := put("", "c-002", "c-522", "a lane brief", 4*time.Minute, "")
			human := put("", "HUM-10", "c-001", "from the owner", 3*time.Minute, pdf)
			toHuman := put("", "c-001", "HUM-10", "to the owner", 2*time.Minute, "")
			post := put(ChannelTasks, "c-001", "c-002", "in a channel", time.Minute, "")
			se := s.(Searcher)
			hide := func(q string) SearchQuery {
				r := sq(t, q, now)
				r.HideRelay = true
				return r
			}
			ids := func(q SearchQuery) []string {
				rs, err := se.SearchMessages(ctx, ta, q)
				if err != nil {
					t.Fatal(err)
				}
				return msgIDs(rs)
			}
			// the owner's query: no relay, the human ends and the channel post stay
			if got, want := ids(hide("type:msg SPAWN REQUEST "+word)), []string{post.MsgID, toHuman.MsgID, human.MsgID}; !slices.Equal(got, want) {
				t.Fatalf("hidden: %v, want %v (relay %s %s)", got, want, relay.MsgID, relay2.MsgID)
			}
			// is:relay finds exactly the agent-to-agent mail
			if got, want := ids(sq(t, "is:relay "+word, now)), []string{relay2.MsgID, relay.MsgID}; !slices.Equal(got, want) {
				t.Fatalf("is:relay: %v, want %v", got, want)
			}
			// CONTROL: -is:relay is the hidden set, without the flag
			if got, want := ids(sq(t, "-is:relay "+word, now)), []string{post.MsgID, toHuman.MsgID, human.MsgID}; !slices.Equal(got, want) {
				t.Fatalf("-is:relay: %v, want %v", got, want)
			}
			// CONTROL: without HideRelay every row is there
			if got := ids(sq(t, word, now)); len(got) != 5 {
				t.Fatalf("not hidden: %v", got)
			}
			// files: the relay's attachment is hidden, the owner's stays
			fs, err := se.SearchFiles(ctx, ta, hide(word))
			if err != nil || len(fs) != 1 || fs[0].Msg.MsgID != human.MsgID {
				t.Fatalf("files: %v %+v", err, fs)
			}
			// topics: a relay-only topic is gone; the other three stay
			ts, err := se.SearchTopics(ctx, ta, hide("SPAWN "+word))
			if err != nil {
				t.Fatal(err)
			}
			for _, th := range ts {
				if th.TaskID == relay.TaskID || th.TaskID == relay2.TaskID {
					t.Fatalf("relay topic %s listed", th.TaskID)
				}
			}
			if len(ts) != 3 {
				t.Fatalf("topics: %d, want 3", len(ts))
			}
		})
	}
}
