package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-952: PATCH /v1/messages/{msg_id}/kind. Each refusal is a control: delete
// its guard in message_kind.go and the test goes red.

// roleOf gives HUM-9 the admin role and every other human developer.
type roleOf map[string]string

func (m roleOf) Access(ctx context.Context, hum, tenant string) (rbac.Access, error) {
	if r, ok := m[hum]; ok {
		return rbac.Fixed(r).Access(ctx, hum, tenant)
	}
	return rbac.Fixed(rbac.Developer).Access(ctx, hum, tenant)
}

func (m roleOf) Roles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	return rbac.Fixed(rbac.Developer).Roles(ctx, tenant)
}

func kindEnv(t *testing.T) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = roleOf{"HUM-9": rbac.Admin}
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
}

func patchKind(t *testing.T, e *env, tid, msgID, as string, body any) (int, map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPatch, e.url(tid)+"/v1/messages/"+msgID+"/kind", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("PATCH kind: %v", err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	b, _ := io.ReadAll(resp.Body)
	json.Unmarshal(b, &out) //nolint:errcheck
	return resp.StatusCode, out
}

func storedKind(t *testing.T, e *env, tid, msgID string) string {
	t.Helper()
	m, err := e.st.GetEditable(context.Background(), tid, msgID, time.Now())
	if err != nil {
		t.Fatalf("GetEditable: %v", err)
	}
	return m.Kind
}

func kindChanges(t *testing.T, e *env, tid, msgID string) []store.KindChange {
	t.Helper()
	cs, err := e.st.KindChanges(context.Background(), tid, msgID)
	if err != nil {
		t.Fatal(err)
	}
	return cs
}

// The author sets the kind; the response, a second session's frame and a
// later read of the topic all carry it; the envelope keeps the kind it was
// sent with; the register holds the change; the same kind again is a no-op.
func TestSetMessageKindRoundTrip(t *testing.T) {
	e := kindEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	for _, c := range []*websocket.Conn{author, watcher} {
		wsjson.Write(context.Background(), c, map[string]string{"type": "subscribe", "task_id": lobby}) //nolint:errcheck
		readType(t, c, "subscribed")
	}
	id, _ := postNote(t, author, "I need your input")["msg_id"].(string)
	readType(t, watcher, "message")

	code, out := patchKind(t, e, tid, id, "HUM-1", map[string]string{"kind": "blocker"})
	if code != http.StatusOK || out["kind"] != "blocker" || out["kind_set_by"] != "HUM-1" || out["kind_set_at"] == nil {
		t.Fatalf("set kind: %d %v", code, out)
	}
	if out["edited_at"] != nil {
		t.Fatalf("a kind change is not a body edit: %v", out)
	}
	f := readType(t, watcher, "message_edited")
	if f["msg_id"] != id || f["kind"] != "blocker" {
		t.Fatalf("frame: %v", f)
	}
	if inner, _ := f["envelope"].(map[string]any); inner["kind"] != "note" {
		t.Fatalf("the signed envelope must keep its kind, got %v", inner["kind"])
	}
	if got := storedKind(t, e, tid, id); got != "blocker" {
		t.Fatalf("stored kind %q", got)
	}
	code, topic := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+lobby, "HUM-2", nil)
	rows, _ := topic["messages"].([]any)
	if code != http.StatusOK || len(rows) != 1 {
		t.Fatalf("view topic: %d %v", code, topic)
	}
	if row, _ := rows[0].(map[string]any); row["kind"] != "blocker" || row["kind_set_by"] != "HUM-1" {
		t.Fatalf("topic row: %v", row)
	}
	if cs := kindChanges(t, e, tid, id); len(cs) != 1 || cs[0].From != "note" || cs[0].To != "blocker" || cs[0].Seq != 1 {
		t.Fatalf("register: %+v", cs)
	}
	// The same kind again records nothing.
	if code, _ := patchKind(t, e, tid, id, "HUM-1", map[string]string{"kind": "blocker"}); code != http.StatusOK {
		t.Fatalf("unchanged kind: %d", code)
	}
	if cs := kindChanges(t, e, tid, id); len(cs) != 1 {
		t.Fatalf("an unchanged kind wrote a row: %+v", cs)
	}
	// A body edit afterwards keeps the override in its answer.
	if code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": "I still need it"}); code != http.StatusOK || out["kind"] != "blocker" {
		t.Fatalf("edit after kind: %d %v", code, out)
	}
}

