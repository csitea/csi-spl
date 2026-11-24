package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"filippo.io/age"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The sidecar's sign-in relayer (spec 181 row B11) on a private VM: on
// with SPOOL_SIGNIN_RELAY_CMD, the command line (split on spaces, no
// shell) of the VM's relay action, e.g. `<orc>/run -a do_spl_ws_signin_relay`,
// run as this sidecar's user (the workspace's own OS user). Off (unset, the
// default) the hello carries no signin_relay feature and the hub sends no
// frame.
//
// Per frame it runs the command once with SIGNIN_RELAY_OP, SIGNIN_RELAY_KIND,
// SIGNIN_RELAY_ID and DRY_RUN=0 in its environment. An input frame's sealed
// text is opened here with the desk's X25519 identity (the key the pin's
// recipient names, rdb 0235) and handed to the command on its STDIN only:
// never in its argv or environment (both readable in /proc), never logged.
// The command's last stdout line `SIGNIN_RELAY state=<s> [url=<u>]
// [reason=<r>]` is the report; its stderr is dropped.

// signinRelayTimeout bounds one run of the relay command.
const signinRelayTimeout = 90 * time.Second

// signinRelayPrefix starts the command's report line.
const signinRelayPrefix = "SIGNIN_RELAY "

// cmdSigninRelayer is the relayer: the command and the desk identity.
type cmdSigninRelayer struct {
	argv []string
	id   age.Identity
	run  func(ctx context.Context, argv, env []string, stdin io.Reader) ([]byte, error)
}

// startSigninRelay sets c.SigninRelay when SPOOL_SIGNIN_RELAY_CMD is set and
// the desk identity loads; a relayer that cannot start is logged and left
// off, so the hub never sends this box a frame.
func startSigninRelay(cfg *config.Config, c *hubclient.Client) {
	argv := strings.Fields(os.Getenv("SPOOL_SIGNIN_RELAY_CMD"))
	if len(argv) == 0 {
		return
	}
	if err := os.MkdirAll(cfg.HubDir(), 0o700); err != nil {
		c.Log.Error().Err(err).Msg("sign-in relay not started")
		return
	}
	id, err := keydesk.LoadOrCreateIdentity(keydesk.IdentityPath(cfg.HubDir()))
	if err != nil {
		c.Log.Error().Err(err).Msg("sign-in relay not started: no desk identity")
		return
	}
	c.SigninRelay = cmdSigninRelayer{argv: argv, id: id, run: runRelayCmd}
	c.Log.Info().Str("cmd", argv[0]).Msg("sign-in relay on")
}

// runRelayCmd runs argv with env added and stdin, and returns its stdout.
func runRelayCmd(ctx context.Context, argv, env []string, stdin io.Reader) ([]byte, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...) // #nosec G204 -- the operator's own SPOOL_SIGNIN_RELAY_CMD
	cmd.Env = append(os.Environ(), env...)
	cmd.Stdin = stdin
	cmd.Stderr = io.Discard
	return cmd.Output()
}

// Run runs one frame: opens an input's sealed text, runs the command,
// reads its report.
func (r cmdSigninRelayer) Run(ctx context.Context, relay string, lane wire.SigninRelayLane) wire.SigninRelayOutLane {
	failed := func(why string) wire.SigninRelayOutLane {
		return wire.SigninRelayOutLane{State: wire.SigninStateFailed, Reason: why}
	}
	var stdin io.Reader = strings.NewReader("")
	switch lane.Op {
	case wire.SigninOpStart, wire.SigninOpEnd:
	case wire.SigninOpInput:
		input, ok := openSigninInput(r.id, relay, lane.Sealed)
		if !ok {
			return failed("seal_mismatch")
		}
		stdin = strings.NewReader(input + "\n")
	default:
		return failed("bad_op")
	}
	ctx, cancel := context.WithTimeout(ctx, signinRelayTimeout)
	defer cancel()
	env := []string{"SIGNIN_RELAY_OP=" + lane.Op, "SIGNIN_RELAY_KIND=" + lane.Kind, "SIGNIN_RELAY_ID=" + relay, "DRY_RUN=0"}
	out, err := r.run(ctx, r.argv, env, stdin)
	rep, ok := parseRelayReport(out)
	if !ok {
		if err != nil {
			return failed("relay_cmd_failed")
		}
		return failed("no_report")
	}
	return rep
}

// openSigninInput opens sealed (base64 age) with id and returns its input
// when it names this relay; false for anything else.
func openSigninInput(id age.Identity, relay, sealed string) (string, bool) {
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		return "", false
	}
	rd, err := age.Decrypt(bytes.NewReader(raw), id)
	if err != nil {
		return "", false
	}
	pt, err := io.ReadAll(io.LimitReader(rd, 4096))
	if err != nil {
		return "", false
	}
	var p wire.SigninRelaySealed
	dec := json.NewDecoder(bytes.NewReader(pt))
	dec.DisallowUnknownFields()
	if dec.Decode(&p) != nil || p.Relay != relay || p.Input == "" || strings.ContainsAny(p.Input, "\r\n") {
		return "", false
	}
	return p.Input, true
}

// parseRelayReport reads the last `SIGNIN_RELAY k=v ...` line of out.
func parseRelayReport(out []byte) (wire.SigninRelayOutLane, bool) {
	var last string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if l := sc.Text(); strings.HasPrefix(l, signinRelayPrefix) {
			last = l
		}
	}
	if last == "" {
		return wire.SigninRelayOutLane{}, false
	}
	var o wire.SigninRelayOutLane
	for _, kv := range strings.Fields(strings.TrimPrefix(last, signinRelayPrefix)) {
		k, v, _ := strings.Cut(kv, "=")
		switch k {
		case "state":
			o.State = v
		case "url":
			o.URL = v
		case "reason":
			o.Reason = v
		}
	}
	return o, o.State != ""
}
