package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 153 section 3.20 (SPL-4810; owner HUM-10, t1 27162335): a lane's
// live console. A reader the Lanes tab shows the lane to watches it (POST),
// the lane's box pulls the demand and pushes the masked screen, the reader
// reads it (GET). Memory, and Postgres under SPOOL_TEST_PG_DSN (RLS).
// RED CONTROL (this tree before lane_console.go): every route answers 404
// (no route) and the box's console ops 400 bad_frame.

const (
	opConsolePath = "/v1/operator/lane-console"
	wsConsolePath = "/v1/lanes/console"
)

type consoleBody struct {
	AgentID    string           `json:"agent_id"`
	AgentBox   string           `json:"agent_box"`
	State      string           `json:"state"`
	Screen     string           `json:"screen"`
	Lines      int              `json:"lines"`
	Redactions map[string]int64 `json:"redactions"`
	CapturedAt string           `json:"captured_at"`
}

func consoleCall(t *testing.T, r *wsLanesRig, tid, as, path, method, agent, box string, want int) (consoleBody, string) {
	t.Helper()
	var body any
	p := path
	if method == http.MethodPost {
		body = map[string]any{"agent_id": agent, "agent_box": box}
	} else {
		p += "?" + url.Values{"agent_id": {agent}, "agent_box": {box}}.Encode()
	}
	code, got := call(t, r.e, tid, method, p, as, body)
	raw, _ := json.Marshal(got)
	if code != want {
		t.Errorf("%s %s in %s as %s: %d %s, want %d", method, p, tid, as, code, raw, want)
		return consoleBody{}, string(raw)
	}
	var c consoleBody
	if code == http.StatusOK {
		if err := json.Unmarshal(raw, &c); err != nil {
			t.Fatal(err)
		}
	}
	return c, string(raw)
}

func consoleLane(t *testing.T, b *box, op, payload string) (wire.FileStreamsAckFrame, error) {
	t.Helper()
	raw, err := b.c.Lane(context.Background(), op, "", json.RawMessage(payload))
	var ack wire.FileStreamsAckFrame
	if err == nil {
		if err := json.Unmarshal(raw, &ack); err != nil {
			t.Fatalf("ack %s: %v", raw, err)
		}
	}
	return ack, err
}

func consoleDemands(t *testing.T, b *box) []string {
	t.Helper()
	ack, err := consoleLane(t, b, wire.FileStreamsConsoleDemandsOp, `{}`)
	if err != nil || ack.Agents == nil {
		t.Fatalf("demands of %s: %+v %v", b.id, ack, err)
	}
	return *ack.Agents
}

func consolePush(t *testing.T, b *box, agent, screen string) error {
	t.Helper()
	p, _ := json.Marshal(map[string]any{"agent_id": agent, "screen": screen, "lines": strings.Count(screen, "\n") + 1,
		"redactions": map[string]int{"github-token": 1}})
	_, err := consoleLane(t, b, wire.FileStreamsConsolePushOp, string(p))
	return err
}

