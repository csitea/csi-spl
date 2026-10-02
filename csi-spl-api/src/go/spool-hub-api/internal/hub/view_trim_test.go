package hub

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// DB payload cut 4: what the view leaves out of a message, and what it keeps.
func TestViewMsgsTrim(t *testing.T) {
	const topic = "11111111-1111-4111-8111-111111111111"
	env := `{"from_box":"box-wui","msg":{"body":"a <b> & c","files":[],"from":"HUM-1","kind":"msg","msg_id":"m1","task_id":"` +
		topic + `","to":"@lobby","ts":"2026-10-02T00:00:00Z","v":1},"sig":"c2ln","to_box":"box-wui"}`
	at := time.Unix(1_800_000_000, 0)
	rows := []store.ViewMsg{
		{MsgID: "m1", ReceivedAt: at, Env: []byte(env), Deliveries: []store.ViewDelivery{{ToBox: WUIBox, State: store.StateSent}}},
		{MsgID: "m2", ReceivedAt: at, Env: []byte(strings.Replace(env, `"files":[]`, `"files":[{"file_id":"f"}]`, 1)),
			Deliveries: []store.ViewDelivery{{ToBox: WUIBox, State: store.StateQueued}}},
		{MsgID: "m3", ReceivedAt: at, Env: []byte(env)},
	}
	react := map[string][]store.StoredReaction{"m2": {{Emoji: "👍", Actor: "HUM-2"}}}
	b, err := json.Marshal(viewMsgsIn(rows, react, topic))
	if err != nil {
		t.Fatal(err)
	}
	var got []map[string]json.RawMessage
	if err := json.Unmarshal(b, &got); err != nil || len(got) != 3 {
		t.Fatalf("%v %s", err, b)
	}
	m1 := string(got[0]["env"])
	for _, gone := range []string{`"sig"`, `"files"`, `"task_id"`} {
		if strings.Contains(m1, gone) {
			t.Errorf("m1 env still carries %s: %s", gone, m1)
		}
	}
	var e1 struct {
		Msg struct {
			Body  string `json:"body"`
			MsgID string `json:"msg_id"`
		} `json:"msg"`
	}
	if json.Unmarshal(got[0]["env"], &e1) != nil || e1.Msg.Body != "a <b> & c" || e1.Msg.MsgID != "m1" {
		t.Errorf("m1 env lost its body: %s", m1)
	}
	if _, ok := got[0]["deliveries"]; ok {
		t.Errorf("m1 sent the default [box-wui sent]: %s", b)
	}
	if _, ok := got[0]["reactions"]; ok {
		t.Errorf("m1 sent empty reactions: %s", b)
	}
	if !strings.Contains(string(got[1]["env"]), `"files":[{"file_id":"f"}]`) || string(got[1]["deliveries"]) != `[{"to_box":"box-wui","state":"queued"}]` ||
		!strings.Contains(string(got[1]["reactions"]), "HUM-2") {
		t.Errorf("m2 lost a non-default field: %s", b)
	}
	if string(got[2]["deliveries"]) != `[]` {
		t.Errorf("m3: no delivery at all must stay [], got %s", got[2]["deliveries"])
	}
	// outside one topic (archive cards) the task_id stays
	if out, _ := json.Marshal(viewMsgs(rows[:1], nil)); !strings.Contains(string(out), `"task_id":"`+topic+`"`) {
		t.Errorf("viewMsgs dropped task_id: %s", out)
	}
	// another topic's task_id stays
	if out, _ := json.Marshal(viewMsgsIn(rows[:1], nil, "other")); !strings.Contains(string(out), `"task_id":"`+topic+`"`) {
		t.Errorf("foreign task_id dropped: %s", out)
	}
	// an envelope that is not JSON passes through
	if got := string(trimEnv([]byte("x"), topic)); got != "x" {
		t.Errorf("bad env = %q", got)
	}
}
