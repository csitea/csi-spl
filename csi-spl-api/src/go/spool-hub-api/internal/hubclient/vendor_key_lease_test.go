//go:build linux

package hubclient

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"filippo.io/age"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// fakeVendorKey is the obvious fake of spec 127 6.
const fakeVendorKey = "sk-test-0000"

type sealingHub struct{ to age.Recipient }

func (h sealingHub) Lease(_ context.Context, kind string) ([]byte, error) {
	return keydesk.Seal(h.to, keydesk.Payload{Kind: kind, Box: "box-a", KeyID: "k1", Key: fakeVendorKey})
}

func (sealingHub) Exhausted(context.Context, string) error { return nil }

// keyDeskUp runs this client's box-root key desk and leases a grok key
// through it, as a seat start does.
func keyDeskUp(t *testing.T, c *Client) {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	s := &keydesk.Server{Path: keydesk.SockPath(c.Cfg.HubDir()), SeatRoot: filepath.Join(t.TempDir(), "spool-seat"),
		Box: "box-a", Hub: sealingHub{to: id.Recipient()}, Identity: id, PeerOK: keydesk.OwnUID}
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go s.Serve(ctx)
	conn, err := net.Dial("unix", s.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = json.NewEncoder(conn).Encode(map[string]string{"op": "lease", "kind": "grok"})
	if b, _ := io.ReadAll(conn); !strings.Contains(string(b), `"ok":true`) {
		t.Fatalf("lease: %s", b)
	}
}

// grepRoot counts the files under root that hold s.
func grepRoot(t *testing.T, root, s string) int {
	t.Helper()
	n := 0
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			if b, rerr := os.ReadFile(p); rerr == nil && strings.Contains(string(b), s) {
				n++
			}
		}
		return nil
	})
	return n
}

// TestSendRedactsHandedOutKey: spec 127 L9, the desk half. A seat echoes its
// leased key into a spool body (or the terminal mirror, which posts through
// spool send): no copy of the body on the box holds the key.
// RED CONTROL: no redactKeys call in SendMessageClaims -> the fake is found.
func TestSendRedactsHandedOutKey(t *testing.T) {
	c := testClient(t)
	keyDeskUp(t, c)
	m, err := spool.New(c.Cfg).Compose("c-005", "c-004", "", "task", "my env: XAI_API_KEY="+fakeVendorKey, nil)
	if err != nil {
		t.Fatal(err)
	}
	if d, err := c.SendMessage(context.Background(), m, "box-a"); err != nil || d != wire.DeliveryLocal {
		t.Fatalf("send: %q %v", d, err)
	}
	if n := grepRoot(t, c.Cfg.SpoolRoot, fakeVendorKey); n != 0 {
		t.Fatalf("the handed-out key is in %d files of the spool root", n)
	}
	if n := grepRoot(t, c.Cfg.SpoolRoot, keydesk.Removed); n == 0 {
		t.Fatal("the redacted body was not delivered")
	}
}

// A key socket that is there but dead refuses the send: nothing written.
func TestSendRefusedOnDeadKeySocket(t *testing.T) {
	c := testClient(t)
	sock := keydesk.SockPath(c.Cfg.HubDir())
	if err := os.MkdirAll(filepath.Dir(sock), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sock, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	m, err := spool.New(c.Cfg).Compose("c-005", "c-004", "", "task", "marker-dead-desk", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.SendMessage(context.Background(), m, "box-a"); err == nil || !strings.Contains(err.Error(), "desk key socket") {
		t.Fatalf("send through a dead key socket: %v", err)
	}
	if n := grepRoot(t, c.Cfg.SpoolRoot, "marker-dead-desk"); n != 0 {
		t.Fatalf("a refused send left %d copies", n)
	}
}

// leaseHub is a test hub: the box handshake of fakehub, then the two
// vendor-key routes of 127 H2 as the desk calls them.
func leaseHub(t *testing.T, to age.Recipient, exhausted *atomic.Int32) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		_ = wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"})
		var hello wire.Frame
		if wsjson.Read(ctx, conn, &hello) != nil {
			return
		}
		_ = wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID,
			UploadToken: "tok", UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)})
		var f wire.Frame
		for wsjson.Read(ctx, conn, &f) == nil {
		}
	})
	mux.HandleFunc("POST /v1/vendor-keys/{kind}/{op}", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		kind, op := r.PathValue("kind"), r.PathValue("op")
		switch {
		case op == "exhausted":
			exhausted.Add(1)
			w.WriteHeader(http.StatusNoContent)
		case kind == "grok":
			b, _ := keydesk.Seal(to, keydesk.Payload{Kind: kind, Box: "box-a", KeyID: "k1", Key: fakeVendorKey})
			_ = json.NewEncoder(w).Encode(leaseAnswer{Sealed: base64.StdEncoding.EncodeToString(b)})
		case kind == "qwen":
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(wire.ErrorBody{Error: "box_not_approved"})
		case kind == "claude":
			_ = json.NewEncoder(w).Encode(leaseAnswer{Sealed: "not base64 !"})
		default:
			http.NotFound(w, r)
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

// TestVendorKeyHubLease: the desk's hub calls, against a hub that answers
// as 127 H2 will. A sealed answer opens with the desk's identity; a hub
// refusal keeps its token; a 404 (H2 not live) reads no_lease_route.
func TestVendorKeyHubLease(t *testing.T) {
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	var exhausted atomic.Int32
	root := t.TempDir()
	cfg := &config.Config{SpoolRoot: filepath.Join(root, "spool"), KeysDir: filepath.Join(root, "keys"),
		PinsDir: filepath.Join(root, "spool", "pins"), HubURL: leaseHub(t, id.Recipient(), &exhausted),
		BoxID: "box-a", Tenant: "t1", SubmitSocket: "off"}
	if _, err := sign.GenerateKey(cfg.KeysDir, "box-a", false); err != nil {
		t.Fatal(err)
	}
	h := VendorKeyHub{C: New(cfg)}
	ctx := context.Background()
	b, err := h.Lease(ctx, "grok")
	if err != nil {
		t.Fatal(err)
	}
	if p, err := keydesk.Open(id, b); err != nil || p.Key != fakeVendorKey || p.Kind != "grok" {
		t.Fatalf("open: %v %v", p, err)
	}
	for kind, want := range map[string]string{"qwen": "box_not_approved", "mistral": keydesk.TokNoLeaseRoute, "claude": keydesk.TokBadSeal} {
		_, err := h.Lease(ctx, kind)
		var re *keydesk.Refused
		if !errors.As(err, &re) || re.Token != want {
			t.Fatalf("%s: %v, want refused %s", kind, err, want)
		}
	}
	if err := h.Exhausted(ctx, "grok"); err != nil || exhausted.Load() != 1 {
		t.Fatalf("exhausted: %v (%d)", err, exhausted.Load())
	}
}
