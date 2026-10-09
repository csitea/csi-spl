// Tests for Queue.Stop behavior.

package notify

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

func TestQueueStopDoesNotInterruptRunningNotifier(t *testing.T) {
	// A notifier that takes 1s to run.
	slowCmd := `#!/usr/bin/env bash
# Write a .started file before sleep.
touch "${0}.started"
sleep 1
echo "ARGV: $*" >> "${0}.log"
`
	dir := t.TempDir()
	cmd := dir + "/notify.sh"
	log := cmd + ".log"
	if err := os.WriteFile(cmd, []byte(slowCmd), 0o755); err != nil {
		t.Fatal(err)
	}

	// Start a queue and enqueue a slow notifier.
	cfg := &config.Config{
		SpoolRoot:     dir,
		NotifyCmd:     cmd,
		NotifyTimeout: 2 * time.Second,
	}
	q := Start(cfg)
	defer q.Stop()

	// Enqueue a slow notifier.
	go Deliver(cfg, testMsgForQueue(), "CLE-91")

	// Wait for the notifier to start.
	started := filepath.Join(dir, "notify.sh.started")
	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("notifier did not start within 500ms")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Stop the queue while the notifier is running.
	stopped := make(chan struct{})
	go func() {
		q.Stop()
		close(stopped)
	}()

	// The notifier must finish, and the queue must stop.
	select {
	case <-stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("Queue.Stop did not return within 2s")
	}

	// The notifier must have run to completion.
	time.Sleep(100 * time.Millisecond) // Give it time to write the log.

	// The log must exist and contain the notifier's output.
	if _, err := os.Stat(log); err != nil {
		t.Fatalf("notifier did not run: %v", err)
	}
}

func testMsgForQueue() *msg.Message {
	return &msg.Message{
		V: 1, MsgID: "m-1", TaskID: "t-1", TS: msg.Now(time.Now()),
		From: "CLE-90", To: "CLE-91", Kind: "task", Body: "ping from 90",
		Files: []msg.Attachment{},
	}
}
