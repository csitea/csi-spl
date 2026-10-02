package hub_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// deltaList is GET /v1/view/topics with since= (view_delta.go).
type deltaList struct {
	Topics []struct {
		TaskID   string     `json:"task_id"`
		Messages []deltaMsg `json:"messages"`
	} `json:"topics"`
	Next      *string  `json:"next"`
	Delta     *bool    `json:"delta"`
	GoneTasks []string `json:"gone_tasks"`
	GoneMsgs  []string `json:"gone_msgs"`
}

type deltaMsg struct {
	Env struct {
		Msg struct {
			MsgID string `json:"msg_id"`
		} `json:"msg"`
	} `json:"env"`
	Reactions json.RawMessage `json:"reactions"`
	EditedAt  string          `json:"edited_at"`
	raw       json.RawMessage
}

func (m *deltaMsg) UnmarshalJSON(b []byte) error {
	type plain deltaMsg
	m.raw = append(json.RawMessage{}, b...)
	return json.Unmarshal(b, (*plain)(m))
}

func (m deltaMsg) id() string { return m.Env.Msg.MsgID }

func (l deltaList) tasks() []string {
	var out []string
	for _, tp := range l.Topics {
		out = append(out, tp.TaskID)
	}
	sort.Strings(out)
	return out
}

func sorted(ids ...string) []string {
	out := append([]string{}, ids...)
	sort.Strings(out)
	return out
}

// viewCursor is hub/view.go encCursor.
func viewCursor(at time.Time, id string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(at.UTC().Format(time.RFC3339Nano) + "|" + id))
}

