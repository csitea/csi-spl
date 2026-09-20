// Package notify is the terminal leg of a delivery (specs/028-spool-terminal-delivery):
// after a v:1 message lands in a LOCAL agent's inbox, the agent's terminal
// pane is made to show it.
//
// The binary carries no tmux knowledge. It runs one command, $SPOOL_NOTIFY_CMD
// — on a box that is csi-spl-orc's spool-notify.sh — and hands it the message's
// fields as flags and the body on stdin. That one command owns the safe-poke
// rules (contracts/poke-line.md) and is the same code path spool-send.sh uses,
// so there is exactly one renderer on the box.
//
// Nothing here can fail a delivery. The file is the record (002); this is the
// second leg, and a notifier that is missing, slow or angry is logged and
// forgotten.
package notify

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/logging"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Off is the $SPOOL_NOTIFY_CMD value that disables the terminal leg explicitly
// (spool-send.sh sets it for its own send: it rings the pane itself).
const Off = "off"

// Enabled reports whether cfg asks for a terminal leg at all. Unset is the
// default, so a hub, a CI job and every test behave exactly as before.
func Enabled(cfg *config.Config) bool {
	if cfg == nil {
		return false
	}
	c := strings.TrimSpace(cfg.NotifyCmd)
	return c != "" && c != Off
}

// poked is an exit code that means the notifier did its job and decided, under
// the safe-poke rules, what to do with the pane: 0 shown, 5 no live window,
// 6 refused (unsent text), 7 the agent has exited. None of them is a fault.
func poked(code int) bool {
	switch code {
	case 0, 5, 6, 7:
		return true
	}
	return false
}

// Run shows m in the terminal of agent `to` on this box. `to` is passed
// separately because a mention-routed channel message (003 channels-v1 §4) is
// delivered to several local agents and m.To names only one of them.
//
// It blocks for at most cfg.NotifyTimeout and returns nothing: every outcome
// is a log line.
func Run(cfg *config.Config, m *msg.Message, to string) {
	if !Enabled(cfg) || m == nil || to == "" {
		return
	}
	argv := strings.Fields(cfg.NotifyCmd)
	argv = append(argv,
		"--to", to,
		"--from", m.From,
		"--kind", m.Kind,
		"--task", m.TaskID,
		"--msg-id", m.MsgID,
		"--body-stdin",
	)

	ctx, cancel := context.WithTimeout(context.Background(), cfg.NotifyTimeoutOr())
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...) //nolint:gosec // operator-set command, no shell
	// The notifier is a shell script that runs tmux; its OWN children inherit
	// the output pipe, so killing it on the deadline is not enough - Wait would
	// block on that pipe until the grandchild exits. WaitDelay gives up on the
	// pipe shortly after the kill, which is what actually bounds Run.
	cmd.WaitDelay = time.Second
	cmd.Stdin = strings.NewReader(m.Body)
	// The notifier resolves the recipient's pane from $SPOOL_ROOT/registry.tsv,
	// so it must see the same root this store wrote into, whatever the parent
	// process inherited.
	cmd.Env = append(os.Environ(), "SPOOL_ROOT="+cfg.SpoolRoot)
	out, err := cmd.CombinedOutput()

	log := logging.New(cfg).With().Str("to", to).Str("msg_id", m.MsgID).Logger()
	line := strings.TrimSpace(string(out))
	var ee *exec.ExitError
	switch {
	case err == nil:
		log.Debug().Str("notify", line).Msg("terminal delivery")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		log.Warn().Str("cmd", argv[0]).Msg("terminal delivery timed out; the message is still in the inbox")
	case errors.As(err, &ee) && poked(ee.ExitCode()):
		log.Debug().Int("rc", ee.ExitCode()).Str("notify", line).Msg("terminal delivery: pane left alone")
	default:
		log.Warn().Err(err).Str("cmd", argv[0]).Str("notify", line).
			Msg("terminal delivery failed; the message is still in the inbox")
	}
}