// C90-C94: watch, pull, push, read on both doors; the access matrix; the
// box's refusals; the demand's end.
func TestLaneConsole(t *testing.T) {
	r := newWSLanesRig(t)
	now := time.Now()
	laneAt(t, r.fleetTokensRig, "c-501", r.opBox.id, r.t1, "", now.Add(-time.Minute)) // an operator lane on a w1 topic
	laneAt(t, r.fleetTokensRig, "c-502", r.opBox.id, "", "", now.Add(-time.Minute))   // an operator lane, no topic
	mac := r.e.box(r.w1, "mbp-"+newTenantID(""))
	r.e.pin(r.w1, mac)
	// rdb 0264: a lane names its discussion and its issue; "unknown" is what an old row reads
	if _, err := lanePut(t, mac, `{"agent_id":"c-701","agent_box":"`+mac.id+`","topic":"unknown","issue_key":"unknown","scope":"own","state":"live"}`); err != nil {
		t.Fatal(err)
	}

	// C90: the operator admin watches c-501; the box pulls it, pushes, the admin reads it.
	if c, _ := consoleCall(t, r, r.op, r.admin, opConsolePath, http.MethodPost, "c-501", r.opBox.id, http.StatusOK); c.State != "waiting" || c.Screen != "" {
		t.Errorf("C90 first watch: %+v, want waiting with no screen", c)
	}
	if got := consoleDemands(t, r.opBox); !slices.Equal(got, []string{"c-501"}) {
		t.Errorf("C90 demands of the operator box %v, want [c-501]", got)
	}
	screen := "$ make test\nok <redacted:github-token>\n❯ "
	if err := consolePush(t, r.opBox, "c-501", screen); err != nil {
		t.Fatalf("C90 push: %v", err)
	}
	c, _ := consoleCall(t, r, r.op, r.admin, opConsolePath, http.MethodGet, "c-501", r.opBox.id, http.StatusOK)
	if c.State != "live" || c.Screen != screen || c.Lines != 3 || c.Redactions["github-token"] != 1 || c.CapturedAt == "" {
		t.Errorf("C90 read: %+v", c)
	}

	// C91: w1's admin and owner read the same console through the lanes
	// door, by agent alone: the operator box is never named to them.
	for _, as := range []string{r.w1Admin, r.w1Owner} {
		c, raw := consoleCall(t, r, r.w1, as, wsConsolePath, http.MethodPost, "c-501", "", http.StatusOK)
		if c.Screen != screen || c.AgentBox != "" || strings.Contains(raw, r.opBox.id) {
			t.Errorf("C91 w1 %s: %s", as, raw)
		}
	}

	// C92: who may not. A w1 developer (403), the operator's developer on
	// the operator door (403), w2's admin on a lane on no w2 topic (404),
	// w1's admin on an operator lane on no w1 topic (404) or naming the
	// operator box (404), an unknown lane (404).
	consoleCall(t, r, r.w1, r.w1Dev, wsConsolePath, http.MethodGet, "c-501", "", http.StatusForbidden)
	consoleCall(t, r, r.w1, r.w1Dev, wsConsolePath, http.MethodPost, "c-501", "", http.StatusForbidden)
	consoleCall(t, r, r.op, r.dev, opConsolePath, http.MethodGet, "c-501", r.opBox.id, http.StatusForbidden)
	consoleCall(t, r, r.w1, r.w1Admin, opConsolePath, http.MethodGet, "c-501", r.opBox.id, http.StatusForbidden)
	consoleCall(t, r, r.w2, r.w2Admin, wsConsolePath, http.MethodGet, "c-501", "", http.StatusNotFound)
	consoleCall(t, r, r.w1, r.w1Admin, wsConsolePath, http.MethodPost, "c-502", "", http.StatusNotFound)
	consoleCall(t, r, r.w1, r.w1Admin, wsConsolePath, http.MethodGet, "c-501", r.opBox.id, http.StatusNotFound)
	consoleCall(t, r, r.op, r.admin, opConsolePath, http.MethodPost, "c-999", r.opBox.id, http.StatusNotFound)
	consoleCall(t, r, r.op, r.admin, opConsolePath, http.MethodPost, "../etc", r.opBox.id, http.StatusBadRequest)

	// C93: a workspace's own lane (3.17) lives in that workspace: the
	// operator admin watches it, and only w1's box hears of it.
	consoleCall(t, r, r.op, r.admin, opConsolePath, http.MethodPost, "c-701", mac.id, http.StatusOK)
	if got := consoleDemands(t, mac); !slices.Equal(got, []string{"c-701"}) {
		t.Errorf("C93 demands of w1's box %v, want [c-701]", got)
	}
	if got := consoleDemands(t, r.otherBox); len(got) != 0 {
		t.Errorf("C93 another workspace's box hears %v", got)
	}
	if err := consolePush(t, r.otherBox, "c-501", "x"); err == nil || !strings.Contains(err.Error(), "not_demanded") {
		t.Errorf("C93 a push from another box: %v, want 409 not_demanded", err)
	}
	if err := consolePush(t, r.opBox, "c-502", "x"); err == nil || !strings.Contains(err.Error(), "not_demanded") {
		t.Errorf("C93 a push nobody asked for: %v, want 409 not_demanded", err)
	}
	if err := consolePush(t, r.opBox, "c-501", strings.Repeat("x", wire.LaneConsoleScreenMax+1)); err == nil || !strings.Contains(err.Error(), "too_large") {
		t.Errorf("C93 an oversized screen: %v, want 413 too_large", err)
	}

	// C94: a demand lasts 60 s: past it the box hears none and a push is refused.
	r.offset.Store(int64(61 * time.Second))
	if got := consoleDemands(t, r.opBox); len(got) != 0 {
		t.Errorf("C94 demands after 61 s %v, want none", got)
	}
	if err := consolePush(t, r.opBox, "c-501", screen); err == nil || !strings.Contains(err.Error(), "not_demanded") {
		t.Errorf("C94 a push after the demand: %v, want 409 not_demanded", err)
	}
}
