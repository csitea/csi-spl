package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// HUM-10 (topic cd357c76): POST /v1/view/ids resolves the ids quoted in one
// body, with a topic read's door. Every refusal is paired with the same id
// read by someone who may read it.

func viewIDs(t *testing.T, r privacyRig, as string, ids ...string) (int, map[string]map[string]any) {
	t.Helper()
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/view/ids", as, map[string]any{"ids": ids})
	got := map[string]map[string]any{}
	rows, _ := out["ids"].([]any)
	for _, row := range rows {
		if m, ok := row.(map[string]any); ok {
			got[m["id"].(string)] = m
		}
	}
	return code, got
}

// putReply stores a reply under parent in channel.
func putReply(t *testing.T, r privacyRig, parent, channel, from, to string, at time.Time) store.Message {
	t.Helper()
	m := putRowWith(t, r, uuidV4(), channel, from, to, at, func(m *store.Message) { m.ParentTaskID = parent; m.IsParent = 0 })
	return m
}

func putRowWith(t *testing.T, r privacyRig, task, channel, from, to string, at time.Time, mut func(*store.Message)) store.Message {
	t.Helper()
	inner := `{"v":1,"msg_id":"` + uuidV4() + `","task_id":"` + task + `","from":"` + from +
		`","to":"` + to + `","kind":"note","body":"x","files":[]}`
	m := store.Message{TenantID: r.tid, MsgID: uuidV4(), TaskID: task, Channel: channel, TS: at, IsParent: 1,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: to, Kind: "note", Body: "x",
		Files: []byte("[]"), Msg: []byte(inner), Env: []byte(`{"msg":` + inner + `,"sig":""}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	mut(&m)
	if _, err := r.e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestViewIDsDoor(t *testing.T) {
	r := newPrivacyRig(t)
	now := time.Now().UTC().Truncate(time.Microsecond)
	privMsg := putRowWith(t, r, r.priv, "live-proof", "HUM-1", "CLE-07", now.Add(3*time.Second), func(*store.Message) {})
	dmMsg := putRowWith(t, r, r.dm, "", "HUM-1", "CLE-07", now.Add(4*time.Second), func(*store.Message) {})
	ids := []string{r.priv, r.dm, r.public, privMsg.MsgID, dmMsg.MsgID}

	code, mine := viewIDs(t, r, "HUM-1", ids...)
	if code != http.StatusOK || len(mine) != len(ids) {
		t.Fatalf("CONTROL: HUM-1 resolves %d of %d (%d): %v", len(mine), len(ids), code, mine)
	}
	for _, tc := range []struct{ id, kind, task, channel, peer string }{
		{r.priv, "topic", r.priv, "live-proof", ""},
		{r.dm, "topic", r.dm, "", "CLE-07@box-wui"},
		{r.public, "topic", r.public, "lobby", ""},
		{privMsg.MsgID, "message", r.priv, "live-proof", ""},
		{dmMsg.MsgID, "message", r.dm, "", "CLE-07@box-wui"},
	} {
		h := mine[tc.id]
		if h["kind"] != tc.kind || h["task_id"] != tc.task || str(h["channel"]) != tc.channel || str(h["peer"]) != tc.peer || h["archived"] != false {
			t.Errorf("%s: got %v, want kind=%s task=%s channel=%q peer=%q", tc.id, h, tc.kind, tc.task, tc.channel, tc.peer)
		}
	}
	// HUM-2 is in neither the private channel nor the DM: only #lobby.
	_, theirs := viewIDs(t, r, "HUM-2", ids...)
	if len(theirs) != 1 || theirs[r.public] == nil {
		t.Fatalf("LEAK: HUM-2 resolves %v, want only the lobby topic", theirs)
	}
}

func TestViewIDsReplyArchivedShort(t *testing.T) {
	r := newPrivacyRig(t)
	now := time.Now().UTC().Truncate(time.Microsecond)
	reply := putReply(t, r, r.public, "lobby", "HUM-2", "HUM-1", now.Add(3*time.Second))
	gone := uuidV4()
	card := putRowWith(t, r, gone, "lobby", "HUM-1", "HUM-1", now.Add(4*time.Second), func(*store.Message) {})
	if _, err := r.e.st.(store.TopicArchive).SetArchived(context.Background(), r.tid, card.MsgID, "HUM-1", now, true); err != nil {
		t.Fatal(err)
	}
	unknown := uuidV4()
	short := r.public[:8]
	_, got := viewIDs(t, r, "HUM-1", reply.MsgID, gone, card.MsgID, unknown, strings.ToUpper(short))
	if h := got[reply.MsgID]; h["kind"] != "message" || h["task_id"] != r.public || h["msg_id"] != reply.MsgID || h["channel"] != "lobby" {
		t.Errorf("reply: %v, want a message under its parent topic", h)
	}
	if h := got[gone]; h["kind"] != "topic" || h["archived"] != true {
		t.Errorf("archived topic: %v, want an archived topic", h)
	}
	if h := got[card.MsgID]; h["kind"] != "message" || h["archived"] != true {
		t.Errorf("archived card: %v, want an archived message", h)
	}
	if got[unknown] != nil {
		t.Errorf("unknown id answered: %v", got[unknown])
	}
	if h := got[short]; h["kind"] != "topic" || h["task_id"] != r.public {
		t.Errorf("short %s: %v, want the lobby topic %s", short, h, r.public)
	}
	// A topic id stays a topic when a message carries the same string.
	twin := putRowWith(t, r, uuidV4(), "lobby", "HUM-1", "HUM-1", now.Add(5*time.Second), func(m *store.Message) { m.MsgID = r.priv })
	_, got = viewIDs(t, r, "HUM-1", twin.MsgID)
	if h := got[r.priv]; h["kind"] != "topic" || h["channel"] != "live-proof" {
		t.Errorf("topic id shared by a message: %v, want the topic", h)
	}
}

func TestViewIDsRefusals(t *testing.T) {
	r := newPrivacyRig(t)
	if code, _ := viewIDs(t, r, "HUM-1", "not-an-id"); code != http.StatusBadRequest {
		t.Errorf("bad id: %d, want 400", code)
	}
	many := make([]string, 51)
	for i := range many {
		many[i] = uuidV4()
	}
	if code, _ := viewIDs(t, r, "HUM-1", many...); code != http.StatusBadRequest {
		t.Errorf("51 ids: %d, want 400", code)
	}
	if code, got := viewIDs(t, r, "HUM-1", many[:50]...); code != http.StatusOK || len(got) != 0 {
		t.Errorf("CONTROL: 50 unknown ids: %d %v, want 200 and none", code, got)
	}
	if code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/view/ids", "HUM-1", nil); code == http.StatusOK {
		t.Errorf("GET /v1/view/ids answered 200: %v", out)
	}
}

func str(v any) string {
	s, _ := v.(string)
	return s
}
