package main

import (
	"encoding/json"
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

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// opsCLIHub is the role=cli WS contract of the topic and message verbs
// (r9-01): archive, move and react answer with their object, an edit frame
// without env fetches the stored envelope and one with env applies it, a
// delete answers the topic. refuse answers every request with a hub error.
type opsCLIHub struct {
	stored []byte

	mu     sync.Mutex
	frames []wire.Frame
	refuse bool
}

const (
	fsTask = "0b6f3c1e-1111-4a2b-8c3d-000000000001"
	fsMsg  = "0b6f3c1e-2222-4a2b-8c3d-000000000002"
)

func newOpsCLIHub(t *testing.T) *opsCLIHub {
	t.Helper()
	h := &opsCLIHub{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.ws)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	docEnv(t, srv.URL)
	h.stored = storedBy(t, "c-007")
	return h
}

// storedBy is a message from agent from, signed by this box (box-a, the key
// docEnv minted), as the hub hands it back for an edit.
func storedBy(t *testing.T, from string) []byte {
	t.Helper()
	priv, err := sign.LoadPrivate(os.Getenv("SPOOL_KEYS_DIR"), "box-a")
	if err != nil {
		t.Fatal(err)
	}
	m := &msg.Message{V: msg.V1, MsgID: fsMsg, TaskID: fsTask, TS: time.Now().UTC().Format(time.RFC3339),
		From: from, To: "c-008", Kind: "note", Body: "old body"}
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

func (h *opsCLIHub) reset(refuse bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.frames = nil
	h.refuse = refuse
}

func (h *opsCLIHub) seen(typ string) []wire.Frame {
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

func (h *opsCLIHub) ws(w http.ResponseWriter, r *http.Request) {
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
	if wsjson.Read(ctx, conn, &hello) != nil || hello.Role != wire.RoleCLI {
		return
	}
	if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome}) != nil {
		return
	}
	for {
		var f wire.Frame
		if wsjson.Read(ctx, conn, &f) != nil {
			return
		}
		if wsjson.Write(ctx, conn, h.answer(f)) != nil {
			return
		}
	}
}

func (h *opsCLIHub) answer(f wire.Frame) wire.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.frames = append(h.frames, f)
	if h.refuse {
		return wire.Frame{Type: wire.TError, MsgID: f.MsgID, Error: "forbidden", Status: http.StatusForbidden, Detail: "not yours"}
	}
	obj := func(v map[string]any) json.RawMessage {
		b, _ := json.Marshal(v)
		return b
	}
	switch f.Type {
	case wire.TArchive:
		return wire.Frame{Type: f.Type, MsgID: f.MsgID, Archive: obj(map[string]any{
			"task_id": f.TaskID, "archived": f.ArchiveOp == "archive", "archived_by": f.As})}
	case wire.TMove:
		return wire.Frame{Type: f.Type, MsgID: f.MsgID, Move: obj(map[string]any{
			"task_id": f.TaskID, "channel": f.MoveTo, "moved": true, "moved_by": f.As, "typed_by": f.TypedBy})}
	case wire.TReact:
		return wire.Frame{Type: f.Type, MsgID: f.MsgID, Reaction: obj(map[string]any{
			"task_id": f.TaskID, "msg_id": f.ReactMsg, "op": f.ReactOp, "emoji": f.Emoji})}
	case wire.TEdit:
		if len(f.Env) == 0 {
			return wire.Frame{Type: f.Type, MsgID: f.MsgID, Env: h.stored}
		}
		return wire.Frame{Type: f.Type, MsgID: f.MsgID, TaskID: fsTask, Revision: 2}
	case wire.TDelete:
		return wire.Frame{Type: f.Type, MsgID: f.MsgID, TaskID: fsTask}
	}
	return wire.Frame{Type: wire.TError, MsgID: f.MsgID, Error: "bad_frame"}
}

// fsRun runs the verb and decodes its one JSON line.
func fsRun(t *testing.T, args ...string) (int, map[string]any, string) {
	t.Helper()
	rc, out, errOut := captureRun(t, args)
	var got map[string]any
	if rc == 0 {
		if err := json.Unmarshal([]byte(out), &got); err != nil {
			t.Fatalf("%v: stdout is not one JSON object: %q (%v)", args, out, err)
		}
	}
	return rc, got, errOut
}

