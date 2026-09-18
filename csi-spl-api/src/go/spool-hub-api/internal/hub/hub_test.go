package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const domain = ".hub.test"

// env is one in-process hub on a random port. Every Host resolves to it, so
// tenant routing by Host works exactly as in production.
type env struct {
	t      *testing.T
	st     store.Store
	srv    *hub.Server
	ts     *httptest.Server
	client *http.Client
	blobs  string
}

func newStore(t *testing.T) store.Store {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		return store.NewMemory()
	}
	ctx := context.Background()
	pg, err := store.OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	dir := os.Getenv("SPOOL_TEST_SQL_DIR")
	if dir == "" {
		_, f, _, _ := runtime.Caller(0)
		dir = filepath.Join(filepath.Dir(f), "..", "..", "..", "..", "..", "..", "csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
	}
	if _, err := store.Migrate(ctx, pg.Pool(), dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	return pg
}

func newEnv(t *testing.T, mut ...func(*hub.Options)) *env {
	t.Helper()
	e := &env{t: t, st: newStore(t), blobs: t.TempDir()}
	o := hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test",
	}
	for _, m := range mut {
		m(&o)
	}
	srv, err := hub.New(o)
	if err != nil {
		t.Fatal(err)
	}
	e.srv = srv
	e.ts = httptest.NewServer(srv.Handler())
	t.Cleanup(func() { srv.Shutdown(); e.ts.Close() })
	addr := e.ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	e.client = &http.Client{Transport: tr}
	return e
}

// tenant creates a fresh tenant and returns its id and root private key.
func (e *env) tenant() (string, ed25519.PrivateKey) {
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	id := "t" + hex.EncodeToString(b)
	pub, priv, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
		e.t.Fatal(err)
	}
	return id, priv
}

func (e *env) url(tenant string) string { return "http://" + tenant + domain }

// box is one temp box: its own $SPOOL_ROOT, key dir and hub client.
type box struct {
	id  string
	cfg *config.Config
	c   *hubclient.Client
	pub string
}

func (e *env) box(tenant, id string, agents ...string) *box {
	e.t.Helper()
	root := e.t.TempDir()
	cfg := &config.Config{
		SpoolRoot: filepath.Join(root, "spool"), KeysDir: filepath.Join(root, "keys"),
		PinsDir: filepath.Join(root, "spool", "pins"), BoxID: id, HubURL: e.url(tenant),
		LogLevel: "error", LogFormat: "console",
	}
	pub, err := sign.GenerateKey(cfg.KeysDir, id, false)
	if err != nil {
		e.t.Fatal(err)
	}
	for _, a := range agents {
		os.MkdirAll(filepath.Join(cfg.SpoolRoot, a, "inbox"), 0o775) //nolint:errcheck
	}
	c := hubclient.New(cfg)
	c.HTTP = e.client
	c.ReadyTimeout = 5 * time.Second
	return &box{id: id, cfg: cfg, c: c, pub: pub}
}

