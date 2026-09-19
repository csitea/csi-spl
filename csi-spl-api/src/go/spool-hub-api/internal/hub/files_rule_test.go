package hub_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestFileRuleConcurrentChecks (027 T040 CONTROLS): the blob checks now run
// concurrently and must refuse exactly as the sequential loop did. A file id
// held only under ANOTHER tenant's prefix is missing_file; with several
// attachments the error names the first missing one in message order; all
// held is sent.
func TestFileRuleConcurrentChecks(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	blobs := blob.Dir{Root: e.blobs}
	put := func(tenant, body string) msg.Attachment {
		t.Helper()
		sum := sha256.Sum256([]byte(body))
		id := hex.EncodeToString(sum[:])
		key, _ := blob.Key(tenant, id)
		if err := blobs.Put(ctx, key, []byte(body)); err != nil {
			t.Fatal(err)
		}
		return msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id, Name: body, Bytes: int64(len(body))}
	}
	ghost := func(n string) msg.Attachment {
		id := strings.Repeat(n, 64)
		return msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id, Name: "ghost"}
	}
	mine1, mine2 := put(tid, "one"), put(tid, "two")
	theirs := put(other, "theirs")

	sess, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	send := func(files ...msg.Attachment) error {
		t.Helper()
		m, err := spool.New(a.cfg).Compose("GRK-03", "CLE-07", "", "note", "files", files)
		if err != nil {
			t.Fatal(err)
		}
		env, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
		if err != nil {
			t.Fatal(err)
		}
		_, err = sess.Send(ctx, env)
		return err
	}
	missing := func(what, wantID string, err error) {
		t.Helper()
		var he *hubclient.HubError
		if !errors.As(err, &he) || he.Token != "missing_file" || !strings.Contains(he.Detail, wantID) {
			t.Fatalf("%s: want missing_file naming %s, got %v", what, wantID[:8], err)
		}
	}

	if err := send(mine1, mine2); err != nil {
		t.Fatalf("both held: %v", err)
	}
	missing("another tenant's file", theirs.FileID, send(mine1, theirs))
	missing("first missing in order", ghost("a").FileID, send(mine1, ghost("a"), mine2, ghost("b")))
	missing("first attachment missing", ghost("c").FileID, send(ghost("c"), mine1))
}
