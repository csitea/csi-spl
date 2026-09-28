package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// Grammar 1.1 on both stores (rdb 0048 spool_search): accents and
// case fold in the message index, topic titles, topic name: and file names;
// the topic prefilter keeps the aggregate's answer. CONTROLS: a word that is
// not there stays a miss, and another tenant's accented row never appears.
func TestSearchFold(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			se := s.(Searcher)
			ta, tb := newTenant(t, s), newTenant(t, s)
			tk1, tk2 := uuid4(), uuid4()
			mk := func(tenant, task, body string, ago time.Duration) Message {
				m := msgFor(tenant, task, "box-b", now.Add(-ago), now.Add(-ago), "env-"+uuid4())
				m.Body, m.Channel = body, ChannelTasks
				return m
			}
			m1 := mk(ta, tk1, "Café résumé an der Straße\nzweite Zeile", 3*time.Minute)
			m1.Files = []byte(`[{"mode":"blob","kind":"file","file_id":"` + fmt.Sprintf("%064x", 2) + `","name":"Übersicht Q3.pdf","bytes":10}]`)
			m2 := mk(ta, tk2, "plain cafe notes", 2*time.Minute)
			other := mk(tb, uuid4(), "Café in tenant B", time.Minute) // CONTROL
			for _, m := range []Message{m1, m2, other} {
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			msgs := func(q string) []string {
				t.Helper()
				rs, err := se.SearchMessages(ctx, ta, sq(t, q, now))
				if err != nil {
					t.Fatalf("%q: %v", q, err)
				}
				return msgIDs(rs)
			}
			for q, want := range map[string][]string{
				"cafe ":        {m2.MsgID, m1.MsgID},
				"CAFÉ ":        {m2.MsgID, m1.MsgID},
				"resume ":      {m1.MsgID},
				"strasse ":     {m1.MsgID},
				"résu":         {m1.MsgID}, // as you type
				"cafe notes":   {m2.MsgID},
				"strassenbahn": nil, // CONTROL: a longer word is not a prefix of it
				"kaffee ":      nil, // CONTROL: no translation, no stemming
			} {
				if got := msgs(q); len(got) != len(want) || (len(want) > 0 && got[0] != want[0]) {
					t.Errorf("%q: %v, want %v", q, got, want)
				}
			}
			topics := func(q string) []string {
				t.Helper()
				rs, err := se.SearchTopics(ctx, ta, sq(t, q, now))
				if err != nil {
					t.Fatalf("%q: %v", q, err)
				}
				var out []string
				for _, r := range rs {
					out = append(out, r.TaskID)
				}
				return out
			}
			for q, want := range map[string][]string{
				"type:topic resume ":          {tk1},
				"type:topic stras":            {tk1},
				"type:topic zweite ":          nil, // CONTROL: not in the title (second line)
				"type:topic name:STRASSE":     {tk1},
				"type:topic in:#tasks cafe ":  {tk2, tk1},
				"type:topic -resume cafe ":    {tk2}, // the negated term is not prefiltered
				"type:topic resume OR notes ": {tk2, tk1},
			} {
				if got := topics(q); len(got) != len(want) || (len(want) > 0 && got[0] != want[0]) {
					t.Errorf("%q: %v, want %v", q, got, want)
				}
			}
			fs, err := se.SearchFiles(ctx, ta, sq(t, "type:file ubersicht", now))
			if err != nil || len(fs) != 1 || fs[0].Name != "Übersicht Q3.pdf" {
				t.Fatalf("file ubersicht: %v %+v", err, fs)
			}
		})
	}
}
