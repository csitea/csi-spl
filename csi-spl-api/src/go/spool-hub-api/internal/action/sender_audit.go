package action

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
)

// SenderAuditEnv names the sender journal (SPL-5136, spec 165 3.3.1). A lane
// copied a desk's SPOOL_* variables and ran `spool send` itself, so the
// default is one fixed path and never follows SPOOL_ROOT.
const SenderAuditEnv = "SPOOL_SENDER_AUDIT"

const senderAuditDefault = "/var/spool-hub/dispatch/sender-audit.jsonl"

// senderAuditLine is what a send leaves for do_spl_sender_audit. Chain is the
// ancestor pids, this process first, and Starts each pid's start time, so a
// reused pid is not read as the agent that sent. Agent is the id read at send
// time, because a lane that has exited by audit time can no longer be read; it
// stays empty when any pid could not be read (Unread), since the outermost id
// wins and an unread outer pid could be the real agent. Pane says the chain
// ended at a tmux server, so its window name may still name the agent.
type senderAuditLine struct {
	TS     string   `json:"ts"`
	MsgID  string   `json:"msg_id"`
	From   string   `json:"from"`
	Claim  string   `json:"claim,omitempty"`
	Chain  []int    `json:"chain"`
	Starts []string `json:"starts"`
	Agent  string   `json:"agent,omitempty"`
	Unread int      `json:"unread"`
	Pane   bool     `json:"pane"`
}

// AuditSender journals one delivered CLI send. It is detection only and never
// fails the send: no journal dir (a box without a fleet root, a test) means no
// line, and a journal it cannot write is one line on stderr.
func AuditSender(in SendArgs, res SendResult) {
	path := os.Getenv(SenderAuditEnv)
	if path == "" {
		if os.Getenv("SPOOL_TEST") == "1" || strings.HasSuffix(os.Args[0], ".test") {
			return
		}
		path = senderAuditDefault
	}
	if err := auditSender(path, "/proc", os.Getpid(), ownerEnvHop, in, res); err != nil {
		fmt.Fprintf(os.Stderr, "spool: sender audit: %v\n", err)
	}
}

func auditSender(path, procRoot string, pid int, hop envHop, in SendArgs, res SendResult) error {
	if _, err := os.Stat(filepath.Dir(path)); err != nil {
		return nil
	}
	chain, pane := callerChain(procRoot, pid)
	agent, unread := chainAgent(procRoot, chain, hop)
	line, err := json.Marshal(senderAuditLine{
		TS: time.Now().UTC().Format(time.RFC3339), MsgID: res.MsgID, From: in.From,
		Claim: fromAgentClaim(in.Body), Chain: chain, Starts: chainStarts(procRoot, chain),
		Agent: agent, Unread: unread, Pane: pane,
	})
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o660) //nolint:gosec // G302: both box users append through the group
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	_, err = f.Write(append(line, '\n'))
	return err
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
// pid 1, as send_caller_chain does in lib/spool-caller.inc.sh. The bool says it
// stopped at a tmux server.
func callerChain(root string, pid int) ([]int, bool) {
	chain := []int{}
	for n := 0; n < 64 && pid > 1; n++ {
		dir := filepath.Join(root, strconv.Itoa(pid))
		comm, err := os.ReadFile(filepath.Join(dir, "comm")) //nolint:gosec // G304: a /proc path built from a pid
		if err != nil {
			break
		}
		if strings.HasPrefix(string(comm), "tmux") {
			return chain, true
		}
		chain = append(chain, pid)
		pid = parentPid(dir)
	}
	return chain, false
}

// chainStarts is each pid's start time, "0" for one already gone.
func chainStarts(root string, chain []int) []string {
	starts := make([]string, 0, len(chain))
	for _, p := range chain {
		starts = append(starts, procStart(filepath.Join(root, strconv.Itoa(p))))
	}
	return starts
}