// fsBad runs each bad command line: every one exits non-zero and none of
// them reaches the hub.
func fsBad(t *testing.T, h *opsCLIHub, cases [][]string) {
	t.Helper()
	h.reset(false)
	for _, args := range cases {
		if rc, _, _ := fsRun(t, args...); rc == 0 {
			t.Errorf("%v: rc 0", args)
		}
	}
	if fr := h.seen(""); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
}

// fsRefused runs each command line against a refusing hub: every one exits
// non-zero and prints the hub's token.
func fsRefused(t *testing.T, h *opsCLIHub, cases [][]string) {
	t.Helper()
	h.reset(true)
	for _, args := range cases {
		rc, _, errOut := fsRun(t, args...)
		if rc == 0 || !strings.Contains(errOut, "forbidden") {
			t.Fatalf("%v: rc %d err %q", args, rc, errOut)
		}
	}
}

func TestCLIArchiveMoveReact(t *testing.T) {
	h := newOpsCLIHub(t)

	t.Run("archive and unarchive", func(t *testing.T) {
		h.reset(false)
		rc, got, errOut := fsRun(t, "archive", "--task", strings.ToUpper(fsTask), "--as", "c-007")
		if rc != 0 || got["archived"] != true || got["task_id"] != fsTask || got["archived_by"] != "c-007" {
			t.Fatalf("archive: rc %d got %v err %q", rc, got, errOut)
		}
		rc, got, errOut = fsRun(t, "archive", "--task", fsTask, "--as", "c-007", "--unarchive")
		if rc != 0 || got["archived"] != false {
			t.Fatalf("unarchive: rc %d got %v err %q", rc, got, errOut)
		}
		fr := h.seen(wire.TArchive)
		if len(fr) != 2 || fr[0].ArchiveOp != "archive" || fr[1].ArchiveOp != "unarchive" {
			t.Fatalf("archive frames %+v", fr)
		}
	})

	t.Run("move", func(t *testing.T) {
		h.reset(false)
		rc, got, errOut := fsRun(t, "move", "--task", fsTask, "--channel", "#Ops", "--as", "c-007", "--acting-for", "HUM-10")
		if rc != 0 || got["channel"] != "ops" || got["moved_by"] != "c-007" || got["typed_by"] != "HUM-10" {
			t.Fatalf("move: rc %d got %v err %q", rc, got, errOut)
		}
		if fr := h.seen(wire.TMove); len(fr) != 1 || fr[0].TaskID != fsTask || fr[0].MoveTo != "ops" {
			t.Fatalf("move frames %+v", fr)
		}
	})

	t.Run("react add remove list", func(t *testing.T) {
		h.reset(false)
		cases := []struct {
			args []string
			op   string
		}{
			{[]string{"--emoji", "⏸️"}, "add"},
			{[]string{"--emoji", "⏸️", "--remove", "--msg", fsMsg}, "remove"},
			{[]string{"--list"}, "list"},
		}
		for _, c := range cases {
			args := append([]string{"react", "--task", fsTask, "--as", "c-007"}, c.args...)
			rc, got, errOut := fsRun(t, args...)
			if rc != 0 || got["op"] != c.op || got["task_id"] != fsTask {
				t.Fatalf("react %s: rc %d got %v err %q", c.op, rc, got, errOut)
			}
		}
		fr := h.seen(wire.TReact)
		if len(fr) != 3 || fr[0].ReactMsg != "" || fr[1].ReactMsg != fsMsg || fr[2].Emoji != "" {
			t.Fatalf("react frames %+v", fr)
		}
	})

	t.Run("the hub refuses", func(t *testing.T) {
		fsRefused(t, h, [][]string{
			{"archive", "--task", fsTask, "--as", "c-007"},
			{"move", "--task", fsTask, "--channel", "ops", "--as", "c-007"},
			{"react", "--task", fsTask, "--as", "c-007", "--emoji", "👍"},
		})
	})

	t.Run("bad input sends nothing", func(t *testing.T) {
		fsBad(t, h, [][]string{
			{"archive", "--task", "not-a-uuid", "--as", "c-007"},
			{"archive", "--task", fsTask},
			{"archive", "--no-such-flag"},
			{"move", "--task", fsTask, "--as", "c-007"},
			{"move", "--task", fsTask, "--channel", "ops", "--as", "c-007", "--acting-for", "c-001"},
			{"move", "--no-such-flag"},
			{"react", "--task", fsTask, "--as", "c-007"},
			{"react", "--msg", "nope", "--as", "c-007", "--emoji", "👍"},
			{"react", "--no-such-flag"},
		})
	})
}

