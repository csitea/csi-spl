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

// SPL-2128: a loop that keeps panicking restarts with a bounded backoff, and
// every panic leaves one ERROR line with the loop name and its stack.
func TestSuperviseLogsEveryPanicWithBoundedBackoff(t *testing.T) {
	var buf syncBuf
	log := zerolog.New(&buf)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runs := 0
	n := supervise(ctx, log, "sweeper", func(context.Context) {
		runs++
		if runs == 6 {
			cancel()
			return
		}
		panic("tick failed")
	}, time.Millisecond, 4*time.Millisecond)
	if n != 5 || runs != 6 {
		t.Fatalf("restarts %d runs %d, want 5 and 6", n, runs)
	}
	lines := buf.lines()
	if len(lines) != 5 {
		t.Fatalf("%d log lines, want 5: %v", len(lines), lines)
	}
	wantRetry := []float64{1, 2, 4, 4, 4} // zerolog writes durations in ms
	for i, l := range lines {
		if l["level"] != "error" || l["message"] != LoopPanicMsg || l["loop"] != "sweeper" || l["panic"] != "tick failed" {
			t.Fatalf("line %d = %v", i, l)
		}
		if st, _ := l["stack"].(string); !strings.Contains(st, "goroutine") {
			t.Fatalf("line %d carries no stack: %v", i, l)
		}
		if l["restarts"] != float64(i+1) || l["retry_in"] != wantRetry[i] {
			t.Fatalf("line %d restarts %v retry_in %v, want %d and %v", i, l["restarts"], l["retry_in"], i+1, wantRetry[i])
		}
	}
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
		done <- supervise(ctx, zerolog.Nop(), "wake", func(context.Context) { panic("down") }, time.Hour, time.Hour)
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
