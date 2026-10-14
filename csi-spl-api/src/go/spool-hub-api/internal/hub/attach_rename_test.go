package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-1808 (owner HUM-10 t1 4f98d07c msg f5564d9f "Go"): before SPL-1776 a
// blob attached by id was named by its own sha256, and the WUI offered it as
// a nameless download. The box that sent such a message names those files
// (`spool attach-rename`): re-signed with its own key, names only, no new
// revision. Every refusal below is a control: drop its guard in box_edit.go
// (renamesHashNames, plainFileName) and that case turns red; on master the
// verb does not exist.

const pngBytes = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"

// renameRig: box-a (CLE-07) sent HUM-1 one DM with three files: a png and an
// unknown binary attached by id (named by their sha, as before SPL-1776) and
// notes.txt attached under its own name.
func renameRig(t *testing.T) (e *env, tid string, a, b *box, sent action.SendResult, png, bin string, watch func(string) map[string]any) {
	t.Helper()
	e = followEnv(t)
	tid, _ = e.tenant()
	ctx := context.Background()
	a = e.box(tid, "box-a", "CLE-07")
	b = e.box(tid, "box-b", "CLE-08")
	e.pin(tid, a)
	e.pin(tid, b)
	dir := t.TempDir()
	put := func(name, data string) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(data), 0o644) //nolint:errcheck
		att, err := files.PutFile(a.cfg.FilesDir(), p)
		if err != nil {
			t.Fatal(err)
		}
		return att.FileID
	}
	png, bin = put("shot", pngBytes), put("blob", "\x00\x01\x02\x03\xfe\xff")
	notes := filepath.Join(dir, "notes.txt")
	os.WriteFile(notes, []byte("plain notes\n"), 0o644) //nolint:errcheck
	var err error
	sent, err = action.SendCtx(ctx, a.cfg, action.SendArgs{From: "CLE-07", To: "HUM-1", ToBox: hub.WUIBox,
		Kind: "note", Body: "see the screenshot", FileIDs: []string{png, bin}, PutFiles: []string{notes}, Hub: a.c})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	c := dialMember(t, e, tid, "HUM-1", "HUM-1")
	wsjson.Write(ctx, c, map[string]string{"type": "subscribe", "task_id": sent.TaskID}) //nolint:errcheck
	readType(t, c, "subscribed")
	return e, tid, a, b, sent, png, bin, func(want string) map[string]any { return readType(t, c, want) }
}

func storedFiles(t *testing.T, e *env, tid, msgID string) []msg.Attachment {
	t.Helper()
	m, err := storedEnvelope(t, e, tid, msgID).Inner()
	if err != nil {
		t.Fatal(err)
	}
	return m.Files
}

