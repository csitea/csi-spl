package hub_test

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ---- 006 T012/T013: quota 429, unpaid 402, recv in grace ---------------------

func TestUnpaidSendPin402RecvInGrace(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()

	src := filepath.Join(t.TempDir(), "note.txt")
	os.WriteFile(src, []byte("keep"), 0o644) //nolint:errcheck
	att, err := files.PutFile(a.cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	out := send(t, a, "GRK-03", "CLE-07", "task", "queued in grace", "box-b", att.FileID)
	if out.Delivery != wire.DeliveryQueued {
		t.Fatalf("delivery %q, want queued", out.Delivery)
	}

	if err := e.st.SetBillingStatus(ctx, tid, "grace"); err != nil {
		t.Fatal(err)
	}

	c := e.box(tid, "box-c", "AGY-01")
	code, eb := e.postPin(tid, root, "box-c", c.pub)
	if code != http.StatusPaymentRequired || eb.Error != "unpaid" {
		t.Fatalf("pin in grace: %d %+v", code, eb)
	}

	_, err = action.SendCtx(ctx, a.cfg, action.SendArgs{
		From: "GRK-03", To: "CLE-07", Kind: "note", Body: "blocked", ToBox: "box-b", Hub: a.c,
	})
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Token != "unpaid" || he.Status != http.StatusPaymentRequired {
		t.Fatalf("send in grace: %v", err)
	}

	r, err := b.c.Sync(ctx)
	if err != nil || r.Delivered != 1 {
		t.Fatalf("recv in grace: %+v %v", r, err)
	}
	got := inbox(t, b, "CLE-07")
	if len(got) != 1 || got[0].Body != "queued in grace" {
		t.Fatalf("inbox in grace: %+v", got)
	}

	if code, _ := e.getFile(tid, att.FileID, e.uploadToken(tid, a)); code != http.StatusOK {
		t.Fatalf("get-file in grace: %d", code)
	}

	sess, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatalf("hello in grace: %v", err)
	}
	defer closeWait(sess)
	if err := sess.UploadFile(ctx, att.FileID); err == nil {
		t.Fatal("PUT file in grace succeeded")
	} else if !errors.As(err, &he) || he.Token != "unpaid" {
		t.Fatalf("PUT file in grace: %v", err)
	}
}

func TestQuotaExceeded429(t *testing.T) {
	ctx := context.Background()

	t.Run("pins", func(t *testing.T) {
		e := newEnv(t, func(o *hub.Options) { o.QuotaPins = 1 })
		tid, root := e.tenant()
		a := e.box(tid, "box-a", "GRK-03")
		b := e.box(tid, "box-b", "CLE-07")
		code, _ := e.postPin(tid, root, "box-a", a.pub)
		if code != http.StatusOK {
			t.Fatalf("first pin: %d", code)
		}
		code, eb := e.postPin(tid, root, "box-b", b.pub)
		if code != http.StatusTooManyRequests || eb.Error != "quota" {
			t.Fatalf("second pin: %d %+v", code, eb)
		}
		code, _ = e.postPin(tid, root, "box-a", a.pub)
		if code != http.StatusOK {
			t.Fatalf("re-pin at cap: %d", code)
		}
	})

	t.Run("messages", func(t *testing.T) {
		e := newEnv(t, func(o *hub.Options) { o.QuotaMessagesPerMonth = 1 })
		tid, _ := e.tenant()
		a := e.box(tid, "box-a", "GRK-03")
		b := e.box(tid, "box-b", "CLE-07")
		e.pin(tid, a)
		e.pin(tid, b)
		first := send(t, a, "GRK-03", "CLE-07", "task", "one", "box-b")
		if first.Delivery != wire.DeliveryQueued {
			t.Fatalf("first send: %q", first.Delivery)
		}
		_, err := action.SendCtx(ctx, a.cfg, action.SendArgs{
			From: "GRK-03", To: "CLE-07", Kind: "note", Body: "two", ToBox: "box-b", Hub: a.c,
		})
		var he *hubclient.HubError
		if !errors.As(err, &he) || he.Token != "quota" || he.Status != http.StatusTooManyRequests {
			t.Fatalf("second send: %v", err)
		}
		r, err := b.c.Sync(ctx)
		if err != nil || r.Delivered != 1 {
			t.Fatalf("recv not gated by quota: %+v %v", r, err)
		}
	})

	t.Run("files", func(t *testing.T) {
		e := newEnv(t, func(o *hub.Options) { o.QuotaFileBytes = 4 })
		tid, _ := e.tenant()
		a := e.box(tid, "box-a", "GRK-03")
		e.pin(tid, a)
		sess, err := a.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(sess)
		big := filepath.Join(t.TempDir(), "big.txt")
		os.WriteFile(big, []byte("hello"), 0o644) //nolint:errcheck
		att, err := files.PutFile(a.cfg.FilesDir(), big)
		if err != nil {
			t.Fatal(err)
		}
		var he *hubclient.HubError
		if err := sess.UploadFile(ctx, att.FileID); !errors.As(err, &he) || he.Token != "quota" {
			t.Fatalf("over-quota PUT: %v", err)
		}
		small := filepath.Join(t.TempDir(), "small.txt")
		os.WriteFile(small, []byte("hi"), 0o644) //nolint:errcheck
		okAtt, err := files.PutFile(a.cfg.FilesDir(), small)
		if err != nil {
			t.Fatal(err)
		}
		if err := sess.UploadFile(ctx, okAtt.FileID); err != nil {
			t.Fatalf("under-quota PUT: %v", err)
		}
		if code, _ := e.getFile(tid, okAtt.FileID, e.uploadToken(tid, a)); code != http.StatusOK {
			t.Fatalf("GET after quota PUT: %d", code)
		}
	})
}
