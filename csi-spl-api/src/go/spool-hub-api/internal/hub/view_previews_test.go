package hub_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Topic e1f8f797: POST /v1/view/previews turns the topics and messages a body
// links into short cards, with /v1/view/ids' door resolved as the VIEWER.
// Every refusal is paired with the same id read by someone who may read it.
// Runs on Memory, and on Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

func viewPreviews(t *testing.T, r privacyRig, as string, ids ...string) (int, map[string]map[string]any, string) {
	t.Helper()
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/view/previews", as, map[string]any{"ids": ids})
	raw, _ := json.Marshal(out)
	got := map[string]map[string]any{}
	rows, _ := out["previews"].([]any)
	for _, row := range rows {
		if m, ok := row.(map[string]any); ok {
			got[m["id"].(string)] = m
		}
	}
	return code, got, string(raw)
}

func TestViewPreviewsDoor(t *testing.T) {
	r := newPrivacyRig(t)
	now := time.Now().UTC().Truncate(time.Microsecond)
	privMsg := putRowWith(t, r, r.priv, "live-proof", "HUM-1", "CLE-07", now.Add(3*time.Second), func(m *store.Message) { m.Body = "secret plan line" })
	dmMsg := putRowWith(t, r, r.dm, "", "HUM-1", "CLE-07", now.Add(4*time.Second), func(m *store.Message) { m.Body = "secret dm line" })
	ids := []string{r.priv, r.dm, r.public, privMsg.MsgID, dmMsg.MsgID}

	code, mine, _ := viewPreviews(t, r, "HUM-1", ids...)
	if code != http.StatusOK || len(mine) != len(ids) {
		t.Fatalf("CONTROL: HUM-1 previews %d of %d (%d): %v", len(mine), len(ids), code, mine)
	}
	for _, tc := range []struct{ id, kind, title, excerpt, from string }{
		{r.priv, "topic", "the private channel post", "", "HUM-1"},
		{r.dm, "topic", "the private DM", "", "HUM-1"},
		{r.public, "topic", "the public lobby post", "", "HUM-1"},
		{privMsg.MsgID, "message", "the private channel post", "secret plan line", "HUM-1"},
		{dmMsg.MsgID, "message", "the private DM", "secret dm line", "HUM-1"},
	} {
		h := mine[tc.id]
		if h["kind"] != tc.kind || h["title"] != tc.title || h["excerpt"] != tc.excerpt || h["from"] != tc.from || str(h["ts"]) == "" {
			t.Errorf("%s: got %v, want kind=%s title=%q excerpt=%q from=%s", tc.id, h, tc.kind, tc.title, tc.excerpt, tc.from)
		}
	}
	// HUM-2 is in neither the private channel nor the DM: only #lobby, and
	// no word of the others anywhere in the answer.
	_, theirs, raw := viewPreviews(t, r, "HUM-2", ids...)
	if len(theirs) != 1 || theirs[r.public] == nil {
		t.Fatalf("LEAK: HUM-2 previews %v, want only the lobby topic", theirs)
	}
	for _, word := range []string{"private", "secret", r.priv, r.dm} {
		if strings.Contains(raw, word) {
			t.Errorf("LEAK: HUM-2's answer holds %q: %s", word, raw)
		}
	}
}

// A topic the reader may place (a later row in #lobby) whose FIRST message is
// in a private channel prints nothing: the card would print that message.
func TestViewPreviewsStarterDoor(t *testing.T) {
	r := newPrivacyRig(t)
	now := time.Now().UTC().Truncate(time.Microsecond)
	mixed := uuidV4()
	putRowWith(t, r, mixed, "live-proof", "HUM-1", "@channel", now.Add(3*time.Second), func(m *store.Message) { m.Body = "hidden start" })
	pub := putRowWith(t, r, mixed, "lobby", "HUM-1", "@channel", now.Add(4*time.Second), func(m *store.Message) { m.Body = "public follow-up"; m.IsParent = 0 })

	_, mine, _ := viewPreviews(t, r, "HUM-1", mixed, pub.MsgID)
	if mine[mixed]["title"] != "hidden start" || mine[pub.MsgID]["title"] != "hidden start" || mine[pub.MsgID]["excerpt"] != "public follow-up" {
		t.Fatalf("CONTROL: HUM-1 (reads both) %v", mine)
	}
	_, theirs, raw := viewPreviews(t, r, "HUM-2", mixed, pub.MsgID)
	if theirs[mixed] != nil {
		t.Errorf("LEAK: HUM-2 gets the topic card %v", theirs[mixed])
	}
	if h := theirs[pub.MsgID]; h == nil || h["title"] != "public follow-up" || h["excerpt"] != "" {
		t.Errorf("HUM-2's message card: %v, want its own line as the title", h)
	}
	if strings.Contains(raw, "hidden") {
		t.Errorf("LEAK: %s", raw)
	}
}

