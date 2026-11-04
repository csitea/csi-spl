package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// syncBuf is a log sink the supervisor goroutine and the test share.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) lines() []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(s.b.String()), "\n") {
		var m map[string]any
		if json.Unmarshal([]byte(l), &m) == nil {
			out = append(out, m)
		}
	}
	return out
}

// SPL-2128: the backoff doubles from the minimum and stops at the maximum.
func TestNextBackoffBounded(t *testing.T) {
	d := loopBackoffMin
	var got []time.Duration
	for i := 0; i < 9; i++ {
		got = append(got, d)
		d = nextBackoff(d, loopBackoffMax)
	}
	want := []time.Duration{1, 2, 4, 8, 16, 32, 60, 60, 60}
	for i := range want {
		if got[i] != want[i]*time.Second {
			t.Fatalf("backoff %d = %s, want %s (all %v)", i, got[i], want[i]*time.Second, got)
		}
	}
}

// panicRuns supervises a loop that panics 5 times, then cancels on its 6th
// run, under lo = 1 ms and hi = 4 ms. The clock is fake: it moves only by
// took[i] during run i+1, so a slow box can never make a run outlast hi
// (SPL-4821; the real clock reset the backoff under -race).
func panicRuns(t *testing.T, took map[int]time.Duration) []map[string]any {
	t.Helper()
	var buf syncBuf
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	clock := time.Unix(0, 0)
	runs := 0
	n := supervise(ctx, zerolog.New(&buf), "sweeper", func(context.Context) {
		runs++
		clock = clock.Add(took[runs])
		if runs == 6 {
			cancel()
			return
		}
		panic("tick failed")
	}, time.Millisecond, 4*time.Millisecond, func() time.Time { return clock })
	if n != 5 || runs != 6 {
		t.Fatalf("restarts %d runs %d, want 5 and 6", n, runs)
	}
	lines := buf.lines()
	if len(lines) != 5 {
		t.Fatalf("%d log lines, want 5: %v", len(lines), lines)
	}
	return lines
}

// checkRetries fails unless line i says restart i+1 and retry_in want[i] ms
// (zerolog writes durations in ms).
func checkRetries(t *testing.T, lines []map[string]any, want []float64) {
	t.Helper()
	for i, l := range lines {
		if l["restarts"] != float64(i+1) || l["retry_in"] != want[i] {
			t.Fatalf("line %d restarts %v retry_in %v, want %d and %v", i, l["restarts"], l["retry_in"], i+1, want[i])
		}
	}
}

// SPL-2128: a loop that keeps panicking restarts with a bounded backoff, and
// every panic leaves one ERROR line with the loop name and its stack.
func TestSuperviseLogsEveryPanicWithBoundedBackoff(t *testing.T) {
	lines := panicRuns(t, nil)
	for i, l := range lines {
		if l["level"] != "error" || l["message"] != LoopPanicMsg || l["loop"] != "sweeper" || l["panic"] != "tick failed" {
			t.Fatalf("line %d = %v", i, l)
		}
		if st, _ := l["stack"].(string); !strings.Contains(st, "goroutine") {
			t.Fatalf("line %d carries no stack: %v", i, l)
		}
	}
	checkRetries(t, lines, []float64{1, 2, 4, 4, 4})
}

// SPL-2128, SPL-4821: a run that outlived the maximum starts the backoff
// over; a run of exactly the maximum does not.
func TestSuperviseResetsBackoffAfterALongRun(t *testing.T) {
	checkRetries(t, panicRuns(t, map[int]time.Duration{4: 5 * time.Millisecond}), []float64{1, 2, 4, 1, 2})
	checkRetries(t, panicRuns(t, map[int]time.Duration{4: 4 * time.Millisecond}), []float64{1, 2, 4, 4, 4})
}

// SPL-2128: a loop that returns without a panic (one that is off) is done;
// nothing restarts it and nothing is logged.
func TestSuperviseReturnIsDone(t *testing.T) {
	var buf syncBuf
	runs := 0
	n := Supervise(context.Background(), zerolog.New(&buf), "relay", func(context.Context) { runs++ })
	if n != 0 || runs != 1 || len(buf.lines()) != 0 {
		t.Fatalf("restarts %d runs %d lines %v, want 0, 1, none", n, runs, buf.lines())
	}
}

// SPL-2128: a cancel during the backoff stops the supervisor at once, not
// after the backoff.
func TestSuperviseCancelStopsDuringBackoff(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int)
	go func() {
		done <- supervise(ctx, zerolog.Nop(), "wake", func(context.Context) { panic("down") }, time.Hour, time.Hour, time.Now)
	}()
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case n := <-done:
		if n != 1 {
			t.Fatalf("restarts %d, want 1", n)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("supervisor still waiting out its backoff after the cancel")
	}
}
