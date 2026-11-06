package hubclient

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
)

// wrLogged is testClient with its logger writing to a buffer the test reads.
func wrLogged(t *testing.T) (*Client, *bytes.Buffer) {
	t.Helper()
	c := testClient(t)
	var logs bytes.Buffer
	c.Log = zerolog.New(&logs)
	return c, &logs
}

// wrFile writes a regular file at path, so a directory cannot be made there.
func wrFile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestWriteAtomicParentIsAFile(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "plain")
	wrFile(t, parent)
	if err := writeAtomic(filepath.Join(parent, "sub", "a.json"), []byte("{}")); err == nil {
		t.Fatal("parent is a regular file: want the MkdirAll error, got nil")
	}
}

func TestWriteAtomicParentNotWritable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes a 0500 directory anyway")
	}
	dir := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) }) //nolint:errcheck
	if err := writeAtomic(filepath.Join(dir, "a.json"), []byte("{}")); err == nil {
		t.Fatal("parent is 0500: want the CreateTemp error, got nil")
	}
}

func TestWriteAtomicWritesAndLeavesNoTemp(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "sub")
	path := filepath.Join(dir, "a.json")
	if err := writeAtomic(path, []byte(`{"k":1}`)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != `{"k":1}` {
		t.Fatalf("want the bytes written, got %q %v", got, err)
	}
	left, err := filepath.Glob(filepath.Join(dir, ".tmp-*"))
	if err != nil || len(left) != 0 {
		t.Fatalf("want no .tmp-* left, got %v %v", left, err)
	}
}

func TestSaveRosterNilWritesEmptyObject(t *testing.T) {
	c, _ := wrLogged(t)
	c.saveRoster(nil)
	got, err := os.ReadFile(c.rosterPath())
	if err != nil || string(got) != "{}" {
		t.Fatalf("saveRoster(nil): want roster.json {}, got %q %v", got, err)
	}
}

func TestSaveRosterUnwritableLogsOnly(t *testing.T) {
	c, logs := wrLogged(t)
	wrFile(t, c.Cfg.HubDir())
	c.saveRoster(map[string][]string{"box-b": {"c-009"}})
	if s := logs.String(); !strings.Contains(s, "roster cache not written") {
		t.Fatalf("hub dir is a file: want the warn line, got %q", s)
	}
}

func TestDeskOutboxUnwritableLogsMsgID(t *testing.T) {
	c, logs := wrLogged(t)
	m, err := spool.New(c.Cfg).Compose("c-009", "c-010", "", "note", "re-routed", nil)
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(t.TempDir(), "root-file")
	wrFile(t, root)
	c.Cfg.SpoolRoot = root
	c.deskOutbox(m)
	s := logs.String()
	if !strings.Contains(s, "re-route: no outbox copy on the desk") || !strings.Contains(s, m.MsgID) {
		t.Fatalf("spool root is a file: want the warn line with msg %s, got %q", m.MsgID, s)
	}
}
