package hub_test

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ---- US2: files ------------------------------------------------------------------

func TestFilesRoundTripAndTenantIsolation(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if _, err := b.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	src := filepath.Join(t.TempDir(), "report.txt")
	os.WriteFile(src, []byte("the bytes"), 0o644) //nolint:errcheck
	att, err := files.PutFile(a.cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	out := send(t, a, "GRK-03", "CLE-07", "task", "see file", "", att.FileID)
	if out.Delivery != wire.DeliveryQueued {
		t.Fatalf("delivery %q", out.Delivery)
	}
	if ok, _ := (blob.Dir{Root: e.blobs}).Exists(ctx, "t/"+tid+"/files/"+att.FileID); !ok {
		t.Fatal("blob not at t/<tenant>/files/<sha256>")
	}
	if _, err := b.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "got.txt")
	if _, err := action.Get(b.cfg, att.FileID, dest, false); err != nil {
		t.Fatalf("get-file on box-b: %v", err)
	}
	if got, _ := os.ReadFile(dest); string(got) != "the bytes" {
		t.Fatalf("got %q", got)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, tid, out.TaskID)
	if strings.Contains(string(envs[0]), "the bytes") {
		t.Fatal("file bytes inside an envelope")
	}

	// Another tenant's URL cannot read it, even with that tenant's box token
	// (017 FR-SEC-002: a credential of the Host tenant, then tenant-scoped ids).
	ob := e.box(other, "box-o", "GRK-09")
	e.pin(other, ob)
	if code, _ := e.getFile(other, att.FileID, e.uploadToken(other, ob)); code != http.StatusNotFound {
		t.Fatalf("cross-tenant GET: %d", code)
	}
	var resp *http.Response
	// Anonymous PUT is refused.
	resp, _ = e.client.Post(e.url(tid)+"/v1/files", "application/octet-stream", strings.NewReader("x"))
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous PUT: %d", resp.StatusCode)
	}
	// A file_id the hub does not hold → missing_file (OQ-11 default).
	cli, _ := a.c.Dial(ctx, wire.RoleCLI)
	defer closeWait(cli)
	m, _ := spool.New(a.cfg).Compose("GRK-03", "CLE-07", "", "task", "ghost",
		[]msg.Attachment{{Mode: "blob", Kind: "file", FileID: strings.Repeat("ab", 32), Name: "ghost"}})
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
	var he *hubclient.HubError
	if _, err := cli.Send(ctx, env); !errors.As(err, &he) || he.Token != "missing_file" {
		t.Fatalf("missing file: %v", err)
	}
}
