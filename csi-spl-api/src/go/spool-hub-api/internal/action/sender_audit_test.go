package action

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func fakeProc(t *testing.T, root string, pid, ppid int, comm string) {
	t.Helper()
	d := filepath.Join(root, strconv.Itoa(pid))
	if err := os.MkdirAll(d, 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "comm"), []byte(comm+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	status := "Name:\t" + comm + "\nPPid:\t" + strconv.Itoa(ppid) + "\n"
	if err := os.WriteFile(filepath.Join(d, "status"), []byte(status), 0o600); err != nil {
		t.Fatal(err)
	}
	stat := strconv.Itoa(pid) + " (a b) S " + strconv.Itoa(ppid) + " 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 " + strconv.Itoa(pid*10) + " 9\n"
	if err := os.WriteFile(filepath.Join(d, "stat"), []byte(stat), 0o600); err != nil {
		t.Fatal(err)
	}
}

func fakeEnviron(t *testing.T, root string, pid int, env string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, strconv.Itoa(pid), "environ"), []byte(env), mode); err != nil {
		t.Fatal(err)
	}
}

func noHop(string, uint32, []int) map[int]string { return map[int]string{} }

func readAuditLine(t *testing.T, path string) senderAuditLine {
	t.Helper()
	raw, err := os.ReadFile(path) //nolint:gosec // G304: the test's temp file
	if err != nil {
		t.Fatal(err)
	}
	var got senderAuditLine
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	return got
}

func TestAuditSenderJournalsChainAndClaim(t *testing.T) {
	root, path := t.TempDir(), filepath.Join(t.TempDir(), "j.jsonl")
	fakeProc(t, root, 99, 1, "tmux: server")
	fakeProc(t, root, 100, 99, "claude")
	fakeProc(t, root, 101, 100, "spool")
	in := SendArgs{From: "c-002", Body: "from_agent: c-777@box-a\nhello"}
	if err := auditSender(path, root, 101, noHop, in, SendResult{MsgID: "m1"}); err != nil {
		t.Fatal(err)
	}
	got := readAuditLine(t, path)
	if got.MsgID != "m1" || got.From != "c-002" || got.Claim != "c-777" {
		t.Fatalf("line = %+v", got)
	}
	if len(got.Chain) != 2 || got.Chain[0] != 101 || got.Chain[1] != 100 {
		t.Fatalf("chain = %v, want [101 100]: stops before the tmux server", got.Chain)
	}
	if !got.Pane || len(got.Starts) != 2 || got.Starts[0] != "1010" || got.Starts[1] != "1000" {
		t.Fatalf("pane = %v, starts = %v, want true [1010 1000]", got.Pane, got.Starts)
	}
}

func TestAuditSenderJournalsOutermostAgentAtSendTime(t *testing.T) {
	root, path := t.TempDir(), filepath.Join(t.TempDir(), "j.jsonl")
	fakeProc(t, root, 100, 1, "claude")
	fakeProc(t, root, 101, 100, "spool")
	fakeEnviron(t, root, 100, "A=1\x00SPOOL_AGENT_ID=c-777@box-a\x00", 0o600)
	fakeEnviron(t, root, 101, "SPOOL_AGENT_ID=c-002\x00", 0o600)
	if err := auditSender(path, root, 101, noHop, SendArgs{From: "c-002"}, SendResult{MsgID: "m2"}); err != nil {
		t.Fatal(err)
	}
	got := readAuditLine(t, path)
	if got.Agent != "c-777" || got.Unread != 0 || got.Pane {
		t.Fatalf("line = %+v, want agent c-777 (the outermost), unread 0, no pane", got)
	}
}

func TestAuditSenderUnreadPidDropsTheAgent(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads a mode 000 file")
	}
	root, path := t.TempDir(), filepath.Join(t.TempDir(), "j.jsonl")
	fakeProc(t, root, 100, 1, "claude")
	fakeProc(t, root, 101, 100, "spool")
	fakeEnviron(t, root, 100, "SPOOL_AGENT_ID=c-777\x00", 0o000)
	fakeEnviron(t, root, 101, "SPOOL_AGENT_ID=c-002\x00", 0o600)
	if err := auditSender(path, root, 101, noHop, SendArgs{From: "c-002"}, SendResult{MsgID: "m3"}); err != nil {
		t.Fatal(err)
	}
	if got := readAuditLine(t, path); got.Agent != "" || got.Unread != 1 {
		t.Fatalf("line = %+v, want no agent and unread 1: the inner copied id must not win", got)
	}
	hop := func(string, uint32, []int) map[int]string { return map[int]string{100: "c-777"} }
	path2 := filepath.Join(t.TempDir(), "j.jsonl")
	if err := auditSender(path2, root, 101, hop, SendArgs{From: "c-002"}, SendResult{MsgID: "m4"}); err != nil {
		t.Fatal(err)
	}
	if got := readAuditLine(t, path2); got.Agent != "c-777" || got.Unread != 0 {
		t.Fatalf("line = %+v, want the owner hop to read c-777", got)
	}
}

func TestParseHopOutputMarksOnlyWhatWasRead(t *testing.T) {
	got := parseHopOutput("SPOOL_AGENT_ID=c-777\x00@@100\x00@@101\x00")
	if id, ok := got[100]; !ok || id != "c-777" {
		t.Fatalf("100 = %q %v", id, ok)
	}
	if id, ok := got[101]; !ok || id != "" {
		t.Fatalf("101 = %q %v, want read and no id", id, ok)
	}
	if _, ok := got[102]; ok {
		t.Fatal("a pid with no marker counted as read")
	}
}

func TestAuditSenderReportsAJournalItCannotOpen(t *testing.T) {
	path := t.TempDir()
	if err := auditSender(path, t.TempDir(), 5, noHop, SendArgs{From: "c-1"}, SendResult{}); err == nil {
		t.Fatal("no error for a journal path that is a directory")
	}
}

func TestAuditSenderNoClaimOnPlainBody(t *testing.T) {
	if c := fromAgentClaim("hello\nfrom_agent: c-1@b"); c != "" {
		t.Fatalf("claim = %q: only the first line counts", c)
	}
}

func TestAuditSenderMissingDirWritesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent", "j.jsonl")
	if err := auditSender(path, t.TempDir(), 5, noHop, SendArgs{From: "c-1"}, SendResult{}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err == nil {
		t.Fatal("a journal was created in a dir that did not exist")
	}
}

func TestAuditSenderOffUnderGoTest(t *testing.T) {
	t.Setenv(SenderAuditEnv, "")
	if _, err := os.Stat(senderAuditDefault); err == nil {
		before, _ := os.ReadFile(senderAuditDefault)
		AuditSender(SendArgs{From: "c-1"}, SendResult{})
		after, _ := os.ReadFile(senderAuditDefault)
		if len(before) != len(after) {
			t.Fatal("a go test wrote the live journal")
		}
	}
}
