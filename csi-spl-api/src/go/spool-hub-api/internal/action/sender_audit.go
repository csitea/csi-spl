package action

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
)

// SenderAuditEnv names the sender journal (SPL-5136, spec 165 3.3.1). A lane
// copied a desk's SPOOL_* variables and ran `spool send` itself, so the
// default is one fixed path and never follows SPOOL_ROOT.
const SenderAuditEnv = "SPOOL_SENDER_AUDIT"

const senderAuditDefault = "/var/spool-hub/dispatch/sender-audit.jsonl"

// senderAuditLine is what a send leaves for do_spl_sender_audit. Chain is the
// ancestor pids, this process first: every agent has sudo to the box user and
// the agent's environ may be another uid's, so the binary records the pids
// and the action, which may read them, names the caller.
type senderAuditLine struct {
	TS    string `json:"ts"`
	MsgID string `json:"msg_id"`
	From  string `json:"from"`
	Claim string `json:"claim,omitempty"`
	Chain []int  `json:"chain"`
}

// AuditSender journals one delivered CLI send. It is detection only and never
// fails or delays the send: no journal dir (a box without a fleet root, a
// test) means no line.
func AuditSender(in SendArgs, res SendResult) {
	path := os.Getenv(SenderAuditEnv)
	if path == "" {
		if os.Getenv("SPOOL_TEST") == "1" || strings.HasSuffix(os.Args[0], ".test") {
			return
		}
		path = senderAuditDefault
	}
	auditSender(path, "/proc", os.Getpid(), in, res)
}

func auditSender(path, procRoot string, pid int, in SendArgs, res SendResult) {
	if _, err := os.Stat(filepath.Dir(path)); err != nil {
		return
	}
	line, err := json.Marshal(senderAuditLine{
		TS: time.Now().UTC().Format(time.RFC3339), MsgID: res.MsgID, From: in.From,
		Claim: fromAgentClaim(in.Body), Chain: callerChain(procRoot, pid),
	})
	if err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o660) //nolint:gosec // G302: both box users append through the group
	if err != nil {
		return
	}
	defer func() { _ = f.Close() }()
	_, _ = f.Write(append(line, '\n'))
}

// fromAgentClaim is the id a relayed body's from_agent first line names.
func fromAgentClaim(body string) string {
	first, _, _ := strings.Cut(body, "\n")
	if !strings.HasPrefix(first, spool.FromAgentPrefix) {
		return ""
	}
	id, _, _ := strings.Cut(strings.TrimSpace(strings.TrimPrefix(first, spool.FromAgentPrefix)), "@")
	return id
}

// callerChain walks the parents of pid up to (not into) the tmux server or
// pid 1, as send_caller_chain does in lib/spool-caller.inc.sh.
func callerChain(root string, pid int) []int {
	chain := []int{}
	for n := 0; n < 64 && pid > 1; n++ {
		dir := filepath.Join(root, strconv.Itoa(pid))
		comm, err := os.ReadFile(filepath.Join(dir, "comm")) //nolint:gosec // G304: a /proc path built from a pid
		if err != nil || strings.HasPrefix(string(comm), "tmux") {
			break
		}
		chain = append(chain, pid)
		pid = parentPid(dir)
	}
	return chain
}

func parentPid(dir string) int {
	status, err := os.ReadFile(filepath.Join(dir, "status")) //nolint:gosec // G304: a /proc path built from a pid
	if err != nil {
		return 0
	}
	for _, l := range strings.Split(string(status), "\n") {
		if v, ok := strings.CutPrefix(l, "PPid:"); ok {
			p, _ := strconv.Atoi(strings.TrimSpace(v))
			return p
		}
	}
	return 0
}
