package spool

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// newCfg delegates to the shared testkit fixture (T004c).
func newCfg(t *testing.T) *config.Config { return testkit.NewConfig(t) }

func TestUS1_RoundTrip(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)

	sent, err := st.Send("GRK-03", "CLE-07", "", "task", "review this", nil)
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	res, err := st.Recv("CLE-07", false)
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if len(res.Messages) != 1 || res.Failed != 0 {
		t.Fatalf("want 1 msg 0 failed, got %d/%d", len(res.Messages), res.Failed)
	}
	if got := res.Messages[0]; got.MsgID != sent.MsgID || got.Body != "review this" || got.From != "GRK-03" {
		t.Fatalf("recv mismatch: %+v", got)
	}
	// A copy is in the sender's outbox.
	if outs, _ := os.ReadDir(st.dir("GRK-03", "outbox")); len(outs) != 1 {
		t.Fatalf("want 1 outbox copy, got %d", len(outs))
	}
}

func TestUS1_UnsignedNoKeyNoPin(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	// No keygen, no pin: local mode must still deliver (trust-modes section 2).
	if _, err := st.Send("AGY-09", "CLE-07", "", "note", "hi", nil); err != nil {
		t.Fatalf("unsigned send: %v", err)
	}
	entries, _ := os.ReadDir(st.dir("CLE-07", "inbox"))
	if len(entries) != 1 {
		t.Fatalf("want 1 inbox file, got %d", len(entries))
	}
	raw, _ := os.ReadFile(filepath.Join(st.dir("CLE-07", "inbox"), entries[0].Name()))
	if strings.Contains(string(raw), `"sig"`) {
		t.Fatalf("local v:1 must omit sig: %s", raw)
	}
	if _, err := os.Stat(cfg.KeysDir); !os.IsNotExist(err) {
		t.Fatalf("local send must not touch the keys dir (stat err %v)", err)
	}
	res, err := st.Recv("CLE-07", true)
	if err != nil || len(res.Messages) != 1 || res.Messages[0].From != "AGY-09" {
		t.Fatalf("unsigned recv: %v %+v", err, res)
	}
}

func TestUS1_BoxKeyDoesNotSignLocally(t *testing.T) {
	cfg := newCfg(t)
	testkit.KeygenPin(t, cfg, "box-a") // keys may exist for later hub use
	st := New(cfg)
	if _, err := st.Send("GRK-03", "CLE-07", "", "task", "x", nil); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(st.dir("CLE-07", "inbox"))
	raw, _ := os.ReadFile(filepath.Join(st.dir("CLE-07", "inbox"), entries[0].Name()))
	if strings.Contains(string(raw), `"sig"`) {
		t.Fatalf("a box key must not sign local mail: %s", raw)
	}
}

func TestUS1_PresentSigIsTolerated(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if _, err := st.Send("GRK-03", "CLE-07", "", "task", "old", nil); err != nil {
		t.Fatal(err)
	}
	// A file written by the earlier signed model: recv trusts the filesystem
	// and does not check a sig it has no key model for.
	inbox := st.dir("CLE-07", "inbox")
	entries, _ := os.ReadDir(inbox)
	p := filepath.Join(inbox, entries[0].Name())
	raw, _ := os.ReadFile(p)
	m, _ := msg.Parse(raw)
	m.Sig = "bm90LWEtcmVhbC1zaWc="
	signed, _ := msg.Marshal(m)
	os.WriteFile(p, signed, 0o664)
	res, err := st.Recv("CLE-07", false)
	if err != nil || len(res.Messages) != 1 {
		t.Fatalf("recv of a sig-bearing local file: %v len=%d", err, len(res.Messages))
	}
}

func TestUS1_MalformedFileSurfacesExit1(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if _, err := st.Send("GRK-03", "CLE-07", "", "task", "good", nil); err != nil {
		t.Fatal(err)
	}
	bad := filepath.Join(st.dir("CLE-07", "inbox"), "zz-bad.json")
	os.WriteFile(bad, []byte(`{"v":1,"not":"a message"}`), 0o664)

	res, err := st.Recv("CLE-07", true)
	if err == nil {
		t.Fatal("want an error for the malformed file")
	}
	if res.Failed != 1 || len(res.Messages) != 1 {
		t.Fatalf("want 1 good / 1 failed, got %d/%d", len(res.Messages), res.Failed)
	}
	if ExitCode(err) != 1 {
		t.Fatalf("malformed is not a refusal: want exit 1, got %d", ExitCode(err))
	}
	if _, err := os.Stat(bad); err != nil {
		t.Fatalf("malformed file must stay in the inbox: %v", err)
	}
}