func TestCLIEditDelete(t *testing.T) {
	h := newOpsCLIHub(t)

	t.Run("edit re-signs the new body", func(t *testing.T) {
		h.reset(false)
		rc, got, errOut := fsRun(t, "edit", "--msg-id", strings.ToUpper(fsMsg), "--as", "c-007", "--body", "new body")
		if rc != 0 || got["msg_id"] != fsMsg || got["task_id"] != fsTask || got["from"] != "c-007" || got["revision"] != float64(2) {
			t.Fatalf("edit: rc %d got %v err %q", rc, got, errOut)
		}
		fr := h.seen(wire.TEdit)
		if len(fr) != 2 || len(fr[0].Env) != 0 || len(fr[1].Env) == 0 {
			t.Fatalf("edit frames %+v", fr)
		}
		e, err := wire.ParseEnvelope(fr[1].Env)
		if err != nil {
			t.Fatal(err)
		}
		in, err := e.Inner()
		if err != nil {
			t.Fatal(err)
		}
		if e.FromBox != "box-a" || e.ToBox != "box-b" || in.Body != "new body" || in.MsgID != fsMsg {
			t.Fatalf("applied envelope from %s to %s body %q id %s", e.FromBox, e.ToBox, in.Body, in.MsgID)
		}
	})

	t.Run("edit from a body file", func(t *testing.T) {
		h.reset(false)
		f := filepath.Join(t.TempDir(), "body.md")
		if err := os.WriteFile(f, []byte("from a file\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		rc, _, errOut := fsRun(t, "edit", "--msg-id", fsMsg, "--body-file", f)
		if rc != 0 {
			t.Fatalf("edit --body-file: rc %d err %q", rc, errOut)
		}
		fr := h.seen(wire.TEdit)
		e, err := wire.ParseEnvelope(fr[len(fr)-1].Env)
		if err != nil {
			t.Fatal(err)
		}
		if in, err := e.Inner(); err != nil || in.Body != "from a file\n" {
			t.Fatalf("applied body %v %v", in, err)
		}
	})

	t.Run("edit refuses another agent's line", func(t *testing.T) {
		h.reset(false)
		rc, _, errOut := fsRun(t, "edit", "--msg-id", fsMsg, "--as", "c-009", "--body", "x")
		if rc == 0 || !strings.Contains(errOut, "not c-009") {
			t.Fatalf("edit as another agent: rc %d err %q", rc, errOut)
		}
		if fr := h.seen(wire.TEdit); len(fr) != 1 {
			t.Fatalf("only the fetch may reach the hub: %+v", fr)
		}
	})

	t.Run("delete", func(t *testing.T) {
		h.reset(false)
		rc, got, errOut := fsRun(t, "delete", "--msg-id", fsMsg, "--as", "c-007")
		if rc != 0 || got["msg_id"] != fsMsg || got["task_id"] != fsTask || got["deleted"] != "true" {
			t.Fatalf("delete: rc %d got %v err %q", rc, got, errOut)
		}
		if fr := h.seen(wire.TDelete); len(fr) != 1 || fr[0].MsgID != fsMsg {
			t.Fatalf("delete frames %+v", fr)
		}
		rc, _, errOut = fsRun(t, "delete", "--msg-id", fsMsg, "--as", "c-009")
		if rc == 0 || !strings.Contains(errOut, "not written by c-009") {
			t.Fatalf("delete as another agent: rc %d err %q", rc, errOut)
		}
		if fr := h.seen(wire.TDelete); len(fr) != 1 {
			t.Fatalf("a refused delete reached the hub: %+v", fr)
		}
	})

	t.Run("the hub refuses", func(t *testing.T) {
		fsRefused(t, h, [][]string{
			{"edit", "--msg-id", fsMsg, "--body", "x"},
			{"delete", "--msg-id", fsMsg},
		})
	})

	t.Run("bad input sends nothing", func(t *testing.T) {
		fsBad(t, h, [][]string{
			{"edit", "--msg-id", "nope", "--body", "x"},
			{"edit", "--msg-id", fsMsg, "--as", "Not An Id", "--body", "x"},
			{"edit", "--msg-id", fsMsg, "--body", "  "},
			{"edit", "--msg-id", fsMsg, "--body", "x", "--body-file", "/nonexistent"},
			{"edit", "--msg-id", fsMsg, "--body-file", filepath.Join(t.TempDir(), "missing")},
			{"edit", "--no-such-flag"},
			{"delete", "--msg-id", "nope"},
			{"delete", "--no-such-flag"},
		})
	})
}
