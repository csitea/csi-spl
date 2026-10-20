package action

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r15-06: the edit verbs (check, Edit, Delete, AttachRename) against a fake
// hub, and their refusals before any dial.

// opHub is a fake hub for one-shot role=cli sessions: challenge, welcome,
// then reply(f) for each frame it reads. It records every frame.
type opHub struct {
	url    string
	mu     sync.Mutex
	frames []wire.Frame
}

func newOpHub(t *testing.T, reply func(wire.Frame) wire.Frame) *opHub {
	t.Helper()
	h := &opHub{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}) != nil {
			return
		}
		var hello wire.Frame
		if wsjson.Read(ctx, conn, &hello) != nil {
			return
		}
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID, UploadToken: "tok",
			UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}) != nil {
			return
		}
		for {
			var f wire.Frame
			if wsjson.Read(ctx, conn, &f) != nil {
				return
			}
			h.mu.Lock()
			h.frames = append(h.frames, f)
			h.mu.Unlock()
			if wsjson.Write(ctx, conn, reply(f)) != nil {
				return
			}
		}
	}))
	t.Cleanup(srv.Close)
	h.url = srv.URL
	return h
}

// of returns the recorded frames of type typ ("" = every frame).
func (h *opHub) of(typ string) []wire.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []wire.Frame
	for _, f := range h.frames {
		if typ == "" || f.Type == typ {
			out = append(out, f)
		}
	}
	return out
}

// opCfg is a box config wired to url: keypair box-a, tenant t1, no sidecar.
func opCfg(t *testing.T, url string) *config.Config {
	t.Helper()
	cfg := testkit.NewConfig(t)
	if _, err := sign.GenerateKey(cfg.KeysDir, "box-a", false); err != nil {
		t.Fatal(err)
	}
	cfg.HubURL, cfg.BoxID, cfg.Tenant, cfg.SubmitSocket = url, "box-a", "t1", "off"
	testkit.Agents(t, cfg, "CLE-1")
	return cfg
}

const editID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

