package hubclient

// r7-04: a scripted hub for the request/reply, REST and recv paths that no
// other test drove (internal/hubclient at 51.9 %, 55 functions at 0 %). It
// answers every request frame the CLI sends, serves /v1/pins and /v1/files,
// and pushes a test's recv frames to a role=box hello before queue_end.

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
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
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

type opsHub struct {
	// reply answers one client frame (nil = opsReply); no frames = no answer.
	reply func(f wire.Frame) []wire.Frame
	// push is written to a role=box session after welcome, then queue_end.
	push   []wire.Frame
	roster map[string][]string
	mu     sync.Mutex
	// pins is the /v1/pins list; restStatus, when set, answers every REST
	// call with that status and restToken as the error body. Set them
	// before the first dial, or through setPins / setREST.
	pins       []wire.PinEntry
	restStatus int
	restToken  string
	got        []wire.Frame // every frame after the hello
	files      map[string][]byte
	paths      []string // the path + query of every REST call
	auth       []string // the Authorization header of every REST call
}

func (h *opsHub) start(t *testing.T) string {
	t.Helper()
	h.files = map[string][]byte{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.ws)
	mux.HandleFunc("/v1/", h.rest)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

func (h *opsHub) ws(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer conn.CloseNow() //nolint:errcheck
	ctx := r.Context()
	var hello wire.Frame
	if wsjson.Write(ctx, conn, challenge) != nil || wsjson.Read(ctx, conn, &hello) != nil {
		return
	}
	wel := wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID, Roster: h.roster,
		UploadToken: "tok", UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}
	if wsjson.Write(ctx, conn, wel) != nil {
		return
	}
	if hello.Role == wire.RoleBox {
		for _, f := range append(append([]wire.Frame(nil), h.push...), wire.Frame{Type: wire.TQueueEnd, Count: len(h.push)}) {
			if wsjson.Write(ctx, conn, f) != nil {
				return
			}
		}
	}
	reply := h.reply
	if reply == nil {
		reply = opsReply
	}
	for {
		var f wire.Frame
		if wsjson.Read(ctx, conn, &f) != nil {
			return
		}
		h.mu.Lock()
		h.got = append(h.got, f)
		h.mu.Unlock()
		for _, out := range reply(f) {
			if wsjson.Write(ctx, conn, out) != nil {
				return
			}
		}
	}
}

