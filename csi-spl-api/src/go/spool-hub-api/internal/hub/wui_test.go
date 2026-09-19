package hub_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const lobby = "00000000-0000-4000-8000-000000000001"

func wuiEnv(t *testing.T) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
	})
}

type wuiFrame struct {
	Type        string          `json:"type"`
	As          string          `json:"as"`
	LobbyTaskID string          `json:"lobby_task_id"`
	UploadToken string          `json:"upload_token"`
	TaskID      string          `json:"task_id"`
	MsgID       string          `json:"msg_id"`
	Cursor      string          `json:"cursor"`
	Error       string          `json:"error"`
	Envelope    json.RawMessage `json:"envelope"`
	Env         json.RawMessage `json:"env"`
}

type wuiClient struct {
	t *testing.T
	c *websocket.Conn
	w wuiFrame // welcome
}

func dialWUI(t *testing.T, e *env, tenant, as string) *wuiClient {
	t.Helper()
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: e.client})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })                                 //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello", "as": as}) //nolint:errcheck
	w := &wuiClient{t: t, c: c}
	w.w = w.read("welcome")
	return w
}

// read returns the next frame of type want, skipping others.
func (w *wuiClient) read(want string) wuiFrame {
	w.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f wuiFrame
		if err := wsjson.Read(ctx, w.c, &f); err != nil {
			w.t.Fatalf("waiting for %s: %v", want, err)
		}
		if f.Type == want {
			return f
		}
		if f.Type == "error" && want != "error" {
			w.t.Fatalf("waiting for %s: error %s", want, f.Error)
		}
	}
}

func (w *wuiClient) send(v any) {
	wsjson.Write(context.Background(), w.c, v) //nolint:errcheck
}

func innerOf(t *testing.T, f wuiFrame) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(f.Envelope, &m); err != nil {
		t.Fatalf("envelope: %v %s", err, f.Envelope)
	}
	return m
}

// Owner goal acceptance 1: two browser sessions exchange live in the lobby,
// and the message is stored (messages row, deliveries row sent, #general).
func TestWUITwoSessionsLobbyLive(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()

	a := dialWUI(t, e, tid, "AgentA")
	b := dialWUI(t, e, tid, "HUM-2")
	if a.w.LobbyTaskID != lobby || a.w.UploadToken == "" || a.w.As != "HUM-1" || b.w.As != "HUM-2" {
		t.Fatalf("welcome a=%+v b=%+v", a.w, b.w)
	}
	// Before the first post the lobby thread is an empty 200.
	if code, _, body := viewGet(t, e, tid, "/v1/view/threads/"+lobby); code != 200 {
		t.Fatalf("empty lobby: %d %s", code, body)
	}
	a.send(map[string]string{"type": "subscribe", "task_id": "lobby"})
	if f := a.read("subscribed"); f.TaskID != lobby {
		t.Fatalf("subscribed %+v", f)
	}
	b.send(map[string]string{"type": "subscribe", "task_id": lobby})
	b.read("subscribed")

	id := "3f2b8c1e-6a4d-4b7e-9c1a-2d3e4f5a6b7c"
	a.send(map[string]any{"type": "send", "msg_id": id, "task_id": "lobby", "kind": "chat", "body": "hello #general"})
	// The sender's own echo precedes its ack (fan-out happens at store time).
	if echo := innerOf(t, a.read("message")); echo["msg_id"] != id {
		t.Fatalf("echo %v", echo)
	}
	if ack := a.read("ack"); ack.MsgID != id || ack.Cursor == "" {
		t.Fatalf("ack %+v", ack)
	}
	got := b.read("message")
	m := innerOf(t, got)
	if got.TaskID != lobby || m["from"] != "HUM-1" || m["to"] != "ALL-0" || m["kind"] != "note" || m["body"] != "hello #general" || m["msg_id"] != id {
		t.Fatalf("B got %+v %v", got, m)
	}
	var env wire.Envelope
	json.Unmarshal(got.Env, &env) //nolint:errcheck
	if env.FromBox != hub.WUIBox || env.ToBox != hub.WUIBox || env.Sig != "" {
		t.Fatalf("env %+v", env)
	}

	envs, _ := e.st.TaskEnvelopes(ctx, tid, lobby)
	if len(envs) != 1 {
		t.Fatalf("stored %d lobby messages", len(envs))
	}
	if st, _ := e.st.DeliveryState(ctx, tid, id, hub.WUIBox); st != store.StateSent {
		t.Fatalf("delivery state %q", st)
	}
	if ch, _ := e.st.ViewChannels(ctx, tid, time.Now()); len(ch) != 1 || ch[0].Channel != store.ChannelLobby { // C3: #general is stored as lobby
		t.Fatalf("channels %+v", ch)
	}
	// Idempotent resend: acked, stored once.
	a.send(map[string]any{"type": "send", "msg_id": id, "task_id": "lobby", "body": "hello #general"})
	a.read("ack")
	if envs, _ := e.st.TaskEnvelopes(ctx, tid, lobby); len(envs) != 1 {
		t.Fatalf("resend stored twice")
	}
	// B unsubscribes: nothing more arrives for B.
	b.send(map[string]string{"type": "unsubscribe", "task_id": lobby})
	// Frames on one socket are handled in order: once B's next request is
	// answered, the unsubscribe has been applied (no race with A's send).
	b.send(map[string]string{"type": "subscribe", "task_id": "11111111-1111-4111-8111-111111111111"})
	b.read("subscribed")
	a.send(map[string]any{"type": "send", "task_id": "lobby", "body": "second"})
	a.read("ack")
	rctx, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
	defer cancel()
	var f wuiFrame
	if err := wsjson.Read(rctx, b.c, &f); err == nil {
		t.Fatalf("unsubscribed B still got %+v", f)
	}
}