func TestViewPreviewsText(t *testing.T) {
	r := newPrivacyRig(t)
	now := time.Now().UTC().Truncate(time.Microsecond)
	task := uuidV4()
	long := strings.Repeat("é", 150)
	starter := putRowWith(t, r, task, "lobby", "HUM-2", "@channel", now.Add(3*time.Second), func(m *store.Message) {
		m.Body = "\n  " + long + "  \n\nline a\n```go\nline b\n```\nline c\nline d"
	})
	reply := putReply(t, r, task, "lobby", "HUM-1", "HUM-2", now.Add(5*time.Second))
	_, got, _ := viewPreviews(t, r, "HUM-2", strings.ToUpper(task), starter.MsgID, reply.MsgID)
	want := strings.Repeat("é", 99) + "…"
	if h := got[task]; h["title"] != want || h["excerpt"] != "line a\nline b\nline c" || h["from"] != "HUM-2" || h["channel"] != "lobby" {
		t.Errorf("topic: %v", h)
	}
	if h := got[starter.MsgID]; h["kind"] != "message" || h["title"] != want || h["excerpt"] != "line a\nline b\nline c" {
		t.Errorf("the starter as a message: %v", h)
	}
	if h := got[reply.MsgID]; h["title"] != want || h["excerpt"] != "x" || h["from"] != "HUM-1" || h["task_id"] != task {
		t.Errorf("reply: %v, want its topic's title over its own body", h)
	}
}

func TestViewPreviewsRefusals(t *testing.T) {
	r := newPrivacyRig(t)
	if code, _, _ := viewPreviews(t, r, "HUM-1", r.public[:8]); code != http.StatusBadRequest {
		t.Errorf("8-hex id: %d, want 400", code)
	}
	many := make([]string, 21)
	for i := range many {
		many[i] = uuidV4()
	}
	if code, _, _ := viewPreviews(t, r, "HUM-1", many...); code != http.StatusBadRequest {
		t.Errorf("21 ids: %d, want 400", code)
	}
	if code, got, _ := viewPreviews(t, r, "HUM-1", many[:20]...); code != http.StatusOK || len(got) != 0 {
		t.Errorf("CONTROL: 20 unknown ids: %d %v, want 200 and none", code, got)
	}
	if code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/view/previews", "HUM-1", nil); code == http.StatusOK {
		t.Errorf("GET /v1/view/previews answered 200: %v", out)
	}
}

// The cards of every visible link come in one call whose round trips do not
// grow per id: the door's lookup and the rows' read, whatever the count.
// Skipped without SPOOL_TEST_PG_DSN (the memory store has no wire).
func TestNPlus1RoundTripsViewPreviews(t *testing.T) {
	p := proxiedPG(t)
	r := newPrivacyRig(t)
	const n = 5
	var rts [][]int64
	for _, k := range []int{1, 20} {
		ids := []string{r.priv, r.dm, r.public}
		for len(ids) < k {
			ids = append(ids, uuidV4())
		}
		ids = ids[:k]
		ask := func() {
			if code, _, _ := viewPreviews(t, r, "HUM-1", ids...); code != http.StatusOK {
				t.Fatalf("view previews: %d", code)
			}
		}
		ask()
		rt := rtSample(p, n, ask)
		rts = append(rts, rt)
		t.Logf("POST /v1/view/previews ids=%d RT(n=%d)=%v median=%d", k, n, rt, rt[n/2])
	}
	if rts[1][0] > rts[0][0]+1 {
		t.Fatalf("view previews grows per id: min %d at 1 id, %d at 20", rts[0][0], rts[1][0])
	}
}