func (e *env) pin(tenant string, b *box) {
	e.t.Helper()
	raw, _ := base64.StdEncoding.DecodeString(b.pub)
	if err := e.st.PutPin(context.Background(), tenant, b.id, ed25519.PublicKey(raw), false, time.Now()); err != nil {
		e.t.Fatal(err)
	}
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func send(t *testing.T, b *box, from, to, kind, body, toBox string, fileIDs ...string) action.SendResult {
	t.Helper()
	out, err := action.SendCtx(context.Background(), b.cfg, action.SendArgs{
		From: from, To: to, Kind: kind, Body: body, ToBox: toBox, FileIDs: fileIDs, Hub: b.c,
	})
	if err != nil {
		t.Fatalf("send %s -> %s: %v", from, to, err)
	}
	return out
}

func inbox(t *testing.T, b *box, as string) []*msg.Message {
	t.Helper()
	res, err := spool.New(b.cfg).Recv(as, false)
	if err != nil {
		t.Fatalf("recv %s: %v", as, err)
	}
	return res.Messages
}

// raw is a hand-driven socket for protocol-level assertions.
func (e *env) raw(tenant string) (*websocket.Conn, string) {
	e.t.Helper()
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/ws", &websocket.DialOptions{HTTPClient: e.client})
	if err != nil {
		e.t.Fatal(err)
	}
	var ch wire.Frame
	if err := wsjson.Read(ctx, c, &ch); err != nil || ch.Type != wire.TChallenge || ch.Nonce == "" {
		e.t.Fatalf("challenge: %v %+v", err, ch)
	}
	return c, ch.Nonce
}

func helloFrame(b *box, nonce, ts, role string) wire.Frame {
	priv, _ := sign.LoadPrivate(b.cfg.KeysDir, b.id)
	p, _ := wire.HelloPayload(b.id, nonce, ts)
	return wire.Frame{Type: wire.THello, BoxID: b.id, TS: ts, Nonce: nonce, Role: role, Sig: sign.Sign(priv, p)}
}

func closeReason(t *testing.T, c *websocket.Conn) (websocket.StatusCode, string) {
	t.Helper()
	var f wire.Frame
	err := wsjson.Read(context.Background(), c, &f)
	var ce websocket.CloseError
	if !errors.As(err, &ce) {
		t.Fatalf("expected a close, got frame %+v err %v", f, err)
	}
	return ce.Code, ce.Reason
}

// ---- hello --------------------------------------------------------------------

func TestHelloNonceAcceptAndReplayReject(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	now := time.Now().UTC().Format(time.RFC3339)

	// Accept: the right nonce, fresh ts, pinned box.
	c1, n1 := e.raw(tid)
	hello := helloFrame(a, n1, now, wire.RoleCLI)
	wsjson.Write(context.Background(), c1, hello) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(context.Background(), c1, &wel); err != nil || wel.Type != wire.TWelcome || wel.UploadToken == "" {
		t.Fatalf("welcome: %v %+v", err, wel)
	}
	c1.Close(websocket.StatusNormalClosure, "") //nolint:errcheck

	// Replay: the captured hello on a new socket (new nonce) is refused.
	c2, n2 := e.raw(tid)
	if n2 == n1 {
		t.Fatal("nonce reused across sockets")
	}
	wsjson.Write(context.Background(), c2, hello) //nolint:errcheck
	if code, why := closeReason(t, c2); code != wire.CloseUnauthorized || why != "bad_nonce" {
		t.Fatalf("replay: %d %q", code, why)
	}

	// Stale ts (outside ±300 s).
	c3, n3 := e.raw(tid)
	wsjson.Write(context.Background(), c3, helloFrame(a, n3, time.Now().Add(-10*time.Minute).UTC().Format(time.RFC3339), wire.RoleCLI)) //nolint:errcheck
	if code, why := closeReason(t, c3); code != wire.CloseUnauthorized || why != "stale_hello" {
		t.Fatalf("stale: %d %q", code, why)
	}

	// Unpinned box; nothing stored for it.
	u := e.box(tid, "box-u")
	c4, n4 := e.raw(tid)
	wsjson.Write(context.Background(), c4, helloFrame(u, n4, now, wire.RoleBox)) //nolint:errcheck
	if code, why := closeReason(t, c4); code != wire.CloseUnauthorized || why != "unpinned_box" {
		t.Fatalf("unpinned: %d %q", code, why)
	}
	if r, _ := e.st.Roster(context.Background(), tid); len(r["box-u"]) != 0 {
		t.Fatal("unpinned box's roster was stored")
	}

	// Bad sig: box-a's hello signed by another key.
	c5, n5 := e.raw(tid)
	bad := helloFrame(u, n5, now, wire.RoleCLI)
	bad.BoxID = "box-a"
	wsjson.Write(context.Background(), c5, bad) //nolint:errcheck
	if code, why := closeReason(t, c5); code != wire.CloseUnauthorized || why != "bad_sig" {
		t.Fatalf("bad sig: %d %q", code, why)
	}

	// No hello at all → 4408.
	c6, _ := e.raw(tid)
	if code, why := closeReason(t, c6); code != wire.CloseHelloTimeout || why != "hello_timeout" {
		t.Fatalf("timeout: %d %q", code, why)
	}

	// Unknown tenant → HTTP 404 before any upgrade.
	resp, err := e.client.Get("http://nope" + domain + "/v1/ws")
	if err != nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown tenant: %v %v", err, resp)
	}
}

