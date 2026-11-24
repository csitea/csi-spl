package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"filippo.io/age"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// sealFor seals {relay, input} to id as the hub does (signin_relay.go).
func sealFor(t *testing.T, id *age.X25519Identity, relay, input string) string {
	t.Helper()
	pt, _ := json.Marshal(wire.SigninRelaySealed{Relay: relay, Input: input})
	var buf bytes.Buffer
	w, err := age.Encrypt(&buf, id.Recipient())
	if err != nil {
		t.Fatal(err)
	}
	w.Write(pt) //nolint:errcheck
	w.Close()   //nolint:errcheck
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

// TestSigninRelayerInputOnStdinOnly (spec 181 B11): an input frame's sealed
// text is opened with the desk identity and reaches the relay command on
// its stdin only, never its argv or environment; the command's last
// SIGNIN_RELAY line is the report. A seal for another relay, or to another
// desk, is refused before the command runs (CONTROL).
func TestSigninRelayerInputOnStdinOnly(t *testing.T) {
	id, _ := age.GenerateX25519Identity()
	const input = "relay-input-0000-fake"
	var gotArgv, gotEnv []string
	var gotStdin string
	runs := 0
	r := cmdSigninRelayer{argv: []string{"/x/run", "-a", "do_spl_ws_signin_relay"}, id: id,
		run: func(_ context.Context, argv, env []string, stdin io.Reader) ([]byte, error) {
			runs++
			gotArgv, gotEnv = argv, env
			b, _ := io.ReadAll(stdin)
			gotStdin = string(b)
			return []byte("INFO noise\nSIGNIN_RELAY state=delivered\n"), nil
		}}
	out := r.Run(context.Background(), "r-1", wire.SigninRelayLane{ID: "f-1", Op: wire.SigninOpInput, Kind: "claude",
		Sealed: sealFor(t, id, "r-1", input)})
	if out.State != wire.SigninStateDelivered || gotStdin != input+"\n" {
		t.Fatalf("report %+v, stdin %q", out, gotStdin)
	}
	if strings.Contains(strings.Join(append(gotArgv, gotEnv...), " "), input) {
		t.Fatalf("the input is in the argv or env: %v %v", gotArgv, gotEnv)
	}
	if !strings.Contains(strings.Join(gotEnv, " "), "SIGNIN_RELAY_OP=input") {
		t.Fatalf("env %v", gotEnv)
	}
	other, _ := age.GenerateX25519Identity()
	for name, sealed := range map[string]string{
		"another relay's seal": sealFor(t, id, "r-2", input),
		"another desk's seal":  sealFor(t, other, "r-1", input),
		"not base64":           "%%%",
	} {
		runs = 0
		out := r.Run(context.Background(), "r-1", wire.SigninRelayLane{ID: "f-2", Op: wire.SigninOpInput, Kind: "claude", Sealed: sealed})
		if out.State != wire.SigninStateFailed || out.Reason != "seal_mismatch" || runs != 0 {
			t.Errorf("%s: %+v, %d runs; want failed seal_mismatch, no run", name, out, runs)
		}
	}
}

func TestParseRelayReport(t *testing.T) {
	o, ok := parseRelayReport([]byte("x\nSIGNIN_RELAY state=failed reason=a\nSIGNIN_RELAY state=url url=https://example.com/a?b=c\n"))
	if !ok || o.State != "url" || o.URL != "https://example.com/a?b=c" || o.Reason != "" {
		t.Fatalf("%+v %v", o, ok)
	}
	if _, ok := parseRelayReport([]byte("no report\n")); ok {
		t.Fatal("a run with no report line parsed")
	}
}

// TestStartSigninRelaySwitch: SPOOL_SIGNIN_RELAY_CMD unset leaves the
// relayer off (no hello feature); set, the sidecar takes the desk identity
// and the relay command, which runs with the input on stdin only and its
// report read back.
func TestStartSigninRelaySwitch(t *testing.T) {
	d := t.TempDir()
	cfg := &config.Config{SpoolRoot: filepath.Join(d, "spool"), BoxID: "vm-1"}
	c := hubclient.New(cfg)
	t.Setenv("SPOOL_SIGNIN_RELAY_CMD", "")
	startSigninRelay(cfg, c)
	if c.SigninRelay != nil {
		t.Fatal("a relayer started with SPOOL_SIGNIN_RELAY_CMD unset")
	}
	script := filepath.Join(d, "relay.sh")
	body := "#!/bin/sh\nread -r line\n[ \"$SIGNIN_RELAY_OP\" = input ] && [ -n \"$line\" ] && echo 'SIGNIN_RELAY state=delivered'\nexit 0\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPOOL_SIGNIN_RELAY_CMD", script)
	startSigninRelay(cfg, c)
	r, ok := c.SigninRelay.(cmdSigninRelayer)
	if !ok {
		t.Fatalf("relayer %T", c.SigninRelay)
	}
	id, ok := r.id.(*age.X25519Identity)
	if !ok {
		t.Fatalf("identity %T", r.id)
	}
	out := r.Run(context.Background(), "r-1", wire.SigninRelayLane{ID: "f-1", Op: wire.SigninOpInput, Kind: "claude",
		Sealed: sealFor(t, id, "r-1", "relay-input-0000-fake")})
	if out.State != wire.SigninStateDelivered {
		t.Fatalf("the relay command's report: %+v", out)
	}
	if out := r.Run(context.Background(), "r-1", wire.SigninRelayLane{ID: "f-2", Op: wire.SigninOpStart, Kind: "claude"}); out.Reason != "no_report" {
		t.Fatalf("a run with no report line: %+v, want failed no_report", out)
	}
	if out := r.Run(context.Background(), "r-1", wire.SigninRelayLane{ID: "f-3", Op: "nope"}); out.Reason != "bad_op" {
		t.Fatalf("an unknown op: %+v, want failed bad_op", out)
	}
	r.argv = []string{filepath.Join(d, "missing")}
	if out := r.Run(context.Background(), "r-1", wire.SigninRelayLane{ID: "f-4", Op: wire.SigninOpEnd}); out.Reason != "relay_cmd_failed" {
		t.Fatalf("a command that does not run: %+v, want failed relay_cmd_failed", out)
	}
}
