package hubclient

import (
	"bytes"
	"context"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// pkOtherUser is an existing user this test does not run as, and a PATH of
// one empty temp dir: nothing on the box's own PATH (no real sudo) is reachable.
func pkOtherUser(t *testing.T) (name, binDir string) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("running as root: root is not another user")
	}
	u, err := user.Lookup("root")
	if err != nil {
		t.Skipf("no root user: %v", err)
	}
	binDir = t.TempDir()
	t.Setenv("PATH", binDir)
	return u.Username, binDir
}

func pkStubSudo(t *testing.T, binDir, body string) {
	t.Helper()
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(filepath.Join(binDir, "sudo"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestAgentProbeOwnUserIsNil(t *testing.T) {
	me, err := user.Current()
	if err != nil {
		t.Skipf("no current user: %v", err)
	}
	if agentProbe(me.Username) != nil {
		t.Fatal("a probe for the sidecar's own user")
	}
}

func TestAgentProbeUnknownUserIsNil(t *testing.T) {
	if agentProbe("pk-no-such-user") != nil {
		t.Fatal("a probe for a user the box does not have")
	}
}

func TestAgentProbeNoSudoIsNil(t *testing.T) {
	name, _ := pkOtherUser(t)
	if agentProbe(name) != nil {
		t.Fatal("a probe on a box without sudo")
	}
}

// Only the first line of the output is the probe's answer.
func TestAgentProbeReturnsFirstLine(t *testing.T) {
	name, binDir := pkOtherUser(t)
	pkStubSudo(t, binDir, `printf 'v1\nv2\n'`)
	run := agentProbe(name)
	if run == nil {
		t.Fatal("no probe with a sudo on PATH")
	}
	line, err := run(context.Background(), []string{"claude", "--version"})
	if err != nil || line != "v1" {
		t.Fatalf("line = %q, err = %v, want v1", line, err)
	}
}

func TestAgentProbeSudoFailureIsAnError(t *testing.T) {
	name, binDir := pkOtherUser(t)
	pkStubSudo(t, binDir, `exit 1`)
	run := agentProbe(name)
	if run == nil {
		t.Fatal("no probe with a sudo on PATH")
	}
	if _, err := run(context.Background(), []string{"claude", "--version"}); err == nil {
		t.Fatal("a failing sudo reported no error")
	}
}

// A listener that will not open is logged and still hands back a stop func.
func TestServeSubmitNotOpenedLogsAndStops(t *testing.T) {
	c := testClient(t)
	var logs bytes.Buffer
	c.Log = zerolog.New(&logs)
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	c.Cfg.SubmitSocket = filepath.Join(file, "s")
	stop := c.serveSubmit(context.Background(), nil)
	if stop == nil {
		t.Fatal("no stop func")
	}
	stop()
	if !strings.Contains(logs.String(), "submit listener not opened") {
		t.Fatalf("logs = %q", logs.String())
	}
}

// The session stays nil: a dial that sends no request never reaches it.
func TestServeSubmitListensUntilStopped(t *testing.T) {
	c := testClient(t)
	var logs bytes.Buffer
	c.Log = zerolog.New(&logs)
	c.Cfg.SubmitSocket = shortSock(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stop := c.serveSubmit(ctx, nil)
	if !strings.Contains(logs.String(), "submit listener up") {
		t.Fatalf("logs = %q", logs.String())
	}
	conn, err := net.DialTimeout("unix", c.Cfg.SubmitPath(), time.Second)
	if err != nil {
		t.Fatalf("dial while up: %v", err)
	}
	conn.Close()
	stop()
	if conn, err := net.DialTimeout("unix", c.Cfg.SubmitPath(), time.Second); err == nil {
		conn.Close()
		t.Fatal("the socket still answers after stop")
	}
}

func TestKeepRunNoneOfTheAgentsIsNil(t *testing.T) {
	if got := keepRun([]string{"a", "b"}, map[string]bool{"gone": true}); got != nil {
		t.Fatalf("keepRun = %v, want nil", got)
	}
}

func TestKeepRunTwoOfThree(t *testing.T) {
	run := map[string]bool{"a": true, "c": false, "gone": true}
	got := keepRun([]string{"a", "b", "c"}, run)
	want := map[string]bool{"a": true, "c": false}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("keepRun = %v, want %v", got, want)
	}
}
