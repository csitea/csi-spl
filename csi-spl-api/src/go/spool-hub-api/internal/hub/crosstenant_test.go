package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Cross-tenant suite, hub half (specs/017 FR-SEC-015, CLE-3416). One suite:
// every test is TestCrossTenant*, CLE-3415's tenant-from-identity tests
// (crosstenant_identity_test.go: B's Host, ?tenant=B, X-Spool-Tenant: B)
// included; hub-pg.tst.sh runs them against Postgres and requires every one
// to PASS. The store half (every tenant table, every scoped store read) is
// internal/store crosstenant_test.go.
//
// This file covers B's IDS on A's own tenant: a member of A, on the api host
// and on A's host, names B's task, message, file, channel and box ids in
// every read and write path. Every answer is refused, empty or 404, never a
// byte of B's data (the marker below), and B's rows are unchanged after.

// crossB is tenant B with data in every place a path can name.
type crossB struct {
	tenant, marker, taskID, msgID, fileID, channel, owner string
	b1                                                    *box
}

func seedCrossB(t *testing.T, e *env) crossB {
	t.Helper()
	ctx := context.Background()
	b := crossB{}
	b.tenant, _ = e.tenant()
	b.marker = "bsecret" + b.tenant
	b.owner = ownedBy(t, e, b.tenant, "owner-of-"+b.tenant)
	b1 := e.box(b.tenant, "box-b1", "CLE-31")
	b2 := e.box(b.tenant, "box-b2", "CLE-32")
	e.pin(b.tenant, b1)
	e.pin(b.tenant, b2)
	for _, bx := range []*box{b2, b1} {
		if _, err := bx.c.Sync(ctx); err != nil {
			t.Fatal(err)
		}
	}
	src := filepath.Join(t.TempDir(), "b.txt")
	if err := os.WriteFile(src, []byte("file of "+b.marker), 0o644); err != nil {
		t.Fatal(err)
	}
	att, err := files.PutFile(b1.cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	out := send(t, b1, "CLE-31", "CLE-32", "task", "the "+b.marker+" plan", "box-b2", att.FileID)
	b.taskID, b.msgID, b.fileID, b.b1 = out.TaskID, out.MsgID, att.FileID, b1
	b.channel = "bchan" + strings.TrimPrefix(b.tenant, "t")
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: b.tenant, ChannelID: b.channel, Name: b.channel,
		CreatedBy: "CLE-31", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	// CONTROL: B's data is really there, where the paths below look for it.
	if envs, err := e.st.TaskEnvelopes(ctx, b.tenant, b.taskID); err != nil || len(envs) != 1 || !strings.Contains(string(envs[0]), b.marker) {
		t.Fatalf("control: B's thread: %d %v", len(envs), err)
	}
	if ok, _ := (blob.Dir{Root: e.blobs}).Exists(ctx, "t/"+b.tenant+"/files/"+b.fileID); !ok {
		t.Fatal("control: B's file is not in the blob store")
	}
	return b
}

// noB fails when a response carries anything of B's. echoed are the strings
// A itself sent in that request (a search echoes its query, an error names
// the id it refused): they are cut out first, as they are A's input, not B's
// data.
func (b crossB) noB(t *testing.T, what string, code int, body string, echoed ...string) {
	t.Helper()
	for _, e := range echoed {
		body = strings.ReplaceAll(body, e, "<echo>")
	}
	for _, s := range []string{b.marker, b.taskID, b.msgID, b.fileID, b.channel, b.owner, "box-b1", "CLE-31", "CLE-32"} {
		if strings.Contains(body, s) {
			t.Errorf("%s: %d leaks B's %q: %s", what, code, s, body)
		}
	}
}

// TestCrossTenantMemberNamesBsIds: the view API, search, files and channels.
func TestCrossTenantMemberNamesBsIds(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	b := seedCrossB(t, r.e)
	if landed := r.signIn(t, a); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in to A: %s", landed)
	}
	for _, host := range []string{apiLabel, a} {
		// Positive control: the door is open for A on this host.
		if code, body := r.req(t, http.MethodGet, host, "/v1/view/threads", nil, nil); code != http.StatusOK {
			t.Fatalf("%s: A's own threads: %d %s", host, code, body)
		}
		for _, c := range []struct {
			path string
			want int // 0 = any non-2xx or a 200 with nothing of B's
		}{
			{"/v1/view/threads/" + b.taskID, http.StatusNotFound},
			{"/v1/view/threads/" + b.taskID + "/children", 0},
			{"/v1/view/threads/" + b.taskID + "?after=" + b.msgID, 0},
			{"/v1/view/threads", 0},
			{"/v1/view/threads?channel=" + b.channel, 0},
			{"/v1/view/channels", 0},
			{"/v1/view/roster", 0},
			{"/v1/view/search?q=" + url.QueryEscape(b.marker), 0},
			{"/v1/view/search?q=" + url.QueryEscape("in:"+b.channel+" plan"), 0},
			{"/v1/files/" + b.fileID, http.StatusNotFound},
		} {
			code, body := r.req(t, http.MethodGet, host, c.path, nil, nil)
			if c.want != 0 && code != c.want {
				t.Errorf("%s GET %s: %d, want %d: %s", host, c.path, code, c.want, body)
			}
			b.noB(t, host+" GET "+c.path, code, body, `"query":"`+b.marker+`"`, `"query":"in:`+b.channel+` plan"`)
		}
		// Writes naming B's ids.
		code, body := r.req(t, http.MethodDelete, host, "/v1/files/"+b.fileID, nil, nil)
		if code/100 == 2 {
			t.Errorf("%s DELETE B's file: %d %s", host, code, body)
		}
		b.noB(t, host+" DELETE file", code, body)
	}
	ctx := context.Background()
	if ok, _ := (blob.Dir{Root: r.e.blobs}).Exists(ctx, "t/"+b.tenant+"/files/"+b.fileID); !ok {
		t.Error("B's file is gone after A's DELETE")
	}
	// A channel named like B's is A's own (per-tenant ids): B still has one.
	code, body := r.req(t, http.MethodPost, apiLabel, "/v1/channels", http.Header{"Content-Type": {"application/json"}},
		strings.NewReader(`{"channel":"`+b.channel+`"}`))
	b.noB(t, "POST /v1/channels", code, strings.ReplaceAll(body, b.channel, ""))
	if ok, err := r.e.st.ChannelKnown(ctx, b.tenant, b.channel); err != nil || !ok {
		t.Errorf("B's channel after A created the same name: %v %v", ok, err)
	}
	if envs, _ := r.e.st.TaskEnvelopes(ctx, b.tenant, b.taskID); len(envs) != 1 {
		t.Errorf("B's thread holds %d message(s) after A's calls, want 1", len(envs))
	}
}

