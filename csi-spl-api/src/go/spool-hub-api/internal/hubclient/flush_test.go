package hubclient

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func testClient(t *testing.T) *Client {
	t.Helper()
	root := t.TempDir()
	cfg := &config.Config{
		SpoolRoot: filepath.Join(root, "spool"),
		KeysDir:   filepath.Join(root, "keys"),
		PinsDir:   filepath.Join(root, "spool", "pins"),
		BoxID:     "box-a",
	}
	if _, err := sign.GenerateKey(cfg.KeysDir, "box-a", false); err != nil {
		t.Fatal(err)
	}
	return New(cfg)
}

func TestPendingOldestFirstAndReject(t *testing.T) {
	c := testClient(t)
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	st := spool.New(c.Cfg)
	m1, err := st.Compose("GRK-03", "CLE-07", "", "task", "first", nil)
	if err != nil {
		t.Fatal(err)
	}
	m1.TS = "2026-09-18T10:00:00Z"
	m2, err := st.Compose("GRK-03", "CLE-07", "", "task", "second", nil)
	if err != nil {
		t.Fatal(err)
	}
	m2.TS = "2026-09-18T10:00:01Z"
	env1, err := wire.NewEnvelope(priv, "box-a", "box-b", m1)
	if err != nil {
		t.Fatal(err)
	}
	env2, err := wire.NewEnvelope(priv, "box-a", "box-b", m2)
	if err != nil {
		t.Fatal(err)
	}
	p1, err := c.writePending(m1, env1, "")
	if err != nil {
		t.Fatal(err)
	}
	p2, err := c.writePending(m2, env2, "")
	if err != nil {
		t.Fatal(err)
	}
	list, err := c.Pending()
	if err != nil || len(list) != 2 || list[0] != p1 || list[1] != p2 {
		t.Fatalf("oldest first: %v %v", list, err)
	}
	raw, err := os.ReadFile(p1)
	if err != nil {
		t.Fatal(err)
	}
	want, err := env1.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != string(want) {
		t.Fatal("pending file is not the signed envelope bytes")
	}
	c.reject(p1)
	left, err := c.Pending()
	if err != nil || len(left) != 1 || left[0] != p2 {
		t.Fatalf("after reject pending=%v err=%v", left, err)
	}
	rej := filepath.Join(c.rejectedDir(), filepath.Base(p1))
	if _, err := os.Stat(rej); err != nil {
		t.Fatalf("rejected file missing: %v", err)
	}
	if _, err := os.Stat(p1); !os.IsNotExist(err) {
		t.Fatal("rejected pending file still in pending/")
	}
}
