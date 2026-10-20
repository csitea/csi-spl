package spool

// Crash drill (SPL-2139, epic SPL-2129 robustness 1). A writer killed mid-write
// leaves what writeFileAtomic had written so far in its ".tmp-*" file; the
// rename that publishes the message never ran. The drill plants exactly that
// half file next to a good message and proves: no reader (Recv, Tail) reads
// the torn bytes as a message or as a malformed one, the half file never
// reaches archive/, and a re-run of the same send delivers the message whole.
// CONTROL: the same torn bytes under a message name (what a non-atomic writer
// would leave) ARE seen and surfaced as malformed, so the drill reads the box
// the readers read, and it is the temp name + rename that keeps them out.

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// tornCopy returns the first half of m's stored bytes: the state of a temp file
// whose writer died after a partial write(2).
func tornCopy(t *testing.T, m *msg.Message) []byte {
	t.Helper()
	blob, err := msg.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := msg.Parse(blob[:len(blob)/2]); err == nil {
		t.Fatal("drill setup: half a message parses; the torn copy proves nothing")
	}
	return blob[:len(blob)/2]
}

// recvShape prints a Recv outcome for a failure message.
func recvShape(res *RecvResult, err error) string {
	if res == nil {
		return fmt.Sprintf("nil result, err=%v", err)
	}
	ids := make([]string, 0, len(res.Messages))
	for _, m := range res.Messages {
		ids = append(ids, m.MsgID)
	}
	return fmt.Sprintf("messages=%v failed=%d err=%v", ids, res.Failed, err)
}

func TestCrashDrill_TornTempFileIsNeverReadAndRerunRecovers(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	good, err := st.Send("GRK-03", "CLE-07", "drill-task", "task", "delivered before the crash", nil)
	if err != nil {
		t.Fatal(err)
	}
	// The crashed send: same task, its message composed, half of it written to
	// the temp file, the process killed before the rename.
	lost, err := st.Compose("GRK-03", "CLE-07", "drill-task", "task", "the send that crashed mid-write", nil)
	if err != nil {
		t.Fatal(err)
	}
	torn := filepath.Join(st.dir("CLE-07", boxInbox), ".tmp-4242424242")
	if err := os.WriteFile(torn, tornCopy(t, lost), 0o600); err != nil {
		t.Fatal(err)
	}

	tail, err := st.Tail("drill-task")
	if err != nil || len(tail) != 1 || tail[0].MsgID != good.MsgID {
		t.Fatalf("tail after the crash: want only the good message, got %d (%v)", len(tail), err)
	}
	res, err := st.Recv("CLE-07", true)
	if err != nil || res.Failed != 0 || len(res.Messages) != 1 || res.Messages[0].MsgID != good.MsgID {
		t.Fatalf("recv after the crash: want 1 good / 0 failed, got %s", recvShape(res, err))
	}
	if _, err := os.Stat(torn); err != nil {
		t.Fatalf("the ack must leave the torn temp file where it is, not archive it: %v", err)
	}
	archived, _ := filepath.Glob(filepath.Join(st.dir("CLE-07", boxArchive), ".tmp-*"))
	if len(archived) != 0 {
		t.Fatalf("a torn temp file reached archive/: %v", archived)
	}

	// The re-run: the sender sends again and the whole message lands.
	again, err := st.Send("GRK-03", "CLE-07", "drill-task", "task", "the send that crashed mid-write", nil)
	if err != nil {
		t.Fatalf("re-run after the crash: %v", err)
	}
	res, err = st.Recv("CLE-07", false)
	if err != nil || res.Failed != 0 || len(res.Messages) != 1 || res.Messages[0].MsgID != again.MsgID ||
		res.Messages[0].Body != "the send that crashed mid-write" {
		t.Fatalf("recv after the re-run: want the re-sent message whole, got %s", recvShape(res, err))
	}
}

func TestCrashDrill_Control_TornBytesUnderAMessageNameAreSurfaced(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if _, err := st.Send("GRK-03", "CLE-07", "drill-task", "task", "delivered before the crash", nil); err != nil {
		t.Fatal(err)
	}
	lost, err := st.Compose("GRK-03", "CLE-07", "drill-task", "task", "the send that crashed mid-write", nil)
	if err != nil {
		t.Fatal(err)
	}
	// A non-atomic writer opens the final name and dies after half of it.
	named := filepath.Join(st.dir("CLE-07", boxInbox), msg.Filename(lost))
	if err := os.WriteFile(named, tornCopy(t, lost), 0o664); err != nil {
		t.Fatal(err)
	}
	res, err := st.Recv("CLE-07", true)
	if err == nil || res.Failed != 1 || len(res.Messages) != 1 {
		t.Fatalf("control: torn bytes under a message name must be surfaced as 1 malformed, got %s", recvShape(res, err))
	}
	if _, err := os.Stat(named); err != nil {
		t.Fatalf("control: the malformed file must stay in the inbox: %v", err)
	}
}
