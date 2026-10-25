package store

import (
	"context"
	"testing"
	"time"
)

// SPL-2584 (human_post_guard.go, rdb 0211) on every driver: Postgres when
// SPOOL_TEST_PG_DSN is set, where spool_norm_body() must say what
// NormalizeBody says. Each case is a control: drop the to_id, sender, window
// or msg_id condition and its "no match" row turns red.
func TestHumanPostGuardStore(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			g := st.(HumanPostGuard)
			tid := newTenant(t, st)
			put := func(task, from, to, body string, at time.Time) Message {
				t.Helper()
				m := msgFor(tid, task, "box-wui", at, at, `{"e":"`+uuid4()+`"}`)
				m.FromID, m.ToID, m.Body = from, to, body
				if _, err := st.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			dm := uuid4()
			first := put(dm, "HUM-1", "CLE-07", "is prd green?", now.Add(-time.Hour))
			got := put(dm, "CLE-07", "HUM-1", "Prd is\tgreen,  1.4.2.", now.Add(-time.Minute))
			put(uuid4(), "CLE-07", "HUM-1", "old news", now.Add(-25*time.Hour))
			put(uuid4(), "HUM-2", "HUM-1", "from a person", now.Add(-time.Minute))

			o, err := g.TopicOpener(ctx, tid, dm)
			if err != nil || o.FromID != first.FromID || o.ToID != "CLE-07" || o.Kind != first.Kind {
				t.Fatalf("opener %+v %v, want %s -> CLE-07", o, err, first.FromID)
			}
			if o, err := g.TopicOpener(ctx, tid, uuid4()); err != nil || o != (TopicOpener{}) {
				t.Fatalf("opener of an empty topic %+v %v", o, err)
			}
			// SPL-3420: the person's post in the topic, not anyone's, and only this topic
			for _, c := range []struct {
				what, task, human string
				want              bool
			}{
				{"the person posted in it", dm, "HUM-1", true},
				{"only an agent wrote to that person", dm, "HUM-2", false},
				{"any sender: the hub asks only of a person", dm, "CLE-07", true},
				{"another topic", uuid4(), "HUM-1", false},
			} {
				if got, err := g.HumanPostedIn(ctx, tid, c.task, c.human); err != nil || got != c.want {
					t.Errorf("posted in, %s: got %v %v, want %v", c.what, got, err, c.want)
				}
			}

			since := now.Add(-24 * time.Hour)
			for _, c := range []struct {
				what, human, body, except, want string
			}{
				{"same text, case and whitespace differ", "HUM-1", "  prd IS green, 1.4.2.\n", "", got.MsgID},
				{"another person", "HUM-2", "prd is green, 1.4.2.", "", ""},
				{"other text", "HUM-1", "prd is green, 1.4.3.", "", ""},
				{"older than the window", "HUM-1", "old news", "", ""},
				{"a person's line is not an agent's", "HUM-1", "from a person", "", ""},
				{"the message itself (a resend)", "HUM-1", "prd is green, 1.4.2.", got.MsgID, ""},
			} {
				id, err := g.HumanGotBody(ctx, tid, c.human, c.body, since, c.except)
				if err != nil || id != c.want {
					t.Errorf("%s: got %q %v, want %q", c.what, id, err, c.want)
				}
			}
		})
	}
}

func TestNormalizeBody(t *testing.T) {
	for in, want := range map[string]string{
		"  A  b\t\nC \r\f\v": "a b c",
		"":                   "",
		"already ok":         "already ok",
	} {
		if got := NormalizeBody(in); got != want {
			t.Errorf("NormalizeBody(%q) = %q, want %q", in, got, want)
		}
	}
}