// storedEnv is a message of CLE-1 signed by box-a to box-b in #ops, the
// envelope an edit fetch returns.
func storedEnv(t *testing.T, cfg *config.Config) []byte {
	t.Helper()
	priv, err := sign.LoadPrivate(cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	m := &msg.Message{V: msg.V1, MsgID: editID, TaskID: "task-stored", TS: time.Now().UTC().Format(time.RFC3339),
		From: "CLE-1", To: "CLE-2", Kind: "note", Body: "old body"}
	e, err := wire.NewEnvelopeIn(priv, "box-a", "box-b", "ops", "", m)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := e.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// editHub answers an edit fetch with storedEnv, an edit apply with revision
// 2, and a delete with its topic.
func editHub(t *testing.T) (*opHub, *config.Config) {
	t.Helper()
	var stored []byte
	h := newOpHub(t, func(f wire.Frame) wire.Frame {
		switch {
		case f.Type == wire.TEdit && len(f.Env) == 0:
			return wire.Frame{Type: wire.TEdit, MsgID: f.MsgID, Env: stored}
		case f.Type == wire.TEdit:
			return wire.Frame{Type: wire.TEdit, MsgID: f.MsgID, TaskID: "task-e", Revision: 2}
		case f.Type == wire.TDelete:
			return wire.Frame{Type: wire.TDelete, MsgID: f.MsgID, TaskID: "task-d"}
		}
		return wire.Frame{Type: wire.TError, Error: "unexpected_frame"}
	})
	cfg := opCfg(t, h.url)
	stored = storedEnv(t, cfg)
	return h, cfg
}

// TestEditCheck: the checks every edit verb shares refuse before any dial.
func TestEditCheck(t *testing.T) {
	cfg := testkit.NewConfig(t)
	injected := hubclient.New(cfg)
	cases := []struct {
		name   string
		hubURL string
		in     EditArgs
		want   string // "" = no error
	}{
		{"no hub", "", EditArgs{MsgID: editID}, "needs hub mode"},
		{"empty id", "http://127.0.0.1:1", EditArgs{}, "--msg-id must be"},
		{"not a uuid", "http://127.0.0.1:1", EditArgs{MsgID: "not-a-uuid"}, "--msg-id must be"},
		{"upper-case uuid", "http://127.0.0.1:1", EditArgs{MsgID: strings.ToUpper(editID)}, ""},
		{"bad as", "http://127.0.0.1:1", EditArgs{MsgID: editID, As: "not an id"}, "--as must be"},
		{"good as", "http://127.0.0.1:1", EditArgs{MsgID: editID, As: "CLE-1"}, ""},
		{"injected client", "http://127.0.0.1:1", EditArgs{MsgID: editID, Hub: injected}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg.HubURL = c.hubURL
			hc, err := c.in.check(cfg)
			if c.want != "" {
				if err == nil || !strings.Contains(err.Error(), c.want) || hc != nil {
					t.Fatalf("got %v, %v; want %q", hc, err, c.want)
				}
				return
			}
			if err != nil || hc == nil {
				t.Fatalf("got %v, %v", hc, err)
			}
			if c.in.Hub != nil && hc != c.in.Hub {
				t.Errorf("check built a new client over the injected one")
			}
		})
	}
}

// TestEditRefused: Edit, Delete and AttachRename refuse a bad request and
// the hub sees no frame.
func TestEditRefused(t *testing.T) {
	h, cfg := editHub(t)
	ctx := context.Background()
	dir := t.TempDir()
	file := filepath.Join(dir, "body.txt")
	blank := filepath.Join(dir, "blank.txt")
	if err := os.WriteFile(file, []byte("from file"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(blank, []byte(" \n\t"), 0o600); err != nil {
		t.Fatal(err)
	}
	edits := []struct {
		name string
		in   EditArgs
		want string
	}{
		{"bad id", EditArgs{MsgID: "x", Body: "b"}, "--msg-id must be"},
		{"body and file", EditArgs{MsgID: editID, Body: "b", BodyFile: file}, "exclusive"},
		{"missing file", EditArgs{MsgID: editID, BodyFile: filepath.Join(dir, "none")}, "no such file"},
		{"no body", EditArgs{MsgID: editID}, "must carry the new text"},
		{"blank body", EditArgs{MsgID: editID, Body: "  \n"}, "must carry the new text"},
		{"blank file", EditArgs{MsgID: editID, BodyFile: blank}, "must carry the new text"},
	}
	for _, c := range edits {
		t.Run("edit "+c.name, func(t *testing.T) {
			if _, err := Edit(ctx, cfg, c.in); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want %q", err, c.want)
			}
		})
	}
	if _, err := Delete(ctx, cfg, EditArgs{MsgID: editID, As: "bad as"}); err == nil || !strings.Contains(err.Error(), "--as must be") {
		t.Errorf("delete: got %v", err)
	}
	if _, err := AttachRename(ctx, cfg, EditArgs{MsgID: "x"}, true); err == nil || !strings.Contains(err.Error(), "--msg-id must be") {
		t.Errorf("attach-rename: got %v", err)
	}
	if n := len(h.of("")); n != 0 {
		t.Errorf("the hub received %d frames for refused requests", n)
	}
}

// TestEditHub: an edit fetches then applies the new body, from --body or
// --body-file; an edit as another agent is refused after the fetch.
func TestEditHub(t *testing.T) {
	file := filepath.Join(t.TempDir(), "body.txt")
	if err := os.WriteFile(file, []byte("from file"), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name     string
		in       EditArgs
		wantBody string
		wantErr  string
	}{
		{"body", EditArgs{MsgID: editID, Body: "new body"}, "new body", ""},
		{"body file", EditArgs{MsgID: editID, BodyFile: file}, "from file", ""},
		{"as the author", EditArgs{MsgID: strings.ToUpper(editID), As: "CLE-1", Body: "mine"}, "mine", ""},
		{"as another agent", EditArgs{MsgID: editID, As: "CLE-2", Body: "theirs"}, "", "not CLE-2"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, cfg := editHub(t)
			r, err := Edit(context.Background(), cfg, c.in)
			fs := h.of(wire.TEdit)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("got %v, want %q", err, c.wantErr)
				}
				if len(fs) != 1 {
					t.Errorf("%d edit frames, want the fetch only", len(fs))
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if r.MsgID != editID || r.TaskID != "task-e" || r.From != "CLE-1" || r.Revision != 2 {
				t.Errorf("result %+v", r)
			}
			if len(fs) != 2 || fs[0].MsgID != editID || len(fs[0].Env) != 0 {
				t.Fatalf("edit frames %+v", fs)
			}
			e, err := wire.ParseEnvelope(fs[1].Env)
			if err != nil {
				t.Fatal(err)
			}
			m, err := e.Inner()
			if err != nil {
				t.Fatal(err)
			}
			if m.Body != c.wantBody || m.MsgID != editID || e.ToBox != "box-b" || e.Channel != "ops" {
				t.Errorf("applied body %q id %s to %s #%s", m.Body, m.MsgID, e.ToBox, e.Channel)
			}
		})
	}
}

// TestDeleteHub: a delete answers the topic; --as fetches first and refuses
// another agent's message before the delete frame.
func TestDeleteHub(t *testing.T) {
	cases := []struct {
		name       string
		as         string
		wantErr    string
		wantFetch  int
		wantDelete int
	}{
		{"any agent", "", "", 0, 1},
		{"as the author", "CLE-1", "", 1, 1},
		{"as another agent", "CLE-2", "not written by CLE-2", 1, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, cfg := editHub(t)
			task, err := Delete(context.Background(), cfg, EditArgs{MsgID: editID, As: c.as})
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("got %v, want %q", err, c.wantErr)
				}
			} else if err != nil || task != "task-d" {
				t.Fatalf("got %q, %v", task, err)
			}
			if n := len(h.of(wire.TEdit)); n != c.wantFetch {
				t.Errorf("%d edit fetches, want %d", n, c.wantFetch)
			}
			if d := h.of(wire.TDelete); len(d) != c.wantDelete || (len(d) == 1 && d[0].MsgID != editID) {
				t.Errorf("delete frames %+v, want %d", d, c.wantDelete)
			}
		})
	}
}

// TestAttachRenameHub: a message with no sha-named attachment renames
// nothing and applies nothing, dry or not; --as another agent is refused.
func TestAttachRenameHub(t *testing.T) {
	cases := []struct {
		name    string
		as      string
		dry     bool
		wantErr string
	}{
		{"dry", "", true, ""},
		{"apply", "CLE-1", false, ""},
		{"as another agent", "CLE-2", true, "not CLE-2"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, cfg := editHub(t)
			r, err := AttachRename(context.Background(), cfg, EditArgs{MsgID: editID, As: c.as}, c.dry)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("got %v, want %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if r.MsgID != editID || r.TaskID != "task-stored" || r.From != "CLE-1" || len(r.Files) != 0 || r.Renamed != 0 || r.Applied {
				t.Errorf("result %+v", r)
			}
			if n := len(h.of(wire.TEdit)); n != 1 {
				t.Errorf("%d edit frames, want the fetch only", n)
			}
		})
	}
}
