package spool

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// TestTailSameSecondKeepsSendOrder: ts has one-second resolution and msg_id
// is random, so a topic whose messages share one ts must still tail in the
// order they were written (test-spool-send.sh "tail is oldest-first" flaked
// on exactly this). The frozen clock makes every ts equal; each copy's mtime
// is stamped a millisecond apart, the way two quick sends land on disk.
// CONTROL: ordered by msg_id alone, 8 messages come back in send order once
// in 8! = 40320 runs.
func TestTailSameSecondKeepsSendOrder(t *testing.T) {
	st := New(newCfg(t))
	t0 := time.Date(2026, 10, 11, 9, 0, 0, 0, time.UTC)
	st.clock = func() time.Time { return t0 }
	task := ""
	for i := 0; i < 8; i++ {
		from, to := "GRK-03", "CLE-07"
		if i%2 == 1 {
			from, to = to, from
		}
		m, err := st.Send(from, to, task, "note", fmt.Sprintf("m%d", i), nil)
		if err != nil {
			t.Fatal(err)
		}
		task = m.TaskID
		at := t0.Add(time.Duration(i) * time.Millisecond)
		for _, p := range []string{
			filepath.Join(st.dir(from, "outbox"), msg.Filename(m)),
			filepath.Join(st.dir(to, "inbox"), msg.Filename(m)),
		} {
			if err := os.Chtimes(p, at, at); err != nil {
				t.Fatal(err)
			}
		}
	}
	msgs, err := st.Tail(task)
	if err != nil {
		t.Fatalf("tail: %v", err)
	}
	if len(msgs) != 8 {
		t.Fatalf("want 8 messages on topic, got %d", len(msgs))
	}
	for i, m := range msgs {
		if m.TS != msg.Now(t0) {
			t.Fatalf("message %d: ts %s, want the frozen %s", i, m.TS, msg.Now(t0))
		}
		if want := fmt.Sprintf("m%d", i); m.Body != want {
			t.Fatalf("tail position %d holds %q, want %q (same-second order lost)", i, m.Body, want)
		}
	}
}

// TestTailSameSecondEarliestCopyWins: a message's place is its FIRST copy's
// mtime. A late copy (an inbox written after a hub delivery, a re-delivery)
// must not move it behind a message written after it.
func TestTailSameSecondEarliestCopyWins(t *testing.T) {
	st := New(newCfg(t))
	t0 := time.Date(2026, 10, 11, 9, 0, 0, 0, time.UTC)
	st.clock = func() time.Time { return t0 }
	a, err := st.Send("GRK-03", "CLE-07", "", "task", "first", nil)
	if err != nil {
		t.Fatal(err)
	}
	b, err := st.Send("CLE-07", "GRK-03", a.TaskID, "result", "second", nil)
	if err != nil {
		t.Fatal(err)
	}
	stamp := func(p string, at time.Time) {
		t.Helper()
		if err := os.Chtimes(p, at, at); err != nil {
			t.Fatal(err)
		}
	}
	stamp(filepath.Join(st.dir("GRK-03", "outbox"), msg.Filename(a)), t0)
	stamp(filepath.Join(st.dir("CLE-07", "inbox"), msg.Filename(a)), t0.Add(500*time.Millisecond))
	stamp(filepath.Join(st.dir("CLE-07", "outbox"), msg.Filename(b)), t0.Add(100*time.Millisecond))
	stamp(filepath.Join(st.dir("GRK-03", "inbox"), msg.Filename(b)), t0.Add(100*time.Millisecond))
	msgs, err := st.Tail(a.TaskID)
	if err != nil {
		t.Fatalf("tail: %v", err)
	}
	if len(msgs) != 2 || msgs[0].Body != "first" || msgs[1].Body != "second" {
		t.Fatalf("want [first second], got %d messages: %+v", len(msgs), msgs)
	}
}
