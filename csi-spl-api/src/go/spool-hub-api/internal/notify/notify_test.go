package notify

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// fakeNotifier writes a shell script that appends its argv, its stdin and
// $SPOOL_ROOT to a log file, then exits with rc. It returns the two paths.
func fakeNotifier(t *testing.T, rc int, extra string) (cmd, log string) {
	t.Helper()
	dir := t.TempDir()
	log = filepath.Join(dir, "calls.log")
	cmd = filepath.Join(dir, "notify.sh")
	body := "#!/usr/bin/env bash\n" +
		extra +
		"{ echo \"ARGV: $*\"; echo \"ROOT: ${SPOOL_ROOT:-}\"; echo \"STDIN: $(cat)\"; } >> " + log + "\n" +
		"exit " + itoa(rc) + "\n"
	if err := os.WriteFile(cmd, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return cmd, log
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

func testMsg() *msg.Message {
	return &msg.Message{
		V: 1, MsgID: "m-1", TaskID: "t-1", TS: msg.Now(time.Now()),
		From: "CLE-90", To: "CLE-91", Kind: "task", Body: "ping from 90",
		Files: []msg.Attachment{},
	}
}

func readLog(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// FR-005: unset and "off" are both silent. A CI job and spool-send.sh's own
// send must behave exactly as they did before this spec.
func TestDisabledByDefault(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "")
	for _, v := range []string{"", Off, "  off  "} {
		cfg := &config.Config{SpoolRoot: t.TempDir(), NotifyCmd: v}
		if Enabled(cfg) {
			t.Fatalf("NotifyCmd %q must be disabled", v)
		}
		Run(cfg, testMsg(), "CLE-91")
	}
	if got := readLog(t, log); got != "" {
		t.Fatalf("a disabled notifier ran: %q (cmd %s)", got, cmd)
	}
	if Enabled(nil) {
		t.Fatal("a nil config must be disabled")
	}
}

// FR-002: the notifier is handed everything the pane line needs, and the body
// arrives on stdin (never on the command line: it is arbitrary text).
func TestRunPassesTheMessage(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "")
	root := t.TempDir()
	cfg := &config.Config{SpoolRoot: root, NotifyCmd: cmd}
	Run(cfg, testMsg(), "CLE-91")

	got := readLog(t, log)
	for _, want := range []string{
		"--to CLE-91", "--from CLE-90", "--kind task",
		"--task t-1", "--msg-id m-1", "--body-stdin",
		"STDIN: ping from 90", "ROOT: " + root,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("notifier call missing %q:\n%s", want, got)
		}
	}
}

// A channel mention (003 §4) is delivered to several local agents; each one is
// notified under ITS id, not the single id in m.To.
func TestRunNotifiesTheGivenAgentNotMsgTo(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "")
	cfg := &config.Config{SpoolRoot: t.TempDir(), NotifyCmd: cmd}
	Run(cfg, testMsg(), "GRK-42")
	if got := readLog(t, log); !strings.Contains(got, "--to GRK-42") {
		t.Fatalf("want --to GRK-42, got:\n%s", got)
	}
}

// FR-006: nothing the notifier does can fail a delivery. Each of these must
// return normally; the message is already on disk when Run is called.
func TestRunNeverFailsADelivery(t *testing.T) {
	root := t.TempDir()
	// A notifier that refuses the pane (unsent text) or finds no window.
	for _, rc := range []int{5, 6, 7, 1, 78} {
		cmd, _ := fakeNotifier(t, rc, "")
		Run(&config.Config{SpoolRoot: root, NotifyCmd: cmd}, testMsg(), "CLE-91")
	}
	// A notifier that is not there at all.
	Run(&config.Config{SpoolRoot: root, NotifyCmd: filepath.Join(root, "nope.sh")}, testMsg(), "CLE-91")
	// A nil message, and no recipient.
	cmd, _ := fakeNotifier(t, 0, "")
	Run(&config.Config{SpoolRoot: root, NotifyCmd: cmd}, nil, "CLE-91")
	Run(&config.Config{SpoolRoot: root, NotifyCmd: cmd}, testMsg(), "")
}

// FR-006: a notifier that hangs is cut off, and the caller is not held.
func TestRunTimesOut(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("uses sleep(1)")
	}
	cmd, _ := fakeNotifier(t, 0, "sleep 30\n")
	cfg := &config.Config{SpoolRoot: t.TempDir(), NotifyCmd: cmd, NotifyTimeout: 300 * time.Millisecond}
	start := time.Now()
	Run(cfg, testMsg(), "CLE-91")
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("Run held the caller for %v; the timeout did not fire", d)
	}
}

// The value is argv, split on whitespace — no shell. An interpreter prefix is
// therefore usable, and a `;` in it is an argument, not a second command.
func TestNotifyCmdIsArgvNotAShell(t *testing.T) {
	cmd, log := fakeNotifier(t, 0, "")
	cfg := &config.Config{SpoolRoot: t.TempDir(), NotifyCmd: "/usr/bin/env bash " + cmd}
	Run(cfg, testMsg(), "CLE-91")
	if got := readLog(t, log); !strings.Contains(got, "--to CLE-91") {
		t.Fatalf("an interpreter prefix must work, got:\n%s", got)
	}

	marker := filepath.Join(t.TempDir(), "pwned")
	cfg2 := &config.Config{SpoolRoot: t.TempDir(), NotifyCmd: cmd + " ; touch " + marker}
	Run(cfg2, testMsg(), "CLE-91")
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("the command string reached a shell")
	}
}

func TestNotifyTimeoutOrDefaults(t *testing.T) {
	if got := (&config.Config{}).NotifyTimeoutOr(); got != 10*time.Second {
		t.Fatalf("want a 10s default, got %v", got)
	}
	if got := (&config.Config{NotifyTimeout: time.Second}).NotifyTimeoutOr(); got != time.Second {
		t.Fatalf("want 1s, got %v", got)
	}
}
