package trace

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// reset lets a test choose $SPOOL_TRACE despite the package's sync.Once.
func reset(t *testing.T, p string) {
	t.Helper()
	t.Setenv("SPOOL_TRACE", p)
	once = sync.Once{}
	path = ""
	t.Cleanup(func() { once = sync.Once{}; path = "" })
}

func TestOffWritesNothing(t *testing.T) {
	dir := t.TempDir()
	reset(t, "")
	Mark(Event{Stage: StageWSRecv, MsgID: "m1"})
	if On() {
		t.Fatal("On() is true with SPOOL_TRACE unset")
	}
	ents, err := os.ReadDir(dir)
	if err != nil || len(ents) != 0 {
		t.Fatalf("an unset trace wrote something: %v %v", ents, err)
	}
}

func TestMarkAppendsOneLinePerEvent(t *testing.T) {
	p := filepath.Join(t.TempDir(), "trace.ndjson")
	reset(t, p)
	if !On() {
		t.Fatal("On() is false with SPOOL_TRACE set")
	}
	Mark(Event{Stage: StageWSRecv, MsgID: "m1", To: "CLE-91"})
	Mark(Event{Stage: StageInboxWritten, MsgID: "m1", To: "CLE-91"})
	Mark(Event{Stage: StageNotifyDone, MsgID: "m1", To: "CLE-91", RC: 6})

	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var got []Event
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var e Event
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			t.Fatalf("line is not NDJSON: %q: %v", sc.Text(), err)
		}
		got = append(got, e)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 events, got %d", len(got))
	}
	// The whole point is subtraction: every mark must carry a stamp, and they
	// must not go backwards.
	for i, e := range got {
		if e.TSNano == 0 {
			t.Fatalf("event %d (%s) carries no ts_nano", i, e.Stage)
		}
		if i > 0 && e.TSNano < got[i-1].TSNano {
			t.Fatalf("event %d (%s) stamps before its predecessor", i, e.Stage)
		}
		if e.MsgID != "m1" {
			t.Fatalf("event %d lost its msg_id: %q", i, e.MsgID)
		}
	}
	if got[0].Stage != StageWSRecv || got[2].Stage != StageNotifyDone {
		t.Fatalf("stages out of order: %v", got)
	}
	if got[2].RC != 6 {
		t.Fatalf("the notifier's exit code did not survive: %d", got[2].RC)
	}
	// An event with nothing to say must not invent fields: the probe joins on
	// msg_id, and an empty one would join everything.
	if got[0].RC != 0 || got[0].Note != "" {
		t.Fatalf("ws_recv carries fields it was not given: %+v", got[0])
	}
}

func TestMarkIsSafeFromManyGoroutines(t *testing.T) {
	p := filepath.Join(t.TempDir(), "trace.ndjson")
	reset(t, p)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); Mark(Event{Stage: StageWSRecv, MsgID: "m"}) }()
	}
	wg.Wait()
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var e Event
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			t.Fatalf("concurrent writers shredded a line: %q", sc.Text())
		}
		n++
	}
	if n != 50 {
		t.Fatalf("want 50 whole lines, got %d", n)
	}
}

func TestMarkNeverPanicsOnAnUnwritableTarget(t *testing.T) {
	reset(t, filepath.Join(t.TempDir(), "no-such-dir", "trace.ndjson"))
	Mark(Event{Stage: StageWSRecv, MsgID: "m1"}) // must not panic, must not fail
}