// procStart is field 22 of stat, counted after the comm, which may hold spaces.
func procStart(dir string) string {
	raw, err := os.ReadFile(filepath.Join(dir, "stat")) //nolint:gosec // G304: a /proc path built from a pid
	if err != nil {
		return "0"
	}
	s := string(raw)
	fields := strings.Fields(s[strings.LastIndexByte(s, ')')+1:])
	if len(fields) < 20 {
		return "0"
	}
	return fields[19]
}

// chainAgent is the agent id of the outermost pid carrying one, and how many
// pids could not be read. As send_caller_env_id: a root-owned hop (sudo, su)
// holds a copy of its parent's environ and is skipped.
func chainAgent(root string, chain []int, hop envHop) (string, int) {
	unread, ids := 0, map[int]string{}
	byOwner := map[uint32][]int{}
	for _, p := range chain {
		dir := filepath.Join(root, strconv.Itoa(p))
		info, err := os.Stat(dir)
		if err != nil {
			unread++
			continue
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok || st.Uid == 0 {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, "environ")) //nolint:gosec // G304: a /proc path built from a pid
		if err != nil {
			byOwner[st.Uid] = append(byOwner[st.Uid], p)
			continue
		}
		ids[p] = environAgentID(string(raw))
	}
	for uid, pids := range byOwner {
		got := hop(root, uid, pids)
		for _, p := range pids {
			id, ok := got[p]
			if !ok {
				unread++
			}
			ids[p] = id
		}
	}
	if unread > 0 {
		return "", unread
	}
	agent := ""
	for _, p := range chain {
		if ids[p] != "" {
			agent = ids[p]
		}
	}
	return agent, 0
}

// environAgentID is the bare id in a NUL-separated environ, SPOOL_AGENT_ID
// before MCP_BOT_AGENT_ID.
func environAgentID(environ string) string {
	spoolID, mcpID := "", ""
	for _, kv := range strings.Split(environ, "\x00") {
		if v, ok := strings.CutPrefix(kv, "SPOOL_AGENT_ID="); ok && spoolID == "" {
			spoolID = bareEnvID(v)
		} else if v, ok := strings.CutPrefix(kv, "MCP_BOT_AGENT_ID="); ok && mcpID == "" {
			mcpID = bareEnvID(v)
		}
	}
	if spoolID != "" {
		return spoolID
	}
	return mcpID
}

func bareEnvID(v string) string {
	id, _ := agentid.SplitAtBox(v)
	if !agentid.IsAgent(id) {
		return ""
	}
	return id
}

// envHop reads the environ of pids another uid owns: pid to agent id, "" for
// no id. A pid missing from the result could not be read.
type envHop func(root string, uid uint32, pids []int) map[int]string

// ownerEnvHop asks the pids' owner, one sudo per owner and never a prompt (the
// rule of proc-owner.inc.sh), on the real /proc only. Bounded, so a wedged sudo
// cannot hold a send up for long.
func ownerEnvHop(root string, uid uint32, pids []int) map[int]string {
	if root != "/proc" {
		return map[int]string{}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	args := []string{"-n", "-u", "#" + strconv.FormatUint(uint64(uid), 10), "--", "sh", "-c",
		`for p in "$@"; do cat "/proc/$p/environ" 2>/dev/null && printf '%s\000' "@@$p"; done`, "sh"}
	for _, p := range pids {
		args = append(args, strconv.Itoa(p))
	}
	out, err := exec.CommandContext(ctx, "sudo", args...).Output() //nolint:gosec // G204: fixed argv, numeric uid and pids
	if err != nil {
		return map[int]string{}
	}
	return parseHopOutput(string(out))
}

// parseHopOutput reads <environ> "@@<pid>" NUL blocks: the marker follows a
// cat that succeeded, so a pid that could not be read has none.
func parseHopOutput(out string) map[int]string {
	got, env := map[int]string{}, ""
	for _, rec := range strings.Split(out, "\x00") {
		if v, ok := strings.CutPrefix(rec, "@@"); ok {
			if pid, err := strconv.Atoi(v); err == nil {
				got[pid] = environAgentID(env)
			}
			env = ""
			continue
		}
		env += rec + "\x00"
	}
	return got
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
