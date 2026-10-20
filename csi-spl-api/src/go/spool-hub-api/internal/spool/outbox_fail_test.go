package spool

// Outbox-fail drill (SPL-2703, found by the SPL-2139 drills). Send writes the
// recipient's inbox first, then the sender's outbox. When only the outbox write
// fails the message is already delivered, so Send must not report a failure:
// every caller that retries on a non-zero exit (spool-send.sh, desk actions)
// would deliver it a second time. The outbox failure is a warning on stderr.
// CONTROL: a failed inbox write is a real delivery failure and still errors.
//
// The box is broken by a regular file where its directory belongs: unlike a
// chmod, that fails for root too, so the test holds under any runner user.

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// blockBox puts a regular file at <root>/<id>/<box>, so writing that box fails.
func blockBox(t *testing.T, root, id, box string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, id), 0o775); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, id, box), []byte("not a dir"), 0o664); err != nil {
		t.Fatal(err)
	}
}

// messageCount counts the messages in <root>/<id>/<box>.
func messageCount(t *testing.T, root, id, box string) int {
	t.Helper()
	ents, err := os.ReadDir(filepath.Join(root, id, box))
	if err != nil {
		return 0
	}
	n := 0
	for _, e := range ents {
		if isMessageFile(e) {
			n++
		}
	}
	return n
}

func TestSend_OutboxFailAfterDeliveryIsAWarningNotAnError(t *testing.T) {
	cfg := newCfg(t)
	var warn bytes.Buffer
	st := New(cfg)
	st.warn = &warn
	blockBox(t, cfg.SpoolRoot, "GRK-03", boxOutbox)

	m, err := st.Send("GRK-03", "CLE-07", "drill-task", "task", "delivered, outbox broken", nil)
	if err != nil {
		t.Fatalf("Send = %v; the message is in the inbox, so a caller that retries on this error delivers it twice", err)
	}
	if got := messageCount(t, cfg.SpoolRoot, "CLE-07", boxInbox); got != 1 {
		t.Fatalf("CLE-07 inbox holds %d messages, want exactly 1", got)
	}
	w := warn.String()
	for _, want := range []string{"WARN", m.MsgID, "outbox", "do not resend"} {
		if !strings.Contains(w, want) {
			t.Fatalf("warning %q lacks %q", w, want)
		}
	}
}

func TestSend_Control_InboxFailIsStillAnError(t *testing.T) {
	cfg := newCfg(t)
	var warn bytes.Buffer
	st := New(cfg)
	st.warn = &warn
	blockBox(t, cfg.SpoolRoot, "CLE-07", boxInbox)

	if _, err := st.Send("GRK-03", "CLE-07", "drill-task", "task", "never delivered", nil); err == nil {
		t.Fatal("Send = nil with the inbox unwritable; a real delivery failure must exit non-zero")
	}
	if got := messageCount(t, cfg.SpoolRoot, "GRK-03", boxOutbox); got != 0 {
		t.Fatalf("GRK-03 outbox holds %d messages for an undelivered send, want 0", got)
	}
	if warn.Len() != 0 {
		t.Fatalf("an inbox failure is an error, not a warning; got warning %q", warn.String())
	}
}
