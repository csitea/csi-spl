package hub_test

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-1808 option A (owner HUM-10, t1 b1af5f5c msg 8d4cf989): the hub names
// the sha-named files of a box whose pin is revoked, keeping the stored sig.
// Controls: no token is 401; a LIVE box's row is never touched (drop the
// GetPin guard in repairNames and box-b's row turns red); the dry run
// changes nothing. On master the route answers 404.
func TestOperatorAttachmentNamesRepairRevokedBoxOnly(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	b := e.box(tid, "box-b", "CLE-08")
	e.pin(tid, a)
	e.pin(tid, b)
	dir := t.TempDir()
	put := func(bx *box, name, data string) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(data), 0o644) //nolint:errcheck
		att, err := files.PutFile(bx.cfg.FilesDir(), p)
		if err != nil {
			t.Fatal(err)
		}
		return att.FileID
	}
	png := put(a, "a.png", pngBytes)
	bin := put(a, "a.bin", "\x00\x01\x02\x03\xfe\xff")
	pngB := put(b, "b.png", pngBytes+"b")
	old, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "CLE-07", To: "HUM-1", ToBox: hub.WUIBox,
		Kind: "note", Body: "old desk shot", FileIDs: []string{png, bin}, Hub: a.c})
	if err != nil {
		t.Fatal(err)
	}
	live, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "CLE-08", To: "HUM-1", ToBox: hub.WUIBox,
		Kind: "note", Body: "live box shot", FileIDs: []string{pngB}, Hub: b.c})
	if err != nil {
		t.Fatal(err)
	}
	if err := e.st.RevokePin(ctx, tid, "box-a", time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	sigBefore := storedEnvelope(t, e, tid, old.MsgID).Sig
	const path = "/v1/operator/attachment-names/repair"

	if code, _ := opCall(t, e, tid, "POST", path, "", map[string]any{"tenant": tid}); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	code, out := opCall(t, e, tid, "POST", path, "good", map[string]any{"tenant": tid, "dry_run": true})
	if code != 200 || out["found"] != float64(2) || out["live_box"] != float64(1) || out["messages"] != float64(1) ||
		out["renamed"] != float64(1) || out["unknown"] != float64(1) || out["more"] != false {
		t.Fatalf("dry run: %d %v", code, out)
	}
	if f := storedFiles(t, e, tid, old.MsgID); f[0].Name != png {
		t.Fatalf("the dry run renamed: %+v", f)
	}

	code, out = opCall(t, e, tid, "POST", path, "good", map[string]any{"tenant": tid})
	if code != 200 || out["messages"] != float64(1) || out["renamed"] != float64(1) || len(out["failed"].([]any)) != 0 {
		t.Fatalf("repair: %d %v", code, out)
	}
	f := storedFiles(t, e, tid, old.MsgID)
	if f[0].Name != "file-"+png[:12]+".png" || f[0].FileID != png || f[0].SHA256 != png || f[1].Name != bin {
		t.Fatalf("revoked box row after repair: %+v", f)
	}
	if lf := storedFiles(t, e, tid, live.MsgID); lf[0].Name != pngB {
		t.Fatalf("a live box's row was renamed by the hub: %+v", lf)
	}
	env := storedEnvelope(t, e, tid, old.MsgID)
	got, err := e.st.GetEditable(ctx, tid, old.MsgID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if env.Sig != sigBefore || got.EnvSig != sigBefore || got.Body != "old desk shot" || got.Revision != 0 {
		t.Fatalf("after repair: sig kept %v/%v body %q rev %d", env.Sig == sigBefore, got.EnvSig == sigBefore, got.Body, got.Revision)
	}
	if revs := revisions(t, e, tid, old.MsgID); len(revs) != 0 {
		t.Fatalf("the repair wrote the register: %+v", revs)
	}
	// Idempotent: the unknown file and the live box's row are what is left.
	code, out = opCall(t, e, tid, "POST", path, "good", map[string]any{"tenant": tid})
	if code != 200 || out["found"] != float64(2) || out["messages"] != float64(0) || out["unknown"] != float64(1) {
		t.Fatalf("second call: %d %v", code, out)
	}
}