func TestLastHelloWinsOnlyForBoxRole(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	ctx := context.Background()

	s1, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	select {
	case <-s1.Done():
		t.Fatal("a role=cli hello evicted the box session")
	case <-time.After(200 * time.Millisecond):
	}
	s2, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	select {
	case <-s1.Done():
		if s1.CloseCode() != wire.CloseSuperseded {
			t.Fatalf("old session closed with %d, want 4409", s1.CloseCode())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("old role=box session not evicted")
	}
}

// ---- US1: cross-box send/recv --------------------------------------------------

func TestCrossBoxSendRecvAndResult(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()

	// Both boxes hold sessions (the box daemon's role).
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sa.Close()
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	// box-a learns box-b's roster from the broadcast (to_box resolved locally).
	eventually(t, "roster with CLE-07@box-b on box-a", func() bool {
		tb, err := a.c.ResolveToBox("CLE-07", "")
		return err == nil && tb == "box-b"
	})

	out := send(t, a, "GRK-03", "CLE-07", "task", "build it", "")
	if out.Delivery != wire.DeliverySent {
		t.Fatalf("delivery = %q, want sent", out.Delivery)
	}
	eventually(t, "CLE-07 inbox on box-b", func() bool { return len(inbox(t, b, "CLE-07")) == 1 })
	got := inbox(t, b, "CLE-07")[0]
	if got.MsgID != out.MsgID || got.From != "GRK-03" || got.Body != "build it" || got.Sig != "" {
		t.Fatalf("inner v:1 changed on the way: %+v", got)
	}
	if len(inbox(t, a, "CLE-07")) != 0 {
		t.Fatal("cross-box mail was also written to a local inbox on box-a")
	}

	// CLE-07 replies kind=result on the same task (an ordinary peer send).
	res, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "CLE-07", To: "GRK-03", Kind: "result", Body: "done", TaskID: got.TaskID, Hub: b.c})
	if err != nil || res.Delivery != wire.DeliverySent {
		t.Fatalf("result: %v %+v", err, res)
	}
	eventually(t, "result in GRK-03 inbox", func() bool {
		m := inbox(t, a, "GRK-03")
		return len(m) == 1 && m[0].Kind == "result" && m[0].TaskID == got.TaskID
	})

	// Same-box stays local and never touches the hub.
	local := send(t, a, "GRK-03", "GRK-03", "note", "self", "")
	if local.Delivery != wire.DeliveryLocal {
		t.Fatalf("same-box delivery = %q", local.Delivery)
	}
	if st, err := e.st.DeliveryState(ctx, tid, local.MsgID, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("same-box message reached the hub: %q %v", st, err)
	}
}

