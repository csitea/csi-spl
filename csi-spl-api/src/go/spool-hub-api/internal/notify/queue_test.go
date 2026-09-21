package notify

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

func qmsg(id, to string) *msg.Message {
	return &msg.Message{V: 1, MsgID: id, From: "CLE-90", To: to, Kind: "note", Body: id}
}

// A queue exists to get the terminal leg off the caller's thread. Prove it
// with the shape that hurt: a notifier that takes real time, called from the
// path a read loop is on.
func TestDeliverDoesNotBlockTheCallerWhileAQueueIsInstalled(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "sleep 0.25\n")
	cfg := &config.Config{NotifyCmd: cmd, SpoolRoot: t.TempDir()}

	// Synchronous first: this is the cost a read loop used to pay per message.
	start := time.Now()
	Run(cfg, qmsg("sync-1", "CLE-91"), "CLE-91")
	sync := time.Since(start)
	if sync < 200*time.Millisecond {
		t.Fatalf("the fake notifier did not actually block (%v); the rest of this test would prove nothing", sync)
	}

	q := Start(cfg)
	defer q.Stop()
	start = time.Now()
	for i := 0; i < 4; i++ {
		Deliver(cfg, qmsg("q-"+itoa(i), "CLE-91"), "CLE-91")
	}
	queued := time.Since(start)
	if queued > sync/2 {
		t.Fatalf("Deliver blocked: 4 queued pokes took %v, one synchronous poke takes %v", queued, sync)
	}
	q.Stop() // drains
	body, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4; i++ {
		if !strings.Contains(string(body), "q-"+itoa(i)) {
			t.Fatalf("Stop returned before poke q-%d ran:\n%s", i, body)
		}
	}
}

// Order is the thing a queue could quietly break, and an agent reading its
// pane would never know which message came first.
func TestALanePokesInDeliveryOrder(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "")
	cfg := &config.Config{NotifyCmd: cmd, SpoolRoot: t.TempDir()}
	q := Start(cfg)
	for i := 0; i < 12; i++ {
		Deliver(cfg, qmsg("m"+itoa(i), "CLE-91"), "CLE-91")
	}
	q.Stop()

	body, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	at := -1
	for i := 0; i < 12; i++ {
		got := strings.Index(string(body), "STDIN: m"+itoa(i)+"\n")
		if got < 0 {
			t.Fatalf("poke m%d never ran:\n%s", i, body)
		}
		if got < at {
			t.Fatalf("poke m%d ran out of order:\n%s", i, body)
		}
		at = got
	}
}

// Two agents must not wait on each other: that is the head-of-line blocking
// the queue was added to remove, and it is invisible in a single-lane test.
func TestLanesForDifferentAgentsRunConcurrently(t *testing.T) {
	cmd, _ := fakeNotifier(t, 0, "sleep 0.25\n")
	cfg := &config.Config{NotifyCmd: cmd, SpoolRoot: t.TempDir()}
	q := Start(cfg)
	for _, to := range []string{"CLE-91", "CLE-92", "CLE-93", "CLE-94"} {
		Deliver(cfg, qmsg("m-"+to, to), to)
	}
	start := time.Now()
	q.Stop()
	if d := time.Since(start); d > 600*time.Millisecond {
		t.Fatalf("four agents' pokes serialised: drained in %v, one poke is ~250ms", d)
	}
}

// Without a queue nothing changes: a CLI exits the moment its delivery
// returns, so its poke has to have run by then.
func TestDeliverIsSynchronousWithNoQueueInstalled(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "")
	cfg := &config.Config{NotifyCmd: cmd, SpoolRoot: t.TempDir()}
	Deliver(cfg, qmsg("cli-1", "CLE-91"), "CLE-91")
	body, err := os.ReadFile(log)
	if err != nil {
		t.Fatalf("the poke had not run when Deliver returned: %v", err)
	}
	if !strings.Contains(string(body), "cli-1") {
		t.Fatalf("the poke had not run when Deliver returned:\n%s", body)
	}
}

// Stop must be safe to call twice - cmdHubRun defers it and may also be
// unwound by a signal path - and must leave the process synchronous again.
func TestStopIsIdempotentAndRestoresTheSynchronousPath(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "")
	cfg := &config.Config{NotifyCmd: cmd, SpoolRoot: t.TempDir()}
	q := Start(cfg)
	q.Stop()
	q.Stop()
	Deliver(cfg, qmsg("after-stop", "CLE-91"), "CLE-91")
	body, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(body), "after-stop") {
		t.Fatalf("Deliver after Stop did not run synchronously: %v %s", err, body)
	}
}

// A queue on a config with the terminal leg off must not swallow the poke
// into a lane that never renders: Enabled is the gate, in both paths.
func TestAQueueDoesNotResurrectADisabledTerminalLeg(t *testing.T) {
	cfg := &config.Config{NotifyCmd: Off, SpoolRoot: t.TempDir()}
	q := Start(cfg)
	defer q.Stop()
	Deliver(cfg, qmsg("off-1", "CLE-91"), "CLE-91") // must not panic, must do nothing
}