func TestExitCode78OnlyForSignErrors(t *testing.T) {
	for _, err := range []error{sign.ErrVerify, sign.ErrUnpinned} {
		if ExitCode(err) != 78 {
			t.Errorf("%v: want 78, got %d", err, ExitCode(err))
		}
	}
	if ExitCode(errors.New("io")) != 1 {
		t.Error("other errors must map to 1")
	}
}

func TestUS1_DoubleAckDeliversOnce(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if _, err := st.Send("GRK-03", "CLE-07", "", "task", "once", nil); err != nil {
		t.Fatal(err)
	}
	res1, err := st.Recv("CLE-07", true)
	if err != nil || len(res1.Messages) != 1 {
		t.Fatalf("first ack recv: %v len=%d", err, len(res1.Messages))
	}
	res2, err := st.Recv("CLE-07", true)
	if err != nil || len(res2.Messages) != 0 {
		t.Fatalf("second recv should be empty: %v len=%d", err, len(res2.Messages))
	}
	if arch, _ := os.ReadDir(st.dir("CLE-07", "archive")); len(arch) != 1 {
		t.Fatalf("want 1 archived, got %d", len(arch))
	}
}

func TestUS2_BlobFileRoundTripAndDedupe(t *testing.T) {
	cfg := newCfg(t)
	src := filepath.Join(t.TempDir(), "patch.zip")
	os.WriteFile(src, []byte("hello-bytes"), 0o644)

	a, err := files.PutFile(cfg.FilesDir(), src)
	if err != nil {
		t.Fatalf("put-file: %v", err)
	}
	if a.Mode != "blob" || a.Kind != "file" || a.FileID == "" || a.SHA256 != a.FileID {
		t.Fatalf("bad attachment: %+v", a)
	}
	// Dedupe: same bytes → same id, one object.
	a2, _ := files.PutFile(cfg.FilesDir(), src)
	if a2.FileID != a.FileID {
		t.Fatalf("dedupe failed: %s != %s", a2.FileID, a.FileID)
	}
	objs, _ := os.ReadDir(cfg.FilesDir())
	if len(objs) != 1 {
		t.Fatalf("want 1 blob object, got %d", len(objs))
	}
	// Get and verify.
	dest := filepath.Join(t.TempDir(), "out.zip")
	if err := files.GetFile(cfg.FilesDir(), a.FileID, dest); err != nil {
		t.Fatalf("get-file: %v", err)
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "hello-bytes" {
		t.Fatalf("content mismatch: %q", got)
	}
	// Absent id fails cleanly.
	if err := files.GetFile(cfg.FilesDir(), "deadbeef", filepath.Join(t.TempDir(), "x")); err == nil {
		t.Fatal("expected error for absent file_id")
	}
}

func TestUS2_BlobDirDeterministicRoundTrip(t *testing.T) {
	cfg := newCfg(t)
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "sub"), 0o755)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("A"), 0o644)
	os.WriteFile(filepath.Join(dir, "sub", "b.txt"), []byte("B"), 0o644)

	a, err := files.PutDir(cfg.FilesDir(), dir)
	if err != nil {
		t.Fatalf("put-dir: %v", err)
	}
	if a.Kind != "dir" || a.Mode != "blob" {
		t.Fatalf("bad dir attachment: %+v", a)
	}
	a2, _ := files.PutDir(cfg.FilesDir(), dir)
	if a2.FileID != a.FileID {
		t.Fatalf("dir tar not deterministic: %s != %s", a2.FileID, a.FileID)
	}
	dest := filepath.Join(t.TempDir(), "unpacked")
	if err := files.GetDir(cfg.FilesDir(), a.FileID, dest); err != nil {
		t.Fatalf("get-dir: %v", err)
	}
	b, _ := os.ReadFile(filepath.Join(dest, "sub", "b.txt"))
	if string(b) != "B" {
		t.Fatalf("unpacked content mismatch: %q", b)
	}
}

func TestUS2_PathRefFileResolves(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)

	src := filepath.Join(t.TempDir(), "report.txt")
	os.WriteFile(src, []byte("on-box-file"), 0o644)
	a, err := files.RefFile(src)
	if err != nil {
		t.Fatalf("ref-file: %v", err)
	}
	if a.Mode != "path" || a.Kind != "file" || a.Path == "" || a.SHA256 == "" {
		t.Fatalf("bad path attachment: %+v", a)
	}
	// Send carrying the path ref.
	if _, err := st.Send("GRK-03", "CLE-07", "", "result", "see attached path", []msg.Attachment{a}); err != nil {
		t.Fatalf("send with path ref: %v", err)
	}
	res, err := st.Recv("CLE-07", false)
	if err != nil || len(res.Messages) != 1 {
		t.Fatalf("recv: %v len=%d", err, len(res.Messages))
	}
	if len(res.Messages[0].Files) != 1 || res.Messages[0].Files[0].Path != a.Path {
		t.Fatalf("path attachment not carried: %+v", res.Messages[0].Files)
	}
	// Resolve copies the referenced file to dest and verifies its hash.
	dest := filepath.Join(t.TempDir(), "copy.txt")
	if err := files.Resolve(cfg.FilesDir(), res.Messages[0].Files[0], dest); err != nil {
		t.Fatalf("resolve path ref: %v", err)
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "on-box-file" {
		t.Fatalf("resolved content mismatch: %q", got)
	}
}

