package hubclient

// Spec 067 3.3: a DM's ref_task_id claim (`spool send --ref`) reaches the hub
// on the SEND FRAME on every path a send takes - the dial, the sidecar's
// submit socket, a later flush of the pending queue - like typed_by, and never
// inside the signed envelope (a box older than the key refuses it).

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func TestRefTaskRidesTheFrameOnEveryPath(t *testing.T) {
	const topic = "0b6f0c55-8a1f-4d5e-9a4c-2f0d4c6e7a10"
	h := newFakeHub(t)
	c := hubClient(t, h)
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	m := compose(t, c, "about a topic")
	env, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	cl := Claims{RefTaskID: topic}

	// (a) the dial path.
	p1, err := c.writePending(m, env, cl)
	if err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(p1 + refTaskSuffix); err != nil || strings.TrimSpace(string(b)) != topic {
		t.Fatalf("pending ref_task_id file: %q %v", b, err)
	}
	if d, err := c.sendNow(ctx, env, m, p1, cl); err != nil || d != wire.DeliverySent {
		t.Fatalf("dial: %q %v", d, err)
	}
	if _, err := os.Stat(p1 + refTaskSuffix); !os.IsNotExist(err) {
		t.Fatalf("a delivered send left its ref_task_id file behind: %v", err)
	}

	// (b) the submit socket.
	stop := sidecarUp(t, c)
	p2, err := c.writePending(m, env, cl)
	if err != nil {
		t.Fatal(err)
	}
	if d, err := c.sendNow(ctx, env, m, p2, cl); err != nil || d != wire.DeliverySent {
		t.Fatalf("submit: %q %v", d, err)
	}
	stop()

	// (c) a queued send: only the pending files exist, the flush reads the claim.
	if _, err := c.writePending(m, env, cl); err != nil {
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

	// (d) CONTROL: a plain send carries no claim and writes no claim file.
	p4, _ := c.writePending(m, env, Claims{})
	if _, err := os.Stat(p4 + refTaskSuffix); !os.IsNotExist(err) {
		t.Fatalf("an unclaimed send wrote a ref_task_id file: %v", err)
	}
	if _, err := c.sendNow(ctx, env, m, p4, Claims{}); err != nil {
		t.Fatal(err)
	}

	got, envs := h.refTasks(), h.sent()
	want := []string{topic, topic, topic, ""}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("ref_task_id per send = %q, want %q", got, want)
	}
	for i, e := range envs {
		if string(e) != string(envs[len(envs)-1]) {
			t.Fatalf("send %d: the claim changed the signed envelope bytes", i)
		}
		if strings.Contains(string(e), "ref_task_id") || strings.Contains(string(e), topic) {
			t.Fatalf("send %d: the claim leaked into the envelope: %s", i, e)
		}
	}
}

// A refused send moves the pending envelope AND its ref_task_id file to
// rejected/, so neither is retried by a later flush.
func TestRefTaskRefusalRejectsBothFiles(t *testing.T) {
	h := newFakeHub(t)
	h.refuse = &wire.Frame{Type: wire.TError, Error: "bad_request", Status: 400}
	c := hubClient(t, h)
	priv, _ := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	m := compose(t, c, "refused")
	env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
	cl := Claims{RefTaskID: "0b6f0c55-8a1f-4d5e-9a4c-2f0d4c6e7a10"}
	p, err := c.writePending(m, env, cl)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.sendNow(context.Background(), env, m, p, cl); err == nil {
		t.Fatal("want the refusal")
	}
	if _, err := os.Stat(p + refTaskSuffix); !os.IsNotExist(err) {
		t.Fatalf("ref_task_id file still pending: %v", err)
	}
	rej := c.rejectedDir() + "/" + p[strings.LastIndex(p, "/")+1:]
	if _, err := os.Stat(rej + refTaskSuffix); err != nil {
		t.Fatalf("ref_task_id file not moved to rejected/: %v", err)
	}
}
