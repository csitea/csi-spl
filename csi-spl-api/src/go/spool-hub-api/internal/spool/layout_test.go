package spool

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// migrate puts root/<id> into the qualified layout the way
// do_spl_naming_migrate leaves it (specs/058 6.2): the dir at <id>@<box>, the
// compat symlink <id> -> <id>@<box>.
func migrate(t *testing.T, root, id, box string) {
	t.Helper()
	q := id + "@" + box
	if err := os.Rename(filepath.Join(root, id), filepath.Join(root, q)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(q, filepath.Join(root, id)); err != nil {
		t.Fatal(err)
	}
}

// oldScan is the roster scan before specs/058 6: a DIR named exactly a valid id.
func oldScan(root string) []string {
	ents, _ := os.ReadDir(root)
	out := []string{}
	for _, e := range ents {
		if e.IsDir() && msg.ValidID(e.Name()) {
			out = append(out, e.Name())
		}
	}
	return out
}

func TestScanAgentsReadsBothLayoutsOnce(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{"CLE-1", "CLE-2@box-desk", "CLE-5@sat", "agents", ".hub", "CLE-9@Bad_Box", "dispatch"} {
		if err := os.MkdirAll(filepath.Join(root, d, "inbox"), 0o775); err != nil {
			t.Fatal(err)
		}
	}
	// the compat link, a self-loop left by a killed migration, a stray file
	if err := os.Symlink("CLE-2@box-desk", filepath.Join(root, "CLE-2")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("CLE-3@box-desk", filepath.Join(root, "CLE-3@box-desk")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "CLE-4"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ScanAgents(root)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"CLE-1", "CLE-2", "CLE-5"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("ScanAgents = %v, want %v", got, want)
	}
	if got, _ := ScanAgents(filepath.Join(root, "missing")); len(got) != 0 {
		t.Fatalf("missing root: %v", got)
	}
}

// TestMigratedRootKeepsRosterAndMail: after the move every message written
// before it is still read by the bare id, a send by the bare id lands in the
// one dir, tail sees each message once, and the roster is unchanged. The
// control is the old scan: on the migrated root it sees an EMPTY roster,
// which is why the binary must be rolled before any dir moves (6.4 step 1).
func TestMigratedRootKeepsRosterAndMail(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	before, err := st.Send("CLE-1", "CLE-2", "t-mig", "note", "before", nil)
	if err != nil {
		t.Fatal(err)
	}
	ids0, _ := ScanAgents(cfg.SpoolRoot)
	migrate(t, cfg.SpoolRoot, "CLE-1", "box-desk")
	migrate(t, cfg.SpoolRoot, "CLE-2", "box-desk")

	if ids1, _ := ScanAgents(cfg.SpoolRoot); !reflect.DeepEqual(ids0, ids1) {
		t.Fatalf("roster changed by the move: %v -> %v", ids0, ids1)
	}
	if old := oldScan(cfg.SpoolRoot); len(old) != 0 {
		t.Fatalf("control: the old scan should read the migrated root as empty, got %v", old)
	}
	after, err := st.SendKnown("CLE-1", "CLE-2", "t-mig", "note", "after", nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := st.Recv("CLE-2", true)
	if err != nil || len(res.Messages) != 2 {
		t.Fatalf("recv after the move: %v, %+v", err, res)
	}
	got := map[string]bool{res.Messages[0].MsgID: true, res.Messages[1].MsgID: true}
	if !got[before.MsgID] || !got[after.MsgID] {
		t.Fatalf("lost a message: %v", got)
	}
	if fi, err := os.Lstat(filepath.Join(cfg.SpoolRoot, "CLE-2")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the bare name must still be the compat link, not a new dir: %v %v", fi, err)
	}
	tail, err := st.Tail("t-mig")
	if err != nil || len(tail) != 2 {
		t.Fatalf("tail: %v, %d msgs", err, len(tail))
	}
}

func TestQualifiedLayoutMakesNewMailboxes(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if _, err := st.Send("CLE-1", "CLE-2", "", "note", "bare", nil); err != nil {
		t.Fatal(err)
	}
	cfg.DirLayout, cfg.DeskBox = "qualified", "sat"
	if _, err := st.Send("CLE-1", "CLE-7", "", "note", "qualified", nil); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name string
		link bool
	}{{"CLE-7@sat", false}, {"CLE-7", true}, {"CLE-1", false}, {"CLE-2", false}} {
		fi, err := os.Lstat(filepath.Join(cfg.SpoolRoot, c.name))
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if isLink := fi.Mode()&os.ModeSymlink != 0; isLink != c.link {
			t.Fatalf("%s: symlink=%v, want %v", c.name, isLink, c.link)
		}
	}
	if _, err := os.Lstat(filepath.Join(cfg.SpoolRoot, "CLE-1@sat")); !os.IsNotExist(err) {
		t.Fatalf("an existing bare mailbox must not be re-laid: %v", err)
	}
	res, err := st.Recv("CLE-7", false)
	if err != nil || len(res.Messages) != 1 {
		t.Fatalf("recv: %v %+v", err, res)
	}
	if ids, _ := ScanAgents(cfg.SpoolRoot); !reflect.DeepEqual(ids, []string{"CLE-1", "CLE-2", "CLE-7"}) {
		t.Fatalf("ScanAgents = %v", ids)
	}
	// no valid box: the layout falls back to bare rather than "<id>@"
	cfg.DeskBox = ""
	if _, err := st.Send("CLE-1", "CLE-8", "", "note", "x", nil); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Lstat(filepath.Join(cfg.SpoolRoot, "CLE-8")); err != nil || !fi.IsDir() {
		t.Fatalf("CLE-8 should be a bare dir: %v %v", fi, err)
	}
}
