package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// TestWriteCompact is token/focus practice 09: `recv --compact` prints the
// header and the body a reader acts on, and none of the envelope fields.
func TestWriteCompact(t *testing.T) {
	msgs := []*msg.Message{
		{V: 1, MsgID: "m-1", TaskID: "t-1", TS: "2026-10-03T00:00:00Z", From: "c-002", To: "c-001",
			Kind: "result", Body: "done\nsha abc\n"},
		{V: 1, MsgID: "m-2", TaskID: "t-2", TS: "2026-10-03T00:00:01Z", From: "c-003", To: "c-001",
			Kind: "note", Body: "see files", Files: []msg.Attachment{{}, {}}},
	}
	var b bytes.Buffer
	writeCompact(&b, msgs)
	want := "c-002 result t-1\ndone\nsha abc\n\nc-003 note t-2 files=2\nsee files\n"
	if b.String() != want {
		t.Fatalf("compact:\n%q\nwant\n%q", b.String(), want)
	}
	for _, env := range []string{"m-1", "m-2", "2026-10-03", `"v"`} {
		if strings.Contains(b.String(), env) {
			t.Errorf("compact output carries the envelope field %q", env)
		}
	}
	b.Reset()
	writeCompact(&b, nil)
	if b.Len() != 0 {
		t.Errorf("empty inbox printed %q, want nothing", b.String())
	}
}
