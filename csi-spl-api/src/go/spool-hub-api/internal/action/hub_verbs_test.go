package action

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r6-06: the hub-mode verbs (send, archive, ask, claim) against a fake hub,
// their refusals before any dial, and the exit-code map.

// verbHub is a fake hub for one-shot role=cli sessions: challenge, welcome,
// then one answer per frame. A send whose answers is "taken" or "moved" is
// refused with that token; an archive of refuseTask is refused; archive, ask
// and claim echo what they received.
type verbHub struct {
	url    string
	mu     sync.Mutex
	frames []wire.Frame
}

const refuseTask = "00000000-0000-4000-8000-000000000000"

func newVerbHub(t *testing.T) *verbHub {
	t.Helper()
	h := &verbHub{}
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
			if wsjson.Write(ctx, conn, h.answer(f)) != nil {
				return
			}
		}
	}))
	t.Cleanup(srv.Close)
	h.url = srv.URL
	return h
}

func (h *verbHub) answer(f wire.Frame) wire.Frame {
	echo := func(v any) json.RawMessage { b, _ := json.Marshal(v); return b }
	switch f.Type {
	case wire.TSend:
		switch f.Answers {
		case "taken":
			return wire.Frame{Type: wire.TError, Error: wire.TokenAnswered, Status: http.StatusConflict}
		case "moved":
			return wire.Frame{Type: wire.TError, Error: wire.TokenNotResponsible, Status: http.StatusConflict}
		}
		return wire.Frame{Type: wire.TSent, MsgID: wire.InnerMsgID(f.Env), Delivery: wire.DeliverySent}
	case wire.TArchive:
		if f.TaskID == refuseTask {
			return wire.Frame{Type: wire.TError, Error: "not_found", Status: http.StatusNotFound, Detail: "no such topic"}
		}
		return wire.Frame{Type: wire.TArchive, MsgID: f.MsgID, Archive: echo(map[string]string{"task_id": f.TaskID, "op": f.ArchiveOp, "as": f.As})}
	case wire.TAsk:
		return wire.Frame{Type: wire.TAsk, MsgID: f.MsgID, Ask: echo(map[string]any{"op": f.AskOp, "fleet": f.Fleet, "body": f.Ask})}
	case wire.TClaim:
		return wire.Frame{Type: wire.TClaim, MsgID: f.MsgID, Claim: echo(map[string]any{"op": f.ClaimOp, "body": f.Claim})}
	}
	return wire.Frame{Type: wire.TError, Error: "unexpected_frame"}
}

func (h *verbHub) last(t *testing.T) wire.Frame {
	t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.frames) == 0 {
		t.Fatal("the hub received no frame")
	}
	return h.frames[len(h.frames)-1]
}

// hubCfg is a box config wired to h: its keypair, tenant t1, no sidecar.
func hubCfg(t *testing.T, h *verbHub) *config.Config {
	t.Helper()
	cfg := testkit.NewConfig(t)
	if _, err := sign.GenerateKey(cfg.KeysDir, "box-a", false); err != nil {
		t.Fatal(err)
	}
	cfg.HubURL, cfg.BoxID, cfg.Tenant, cfg.SubmitSocket = h.url, "box-a", "t1", "off"
	testkit.Agents(t, cfg, "CLE-1")
	return cfg
}

const askID = "11111111-2222-4333-8444-555555555555"

