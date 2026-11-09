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
}

func TestAuditSenderJournalsChainAndClaim(t *testing.T) {
	root, path := t.TempDir(), filepath.Join(t.TempDir(), "j.jsonl")
	fakeProc(t, root, 99, 1, "tmux: server")
	fakeProc(t, root, 100, 99, "claude")
	fakeProc(t, root, 101, 100, "spool")
	in := SendArgs{From: "c-002", Body: "from_agent: c-777@box-a\nhello"}
	auditSender(path, root, 101, in, SendResult{MsgID: "m1"})
	raw, err := os.ReadFile(path) //nolint:gosec // G304: the test's temp file
	if err != nil {
		t.Fatal(err)
	}
	var got senderAuditLine
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got.MsgID != "m1" || got.From != "c-002" || got.Claim != "c-777" {
		t.Fatalf("line = %+v", got)
	}
	if len(got.Chain) != 2 || got.Chain[0] != 101 || got.Chain[1] != 100 {
		t.Fatalf("chain = %v, want [101 100]: stops before the tmux server", got.Chain)
	}
}

func TestAuditSenderNoClaimOnPlainBody(t *testing.T) {
	if c := fromAgentClaim("hello\nfrom_agent: c-1@b"); c != "" {
		t.Fatalf("claim = %q: only the first line counts", c)
	}
}

func TestAuditSenderMissingDirWritesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent", "j.jsonl")
	auditSender(path, t.TempDir(), 5, SendArgs{From: "c-1"}, SendResult{})
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
