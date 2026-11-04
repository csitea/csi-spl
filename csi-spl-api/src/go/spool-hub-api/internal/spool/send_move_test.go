package spool

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// smStore is a Store on its own t.TempDir() spool root with each id's
// mailbox in place, so KnownLocal accepts it.
func smStore(t *testing.T, ids ...string) *Store {
	t.Helper()
	cfg := newCfg(t)
	for _, id := range ids {
		if err := os.MkdirAll(filepath.Join(cfg.SpoolRoot, id, "inbox"), 0o775); err != nil {
			t.Fatal(err)
		}
	}
	return New(cfg)
}

// smWrite writes body to a new file under dir and returns its path.
func smWrite(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o664); err != nil {
		t.Fatal(err)
	}
	return p
}

// A non-empty accepts that is not a uuid is refused by m.Validate() after it
// is set, before anything is written; a uuid rides the message.
func TestSendKnownAcceptingValidatesAccepts(t *testing.T) {
	st := smStore(t, "c-004")
	if _, err := st.SendKnownAccepting("c-005", "c-004", "task-1", "note", "ok", "not-a-uuid", nil); err == nil ||
		!strings.Contains(err.Error(), `accepts "not-a-uuid" is not a uuid`) {
		t.Fatalf("invalid accepts: %v, want the accepts validation error", err)
	}
	if ins, _ := os.ReadDir(st.dir("c-004", "inbox")); len(ins) != 0 {
		t.Fatalf("a refused message reached the inbox: %d file(s)", len(ins))
	}
	const ok = "0b6e8f2a-1c3d-4e5f-8a9b-0c1d2e3f4a5b"
	m, err := st.SendKnownAccepting("c-005", "c-004", "task-1", "note", "ok", ok, nil)
	if err != nil || m.Accepts != ok {
		t.Fatalf("valid accepts: %v, %+v", err, m)
	}
}

// A retired-in-quarantine recipient composes the message before it bounces:
// a bad kind is that compose error, and no reject is written.
func TestSendKnownAcceptingRetiredComposeError(t *testing.T) {
	st := smStore(t)
	retire(t, st.cfg.SpoolRoot, time.Hour, "c-004")
	_, err := st.SendKnownAccepting("c-005", "c-004", "task-1", "no-such-kind", "x", "", nil)
	if err == nil || errors.Is(err, ErrRetiredRecipient) || errors.Is(err, ErrUnknownRecipient) {
		t.Fatalf("bad kind to a retired id: %v, want the compose error", err)
	}
	if _, serr := os.Stat(filepath.Join(st.cfg.SpoolRoot, "c-005")); !os.IsNotExist(serr) {
		t.Fatal("a compose error still wrote a reject into the sender's inbox")
	}
}

// The loser of a move race (src gone) gets an error wrapping fs.ErrNotExist.
func TestAtomicMoveMissingSrc(t *testing.T) {
	dir := t.TempDir()
	err := atomicMove(filepath.Join(dir, "gone"), filepath.Join(dir, "out", "dst"))
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing src: %v, want fs.ErrNotExist", err)
	}
}

// dst's parent cannot be made (a file is in its way): the MkdirAll error.
func TestAtomicMoveBlockedParent(t *testing.T) {
	dir := t.TempDir()
	src := smWrite(t, dir, "src", "x")
	block := smWrite(t, dir, "block", "")
	if err := atomicMove(src, filepath.Join(block, "dst")); err == nil {
		t.Fatal("dst under a file: nil, want the MkdirAll error")
	}
	if _, err := os.Stat(src); err != nil {
		t.Fatalf("a failed move lost src: %v", err)
	}
}

// rename(2) refuses a non-empty dir as dst, so the copy fallback runs and its
// writeFileAtomic onto that dir fails too; src stays.
func TestAtomicMoveFallbackBlockedTarget(t *testing.T) {
	dir := t.TempDir()
	src := smWrite(t, dir, "src", "payload")
	dst := filepath.Join(dir, "dst")
	if err := os.MkdirAll(filepath.Join(dst, "keep"), 0o775); err != nil {
		t.Fatal(err)
	}
	if err := atomicMove(src, dst); err == nil {
		t.Fatal("dst is a non-empty dir: nil, want the fallback's write error")
	}
	if b, err := os.ReadFile(src); err != nil || string(b) != "payload" {
		t.Fatalf("a failed move changed src: %q, %v", b, err)
	}
}

// src's dir is read-only: rename fails, the copy lands at dst, and the final
// remove (the claim) fails and is returned.
func TestAtomicMoveFallbackRemoveFails(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores the read-only dir this case needs")
	}
	dir := t.TempDir()
	ro := filepath.Join(dir, "ro")
	if err := os.MkdirAll(ro, 0o775); err != nil {
		t.Fatal(err)
	}
	src := smWrite(t, ro, "src", "payload")
	if err := os.Chmod(ro, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(ro, 0o775) })
	dst := filepath.Join(dir, "out", "dst")
	if err := atomicMove(src, dst); err == nil {
		t.Fatal("read-only src dir: nil, want the remove error")
	}
	if b, err := os.ReadFile(dst); err != nil || string(b) != "payload" {
		t.Fatalf("the fallback copy: %q, %v", b, err)
	}
}

// A path that cannot be stat'ed falls back to now, in RFC3339 UTC.
func TestFileTimeOrNowMissingPath(t *testing.T) {
	before := time.Now().UTC().Truncate(time.Second)
	got := fileTimeOrNow(filepath.Join(t.TempDir(), "gone"))
	ts, err := time.Parse(time.RFC3339, got)
	if err != nil {
		t.Fatalf("%q is not RFC3339: %v", got, err)
	}
	if ts.Before(before) || ts.After(time.Now().UTC().Add(time.Second)) {
		t.Fatalf("%s is not near now", got)
	}
	if !strings.HasSuffix(got, "Z") {
		t.Fatalf("%q is not UTC", got)
	}
}

// BounceRetired is nil for an id that is not an agent id, and for a known
// local recipient even inside a quarantine: the caller sends as before.
func TestBounceRetiredNilForKnownOrInvalid(t *testing.T) {
	st := smStore(t, "c-004")
	retire(t, st.cfg.SpoolRoot, time.Hour, "c-004")
	for _, to := range []string{"c-004", "not an id"} {
		m := &msg.Message{MsgID: "m1", TaskID: "t1", From: "c-005", To: to, Kind: "note"}
		if err := st.BounceRetired(m); err != nil {
			t.Fatalf("to %q: %v, want nil", to, err)
		}
	}
	if _, err := os.Stat(filepath.Join(st.cfg.SpoolRoot, "c-005")); !os.IsNotExist(err) {
		t.Fatal("a nil bounce wrote a reject")
	}
}

// The sender's mailbox cannot be made (a file holds its name): the bounce is
// still ErrRetiredRecipient and says the reject was not written.
func TestBounceRetiredRejectWriteFails(t *testing.T) {
	st := smStore(t)
	retire(t, st.cfg.SpoolRoot, time.Hour, "c-004")
	smWrite(t, st.cfg.SpoolRoot, "c-005", "")
	m := &msg.Message{MsgID: "m1", TaskID: "t1", From: "c-005@box", To: "c-004", Kind: "note"}
	err := st.BounceRetired(m)
	if !errors.Is(err, ErrRetiredRecipient) || !strings.Contains(err.Error(), "the reject to c-005 was not written") {
		t.Fatalf("blocked sender inbox: %v", err)
	}
}