// TestCrossTenantWUISocketNamesBsIds: A's browser socket subscribes to B's
// task and channel, posts into B's task with B's msg_id and attaches B's
// file. Nothing of B's is pushed to it, nothing of A's lands in B.
func TestCrossTenantWUISocketNamesBsIds(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	b := seedCrossB(t, r.e)
	if landed := r.signIn(t, a); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in to A: %s", landed)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+apiLabel+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow() //nolint:errcheck
	var all []string   // every frame A's socket received, raw
	read := func(want string) wuiFrame {
		t.Helper()
		rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		for {
			var raw json.RawMessage
			if err := wsjson.Read(rctx, c, &raw); err != nil {
				t.Fatalf("waiting for %s: %v (frames so far: %v)", want, err, all)
			}
			all = append(all, string(raw))
			var f wuiFrame
			json.Unmarshal(raw, &f) //nolint:errcheck
			if f.Type == want {
				return f
			}
		}
	}
	w := func(v any) { wsjson.Write(ctx, c, v) } //nolint:errcheck
	w(map[string]string{"type": "hello"})
	read("welcome")

	// Subscriptions naming B.
	w(map[string]string{"type": "subscribe", "channel": b.channel})
	if f := read("error"); f.Error != "unknown_channel" {
		t.Errorf("subscribe to B's channel: %+v", f)
	}
	w(map[string]string{"type": "subscribe", "task_id": b.taskID}) // a UUID is accepted; it names A's (empty) task
	read("subscribed")
	w(map[string]any{"type": "subscribe", "all": true})
	read("subscribed")

	// B's boxes keep talking in B's task while A listens.
	if _, err := action.SendCtx(ctx, b.b1.cfg, action.SendArgs{From: "CLE-31", To: "CLE-32", TaskID: b.taskID,
		Kind: "result", Body: "more " + b.marker, ToBox: "box-b2", Hub: b.b1.c}); err != nil {
		t.Fatalf("B's second send: %v", err)
	}

	// A posts into "B's" task with B's msg_id, and attaches B's file.
	w(map[string]any{"type": "send", "task_id": b.taskID, "msg_id": b.msgID, "body": "from A"})
	ack := read("ack")
	if ack.MsgID != b.msgID {
		t.Fatalf("ack %+v", ack)
	}
	w(map[string]any{"type": "send", "task_id": "lobby", "body": "A with B's file",
		"files": []map[string]any{{"file_id": b.fileID, "name": "x.txt", "bytes": 1, "sha256": b.fileID}}})
	f := read("error")
	if f.Error == "" {
		t.Errorf("attaching B's file: %+v", f)
	}
	// Positive control last: A's own send reaches A's socket, so everything
	// the hub pushed before it has been read.
	w(map[string]any{"type": "send", "task_id": "lobby", "body": "A's own"})
	read("ack")
	// Frames echo what A sent (error details, acks, subscribed): cut those
	// ids out; B's content must not appear anywhere.
	b.noB(t, "A's WUI socket", 0, strings.Join(all, "\n"), b.taskID, b.msgID, b.fileID, b.channel)

	// B unchanged: its message is still B's, its thread has none of A's.
	envs, _ := r.e.st.TaskEnvelopes(ctx, b.tenant, b.taskID)
	for _, env := range envs {
		if strings.Contains(string(env), "from A") {
			t.Error("A's post landed in B's thread")
		}
	}
	if len(envs) == 0 || !strings.Contains(string(envs[0]), b.marker) {
		t.Errorf("B's first message changed: %d envelope(s)", len(envs))
	}
}

