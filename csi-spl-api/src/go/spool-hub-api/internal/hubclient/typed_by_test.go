package hubclient

// specs/036 FR-009: a terminal-typed line's typed_by claim reaches the hub on
// the SEND FRAME, whichever path the send takes (the dial, the sidecar's
// submit socket, a later flush of the pending queue), and never inside the
// signed envelope - which stays byte-identical to an unclaimed send.

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func TestTypedByRidesTheFrameOnEveryPath(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	m := compose(t, c, "typed at the terminal")
	env, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	// (a) the dial path.
	p1, err := c.writePending(m, env, "HUM-7")
	if err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(p1 + typedBySuffix); err != nil || strings.TrimSpace(string(b)) != "HUM-7" {
		t.Fatalf("pending typed_by file: %q %v", b, err)
	}
	if d, err := c.sendNow(ctx, env, m, p1, "HUM-7"); err != nil || d != wire.DeliverySent {
		t.Fatalf("dial: %q %v", d, err)
	}
	if _, err := os.Stat(p1 + typedBySuffix); !os.IsNotExist(err) {
		t.Fatalf("a delivered send left its typed_by file behind: %v", err)
	}

	// (b) the submit socket.
	stop := sidecarUp(t, c)
	p2, err := c.writePending(m, env, "HUM-7")
	if err != nil {
		t.Fatal(err)
	}
	if d, err := c.sendNow(ctx, env, m, p2, "HUM-7"); err != nil || d != wire.DeliverySent {
		t.Fatalf("submit: %q %v", d, err)
	}
	stop()

	// (c) a queued send: only the pending files exist, the flush reads the claim.
	if _, err := c.writePending(m, env, "HUM-7"); err != nil {
		t.Fatal(err)
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := sess.Flush(ctx); err != nil || n != 1 {
		t.Fatalf("flush: n=%d err=%v", n, err)
	}
	sess.Close()

	// (d) CONTROL: a plain send carries no claim.
	p4, _ := c.writePending(m, env, "")
	if _, err := os.Stat(p4 + typedBySuffix); !os.IsNotExist(err) {
		t.Fatalf("an unclaimed send wrote a typed_by file: %v", err)
	}
	if _, err := c.sendNow(ctx, env, m, p4, ""); err != nil {
		t.Fatal(err)
	}

	got, envs := h.typedBy(), h.sent()
	want := []string{"HUM-7", "HUM-7", "HUM-7", ""}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("typed_by per send = %q, want %q", got, want)
	}
	for i, e := range envs {
		if string(e) != string(envs[len(envs)-1]) {
			t.Fatalf("send %d: the claim changed the signed envelope bytes", i)
		}
		if strings.Contains(string(e), "typed_by") || strings.Contains(string(e), "HUM-7") {
			t.Fatalf("send %d: the claim leaked into the envelope: %s", i, e)
		}
	}
}

// A refused claim (typed_by_not_bound is a 4xx) moves the pending envelope AND
// its typed_by file to rejected/, so neither is retried by a later flush.
func TestTypedByRefusalRejectsBothFiles(t *testing.T) {
	h := newFakeHub(t)
	h.refuse = &wire.Frame{Type: wire.TError, Error: "typed_by_not_bound", Status: 403}
	c := hubClient(t, h)
	priv, _ := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	m := compose(t, c, "not bound")
	env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
	p, err := c.writePending(m, env, "HUM-7")
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.sendNow(context.Background(), env, m, p, "HUM-7")
	if err == nil || !strings.Contains(err.Error(), "typed_by_not_bound") {
		t.Fatalf("want typed_by_not_bound, got %v", err)
	}
	if left, _ := c.Pending(); len(left) != 0 {
		t.Fatalf("pending still holds %v", left)
	}
	for _, f := range []string{p, p + typedBySuffix} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Fatalf("%s still pending", f)
		}
	}
	rej := c.rejectedDir() + "/" + p[strings.LastIndex(p, "/")+1:]
	if _, err := os.Stat(rej + typedBySuffix); err != nil {
		t.Fatalf("typed_by file not moved to rejected/: %v", err)
	}
}
