package hubclient

// Refactor round 27 row 08: the send path's refusals under test. sendPending's
// blob loop and its cli from_not_announced case, the two send claims without a
// box key, and copyBlobs' skips and missing source. Non-test code unchanged.

import (
	"context"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// srPending composes a message on c, signs it for box-b and writes it pending.
func srPending(t *testing.T, c *Client, body string) (*msg.Message, *wire.Envelope, string) {
	t.Helper()
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	m := compose(t, c, body)
	env, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
	if err != nil {
		t.Fatal(err)
	}
	p, err := c.writePending(m, env, Claims{})
	if err != nil {
		t.Fatal(err)
	}
	return m, env, p
}

// srSession dials the fake hub in role and closes the session at cleanup.
func srSession(t *testing.T, c *Client, role string) *Session {
	t.Helper()
	s, err := c.Dial(context.Background(), role)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

// srRejected counts the envelopes in rejected/.
func srRejected(t *testing.T, c *Client) int {
	t.Helper()
	list, _ := filepath.Glob(filepath.Join(c.rejectedDir(), "*.json"))
	return len(list)
}

// srFiles lists every regular file under root.
func srFiles(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error { //nolint:errcheck
		if err == nil && d.Type().IsRegular() {
			out = append(out, p)
		}
		return nil
	})
	return out
}

func srNotAnnounced() *wire.Frame {
	return &wire.Frame{Type: wire.TError, Error: wire.TokenFromNotAnnounced, Status: http.StatusConflict}
}

// A cli session cannot announce: from_not_announced leaves the envelope pending
// for the box session's flush, and nothing is rejected.
func TestSRCliFromNotAnnouncedStaysPending(t *testing.T) {
	h := newFakeHub(t)
	h.refuse = srNotAnnounced()
	c := hubClient(t, h)
	m, env, p := srPending(t, c, "cli not announced")
	s := srSession(t, c, wire.RoleCLI)
	d, err := s.sendPending(context.Background(), env, m, p, Claims{})
	if err != nil || d != wire.DeliveryPending {
		t.Fatalf("delivery %q err %v, want pending and no error", d, err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("pending file gone: %v", err)
	}
	if n := srRejected(t, c); n != 0 {
		t.Fatalf("rejected/ holds %d, want 0", n)
	}
}

// A box session gets the same token as a plain 4xx: the client-error path
// rejects the envelope and returns the hub's error.
func TestSRBoxFromNotAnnouncedRejects(t *testing.T) {
	h := newFakeHub(t)
	h.refuse = srNotAnnounced()
	c := hubClient(t, h)
	m, env, p := srPending(t, c, "box not announced")
	s := srSession(t, c, wire.RoleBox)
	d, err := s.sendPending(context.Background(), env, m, p, Claims{})
	if err == nil || !strings.Contains(err.Error(), wire.TokenFromNotAnnounced) || d != "" {
		t.Fatalf("delivery %q err %v, want the from_not_announced error", d, err)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("pending file still there: %v", err)
	}
	if n := srRejected(t, c); n != 1 {
		t.Fatalf("rejected/ holds %d, want 1", n)
	}
}

// Only a blob is uploaded: a path attachment goes straight to the send. The
// fake hub has no /v1/files route, so an upload would fail the send.
func TestSRPathAttachmentNotUploaded(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	m, env, p := srPending(t, c, "path attachment")
	m.Files = []msg.Attachment{{Mode: "path", Kind: "file", Path: "/no/such/file", Name: "f.txt"}}
	s := srSession(t, c, wire.RoleCLI)
	d, err := s.sendPending(context.Background(), env, m, p, Claims{})
	if err != nil || d != wire.DeliverySent {
		t.Fatalf("delivery %q err %v, want sent", d, err)
	}
	if n := len(h.sent()); n != 1 {
		t.Fatalf("hub got %d sends, want 1", n)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("pending file kept after a send: %v", err)
	}
}

// An unreachable hub on the upload keeps the envelope pending, before any send.
func TestSRUploadUnreachablePending(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	m, env, p := srPending(t, c, "blob, hub gone")
	const id = "sr-blob"
	if err := writeAtomic(filepath.Join(c.Cfg.FilesDir(), id), []byte("blob")); err != nil {
		t.Fatal(err)
	}
	m.Files = []msg.Attachment{{Mode: "blob", Kind: "file", FileID: id, Name: "b.txt"}}
	s := srSession(t, c, wire.RoleCLI)
	s.c.Cfg.HubURL = "http://127.0.0.1:0"
	d, err := s.sendPending(context.Background(), env, m, p, Claims{})
	if err != nil || d != wire.DeliveryPending {
		t.Fatalf("delivery %q err %v, want pending and no error", d, err)
	}
	if n := len(h.sent()); n != 0 {
		t.Fatalf("hub got %d sends, want 0", n)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("pending file gone: %v", err)
	}
}

// A blob missing from the local store is an error, not a pending, and no send.
func TestSRUploadMissingBlobErrors(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	m, env, p := srPending(t, c, "blob missing")
	m.Files = []msg.Attachment{{Mode: "blob", Kind: "file", FileID: "sr-absent", Name: "b.txt"}}
	s := srSession(t, c, wire.RoleCLI)
	d, err := s.sendPending(context.Background(), env, m, p, Claims{})
	if err == nil || !strings.Contains(err.Error(), "is not in the local store") || d != "" {
		t.Fatalf("delivery %q err %v, want the local store error", d, err)
	}
	if n := len(h.sent()); n != 0 {
		t.Fatalf("hub got %d sends, want 0", n)
	}
}

// srNoKeyClient is a hub client whose box key is gone.
func srNoKeyClient(t *testing.T) *Client {
	t.Helper()
	c := hubClient(t, newFakeHub(t))
	if err := os.RemoveAll(c.Cfg.KeysDir); err != nil {
		t.Fatal(err)
	}
	return c
}

// Without its box key neither send claim writes anything: no outbox, no pending.
func TestSRSendClaimsNoBoxKey(t *testing.T) {
	ctx := context.Background()
	cases := map[string]func(c *Client, m *msg.Message) (string, error){
		"channel": func(c *Client, m *msg.Message) (string, error) {
			return c.SendChannelClaims(ctx, m, "general", Claims{})
		},
		"message": func(c *Client, m *msg.Message) (string, error) {
			return c.SendMessageClaims(ctx, m, "box-b", Claims{})
		},
	}
	for name, send := range cases {
		t.Run(name, func(t *testing.T) {
			c := srNoKeyClient(t)
			m := compose(t, c, "no key")
			d, err := send(c, m)
			if err == nil || d != "" {
				t.Fatalf("delivery %q err %v, want an error", d, err)
			}
			if left := srFiles(t, c.Cfg.SpoolRoot); len(left) != 0 {
				t.Fatalf("files written without a key: %v", left)
			}
		})
	}
}

// copyBlobs skips a path attachment and a blob the desk already holds, and
// names a blob missing from the local store.
func TestSRCopyBlobs(t *testing.T) {
	src, dst := testClient(t), testClient(t)
	const held, absent = "sr-held", "sr-absent"
	if err := writeAtomic(filepath.Join(dst.Cfg.FilesDir(), held), []byte("desk copy")); err != nil {
		t.Fatal(err)
	}
	m := &msg.Message{Files: []msg.Attachment{
		{Mode: "path", Path: "/no/such/file", Name: "p.txt"},
		{Mode: "blob", FileID: held, Name: "h.txt"},
	}}
	if err := src.copyBlobs(dst, m); err != nil {
		t.Fatalf("skips: %v", err)
	}
	if raw, _ := os.ReadFile(filepath.Join(dst.Cfg.FilesDir(), held)); string(raw) != "desk copy" {
		t.Fatalf("held blob changed: %q", raw)
	}
	m.Files = append(m.Files, msg.Attachment{Mode: "blob", FileID: absent, Name: "a.txt"})
	err := src.copyBlobs(dst, m)
	if err == nil || !strings.Contains(err.Error(), "blob "+absent+" is not in the local store") {
		t.Fatalf("want the missing source named, got %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst.Cfg.FilesDir(), absent)); !os.IsNotExist(err) {
		t.Fatalf("missing blob appeared on the desk: %v", err)
	}
}