func TestTamperedAndAmbiguousAndMissingPin(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	c := e.box(tid, "box-c", "CLE-07", "AGY-01")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()

	sb, err := b.c.Dial(ctx, wire.RoleBox) // box-b synced pins BEFORE box-c exists
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()

	// Tampered envelope: signed, then the body is changed → bad_sig → exit 78.
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	m, _ := spool.New(a.cfg).Compose("GRK-03", "CLE-07", "", "task", "real", nil)
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
	env.Msg = []byte(strings.Replace(string(env.Msg), `"real"`, `"fake"`, 1))
	_, err = cli.Send(ctx, env)
	if action.ExitCode(err) != 78 {
		t.Fatalf("tampered: exit %d (%v), want 78", action.ExitCode(err), err)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, m.MsgID, "box-b"); st != "" {
		t.Fatal("tampered envelope was stored")
	}
	// from_box ≠ hello box is refused the same way.
	env2, _ := wire.NewEnvelope(priv, "box-b", "box-b", m)
	if _, err := cli.Send(ctx, env2); action.ExitCode(err) != 78 {
		t.Fatalf("spoofed from_box: %v", err)
	}

	// box-c joins; CLE-07 is now on box-b AND box-c.
	e.pin(tid, c)
	sc, err := c.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sc.Close()
	a.c.Sync(ctx) //nolint:errcheck // refresh box-a's roster cache
	if _, err := a.c.ResolveToBox("CLE-07", ""); err == nil || !strings.Contains(err.Error(), "ambiguous_to_box") {
		t.Fatalf("CLI must refuse an ambiguous to before signing: %v", err)
	}
	// A hand-built envelope without to_box is refused by the hub (409), never filled.
	env3, _ := wire.NewEnvelope(priv, "box-a", "", m)
	var he *hubclient.HubError
	if _, err := cli.Send(ctx, env3); !errors.As(err, &he) || he.Token != "ambiguous_to_box" || he.Status != 409 {
		t.Fatalf("hub ambiguity: %v", err)
	}
	// With --to-box it goes through.
	if out := send(t, a, "GRK-03", "CLE-07", "task", "for c", "box-c"); out.Delivery != wire.DeliverySent {
		t.Fatalf("explicit to_box: %+v", out)
	}

	// Missing pin: box-c → box-b while box-b has NOT synced box-c's pubkey.
	// The hub stores and pushes it; box-b refuses locally (78), writes nothing.
	if out := send(t, c, "AGY-01", "CLE-07", "task", "from c", "box-b"); out.Delivery != wire.DeliverySent {
		t.Fatalf("c->b: %+v", out)
	}
	eventually(t, "box-b refusal", func() bool { return len(sb.RecvErrors()) == 1 })
	if code := action.ExitCode(sb.RecvErrors()[0]); code != 78 {
		t.Fatalf("missing pin: exit %d (%v), want 78", code, sb.RecvErrors()[0])
	}
	if n := len(inbox(t, b, "CLE-07")); n != 0 {
		t.Fatalf("refused frame was written: %d messages", n)
	}
}

// ---- US3: queued, pending, flush -------------------------------------------------