func TestSendHub(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	ctx := context.Background()
	cases := []struct {
		name  string
		in    SendArgs
		check func(t *testing.T, f wire.Frame)
	}{
		{"dm with claims", SendArgs{From: "CLE-1", To: "CLE-2", ToBox: "box-b", Kind: "note", Body: "hi", TypedBy: "HUM-1", Ref: askID},
			func(t *testing.T, f wire.Frame) {
				if f.TypedBy != "HUM-1" || f.RefTaskID != askID {
					t.Errorf("frame claims %q %q", f.TypedBy, f.RefTaskID)
				}
			}},
		{"channel post", SendArgs{From: "CLE-1", Channel: "#Ops", Body: "all"},
			func(t *testing.T, f wire.Frame) {
				if !strings.Contains(string(f.Env), `"ops"`) || !strings.Contains(string(f.Env), Broadcast) {
					t.Errorf("envelope %s: want channel ops to %s", f.Env, Broadcast)
				}
			}},
		{"answer", SendArgs{From: "CLE-1", To: "CLE-2", ToBox: "box-b", Kind: "result", Body: "done", Answers: askID, IfGen: 3},
			func(t *testing.T, f wire.Frame) {
				if f.Answers != askID || f.IfGen != 3 {
					t.Errorf("frame answers %q gen %d", f.Answers, f.IfGen)
				}
			}},
		{"injected client", SendArgs{From: "CLE-1", To: "CLE-2", ToBox: "box-b", Kind: "note", Body: "x", Hub: hubclient.New(cfg)},
			func(t *testing.T, f wire.Frame) {}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			res, err := SendCtx(ctx, cfg, c.in)
			if err != nil {
				t.Fatal(err)
			}
			f := h.last(t)
			if res.Delivery != wire.DeliverySent || res.MsgID == "" || res.MsgID != wire.InnerMsgID(f.Env) || res.TaskID == "" {
				t.Fatalf("result %+v, frame msg %s", res, wire.InnerMsgID(f.Env))
			}
			c.check(t, f)
		})
	}
}

// TestSendHubRefused: the hub's two answer refusals map to their exit codes.
func TestSendHubRefused(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	for _, c := range []struct {
		answers string
		code    int
	}{{"taken", ExitAnswered}, {"moved", ExitNotResponsible}} {
		// the fake keys its refusal on the answers value
		_, err := sendHub(context.Background(), cfg, SendArgs{From: "CLE-1", To: "CLE-2", ToBox: "box-b", Kind: "note", Body: "b", Answers: c.answers}, nil)
		if err == nil || ExitCode(err) != c.code {
			t.Errorf("%s: err %v code %d, want %d", c.answers, err, ExitCode(err), c.code)
		}
	}
}

// TestSendHubComposeRefused: a message spool cannot compose never dials.
func TestSendHubComposeRefused(t *testing.T) {
	cfg := testkit.NewConfig(t)
	cfg.HubURL = "http://127.0.0.1:1"
	_, err := sendHub(context.Background(), cfg, SendArgs{From: "not an id", To: "CLE-2"}, nil)
	if err == nil || !strings.Contains(err.Error(), "from/to must be valid agent ids") {
		t.Fatalf("got %v", err)
	}
}

func TestExitCode(t *testing.T) {
	for _, c := range []struct {
		name string
		err  error
		want int
	}{
		{"nil", nil, 0},
		{"hash mismatch", fmt.Errorf("get: %w", files.ErrHashMismatch), 78},
		{"answered", &hubclient.HubError{Token: wire.TokenAnswered, Status: 409}, ExitAnswered},
		{"not responsible", fmt.Errorf("send: %w", &hubclient.HubError{Token: wire.TokenNotResponsible}), ExitNotResponsible},
		{"other hub refusal", &hubclient.HubError{Token: "not_found", Status: 404}, 1},
		{"verify refusal", sign.ErrVerify, 78},
		{"plain", errors.New("boom"), 1},
	} {
		if got := ExitCode(c.err); got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
}

func TestGet(t *testing.T) {
	cfg := testkit.NewConfig(t)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("alpha"), 0o644); err != nil {
		t.Fatal(err)
	}
	fileBlob, err := Put(cfg, filepath.Join(dir, "a.txt"), false)
	if err != nil {
		t.Fatal(err)
	}
	dirBlob, err := Put(cfg, dir, true)
	if err != nil || dirBlob.Kind != "dir" {
		t.Fatalf("put dir %+v %v", dirBlob, err)
	}
	out := t.TempDir()
	for _, c := range []struct {
		name, id, dest string
		dir            bool
		read           string // file under dest (or dest itself) that must read "alpha"
	}{
		{"file", fileBlob.FileID, filepath.Join(out, "f.txt"), false, filepath.Join(out, "f.txt")},
		{"dir", dirBlob.FileID, filepath.Join(out, "d"), true, filepath.Join(out, "d", "a.txt")},
	} {
		res, err := Get(cfg, c.id, c.dest, c.dir)
		if err != nil || res != (GetResult{FileID: c.id, Path: c.dest}) {
			t.Fatalf("%s: %+v %v", c.name, res, err)
		}
		if b, err := os.ReadFile(c.read); err != nil || string(b) != "alpha" {
			t.Errorf("%s: %q %v", c.name, b, err)
		}
	}
	if res, err := Get(cfg, strings.Repeat("a", 64), filepath.Join(out, "none"), false); err == nil || res != (GetResult{}) {
		t.Errorf("absent blob: %+v %v", res, err)
	}
}