func TestAttachRenameNamesHashNamedFiles(t *testing.T) {
	e, tid, a, _, sent, png, bin, watch := renameRig(t)
	ctx := context.Background()
	before := storedFiles(t, e, tid, sent.MsgID)
	if len(before) != 3 || before[0].Name != png || before[1].Name != bin || before[2].Name != "notes.txt" {
		t.Fatalf("rig: stored files %+v", before)
	}
	// The box no longer holds the png: the rename fetches it from the hub.
	if err := os.Remove(filepath.Join(a.cfg.FilesDir(), png)); err != nil {
		t.Fatal(err)
	}

	dry, err := action.AttachRename(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-07", Hub: a.c}, true)
	if err != nil {
		t.Fatalf("dry run: %v", err)
	}
	if dry.Applied || dry.Renamed != 1 || dry.Unknown != 1 || len(dry.Files) != 2 ||
		dry.Files[0].To != "file-"+png[:12]+".png" || dry.Files[1].To != "" {
		t.Fatalf("dry run result %+v", dry)
	}
	if got := storedFiles(t, e, tid, sent.MsgID); got[0].Name != png {
		t.Fatalf("the dry run renamed: %+v", got)
	}

	r, err := action.AttachRename(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-07", Hub: a.c}, false)
	if err != nil {
		t.Fatalf("rename: %v", err)
	}
	if !r.Applied || r.Renamed != 1 || r.Unknown != 1 || r.TaskID != sent.TaskID {
		t.Fatalf("rename result %+v", r)
	}
	got := storedFiles(t, e, tid, sent.MsgID)
	want := []msg.Attachment{before[0], before[1], before[2]}
	want[0].Name = "file-" + png[:12] + ".png"
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("file %d: stored %+v, want %+v (names only may change)", i, got[i], want[i])
		}
	}
	// Re-signed by box-a, verifies against its pin; body, edit stamps and
	// the register untouched: a repair is not a revision.
	env := storedEnvelope(t, e, tid, sent.MsgID)
	raw, _ := base64.StdEncoding.DecodeString(a.pub)
	if err := env.Verify(ed25519.PublicKey(raw)); err != nil || env.FromBox != "box-a" {
		t.Fatalf("stored envelope does not verify against box-a: %v", err)
	}
	after, err := e.st.GetEditable(ctx, tid, sent.MsgID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if after.Body != "see the screenshot" || after.Revision != 0 || after.EditedBy != "" || after.EnvSig != env.Sig {
		t.Fatalf("stored after rename: body %q rev %d by %q sig-match %v", after.Body, after.Revision, after.EditedBy, after.EnvSig == env.Sig)
	}
	if !strings.Contains(string(after.Msg), want[0].Name) {
		t.Fatalf("msg column keeps the old name: %s", after.Msg)
	}
	if revs := revisions(t, e, tid, sent.MsgID); len(revs) != 0 {
		t.Fatalf("the rename wrote the register: %+v", revs)
	}
	if f := watch("message_edited"); f["msg_id"] != sent.MsgID {
		t.Fatalf("browser frame %v", f)
	}
	// Idempotent: a second run finds nothing left to name.
	if r, err := action.AttachRename(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, Hub: a.c}, false); err != nil || r.Applied || r.Renamed != 0 || r.Unknown != 1 {
		t.Fatalf("second run: %+v %v", r, err)
	}
}

func TestAttachRenameRefusals(t *testing.T) {
	e, tid, a, b, sent, png, _, _ := renameRig(t)
	ctx := context.Background()
	if _, err := action.AttachRename(ctx, b.cfg, action.EditArgs{MsgID: sent.MsgID, Hub: b.c}, false); hubToken(err) != "not_author" {
		t.Fatalf("other box: %v (want not_author)", err)
	}
	if _, err := action.AttachRename(ctx, a.cfg, action.EditArgs{MsgID: sent.MsgID, As: "CLE-99", Hub: a.c}, false); err == nil {
		t.Fatal("a wrong --as went through")
	}
	sess, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sess)
	old, err := sess.EditFetch(ctx, sent.MsgID)
	if err != nil {
		t.Fatal(err)
	}
	priv, err := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name string
		mut  func(m *msg.Message)
	}{
		{"rename a file that has a name", func(m *msg.Message) { m.Files[2].Name = "other.txt" }},
		{"rename and new body", func(m *msg.Message) { m.Files[0].Name = "shot.png"; m.Body = "changed" }},
		{"a path for a name", func(m *msg.Message) { m.Files[0].Name = "../shot.png" }},
		{"a dot file", func(m *msg.Message) { m.Files[0].Name = ".png" }},
		{"another sha for a name", func(m *msg.Message) { m.Files[0].Name = strings.Repeat("ab", 32) }},
		{"new file_id", func(m *msg.Message) {
			m.Files[0].Name = "shot.png"
			m.Files[0].FileID = strings.Repeat("cd", 32)
			m.Files[0].SHA256 = m.Files[0].FileID
		}},
		{"new bytes", func(m *msg.Message) { m.Files[0].Name = "shot.png"; m.Files[0].Bytes++ }},
		{"a file dropped", func(m *msg.Message) { m.Files = m.Files[:2] }},
	} {
		m, _ := old.Inner()
		c.mut(m)
		env, err := wire.NewEnvelopeIn(priv, "box-a", old.ToBox, old.Channel, old.ParentTaskID, m)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := sess.EditApply(ctx, sent.MsgID, env); hubToken(err) != "bad_edit" {
			t.Fatalf("%s: %v (want bad_edit)", c.name, err)
		}
		if got := storedFiles(t, e, tid, sent.MsgID); got[0].Name != png || got[2].Name != "notes.txt" || len(got) != 3 {
			t.Fatalf("%s changed the files: %+v", c.name, got)
		}
	}
	if got := storedBody(t, e, tid, sent.MsgID); got != "see the screenshot" {
		t.Fatalf("refusals changed the body: %q", got)
	}
}