func TestOfflineQueueAndHubDownFlush(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if _, err := b.c.Sync(ctx); err != nil { // announce box-b's roster once
		t.Fatal(err)
	}
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	// box-b offline → queued (no receiver ack); drained on its next hello.
	out := send(t, a, "GRK-03", "CLE-07", "task", "while you were out", "")
	if out.Delivery != wire.DeliveryQueued {
		t.Fatalf("offline: %q, want queued", out.Delivery)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, out.MsgID, "box-b"); st != store.StateQueued {
		t.Fatalf("state %q, want queued", st)
	}
	r, err := b.c.Sync(ctx)
	if err != nil || r.Delivered != 1 {
		t.Fatalf("drain: %+v %v", r, err)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, out.MsgID, "box-b"); st != store.StateSent {
		t.Fatalf("after drain: %q, want sent", st)
	}
	if n := len(inbox(t, b, "CLE-07")); n != 1 {
		t.Fatalf("inbox has %d", n)
	}
	// An idempotent replay of the same envelope does not deliver twice.
	if r, _ := b.c.Sync(ctx); r.Delivered != 0 {
		t.Fatalf("redelivered %d", r.Delivered)
	}

	// Hub unreachable → pending, exit 0; same-box still works.
	down := *a.cfg
	down.HubURL = "http://" + tid + ".unreachable.invalid"
	dc := hubclient.New(&down)
	dc.ReadyTimeout = 2 * time.Second
	pend, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "task", Body: "later", Hub: dc})
	if err != nil || pend.Delivery != wire.DeliveryPending {
		t.Fatalf("hub down: %v %+v", err, pend)
	}
	if loc, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "GRK-03", Kind: "note", Body: "self", Hub: dc}); err != nil || loc.Delivery != wire.DeliveryLocal {
		t.Fatalf("same-box with hub down: %v %+v", err, loc)
	}
	left, _ := a.c.Pending()
	if len(left) != 1 {
		t.Fatalf("pending files: %d", len(left))
	}
	before, _ := os.ReadFile(left[0])

	// Hub back: flush sends the SAME signed bytes (no re-sign, ts unchanged).
	r, err = a.c.Sync(ctx)
	if err != nil || r.Flushed != 1 || r.Pending != 0 {
		t.Fatalf("flush: %+v %v", r, err)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, pend.MsgID, "box-b"); st != store.StateQueued {
		t.Fatalf("flushed message state %q", st)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, tid, pend.TaskID)
	if len(envs) != 1 || string(envs[0]) != strings.TrimSpace(string(before)) {
		t.Fatalf("flush changed the signed bytes:\n%s\n%s", before, envs)
	}
	if r, err := b.c.Sync(ctx); err != nil || r.Delivered != 1 {
		t.Fatalf("receiver after flush: %+v %v", r, err)
	}
}

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

	// Another tenant's URL cannot read it.
	resp, _ := e.client.Get(e.url(other) + "/v1/files/" + att.FileID)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("cross-tenant GET: %d", resp.StatusCode)
	}
	// Anonymous PUT is refused.
	resp, _ = e.client.Post(e.url(tid)+"/v1/files", "application/octet-stream", strings.NewReader("x"))
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous PUT: %d", resp.StatusCode)
	}
	// A file_id the hub does not hold → missing_file (OQ-11 default).
	cli, _ := a.c.Dial(ctx, wire.RoleCLI)
	defer cli.Close()
	m, _ := spool.New(a.cfg).Compose("GRK-03", "CLE-07", "", "task", "ghost",
		[]msg.Attachment{{Mode: "blob", Kind: "file", FileID: strings.Repeat("ab", 32), Name: "ghost"}})
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
	var he *hubclient.HubError
	if _, err := cli.Send(ctx, env); !errors.As(err, &he) || he.Token != "missing_file" {
		t.Fatalf("missing file: %v", err)
	}
}

// ---- US4: tail ---------------------------------------------------------------------

func TestTailStoredAndFollow(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	b.c.Sync(ctx) //nolint:errcheck
	a.c.Sync(ctx) //nolint:errcheck
	first := send(t, a, "GRK-03", "CLE-07", "task", "one", "")

	sess, err := b.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	var bodies []string
	n, err := sess.Tail(ctx, first.TaskID, false, func(e *wire.Envelope) {
		m, _ := e.Inner()
		bodies = append(bodies, m.Body)
	})
	if err != nil || n != 1 || bodies[0] != "one" {
		t.Fatalf("stored tail: %d %v %v", n, bodies, err)
	}

	fctx, cancel := context.WithCancel(ctx)
	got := make(chan string, 4)
	go sess.Tail(fctx, first.TaskID, true, func(e *wire.Envelope) { //nolint:errcheck
		m, _ := e.Inner()
		got <- m.Body
	})
	<-got                                                                                                                                // the stored "one" again
	action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "note", Body: "two", TaskID: first.TaskID, Hub: a.c}) //nolint:errcheck
	select {
	case b := <-got:
		if b != "two" {
			t.Fatalf("follow got %q", b)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("follower did not see the new message")
	}
	cancel()
}

// ---- pins over REST --------------------------------------------------------------