func TestArchive(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	ctx := context.Background()
	for _, c := range []struct {
		name string
		cfg  *config.Config
		in   ArchiveArgs
		want string // error substring; "" = ok
		op   string
	}{
		{"no hub", testkit.NewConfig(t), ArchiveArgs{TaskID: askID, As: "CLE-1"}, "needs hub mode", ""},
		{"bad task", cfg, ArchiveArgs{TaskID: "nope", As: "CLE-1"}, "--task must be the topic's task UUID", ""},
		{"bad as", cfg, ArchiveArgs{TaskID: askID, As: "bad id"}, "--as (the acting agent id) is required", ""},
		{"archive, upper-case task", cfg, ArchiveArgs{TaskID: strings.ToUpper(askID), As: "CLE-1"}, "", "archive"},
		{"unarchive, injected client", cfg, ArchiveArgs{TaskID: askID, As: "CLE-1", Unarchive: true, Hub: hubclient.New(cfg)}, "", "unarchive"},
		{"hub refusal", cfg, ArchiveArgs{TaskID: refuseTask, As: "CLE-1"}, "hub refused: not_found", ""},
	} {
		raw, err := Archive(ctx, c.cfg, c.in)
		if c.want != "" {
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("%s: %v, want %q", c.name, err, c.want)
			}
			continue
		}
		var got map[string]string
		if err != nil || json.Unmarshal(raw, &got) != nil {
			t.Fatalf("%s: %s %v", c.name, raw, err)
		}
		if got["task_id"] != askID || got["op"] != c.op || got["as"] != "CLE-1" {
			t.Errorf("%s: hub saw %v", c.name, got)
		}
	}
}

// askEcho is the fake hub's echo of an ask or claim frame.
type askEcho struct {
	Op    string                     `json:"op"`
	Fleet string                     `json:"fleet"`
	Body  map[string]json.RawMessage `json:"body"`
}