// Owner goal acceptance 2: a box agent's send to the lobby reaches a
// subscribed browser live.
func TestWUIBoxAgentToLobby(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	ctx := context.Background()
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	br := dialWUI(t, e, tid, "")
	br.send(map[string]string{"type": "subscribe", "task_id": "lobby"})
	br.read("subscribed")

	out, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: hub.BroadcastID, ToBox: hub.WUIBox,
		TaskID: lobby, Kind: "note", Body: "build is green", Hub: a.c})
	if err != nil || out.Delivery != wire.DeliverySent {
		t.Fatalf("agent lobby send: %v %+v", err, out)
	}
	m := innerOf(t, br.read("message"))
	if m["from"] != "GRK-03" || m["body"] != "build is green" {
		t.Fatalf("browser got %v", m)
	}
}

// Owner goal acceptance 3: browser file round trip, then DELETE.
func TestWUIFilesUploadDownloadDelete(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := dialWUI(t, e, tid, "HUM-1")
	b := dialWUI(t, e, tid, "HUM-2")
	b.send(map[string]string{"type": "subscribe", "task_id": "lobby"})
	b.read("subscribed")

	data := []byte("owner goal file\n")
	sum := sha256.Sum256(data)
	want := hex.EncodeToString(sum[:])
	req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/files", bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+a.w.UploadToken)
	req.Header.Set("Origin", wuiOrigin)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var up struct {
		FileID string `json:"file_id"`
	}
	json.NewDecoder(resp.Body).Decode(&up) //nolint:errcheck
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated || up.FileID != want || resp.Header.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("upload %d %+v %v", resp.StatusCode, up, resp.Header)
	}
	a.send(map[string]any{"type": "send", "task_id": "lobby", "body": "see file",
		"files": []map[string]any{{"file_id": up.FileID, "name": "notes.txt", "bytes": len(data), "sha256": up.FileID}}})
	a.read("ack")
	m := innerOf(t, b.read("message"))
	files, _ := m["files"].([]any)
	if len(files) != 1 || files[0].(map[string]any)["file_id"] != want || files[0].(map[string]any)["mode"] != "blob" {
		t.Fatalf("files in message: %v", m)
	}
	code, _, body := viewGet(t, e, tid, "/v1/files/"+want)
	got := sha256.Sum256(body)
	if code != 200 || hex.EncodeToString(got[:]) != want {
		t.Fatalf("download %d sha mismatch", code)
	}
	// An unknown file_id in a send is refused.
	a.send(map[string]any{"type": "send", "task_id": "lobby", "body": "x",
		"files": []map[string]any{{"file_id": string(bytes.Repeat([]byte("a"), 64)), "name": "x"}}})
	if f := a.read("error"); f.Error != "missing_file" {
		t.Fatalf("missing file: %+v", f)
	}

	del := func(tenant, token string) int {
		req, _ := http.NewRequest(http.MethodDelete, e.url(tenant)+"/v1/files/"+want, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		resp.Body.Close()
		return resp.StatusCode
	}
	if c := del(tid, ""); c != http.StatusUnauthorized {
		t.Fatalf("delete without token: %d", c)
	}
	if c := del(other, a.w.UploadToken); c != http.StatusUnauthorized {
		t.Fatalf("delete under another tenant: %d", c)
	}
	if c := del(tid, a.w.UploadToken); c != http.StatusNoContent {
		t.Fatalf("delete: %d", c)
	}
	if code, _, _ := viewGet(t, e, tid, "/v1/files/"+want); code != http.StatusNotFound {
		t.Fatalf("get after delete: %d", code)
	}
	if c := del(tid, a.w.UploadToken); c != http.StatusNotFound {
		t.Fatalf("second delete: %d", c)
	}
}

// Door: prd-style token door refuses the upgrade; box-wui cannot be pinned.
func TestWUIDoorAndReservedBox(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.LobbyTaskID = lobby })
	tid, root := e.tenant()
	_, resp, err := websocket.Dial(context.Background(), "ws://"+tid+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: e.client})
	if err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("token door: %v %v", err, resp)
	}
	if code, eb := e.postPin(tid, root, hub.WUIBox, e.box(tid, "box-z").pub); code != http.StatusBadRequest {
		t.Fatalf("pin box-wui: %d %+v", code, eb)
	}
}