func TestPinRESTRootSigned(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	post := func(req wire.PinRequest) (int, []byte) {
		body, _ := jsonBody(req)
		resp, err := e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp.StatusCode, raw
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	p, _ := wire.PinPayload("box-a", a.pub, ts, false)
	code, raw := post(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(root, p)})
	if code != 200 {
		t.Fatalf("root-signed pin: %d %s", code, raw)
	}
	if strings.Contains(strings.ToLower(string(raw)), "priv") {
		t.Fatalf("pin response leaked a private-key field: %s", raw)
	}
	code, _ = post(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(root, p)})
	if code != 200 {
		t.Fatalf("idempotent same-key pin: %d", code)
	}
	_, other, _ := ed25519.GenerateKey(nil)
	if code, _ = post(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(other, p)}); code != 400 {
		t.Fatalf("non-root pin: %d", code)
	}
	k2, _, _ := ed25519.GenerateKey(nil)
	k2s := base64.StdEncoding.EncodeToString(k2)
	p2, _ := wire.PinPayload("box-a", k2s, ts, false)
	if code, _ = post(wire.PinRequest{BoxID: "box-a", PubKey: k2s, TS: ts, Sig: sign.Sign(root, p2)}); code != 409 {
		t.Fatalf("different key without force: %d", code)
	}
	pb, _ := wire.PinPayload("box-b", b.pub, ts, false)
	if code, _ = post(wire.PinRequest{BoxID: "box-b", PubKey: b.pub, TS: ts, Sig: sign.Sign(root, pb)}); code != 200 {
		t.Fatalf("second box pin: %d", code)
	}

	// GET /v1/pins needs the WS upload token (003 http-v1.md); anonymous is 401.
	resp, err := e.client.Get(e.url(tid) + "/v1/pins")
	if err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous GET /v1/pins: %v %v", err, resp)
	}
	resp.Body.Close()
	if _, err := a.c.Sync(context.Background()); err != nil {
		t.Fatalf("pinned box sync: %v", err)
	}
	c, n := e.raw(tid)
	hello := helloFrame(a, n, ts, wire.RoleCLI)
	wsjson.Write(context.Background(), c, hello) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(context.Background(), c, &wel); err != nil || wel.UploadToken == "" {
		t.Fatalf("welcome token: %v %+v", err, wel)
	}
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/pins", nil)
	req.Header.Set("Authorization", "Bearer "+wel.UploadToken)
	resp, err = e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("GET /v1/pins: %d", resp.StatusCode)
	}
	var list wire.PinList
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Pins) != 2 || list.Pins[0].BoxID != "box-a" || list.Pins[1].BoxID != "box-b" {
		t.Fatalf("GET list = %+v", list.Pins)
	}
	if list.Pins[0].PubKey != a.pub || list.Pins[1].PubKey != b.pub {
		t.Fatalf("GET pubkeys drifted: %+v", list.Pins)
	}
}