func (h *opsHub) rest(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	h.paths = append(h.paths, r.URL.RequestURI())
	h.auth = append(h.auth, r.Header.Get("Authorization"))
	status, token, pins := h.restStatus, h.restToken, append([]wire.PinEntry{}, h.pins...)
	h.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	if status != 0 {
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(wire.ErrorBody{Error: token}) //nolint:errcheck
		return
	}
	switch {
	case r.URL.Path == "/v1/pins" && r.URL.Query().Get("probe") == "1":
		w.WriteHeader(http.StatusNoContent)
	case r.URL.Path == "/v1/pins":
		json.NewEncoder(w).Encode(wire.PinList{Pins: pins}) //nolint:errcheck
	case r.URL.Path == "/v1/files" && r.Method == http.MethodPost:
		raw, _ := io.ReadAll(r.Body)
		id := blobID(raw)
		h.mu.Lock()
		h.files[id] = raw
		h.mu.Unlock()
		json.NewEncoder(w).Encode(wire.FileResult{FileID: id, SHA256: id, Bytes: int64(len(raw))}) //nolint:errcheck
	case strings.HasPrefix(r.URL.Path, "/v1/files/"):
		h.mu.Lock()
		raw, ok := h.files[strings.TrimPrefix(r.URL.Path, "/v1/files/")]
		h.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(wire.ErrorBody{Error: "not_found"}) //nolint:errcheck
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(raw) //nolint:errcheck
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

// setREST makes every later REST call answer status with token (0 = serve).
func (h *opsHub) setREST(status int, token string) {
	h.mu.Lock()
	h.restStatus, h.restToken = status, token
	h.mu.Unlock()
}

// setPins replaces the /v1/pins list.
func (h *opsHub) setPins(pins ...wire.PinEntry) {
	h.mu.Lock()
	h.pins = pins
	h.mu.Unlock()
}

// putFile stores raw as a hub-side blob and returns its file id.
func (h *opsHub) putFile(raw []byte) string {
	id := blobID(raw)
	h.mu.Lock()
	h.files[id] = raw
	h.mu.Unlock()
	return id
}

func blobID(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// frames are the client frames of type typ the hub has read, oldest first.
func (h *opsHub) frames(typ string) []wire.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []wire.Frame
	for _, f := range h.got {
		if f.Type == typ {
			out = append(out, f)
		}
	}
	return out
}

// echo is the answer object of a request op: {"op":"<op>"}.
func echo(op string) json.RawMessage { return json.RawMessage(`{"op":"` + op + `"}`) }

// opsReply answers each request frame the way the hub does: the same type and
// msg_id, the answer object under the frame's own field.
func opsReply(f wire.Frame) []wire.Frame {
	out := wire.Frame{Type: f.Type, MsgID: f.MsgID}
	switch f.Type {
	case wire.TAsk:
		out.Ask = echo(f.AskOp)
	case wire.TClaim:
		out.Claim = echo(f.ClaimOp)
	case wire.TLane:
		out.Lane = echo(f.LaneOp)
	case wire.TLease:
		out.Lease = echo(f.LeaseOp)
	case wire.TMove:
		out.Move = echo(f.MoveTo)
	case wire.TReact:
		out.Reaction = echo(f.ReactOp)
	case wire.TArchive:
		out.Archive = echo(f.ArchiveOp)
	case wire.TIssue:
		out.Issue = echo(f.IssueOp)
	case wire.TSend:
		out = wire.Frame{Type: wire.TSent, MsgID: wire.InnerMsgID(f.Env), Delivery: wire.DeliverySent}
	case wire.TToken:
		out.UploadToken, out.UploadTokenExpiresAt = "tok-new", time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	default:
		return nil // commit, announce: recorded only
	}
	return []wire.Frame{out}
}

// opsClient is testClient wired to h, hosting agents c-007 and c-008.
func opsClient(t *testing.T, h *opsHub) *Client {
	t.Helper()
	c := testClient(t)
	c.Cfg.HubURL = h.start(t)
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = "off"
	c.ReadyTimeout = 5 * time.Second
	c.KeepAlive = -1
	for _, a := range []string{"c-007", "c-008"} {
		if err := os.MkdirAll(filepath.Join(c.Cfg.SpoolRoot, a, "inbox"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return c
}

// peer is another box's keypair and its /v1/pins entry.
type peer struct {
	box  string
	priv ed25519.PrivateKey
	pin  wire.PinEntry
}

func newPeer(t *testing.T, box string) peer {
	t.Helper()
	dir := t.TempDir()
	pub, err := sign.GenerateKey(dir, box, false)
	if err != nil {
		t.Fatal(err)
	}
	priv, err := sign.LoadPrivate(dir, box)
	if err != nil {
		t.Fatal(err)
	}
	return peer{box: box, priv: priv, pin: wire.PinEntry{BoxID: box, PubKey: pub}}
}

// note is a v:1 message from -> to of kind.
func note(from, to, kind, body string) *msg.Message {
	return &msg.Message{V: msg.V1, MsgID: uid.New(), TaskID: uid.New(), TS: time.Now().UTC().Format(time.RFC3339),
		From: from, To: to, Kind: kind, Body: body}
}

// envRaw signs m from p to toBox, tagged channel ("" = a DM).
func envRaw(t *testing.T, p peer, toBox, channel string, m *msg.Message) []byte {
	t.Helper()
	e, err := wire.NewEnvelopeIn(p.priv, p.box, toBox, channel, "", m)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := e.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