// TestCrossTenantBoxNamesBsIds: a box pinned to A, with A's upload token,
// names B's box, file and task. Nothing reaches B, nothing of B's comes back.
func TestCrossTenantBoxNamesBsIds(t *testing.T) {
	e := newEnv(t)
	a, _ := e.tenant()
	b := seedCrossB(t, e)
	ctx := context.Background()
	ax := e.box(a, "box-a", "GRK-41")
	e.pin(a, ax)
	if _, err := ax.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	tok := e.uploadToken(a, ax)
	// A's token on A's host: B's file id is not A's.
	if code, body := e.getFile(a, b.fileID, tok); code != http.StatusNotFound {
		t.Errorf("A's token reads B's file: %d", code)
	} else {
		b.noB(t, "A token GET B file", code, body)
	}
	// A's box sends to B's box id and agent, and into B's task id.
	before, _ := e.st.QueuedFor(ctx, b.tenant, "box-b2", time.Now())
	out, err := action.SendCtx(ctx, ax.cfg, action.SendArgs{From: "GRK-41", To: "CLE-32", ToBox: "box-b2",
		TaskID: b.taskID, Kind: "task", Body: "A to B", Hub: ax.c})
	if err == nil && out.Delivery == "sent" {
		t.Errorf("A's box delivered to B's box: %+v", out)
	}
	after, _ := e.st.QueuedFor(ctx, b.tenant, "box-b2", time.Now())
	if len(after) != len(before) {
		t.Errorf("B's box-b2 queue grew from %d to %d after A's send", len(before), len(after))
	}
	envs, _ := e.st.TaskEnvelopes(ctx, b.tenant, b.taskID)
	for _, env := range envs {
		if strings.Contains(string(env), "A to B") {
			t.Error("A's box message landed in B's thread")
		}
	}
	// A's pins listing has none of B's boxes.
	req, _ := http.NewRequest(http.MethodGet, e.url(a)+"/v1/pins", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var pins json.RawMessage
	json.NewDecoder(resp.Body).Decode(&pins) //nolint:errcheck
	resp.Body.Close()
	b.noB(t, "A's /v1/pins", resp.StatusCode, string(pins))
	// Revoking B's box id through A's tenant touches A only.
	if _, err := e.st.GetPin(ctx, b.tenant, "box-b1"); err != nil {
		t.Errorf("B's pin: %v", err)
	}
}