// R2-2: a reconnect reads only what changed after the newest message the
// browser holds - and every change made in the gap (an edit, a kind change,
// a reaction added, a reaction REMOVED, a move in, a move out, an archive)
// is in that answer or in its gone lists. On the old code since= is ignored
// (no delta flag, every topic listed), so every step below fails there. Runs
// on the memory store and, with SPOOL_TEST_PG_DSN, on Postgres: the two
// answer the same.
func TestViewTopicsSinceDelta(t *testing.T) {
	r := newDoorRig(t)
	tenant, _ := r.e.tenant()
	if landed := r.signIn(t, tenant); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()                                       //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello"}) //nolint:errcheck
	me := (&wuiClient{t: t, c: c}).read("welcome").As

	// Topics A, B, C, D in #feedback, two lines each; C's reply carries a
	// reaction from before the gap.
	task := map[string]string{}
	line := map[string][2]string{}
	for _, k := range []string{"A", "B", "C", "D"} {
		task[k] = uuid4()
		var ids [2]string
		for i := range ids {
			ids[i] = uuid4()
			channelFrame(t, c, ids[i], task[k], "feedback", fmt.Sprintf("topic %s line %d", k, i))
			time.Sleep(2 * time.Millisecond)
		}
		line[k] = ids
	}
	st := r.e.st
	before := time.Now()
	if err := st.(store.MessageReactions).AddReaction(ctx, tenant, line["C"][1], me, "👀", before); err != nil {
		t.Fatal(err)
	}
	// The browser's cursor: past every row and every stamp so far, by more
	// than the hub's 30 s skew. Every mutation below is stamped after it.
	since := viewCursor(time.Now().Add(31*time.Second), line["D"][1])
	at := time.Now().Add(time.Minute)

	read := func(query string) deltaList {
		t.Helper()
		code, _, body := r.get(t, tenant, "/v1/view/topics?channel=feedback&per_topic=50&since="+url.QueryEscape(since)+query)
		if code != http.StatusOK {
			t.Fatalf("since%s: %d %s", query, code, body)
		}
		var l deltaList
		if err := json.Unmarshal([]byte(body), &l); err != nil {
			t.Fatal(err)
		}
		if l.Delta == nil || !*l.Delta {
			t.Fatalf("since%s: not a delta: %s", query, body)
		}
		return l
	}
	rx := "&rx=" + line["C"][1] + "~1"
	want := func(step string, l deltaList, tasks ...string) {
		t.Helper()
		if got, w := l.tasks(), sorted(tasks...); strings.Join(got, ",") != strings.Join(w, ",") {
			t.Fatalf("%s: topics %v, want %v", step, got, w)
		}
	}

	// Nothing changed: no topic, and the held reaction count matches.
	want("quiet", read(rx))

	// An edit.
	ed := st.(store.MessageEdits)
	old, err := ed.GetEditable(ctx, tenant, line["A"][1], time.Now())
	if err != nil {
		t.Fatal(err)
	}
	swap := func(b []byte) []byte { return bytes.Replace(b, []byte(old.Body), []byte("edited in the gap"), 1) }
	if _, err := ed.ApplyEdit(ctx, tenant, line["A"][1], store.Edit{Body: "edited in the gap", Msg: swap(old.Msg),
		Env: swap(old.Env), EditedBy: me, EditedAt: at}); err != nil {
		t.Fatal(err)
	}
	l := read(rx)
	want("edit", l, task["A"])
	if m := l.Topics[0].Messages[0]; !bytes.Contains(m.raw, []byte("edited in the gap")) || m.EditedAt == "" {
		t.Fatalf("edit: the delta row is not the edited one: %s", m.raw)
	}

	// A kind change.
	if _, err := st.(store.MessageKinds).SetKind(ctx, tenant, line["B"][0], "blocker", me, at); err != nil {
		t.Fatal(err)
	}
	want("kind", read(rx), task["A"], task["B"])

	// A reaction added.
	if err := st.(store.MessageReactions).AddReaction(ctx, tenant, line["D"][0], me, "👍", at); err != nil {
		t.Fatal(err)
	}
	want("reaction added", read(rx), task["A"], task["B"], task["D"])

	// A reaction removed leaves no row: the held count (rx) finds it, and
	// its topic comes back without the emoji. CONTROL: without rx it is
	// not found - rx is the path.
	if err := st.(store.MessageReactions).RemoveReaction(ctx, tenant, line["C"][1], me, "👀", at); err != nil {
		t.Fatal(err)
	}
	want("reaction removed, no rx", read(""), task["A"], task["B"], task["D"])
	l = read(rx)
	want("reaction removed", l, task["A"], task["B"], task["C"], task["D"])
	for _, tp := range l.Topics {
		for _, m := range tp.Messages {
			if m.id() == line["C"][1] && bytes.Contains(m.Reactions, []byte("👀")) {
				t.Fatalf("reaction removed: still listed %s", m.Reactions)
			}
		}
	}

	// A message move within the channel: B's reply into topic A. Both
	// topics are listed (A gains it, B lost it).
	mv := st.(store.Moves)
	if _, err := mv.MoveMessage(ctx, tenant, line["B"][1], task["A"], "feedback", me, at, time.Time{}); err != nil {
		t.Fatal(err)
	}
	l = read(rx)
	found := false
	for _, tp := range l.Topics {
		for _, m := range tp.Messages {
			found = found || (tp.TaskID == task["A"] && m.id() == line["B"][1])
		}
	}
	if !found {
		t.Fatalf("move in: topic A does not carry the moved row: %+v", l.Topics)
	}

	// A topic move out of the channel: its rows are gone from #feedback,
	// and #lobby's delta lists the topic.
	if _, err := mv.MoveTopic(ctx, tenant, line["D"][0], task["D"], "lobby", me, at); err != nil {
		t.Fatal(err)
	}
	l = read(rx)
	want("move out", l, task["A"], task["B"], task["C"])
	if got := sorted(l.GoneMsgs...); strings.Join(got, ",") != strings.Join(sorted(line["D"][0], line["D"][1]), ",") {
		t.Fatalf("move out: gone_msgs %v, want D's rows", l.GoneMsgs)
	}
	code, _, body := r.get(t, tenant, "/v1/view/topics?channel=lobby&since="+url.QueryEscape(since))
	if code != http.StatusOK || !strings.Contains(body, task["D"]) || !strings.Contains(body, `"delta":true`) {
		t.Fatalf("move out: #lobby delta %d %s", code, body)
	}

	// An archive: the topic leaves every list, so it is named in gone_tasks.
	if _, err := st.(store.TopicArchive).SetArchived(ctx, tenant, line["C"][0], me, at, true); err != nil {
		t.Fatal(err)
	}
	l = read(rx)
	want("archive", l, task["A"], task["B"])
	if strings.Join(l.GoneTasks, ",") != task["C"] {
		t.Fatalf("archive: gone_tasks %v, want [%s]", l.GoneTasks, task["C"])
	}

	// The fallback: a cursor older than a day reads the full page, flagged.
	old24 := viewCursor(time.Now().Add(-25*time.Hour), line["A"][0])
	code, _, body = r.get(t, tenant, "/v1/view/topics?channel=feedback&since="+url.QueryEscape(old24))
	if code != http.StatusOK || !strings.Contains(body, `"delta":false`) || !strings.Contains(body, task["A"]) || !strings.Contains(body, task["B"]) {
		t.Fatalf("long gap: want the full page with delta false: %d %s", code, body)
	}
	// CONTROL: without since the body is the §4.3 shape, no delta keys.
	if _, _, b := r.get(t, tenant, "/v1/view/topics?channel=feedback"); strings.Contains(b, `"delta"`) || strings.Contains(b, "gone_") {
		t.Fatalf("delta keys without since: %s", b)
	}
	// Refusals.
	for _, q := range []string{"since=nope", "since=" + url.QueryEscape(since) + "&before=" + url.QueryEscape(since),
		"since=" + url.QueryEscape(since) + "&rx=x~1", "since=" + url.QueryEscape(since) + "&rx=" + line["A"][0] + "~-1"} {
		if code, _, b := r.get(t, tenant, "/v1/view/topics?channel=feedback&"+q); code != http.StatusBadRequest {
			t.Fatalf("%s: %d %s", q, code, b)
		}
	}
}