func TestAsk(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	put := AskArgs{Fleet: "csi", Op: "put", AskID: askID, Kind: "blocker", From: "c-004@sat", Topic: "dispatch-1", Summary: "one line"}
	with := func(f func(*AskArgs)) AskArgs { a := put; f(&a); return a }
	cases := []struct {
		name string
		cfg  *config.Config
		in   AskArgs
		want string // error substring; "" = ok
		op   string
		body map[string]string // body fields the hub must see (JSON text)
	}{
		{"no hub", testkit.NewConfig(t), AskArgs{Fleet: "csi"}, "asks need hub mode", "", nil},
		{"bad fleet", cfg, AskArgs{Fleet: "CSI"}, "--fleet must be a lowercase slug", "", nil},
		{"default op is list", cfg, AskArgs{Fleet: "csi", Role: "dispatch", All: true}, "", "list", map[string]string{"role": `"dispatch"`, "all": "true"}},
		{"put defaults role orch", cfg, put, "", "put", map[string]string{"role": `"orch"`, "ask_id": `"` + askID + `"`, "kind": `"blocker"`}},
		{"put with deadline", cfg, with(func(a *AskArgs) { a.Deadline = "2026-10-02T06:00:00Z" }), "", "put", map[string]string{"deadline_at": `"2026-10-02T06:00:00Z"`}},
		{"put bad deadline", cfg, with(func(a *AskArgs) { a.Deadline = "tomorrow" }), "--deadline must be RFC 3339", "", nil},
		{"put bad kind", cfg, with(func(a *AskArgs) { a.Kind = "chat" }), "ask: kind must be blocker, task or escalation", "", nil},
		{"ack", cfg, AskArgs{Fleet: "csi", Op: "ack", AskID: askID, By: "c-001@sat", Hub: hubclient.New(cfg)}, "", "ack", map[string]string{"by": `"c-001@sat"`}},
		{"decline needs a reason", cfg, AskArgs{Fleet: "csi", Op: "decline", AskID: askID, By: "c-001"}, "ask: a decline needs a reason", "", nil},
		{"unknown op", cfg, AskArgs{Fleet: "csi", Op: "shout", AskID: askID, By: "c-001"}, "ask: ask_op must be", "", nil},
		{"bad ask id", cfg, AskArgs{Fleet: "csi", Op: "done", AskID: "X", By: "c-001"}, "ask: --id must be the ask's id", "", nil},
	}
	for _, c := range cases {
		raw, err := Ask(context.Background(), c.cfg, c.in)
		if c.want != "" {
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("%s: %v, want %q", c.name, err, c.want)
			}
			continue
		}
		var got askEcho
		if err != nil || json.Unmarshal(raw, &got) != nil {
			t.Fatalf("%s: %s %v", c.name, raw, err)
		}
		if got.Op != c.op || got.Fleet != "csi" {
			t.Errorf("%s: op %q fleet %q", c.name, got.Op, got.Fleet)
		}
		for k, v := range c.body {
			if string(got.Body[k]) != v {
				t.Errorf("%s: body %s = %s, want %s", c.name, k, got.Body[k], v)
			}
		}
	}
}