func TestUS2_PathRefDir(t *testing.T) {
	cfg := newCfg(t)
	dir := t.TempDir()
	a, err := files.RefDir(dir)
	if err != nil {
		t.Fatalf("ref-dir: %v", err)
	}
	if a.Mode != "path" || a.Kind != "dir" || a.Path == "" {
		t.Fatalf("bad dir path attachment: %+v", a)
	}
	// A path-dir is referenced in place: Resolve declines to copy.
	if err := files.Resolve(cfg.FilesDir(), a, filepath.Join(t.TempDir(), "x")); err == nil {
		t.Fatal("expected path-dir Resolve to decline (referenced in place)")
	}
}

func TestUS3_TailOrdered(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	m1, _ := st.Send("GRK-03", "CLE-07", "", "task", "first", nil)
	task := m1.TaskID
	if _, err := st.Send("CLE-07", "GRK-03", task, "result", "second", nil); err != nil {
		t.Fatal(err)
	}
	msgs, err := st.Tail(task)
	if err != nil {
		t.Fatalf("tail: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("want 2 messages on thread, got %d", len(msgs))
	}
	if msgs[0].TS > msgs[1].TS {
		t.Fatalf("tail not oldest-first")
	}
}

func TestLegacyMDBridge(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if err := st.ensureAgent("CLE-07"); err != nil {
		t.Fatal(err)
	}
	inbox := st.dir("CLE-07", "inbox")

	// Drop a legacy .md file with frontmatter and filename
	legacyContent := `---
from: CLE-387
to: CLE-07
sent: 20260903T084612Z
subject: done
task_id: 11111111-2222-3333-4444-555555555555
---

# Done report
Verification completed cleanly.
`
	legacyPath := filepath.Join(inbox, "20260903T084612Z--CLE-387--done.md")
	if err := os.WriteFile(legacyPath, []byte(legacyContent), 0o664); err != nil {
		t.Fatal(err)
	}

	// Recv without ack
	res, err := st.Recv("CLE-07", false)
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if len(res.Messages) != 1 || res.Failed != 0 {
		t.Fatalf("want 1 msg 0 failed, got %d/%d", len(res.Messages), res.Failed)
	}
	m := res.Messages[0]
	if m.From != "CLE-387" {
		t.Errorf("want from=CLE-387, got %s", m.From)
	}
	if m.To != "CLE-07" {
		t.Errorf("want to=CLE-07, got %s", m.To)
	}
	if m.Kind != "note" {
		t.Errorf("want kind=note, got %s", m.Kind)
	}
	if m.Sig != "" {
		t.Errorf("legacy bridge must be unsigned, got sig=%s", m.Sig)
	}
	if m.TaskID != "11111111-2222-3333-4444-555555555555" {
		t.Errorf("want task_id from frontmatter, got %s", m.TaskID)
	}
	if !strings.Contains(m.Body, "Verification completed cleanly.") {
		t.Errorf("expected body to contain report text, got %q", m.Body)
	}

	// Recv with ack moves to archive
	resAck, err := st.Recv("CLE-07", true)
	if err != nil {
		t.Fatalf("recv ack: %v", err)
	}
	if len(resAck.Messages) != 1 {
		t.Fatalf("expected 1 msg on ack, got %d", len(resAck.Messages))
	}

	// Subsequent recv is empty
	resEmpty, err := st.Recv("CLE-07", false)
	if err != nil {
		t.Fatalf("recv empty: %v", err)
	}
	if len(resEmpty.Messages) != 0 {
		t.Fatalf("expected 0 msgs after ack, got %d", len(resEmpty.Messages))
	}

	// File is in archive
	archived := filepath.Join(st.dir("CLE-07", "archive"), "20260903T084612Z--CLE-387--done.md")
	if _, err := os.Stat(archived); err != nil {
		t.Fatalf("expected file in archive, got: %v", err)
	}

	// Tail finds it
	tailMsgs, err := st.Tail("11111111-2222-3333-4444-555555555555")
	if err != nil {
		t.Fatalf("tail: %v", err)
	}
	if len(tailMsgs) != 1 {
		t.Fatalf("expected 1 msg in tail, got %d", len(tailMsgs))
	}
}