func TestPinRevokeAndForce(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	ts := time.Now().UTC().Format(time.RFC3339)
	p, _ := wire.PinPayload("box-a", a.pub, ts, false)
	body, _ := jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(root, p)})
	resp, _ := e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if resp.StatusCode != 200 {
		t.Fatalf("pin: %d", resp.StatusCode)
	}
	resp.Body.Close()

	ctx := context.Background()
	sess, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}

	rp, _ := wire.RevokePayload("box-a", ts)
	rbody, _ := jsonBody(wire.RevokeRequest{BoxID: "box-a", TS: ts, Sig: sign.Sign(root, rp)})
	req, _ := http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/pins/box-a", rbody)
	req.Header.Set("Content-Type", "application/json")
	resp, err = e.client.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("revoke: %v %v", err, resp)
	}
	resp.Body.Close()
	select {
	case <-sess.Done():
		if sess.CloseCode() != wire.CloseUnauthorized {
			t.Fatalf("revoked session close %d, want 4401", sess.CloseCode())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("revoked box session was not closed")
	}
	if _, err := e.st.GetPin(ctx, tid, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("revoked pin still active: %v", err)
	}

	c, n := e.raw(tid)
	wsjson.Write(ctx, c, helloFrame(a, n, ts, wire.RoleCLI)) //nolint:errcheck
	if code, why := closeReason(t, c); code != wire.CloseUnauthorized || why != "unpinned_box" {
		t.Fatalf("hello after revoke: %d %q", code, why)
	}

	k2, priv2, _ := ed25519.GenerateKey(nil)
	k2s := base64.StdEncoding.EncodeToString(k2)
	p2, _ := wire.PinPayload("box-a", k2s, ts, false)
	body, _ = jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: k2s, TS: ts, Sig: sign.Sign(root, p2)})
	resp, _ = e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("new key without force after revoke: %d", resp.StatusCode)
	}
	resp.Body.Close()
	p3, _ := wire.PinPayload("box-a", k2s, ts, true)
	body, _ = jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: k2s, TS: ts, Force: true, Sig: sign.Sign(root, p3)})
	resp, _ = e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if resp.StatusCode != 200 {
		t.Fatalf("force new key: %d", resp.StatusCode)
	}
	resp.Body.Close()

	// Operator --force: new private key AND local pin. Sidecar will not clobber
	// a local pin that still holds the revoked key (004 T008).
	os.WriteFile(filepath.Join(a.cfg.KeysDir, "box-box-a.key"), []byte(base64.StdEncoding.EncodeToString(priv2)+"\n"), 0o600) //nolint:errcheck
	if err := sign.Pin(a.cfg.PinsDir, "box-a", k2s, true); err != nil {
		t.Fatal(err)
	}
	a.pub = k2s
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatalf("hello with forced key: %v", err)
	}
}

func TestPinCLIPublishesAndHygiene(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b")
	rootPath := filepath.Join(t.TempDir(), "root.key")
	if err := os.WriteFile(rootPath, []byte(base64.StdEncoding.EncodeToString(root)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := action.Pin(a.cfg, action.PinArgs{Box: "box-a", PubKey: a.pub, RootKey: rootPath, HTTP: e.client}); err != nil {
		t.Fatalf("spool-pin publish: %v", err)
	}
	if _, err := sign.LoadPin(a.cfg.PinsDir, "box-a"); err != nil {
		t.Fatalf("local pin missing after publish: %v", err)
	}
	if err := action.Pin(a.cfg, action.PinArgs{Box: "box-b", PubKey: b.pub, RootKey: rootPath, HTTP: e.client}); err != nil {
		t.Fatalf("second box: %v", err)
	}
	_, err := action.PublishPin(a.cfg, action.PinArgs{Box: "box-a", PubKey: b.pub, RootKey: rootPath, HTTP: e.client})
	if action.ExitCode(err) != 78 {
		t.Fatalf("collision without force: %v (exit %d)", err, action.ExitCode(err))
	}
	if err := action.Pin(a.cfg, action.PinArgs{Box: "box-a", Revoke: true, RootKey: rootPath, HTTP: e.client}); err != nil {
		t.Fatalf("spool-pin --revoke: %v", err)
	}
	if _, err := e.st.GetPin(context.Background(), tid, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("hub pin survived revoke: %v", err)
	}

	req, _ := json.Marshal(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: "2026-09-18T12:00:00Z", Sig: "sig"})
	var obj map[string]any
	if err := json.Unmarshal(req, &obj); err != nil {
		t.Fatal(err)
	}
	for k := range obj {
		lk := strings.ToLower(k)
		if strings.Contains(lk, "priv") || lk == "seed" || lk == "key" {
			t.Fatalf("pin JSON field %q looks like a private key", k)
		}
	}
	for _, path := range []string{"/v1/pins/task", "/v1/pins/kind/note"} {
		resp, err := e.client.Get(e.url(tid) + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("per-kind route %s: %d", path, resp.StatusCode)
		}
		resp, err = e.client.Post(e.url(tid)+path, "application/json", strings.NewReader(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("per-kind POST %s: %d", path, resp.StatusCode)
		}
	}
}

func jsonBody(v any) (io.Reader, error) {
	b, err := json.Marshal(v)
	return bytes.NewReader(b), err
}