func TestClaim(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	seat := func(op string) ClaimArgs { return ClaimArgs{Op: op, Seat: "c-001@sat", MsgID: askID, Gen: 2} }
	with := func(a ClaimArgs, f func(*ClaimArgs)) ClaimArgs { f(&a); return a }
	cases := []struct {
		name string
		cfg  *config.Config
		in   ClaimArgs
		want string // error substring; "" = ok
		body map[string]string
	}{
		{"no hub", testkit.NewConfig(t), seat("poll"), "claims need hub mode", nil},
		{"no seat", cfg, ClaimArgs{Op: "poll"}, "claim: --as must name the seat", nil},
		{"ttl too short", cfg, with(seat("poll"), func(a *ClaimArgs) { a.TTLS = 5 }), "claim: --ttl must be 10..600", nil},
		{"poll", cfg, with(seat("poll"), func(a *ClaimArgs) { a.Max, a.State, a.TTLS = 3, "idle", 60 }), "", map[string]string{"max": "3", "state": `"idle"`, "ttl_s": "60"}},
		{"poll max over", cfg, with(seat("poll"), func(a *ClaimArgs) { a.Max = 51 }), "claim: --max must be 1..50", nil},
		{"poll bad state", cfg, with(seat("poll"), func(a *ClaimArgs) { a.State = "asleep" }), "claim: --state must be idle or busy", nil},
		{"renew plain", cfg, seat("renew"), "", map[string]string{"seat": `"c-001@sat"`}},
		{"renew fresh", cfg, with(seat("renew"), func(a *ClaimArgs) { a.HB, a.AnchorAgeS = "fresh", 7 }), "", map[string]string{"fresh": "true", "able": "true", "anchor_age_s": "7"}},
		{"renew able", cfg, with(seat("renew"), func(a *ClaimArgs) { a.HB = "able" }), "", map[string]string{"fresh": "false", "able": "true"}},
		{"renew stale", cfg, with(seat("renew"), func(a *ClaimArgs) { a.HB = "stale" }), "", map[string]string{"fresh": "false", "able": "false"}},
		{"renew bad hb", cfg, with(seat("renew"), func(a *ClaimArgs) { a.HB = "warm" }), "claim: --hb must be fresh, able or stale", nil},
		{"renew negative anchor", cfg, with(seat("renew"), func(a *ClaimArgs) { a.HB, a.AnchorAgeS = "fresh", -1 }), "claim: --anchor-age must be >= 0", nil},
		{"accept", cfg, with(seat("accept"), func(a *ClaimArgs) { a.Round = 1 }), "", map[string]string{"round": "1"}},
		{"accept no round", cfg, seat("accept"), "claim: --accept needs --round", nil},
		{"accept bad msg", cfg, with(seat("accept"), func(a *ClaimArgs) { a.MsgID = "x" }), "claim: --accept needs the message id", nil},
		{"park", cfg, with(seat("park"), func(a *ClaimArgs) { a.Until, a.Wait, a.Reason = "10m", "lane", "waits on c-002" }), "", map[string]string{"wait": `"lane"`}},
		{"park missing until", cfg, with(seat("park"), func(a *ClaimArgs) { a.Wait, a.Reason = "lane", "r" }), "claim: --park needs --until", nil},
		{"touch no gen", cfg, with(seat("touch"), func(a *ClaimArgs) { a.Gen = 0 }), "claim: --touch needs --gen", nil},
		{"check", cfg, seat("check"), "", map[string]string{"gen": "2"}},
		{"check no gen", cfg, with(seat("check"), func(a *ClaimArgs) { a.Gen = 0 }), "claim: --check needs --gen", nil},
		{"adopt bad msg", cfg, with(seat("adopt"), func(a *ClaimArgs) { a.MsgID = "" }), "claim: --adopt needs --msg", nil},
		{"release", cfg, with(seat("release"), func(a *ClaimArgs) { a.Reason = "send-failed" }), "", map[string]string{"reason": `"send-failed"`}},
		{"release no reason", cfg, seat("release"), "claim: --reason:", nil},
		{"done defaults answered", cfg, with(seat("done"), func(a *ClaimArgs) { a.Hub = hubclient.New(cfg) }), "", map[string]string{"how": `"answered"`}},
		{"done bad how", cfg, with(seat("done"), func(a *ClaimArgs) { a.How = "ignored" }), "claim: --how:", nil},
		{"done bad msg", cfg, with(seat("done"), func(a *ClaimArgs) { a.MsgID = "x" }), "claim: --done needs the message id", nil},
		{"unknown op", cfg, seat("steal"), "claim: one of --poll", nil},
	}
	for _, c := range cases {
		raw, err := Claim(context.Background(), c.cfg, c.in)
		if c.want != "" {
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("%s: %v, want %q", c.name, err, c.want)
			}
			continue
		}
		var got askEcho
		if err != nil || json.Unmarshal(raw, &got) != nil {
			t.Fatalf("%s: %s %v", c.name, raw, err)
		}
		if got.Op != c.in.Op {
			t.Errorf("%s: op %q", c.name, got.Op)
		}
		for k, v := range c.body {
			if string(got.Body[k]) != v {
				t.Errorf("%s: body %s = %s, want %s", c.name, k, got.Body[k], v)
			}
		}
	}
}

func TestClaimFlat(t *testing.T) {
	raw := json.RawMessage(`{"msgs":[{"msg_id":"m1","responsible_gen":2,"from":"stale","msg":{"from":"CLE-1","body":"hi","task_id":"t"}}],
		"dead":[{"msg_id":"m2","from":"CLE-9"}]}`)
	out, err := ClaimFlat(raw)
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if err := json.Unmarshal(out, &rows); err != nil || len(rows) != 2 {
		t.Fatalf("%s %v", out, err)
	}
	if rows[0]["from"] != "CLE-1" || rows[0]["body"] != "hi" || rows[0]["msg_id"] != "m1" || rows[0]["dead"] != nil || rows[0]["msg"] != nil {
		t.Errorf("live row %v", rows[0])
	}
	if rows[1]["from"] != "CLE-9" || rows[1]["dead"] != true {
		t.Errorf("dead row %v", rows[1])
	}
	if _, err := ClaimFlat(json.RawMessage(`[`)); err == nil || !strings.Contains(err.Error(), "does not decode") {
		t.Errorf("bad answer: %v", err)
	}
}
