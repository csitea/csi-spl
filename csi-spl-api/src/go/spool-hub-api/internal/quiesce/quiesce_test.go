package quiesce

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fake is a Waiter over a desk dir in t.TempDir with a manual clock that
// Sleep advances.
func fake(t *testing.T) (*Waiter, string, *time.Time) {
	t.Helper()
	desk := filepath.Join(t.TempDir(), "desk", "t1", "box-x")
	if err := os.MkdirAll(filepath.Join(desk, "spool"), 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	w := &Waiter{Root: filepath.Join(desk, "spool"), Max: 300 * time.Second, Wait: 10 * time.Second, Every: time.Second, Log: &bytes.Buffer{}}
	w.Now = func() time.Time { return now }
	w.Sleep = func(d time.Duration) { now = now.Add(d) }
	return w, desk, &now
}

// plant writes the marker of desk with mtime at.
func plant(t *testing.T, desk string, at time.Time) string {
	t.Helper()
	m := desk + ".quiesce"
	if err := os.WriteFile(m, []byte("do_spl_desk_move box -> agent 20261031T000000Z\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(m, at, at); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestMarkerPath(t *testing.T) {
	if got := Marker("/s/desk/t1/box-x/spool/"); got != "/s/desk/t1/box-x.quiesce" {
		t.Fatalf("Marker = %q", got)
	}
	if Marker("") != "" {
		t.Fatal("an empty root has no marker")
	}
}

func TestGateNoMarkerPassesAtOnce(t *testing.T) {
	w, _, _ := fake(t)
	slept := 0
	w.Sleep = func(time.Duration) { slept++ }
	if err := w.Gate(); err != nil || slept != 0 {
		t.Fatalf("Gate = %v after %d sleeps, want nil at once", err, slept)
	}
}

func TestGateWaitsUntilMarkerGoes(t *testing.T) {
	w, desk, now := fake(t)
	m := plant(t, desk, *now)
	n := 0
	w.Sleep = func(d time.Duration) {
		*now = now.Add(d)
		if n++; n == 3 {
			os.Remove(m)
		}
	}
	if err := w.Gate(); err != nil || n != 3 {
		t.Fatalf("Gate = %v after %d sleeps, want nil after 3", err, n)
	}
	if out := w.Log.(*bytes.Buffer).String(); !strings.Contains(out, "quiesced (do_spl_desk_move") {
		t.Fatalf("no wait line: %q", out)
	}
}

// A writer that waited and finds the desk renamed aside refuses: its root
// is stale, and a write there would re-create an orphan desk (R7 W1).
func TestGateRefusesWhenDeskMovedDuringWait(t *testing.T) {
	w, desk, now := fake(t)
	m := plant(t, desk, *now)
	w.Sleep = func(d time.Duration) {
		*now = now.Add(d)
		if err := os.Rename(desk, desk+".moved"); err == nil {
			os.Remove(m)
		}
	}
	err := w.Gate()
	if !errors.Is(err, ErrQuiesced) || !strings.Contains(err.Error(), "moved "+desk+" away") || !strings.Contains(err.Error(), "do_spl_desk_move") {
		t.Fatalf("Gate = %v, want ErrQuiesced naming the move", err)
	}
	if _, err := os.Stat(desk); !os.IsNotExist(err) {
		t.Fatalf("the gate re-created %s: %v", desk, err)
	}
}

func TestGateRefusesAfterWait(t *testing.T) {
	w, desk, now := fake(t)
	plant(t, desk, *now)
	err := w.Gate()
	if !errors.Is(err, ErrQuiesced) || !strings.Contains(err.Error(), "nothing was written") {
		t.Fatalf("Gate = %v, want ErrQuiesced", err)
	}
}

func TestStaleMarkerIgnored(t *testing.T) {
	w, desk, now := fake(t)
	plant(t, desk, now.Add(-301*time.Second))
	if live, _ := w.Live(); live {
		t.Fatal("a marker older than Max must not count")
	}
	if err := w.Gate(); err != nil {
		t.Fatalf("Gate = %v on a stale marker", err)
	}
}

func TestNewReadsEnv(t *testing.T) {
	t.Setenv("DESK_QUIESCE_MAX_SECS", "7")
	t.Setenv("DESK_QUIESCE_WAIT_SECS", "bad")
	w := New("/x/spool", nil)
	if w.Max != 7*time.Second || w.Wait != DefaultWaitSecs*time.Second {
		t.Fatalf("New: max %s wait %s", w.Max, w.Wait)
	}
}
