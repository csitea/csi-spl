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
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
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
		// go test runs in the package dir; runtime.Caller's file is module-relative under -trimpath (SPL-3171)
		dir = filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
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

// pin pins b and seats the agents its spool root holds, as the box's
// sidecar hello would: onSend accepts msg.from only from the box that
// announced it, and most rigs send over role=cli alone.
func (e *env) pin(tenant string, b *box) {
	e.t.Helper()
	raw, _ := base64.StdEncoding.DecodeString(b.pub)
	if err := e.st.PutPin(context.Background(), tenant, b.id, ed25519.PublicKey(raw), false, time.Now(), time.Now()); err != nil {
		e.t.Fatal(err)
	}
	ents, _ := os.ReadDir(b.cfg.SpoolRoot)
	var agents []string
	for _, d := range ents {
		if d.IsDir() && msg.ValidID(d.Name()) {
			agents = append(agents, d.Name())
		}
	}
	if len(agents) > 0 {
		if err := e.st.SetRoster(context.Background(), tenant, b.id, agents, time.Now()); err != nil {
			e.t.Fatal(err)
		}
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

// watch waits d for something that must NOT happen and returns as soon as
// happened() reports it, so the assertion after it fails at once instead of
// after a blind sleep - and passes only once the whole window is over.
func watch(d time.Duration, happened func() bool) {
	for deadline := time.Now().Add(d); time.Now().Before(deadline) && !happened(); {
		time.Sleep(10 * time.Millisecond)
	}
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

func jsonBody(v any) (io.Reader, error) {
	b, err := json.Marshal(v)
	return bytes.NewReader(b), err
}

func (e *env) postPin(tenant string, root ed25519.PrivateKey, boxID, pub string) (int, wire.ErrorBody) {
	e.t.Helper()
	ts := time.Now().UTC().Format(time.RFC3339)
	payload, _ := wire.PinPayload(boxID, pub, ts, false)
	body, _ := json.Marshal(wire.PinRequest{BoxID: boxID, PubKey: pub, TS: ts, Sig: sign.Sign(root, payload)})
	resp, err := e.client.Post(e.url(tenant)+"/v1/pins", "application/json", bytes.NewReader(body))
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var eb wire.ErrorBody
	json.Unmarshal(raw, &eb) //nolint:errcheck
	return resp.StatusCode, eb
}

func (e *env) uploadToken(tenant string, b *box) string {
	e.t.Helper()
	ctx := context.Background()
	c, nonce := e.raw(tenant)
	defer c.CloseNow()
	now := time.Now().UTC().Format(time.RFC3339)
	if err := wsjson.Write(ctx, c, helloFrame(b, nonce, now, wire.RoleCLI)); err != nil {
		e.t.Fatal(err)
	}
	var wel wire.Frame
	if err := wsjson.Read(ctx, c, &wel); err != nil || wel.Type != wire.TWelcome || wel.UploadToken == "" {
		e.t.Fatalf("welcome token: %v %+v", err, wel)
	}
	return wel.UploadToken
}

func (e *env) pinKey(tenant, boxID string, pub ed25519.PublicKey) {
	e.t.Helper()
	if err := e.st.PutPin(context.Background(), tenant, boxID, pub, false, time.Now(), time.Now()); err != nil {
		e.t.Fatal(err)
	}
}