// Another developer may not set it; an admin may (the CONTROL of the 403).
func TestSetMessageKindWho(t *testing.T) {
	e := kindEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "mine")["msg_id"].(string)

	code, out := patchKind(t, e, tid, id, "HUM-2", map[string]string{"kind": "task"})
	if code != http.StatusForbidden || out["error"] != "not_allowed" {
		t.Fatalf("a developer who is not the author: %d %v (want 403 not_allowed)", code, out)
	}
	if got := storedKind(t, e, tid, id); got != "note" {
		t.Fatalf("the refusal changed the kind: %q", got)
	}
	if code, out := patchKind(t, e, tid, id, "HUM-9", map[string]string{"kind": "task"}); code != http.StatusOK || out["kind"] != "task" {
		t.Fatalf("an admin: %d %v", code, out)
	}
}

// Bad input: an unknown kind and an unknown field are 400s; a guest is refused.
func TestSetMessageKindRefusals(t *testing.T) {
	e := kindEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "mine")["msg_id"].(string)
	if code, out := patchKind(t, e, tid, id, "HUM-1", map[string]string{"kind": "shout"}); code != http.StatusBadRequest || out["error"] != "bad_kind" {
		t.Fatalf("unknown kind: %d %v", code, out)
	}
	if code, out := patchKind(t, e, tid, id, "HUM-1", map[string]string{"kind": "task", "body": "x"}); code != http.StatusBadRequest || out["error"] != "bad_json" {
		t.Fatalf("unknown field: %d %v", code, out)
	}
	if code, _ := patchKind(t, e, tid, id, "", map[string]string{"kind": "task"}); code != http.StatusForbidden {
		t.Fatalf("a guest: %d", code)
	}
	if code, out := patchKind(t, e, tid, "00000000-0000-4000-8000-000000000000", "HUM-1", map[string]string{"kind": "task"}); code != http.StatusNotFound {
		t.Fatalf("absent message: %d %v", code, out)
	}
	if got := storedKind(t, e, tid, id); got != "note" {
		t.Fatalf("a refusal changed the kind: %q", got)
	}
}

// An agent's box-signed lobby post: the hub cannot re-sign it, yet an admin
// may set its kind (a DM stays a 404 to anyone outside it: the read door), because the kind is hub metadata and the envelope is untouched.
func TestSetMessageKindBoxSigned(t *testing.T) {
	e := kindEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Microsecond)
	m := &msg.Message{V: 1, MsgID: "21111111-2222-4333-8444-555555555555", TaskID: lobby,
		TS: now.Format(time.RFC3339), From: "CLE-7", To: "ALL-0", Kind: "blocker",
		Body: "cannot proceed", Files: []msg.Attachment{}}
	inner, err := msg.Canonical(m)
	if err != nil {
		t.Fatal(err)
	}
	env := &wire.Envelope{FromBox: "box-a", ToBox: hub.WUIBox, Msg: inner, Sig: "not-verified-here"}
	canon, err := env.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	row := store.Message{TenantID: tid, MsgID: m.MsgID, TaskID: m.TaskID, TS: now, Channel: "lobby",
		FromBox: "box-a", FromID: "CLE-7", ToBox: hub.WUIBox, ToID: "ALL-0", Kind: "blocker",
		Body: m.Body, Files: []byte(`[]`), Msg: inner, EnvSig: env.Sig, Env: canon,
		ReceivedAt: now, ExpiresAt: now.Add(24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	if code, out := patchKind(t, e, tid, m.MsgID, "HUM-1", map[string]string{"kind": "note"}); code != http.StatusForbidden {
		t.Fatalf("a developer reader: %d %v (want 403)", code, out)
	}
	code, out := patchKind(t, e, tid, m.MsgID, "HUM-9", map[string]string{"kind": "note"})
	if code != http.StatusOK || out["kind"] != "note" {
		t.Fatalf("admin on a box-signed message: %d %v", code, out)
	}
	got, err := e.st.GetEditable(context.Background(), tid, m.MsgID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Env, canon) || got.EnvSig != env.Sig {
		t.Fatal("the signed envelope changed")
	}
}
