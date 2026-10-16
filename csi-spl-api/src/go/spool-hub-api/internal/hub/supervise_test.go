package hub_test

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// panicWakeStore makes the real wake loop (RunWake) panic: its listener
// (ListenWakes, the one RunWake calls on a store that has it)
// panics on the first `panics` calls, then listens until ctx ends.
type panicWakeStore struct {
	*store.Memory
	panics  int32
	calls   atomic.Int32
	steady  chan struct{}
	steadyN sync.Once
}

func (p *panicWakeStore) ListenWakes(ctx context.Context, _ func(tenant, box string), _ func(tenant, msgID string)) error {
	if p.calls.Add(1) <= p.panics {
		panic("wake listener boom")
	}
	p.steadyN.Do(func() { close(p.steady) })
	<-ctx.Done()
	return nil
}

func panicWakeEnv(t *testing.T, panics int32) (*env, *panicWakeStore) {
	ps := &panicWakeStore{Memory: store.NewMemory(), panics: panics, steady: make(chan struct{})}
	e := newEnv(t, func(o *hub.Options) { o.Store = ps; o.Wake = true })
	return e, ps
}

func (e *env) healthz() int {
	e.t.Helper()
	resp, err := e.client.Get("http://x" + domain + "/healthz")
	if err != nil {
		e.t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// SPL-2128 CONTROL (the gap): the child process starts the wake loop bare,
// as hub.go did before, and its panic ends the whole process.
func TestLoopPanicChild(t *testing.T) {
	if os.Getenv("SPL_LOOP_PANIC_CHILD") != "bare" {
		t.Skip("child of TestBareLoopPanicKillsHub")
	}
	e, _ := panicWakeEnv(t, 1)
	go e.srv.RunWake(context.Background())
	time.Sleep(3 * time.Second)
	t.Log("SURVIVED")
}

func TestBareLoopPanicKillsHub(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestLoopPanicChild$", "-test.v")
	cmd.Env = append(os.Environ(), "SPL_LOOP_PANIC_CHILD=bare")
	out, err := cmd.CombinedOutput()
	if err == nil || strings.Contains(string(out), "SURVIVED") || !strings.Contains(string(out), "panic: wake listener boom") {
		t.Fatalf("a bare loop panic should end the process; err %v, output:\n%s", err, out)
	}
}

// SPL-2128: supervised, the same panic restarts only the wake loop: it comes
// back, another loop keeps ticking and the HTTP handler keeps serving; a
// cancel stops them all.
func TestSupervisedLoopPanicHubServesOn(t *testing.T) {
	e, ps := panicWakeEnv(t, 2)
	var buf strings.Builder
	var mu sync.Mutex
	log := zerolog.New(lockedWriter{&mu, &buf})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var ticks atomic.Int32
	other := func(ctx context.Context) {
		tk := time.NewTicker(10 * time.Millisecond)
		defer tk.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tk.C:
				ticks.Add(1)
			}
		}
	}
	var wg sync.WaitGroup
	restarts := make([]int, 2)
	for i, l := range []struct {
		name string
		run  func(context.Context)
	}{{"wake", e.srv.RunWake}, {"other", other}} {
		wg.Add(1)
		go func() { defer wg.Done(); restarts[i] = hub.Supervise(ctx, log, l.name, l.run) }()
	}
	if code := e.healthz(); code != http.StatusOK {
		t.Fatalf("healthz while the loop panics = %d", code)
	}
	select {
	case <-ps.steady: // two panics, backoff 1 s then 2 s
	case <-time.After(10 * time.Second):
		t.Fatalf("wake loop not back after its panics (calls %d)", ps.calls.Load())
	}
	before := ticks.Load()
	time.Sleep(50 * time.Millisecond)
	if ticks.Load() <= before || before == 0 {
		t.Fatalf("the other loop stopped ticking: %d then %d", before, ticks.Load())
	}
	if code := e.healthz(); code != http.StatusOK {
		t.Fatalf("healthz after the restarts = %d", code)
	}
	cancel()
	stopped := make(chan struct{})
	go func() { wg.Wait(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("a cancel did not stop every supervised loop")
	}
	if restarts[0] != 2 || restarts[1] != 0 {
		t.Fatalf("restarts wake %d other %d, want 2 and 0", restarts[0], restarts[1])
	}
	mu.Lock()
	got := buf.String()
	mu.Unlock()
	if n := strings.Count(got, `"message":"`+hub.LoopPanicMsg+`"`); n != 2 || !strings.Contains(got, `"loop":"wake"`) {
		t.Fatalf("want 2 %q lines for loop wake, got %d:\n%s", hub.LoopPanicMsg, n, got)
	}
}

// lockedWriter is a log sink the supervised goroutines and the test share.
type lockedWriter struct {
	mu *sync.Mutex
	b  *strings.Builder
}

func (w lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}
