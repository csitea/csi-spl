package hub_test

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// a file_id is not a capability. box-a sends box-b a file; box-x
// knows its file_id (a log line, a removed channel member). Before: any
// upload token of the tenant DELETED it (204), and box-x re-attached the id
// to its own message, which made the blob readable to box-x through that
// message. Now both answer as for a file that does not exist, and the file is
// intact. CONTROL: box-b, which received it, re-attaches it in its reply.
func TestFileIDIsNotACapability(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	x := e.box(tid, "box-x", "AGY-09")
	for _, bx := range []*box{a, b, x} {
		e.pin(tid, bx)
	}
	ctx := context.Background()
	b.c.Sync(ctx) //nolint:errcheck
	a.c.Sync(ctx) //nolint:errcheck
	x.c.Sync(ctx) //nolint:errcheck
	src := filepath.Join(t.TempDir(), "hr.txt")
	os.WriteFile(src, []byte("salary figures"), 0o644) //nolint:errcheck
	att, err := files.PutFile(a.cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	send(t, a, "GRK-03", "CLE-07", "task", "see file", "box-b", att.FileID)
	b.c.Sync(ctx) //nolint:errcheck

	// delete by a box that may not read it: 404, and the file stays.
	req, _ := http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/files/"+att.FileID, nil)
	req.Header.Set("Authorization", "Bearer "+e.uploadToken(tid, x))
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("box-x deletes box-a's file: %d, want 404", resp.StatusCode)
	}
	if code, _ := e.getFile(tid, att.FileID, e.uploadToken(tid, b)); code != http.StatusOK {
		t.Fatalf("the file is gone after a refused delete: %d", code)
	}

	resend := func(bx *box, from, to, toBox string) error {
		t.Helper()
		cli, err := bx.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(cli)
		m, _ := spool.New(bx.cfg).Compose(from, to, "", "task", "have this",
			[]msg.Attachment{{Mode: "blob", Kind: "file", FileID: att.FileID, Name: "hr.txt"}})
		priv, _ := sign.LoadPrivate(bx.cfg.KeysDir, bx.id)
		env, _ := wire.NewEnvelope(priv, bx.id, toBox, m)
		_, err = cli.Send(ctx, env)
		return err
	}
	var he *hubclient.HubError
	if err := resend(x, "AGY-09", "GRK-03", "box-a"); !errors.As(err, &he) || he.Token != "missing_file" {
		t.Fatalf("box-x re-attaches a file_id it cannot read: %v, want missing_file", err)
	}
	if code, _ := e.getFile(tid, att.FileID, e.uploadToken(tid, x)); code != http.StatusNotFound {
		t.Fatalf("box-x reads the file after the refused re-attach: %d", code)
	}
	if err := resend(b, "CLE-07", "GRK-03", "box-a"); err != nil {
		t.Fatalf("CONTROL: box-b re-attaches the file it received: %v", err)
	}
}
