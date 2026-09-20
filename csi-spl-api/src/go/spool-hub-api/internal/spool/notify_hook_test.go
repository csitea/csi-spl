package spool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// specs/028-spool-terminal-delivery FR-001/FR-003/FR-008: the terminal leg
// hangs off the ONE inbox write, so every hop that puts a message in a local
// agent's inbox rings that agent - and nothing else does.

// notifierLog installs a fake $SPOOL_NOTIFY_CMD on cfg and returns a reader of
// the calls it recorded (one line per call: the --to it was given).
func notifierLog(t *testing.T, st *Store) func() []string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls.log")
	cmd := filepath.Join(dir, "notify.sh")
	script := "#!/usr/bin/env bash\n" +
		"to=''; while [ $# -gt 0 ]; do case \"$1\" in --to) to=\"$2\"; shift 2;; *) shift;; esac; done\n" +
		"echo \"$to $(cat)\" >> " + log + "\n"
	if err := os.WriteFile(cmd, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	st.cfg.NotifyCmd = cmd
	st.cfg.NotifyTimeout = 5 * time.Second
	return func() []string {
		b, err := os.ReadFile(log)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
			if l != "" {
				out = append(out, l)
			}
		}
		return out
	}
}

// A same-box send - the CLI verb and the spool_send MCP tool share this code -
// rings the RECIPIENT once. The sender's outbox copy rings nobody.
func TestNotifyOnLocalSend(t *testing.T) {
	st := New(newCfg(t))
	calls := notifierLog(t, st)

	if _, err := st.Send("GRK-03", "CLE-07", "", "task", "review this", nil); err != nil {
		t.Fatalf("send: %v", err)
	}
	got := calls()
	if len(got) != 1 {
		t.Fatalf("want exactly one notification, got %d: %v", len(got), got)
	}
	if got[0] != "CLE-07 review this" {
		t.Fatalf("want the recipient and the body, got %q", got[0])
	}
}

// The hub sidecar's path: cross-box mail, and a signed-in human's box-wui task
// (014), both land through Deliver.
func TestNotifyOnHubDeliver(t *testing.T) {
	st := New(newCfg(t))
	calls := notifierLog(t, st)

	m := &msg.Message{
		V: 1, MsgID: "m-1", TaskID: "t-1", TS: msg.Now(time.Now()),
		From: "HUM-1", To: "CLE-07", Kind: "task", Body: "run the tests",
		Files: []msg.Attachment{},
	}
	wrote, err := st.Deliver(m)
	if err != nil || !wrote {
		t.Fatalf("deliver: wrote=%v err=%v", wrote, err)
	}
	if got := calls(); len(got) != 1 || got[0] != "CLE-07 run the tests" {
		t.Fatalf("want one notification for CLE-07, got %v", got)
	}

	// FR-003: the hub redelivers on reconnect. The file is already there, so
	// nothing is written and nothing is rung a second time.
	wrote, err = st.Deliver(m)
	if err != nil || wrote {
		t.Fatalf("redelivery: wrote=%v err=%v", wrote, err)
	}
	if got := calls(); len(got) != 1 {
		t.Fatalf("a redelivery rang the pane again: %v", got)
	}
}

// A channel mention (003 channels-v1 §4) reaches several local agents; each is
// rung under its own id, not the single id in m.To.
func TestNotifyOnDeliverToEachMentionedAgent(t *testing.T) {
	st := New(newCfg(t))
	calls := notifierLog(t, st)

	m := &msg.Message{
		V: 1, MsgID: "m-2", TaskID: "t-2", TS: msg.Now(time.Now()),
		From: "HUM-1", To: "CLE-07", Kind: "note", Body: "@CLE-07 @GRK-03 standup",
		Files: []msg.Attachment{},
	}
	for _, id := range []string{"CLE-07", "GRK-03"} {
		if _, err := st.DeliverTo(m, id); err != nil {
			t.Fatalf("deliverTo %s: %v", id, err)
		}
	}
	got := calls()
	if len(got) != 2 {
		t.Fatalf("want one notification per mentioned agent, got %v", got)
	}
	if !strings.HasPrefix(got[0], "CLE-07 ") || !strings.HasPrefix(got[1], "GRK-03 ") {
		t.Fatalf("each agent must be rung under its own id, got %v", got)
	}
}

// FR-008 / FR-005: with no command configured nothing is run and nothing
// changes for a hub, a CI job or spool-send.sh's own send.
func TestNoNotifierNoCall(t *testing.T) {
	st := New(newCfg(t))
	calls := notifierLog(t, st)
	st.cfg.NotifyCmd = "off"

	if _, err := st.Send("GRK-03", "CLE-07", "", "note", "quiet", nil); err != nil {
		t.Fatalf("send: %v", err)
	}
	if got := calls(); len(got) != 0 {
		t.Fatalf("off must ring nobody, got %v", got)
	}
}
