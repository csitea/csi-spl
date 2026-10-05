package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

// dc6d5e3f (owner, prd t1): a channel line that tags an agent is also in the
// person's DM view of that agent, as the stored row itself. Run on Memory and
// Postgres. Controls: before ViewDMPointers the DM view had no read for it
// (TopicQuery.DM requires channel IS NULL); drop a side of the pair and the
// agent's answer or the tag goes missing; drop the door and the closed
// channel's line leaks; drop the box filter and the other box's line comes in.
func TestViewDMPointers(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			pr, ok := s.(DMPointerReader)
			if !ok {
				t.Fatalf("%s offers no DMPointerReader", name)
			}
			tid, other := newTenant(t, s), newTenant(t, s)
			for _, b := range []string{"box-a", "box-b"} {
				if err := s.PutPin(ctx, tid, b, pubkey(), false, now, now); err != nil {
					t.Fatal(err)
				}
			}
			topic, closed := uuid4(), uuid4()
			at := func(i int) time.Time { return now.Add(time.Duration(i) * time.Second) }
			line := func(i int, task, ch, fromBox, from, toBox, to string) Message {
				m := msgFor(tid, task, toBox, at(i), at(i), `{"i":`+string(rune('0'+i))+`}`)
				m.Channel, m.FromBox, m.FromID, m.ToID, m.Kind = ch, fromBox, from, to, "note"
				return m
			}
			tag := line(1, topic, "lobby", "box-wui", "HUM-10", "box-wui", "CLE-07")      // the person tags the agent
			answer := line(2, topic, "lobby", "box-a", "CLE-07", "box-wui", "HUM-10")     // the agent answers in the topic
			dm := line(3, uuid4(), "", "box-wui", "HUM-10", "box-a", "CLE-07")            // a plain DM: not a pointer
			otherHum := line(4, topic, "lobby", "box-wui", "HUM-11", "box-wui", "CLE-07") // someone else's tag
			untagged := line(5, topic, "lobby", "box-wui", "HUM-10", "box-wui", "")       // a reply that tags nobody
			private := line(6, closed, "ops-x", "box-wui", "HUM-10", "box-wui", "CLE-07") // a channel the reader left
			otherBox := line(7, topic, "lobby", "box-b", "CLE-07", "box-wui", "HUM-10")   // the same id on another box
			for _, m := range []Message{tag, answer, dm, otherHum, untagged, private, otherBox} {
				if ok, err := s.InsertMessage(ctx, m); err != nil || !ok {
					t.Fatalf("insert %s: %v %v", m.Env, ok, err)
				}
			}
			ids := func(rows []ViewMsg) []string {
				out := []string{}
				for _, r := range rows {
					out = append(out, r.MsgID)
				}
				return out
			}
			q := DMPointerQuery{Viewer: "HUM-10", Agent: "CLE-07", Reader: "HUM-10", Now: now}
			got, err := pr.ViewDMPointers(ctx, tid, q)
			if err != nil {
				t.Fatal(err)
			}
			if want := []string{otherBox.MsgID, answer.MsgID, tag.MsgID}; !reflect.DeepEqual(ids(got), want) {
				t.Fatalf("pointers %v, want %v (newest first: other box, answer, tag)", ids(got), want)
			}
			for _, r := range got {
				if r.RowChannel != "lobby" {
					t.Fatalf("pointer %s channel %q: the row keeps its channel", r.MsgID, r.RowChannel)
				}
			}

			q.AgentBox = "box-a"
			if got, err = pr.ViewDMPointers(ctx, tid, q); err != nil {
				t.Fatal(err)
			}
			if want := []string{answer.MsgID, tag.MsgID}; !reflect.DeepEqual(ids(got), want) {
				t.Fatalf("peer CLE-07@box-a: %v, want %v", ids(got), want)
			}

			q.AgentBox, q.Reader, q.ReaderChannels = "", "", nil // the door-off rig reads the closed channel too
			if got, err = pr.ViewDMPointers(ctx, tid, q); err != nil || len(got) != 4 || got[1].MsgID != private.MsgID {
				t.Fatalf("door off: %v %v", err, ids(got))
			}
			q.Reader, q.ReaderChannels = "HUM-10", []string{"ops-x"} // a member reads it
			if got, err = pr.ViewDMPointers(ctx, tid, q); err != nil || len(got) != 4 {
				t.Fatalf("member of ops-x: %v %v", err, ids(got))
			}

			q.Limit = 1
			if got, err = pr.ViewDMPointers(ctx, tid, q); err != nil || len(got) != 1 {
				t.Fatalf("limit 1: %v %v", err, ids(got))
			}
			q.Limit = 0

			if got, err = pr.ViewDMPointers(ctx, tid, q); err != nil || len(got) != 4 {
				t.Fatalf("again: %v %v", err, ids(got))
			}
			if leak, err := pr.ViewDMPointers(ctx, other, q); err != nil || len(leak) != 0 {
				t.Fatalf("other tenant: %v %d", err, len(leak))
			}
			if got, err := pr.ViewDMPointers(ctx, tid, DMPointerQuery{Viewer: "HUM-10", Agent: "CLE-07", Now: at(400 * 24 * 3600)}); err != nil || len(got) != 0 {
				t.Fatalf("expired: %v %d", err, len(got))
			}
		})
	}
}
