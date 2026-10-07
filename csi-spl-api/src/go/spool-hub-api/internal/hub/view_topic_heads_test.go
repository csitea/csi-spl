package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 099 T005: SPOOL_HUB_TOPIC_HEADS. GET /v1/view/topics is byte-identical
// off and on; shadow serves the walk's bytes and logs one topic_head_mismatch
// per mismatched list; GET /version reports the mode. SPOOL_TEST_TOPIC_HEADS=on
// runs every other hub test on the head read too (store.TopicHeadsTestAll).
func init() {
	store.TopicHeadsTestAll = os.Getenv("SPOOL_TEST_TOPIC_HEADS") == "on"
}

func TestVersionReportsTopicHeads(t *testing.T) {
	for mode, want := range map[string]string{"": "off", "off": "off", "shadow": "shadow", "on": "on"} {
		e := newEnv(t, func(o *hub.Options) { o.TopicHeads = mode })
		resp, err := e.client.Get(e.url("x") + "/version")
		if err != nil {
			t.Fatal(err)
		}
		var v map[string]string
		json.NewDecoder(resp.Body).Decode(&v) //nolint:errcheck
		resp.Body.Close()
		if v["topic_heads"] != want {
			t.Fatalf("TopicHeads %q: /version topic_heads = %q, want %q", mode, v["topic_heads"], want)
		}
	}
	if _, err := hub.New(hub.Options{Store: store.NewMemory(), Blob: blob.Dir{Root: t.TempDir()}, TenantHostPattern: "{tenant}" + domain,
		TopicHeads: "heads"}); err == nil {
		t.Fatal("TopicHeads \"heads\" accepted")
	}
}

// headsRig is one tenant on Postgres seen through hubs in different modes
// (each its own store and pool on the same database), backfill-marked.
type headsRig struct {
	t      *testing.T
	off    *env
	tid    string
	reader string
	pool   *pgxpool.Pool
	parent string
}

func headsEnv(t *testing.T, mode string, mut ...func(*hub.Options)) *env {
	return newEnv(t, append([]func(*hub.Options){func(o *hub.Options) { // followEnv's options
		o.ViewDoor, o.LobbyTaskID, o.ViewCORSOrigins = hub.ViewDoorOff, lobby, []string{wuiOrigin}
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		o.TopicHeads = mode
	}}, mut...)...)
}

// newHeadsRig seeds a tenant with every list shape the WUI reads: #lobby
// topics (one with a child topic), a private channel the reader is not in, a
// DM of the reader and one of others, and an archived topic.
func newHeadsRig(t *testing.T) *headsRig {
	if os.Getenv("SPOOL_TEST_PG_DSN") == "" {
		t.Skip("topic heads need Postgres (SPOOL_TEST_PG_DSN)")
	}
	if store.TopicHeadsTestAll {
		t.Skip("SPOOL_TEST_TOPIC_HEADS=on reads heads in every mode: no walk to compare with")
	}
	off := headsEnv(t, hub.TopicHeadsOff)
	pg := off.st.(*store.Postgres)
	r := &headsRig{t: t, off: off, pool: pg.Pool()}
	r.tid, _ = off.tenant()
	r.reader = seat(t, off, r.tid, "developer")
	now := time.Now().UTC().Truncate(time.Microsecond)
	at := func(m int) time.Time { return now.Add(time.Duration(m-60) * time.Minute) }
	a, b, c, k := uuidV4(), uuidV4(), uuidV4(), uuidV4()
	r.parent = a
	r.put(a, "", store.ChannelLobby, "HUM-2", "ALL-0", "alpha", at(1))
	r.put(a, "", store.ChannelLobby, "CLE-07", r.reader, "alpha reply", at(9))
	r.put(b, "", "crew", "HUM-2", "ALL-0", "private crew", at(5))
	r.put(c, "", "", r.reader, "CLE-07", "my dm", at(3))
	r.put(c, "", "", "CLE-07", r.reader, "my dm reply", at(11))
	r.put(uuidV4(), "", "", "HUM-2", "CLE-07", "their dm", at(7))
	r.put(k, a, store.ChannelLobby, "CLE-07", "ALL-0", "child of alpha", at(8))
	for i := 0; i < 5; i++ {
		r.put(uuidV4(), "", store.ChannelLobby, "CLE-0"+string(rune('1'+i)), "ALL-0", "lobby topic", at(12+i))
	}
	r.operator(`INSERT INTO topic_head_tenants (tenant_id, backfilled_at) VALUES ($1, now())`, r.tid)
	return r
}

// put stores one line (its card when it opens the topic).
func (r *headsRig) put(task, parent, channel, from, to, body string, at time.Time) {
	r.t.Helper()
	inner := `{"v":1,"msg_id":"` + uuidV4() + `","task_id":"` + task + `","from":"` + from +
		`","to":"` + to + `","kind":"note","body":"` + body + `","files":[]}`
	m := store.Message{TenantID: r.tid, MsgID: uuidV4(), TaskID: task, ParentTaskID: parent, Channel: channel, TS: at,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: to, Kind: "note", Body: body,
		Files: []byte("[]"), Msg: []byte(inner), Env: []byte(`{"msg":` + inner + `,"sig":""}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := r.off.st.InsertMessage(context.Background(), m); err != nil {
		r.t.Fatal(err)
	}
}

// operator runs one statement in the operator scope (the backfill's).
func (r *headsRig) operator(sql string, args ...any) {
	r.t.Helper()
	ctx := context.Background()
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		r.t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
		r.t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, sql, args...); err != nil {
		r.t.Fatalf("%s: %v", sql, err)
	}
	if err := tx.Commit(ctx); err != nil {
		r.t.Fatal(err)
	}
}

// corrupt moves the #lobby topic alpha's head an hour into the future: the
// head read lists it first, the walk lists it where its lines are.
func (r *headsRig) corrupt() {
	r.operator(`UPDATE topic_heads SET last_at = last_at + interval '1 hour' WHERE tenant_id = $1 AND task_id = $2`, r.tid, r.parent)
}

// get is the raw body of GET path as the reader.
func get(t *testing.T, e *env, tid, path, as string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+path, nil)
	req.Header.Set(memberHeader, as)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

// headPaths is every list shape, each with a small page so the cursor pages.
func (r *headsRig) headPaths() []string {
	return []string{"/v1/view/topics", "/v1/view/topics?limit=2", "/v1/view/topics?roots=false&limit=3",
		"/v1/view/topics?dm=true", "/v1/view/topics?dm=true&limit=1", "/v1/view/topics?channel=" + store.ChannelLobby + "&limit=2",
		"/v1/view/topics?channel=crew", "/v1/view/topics?peer=CLE-07", "/v1/view/topics?peer=CLE-07@box-wui&roots=false",
		"/v1/view/topics?per_topic=2&limit=3", "/v1/view/topics/" + r.parent + "/children"}
}

// TestTopicHeadsJSONByteIdentical: every list shape and every page answers
// the same bytes from a hub with topic heads off and one with them on.
// CONTROL: a hand-corrupted head changes the `on` answer, so the `on` hub
// really reads the heads.
func TestTopicHeadsJSONByteIdentical(t *testing.T) {
	r := newHeadsRig(t)
	on := headsEnv(t, hub.TopicHeadsOn)
	pages, nonEmpty := 0, 0
	for _, path := range r.headPaths() {
		for p := path; p != ""; pages++ {
			c1, b1 := get(t, r.off, r.tid, p, r.reader)
			c2, b2 := get(t, on, r.tid, p, r.reader)
			if c1 != http.StatusOK || c1 != c2 || !bytes.Equal(b1, b2) {
				t.Fatalf("GET %s: off %d %s\n on %d %s", p, c1, b1, c2, b2)
			}
			var body struct {
				Topics []json.RawMessage `json:"topics"`
				Next   *string           `json:"next"`
			}
			json.Unmarshal(b1, &body) //nolint:errcheck
			if len(body.Topics) > 0 {
				nonEmpty++
			}
			p = ""
			if body.Next != nil {
				p = path + sep(path) + "before=" + *body.Next
			}
		}
	}
	if nonEmpty < 9 {
		t.Fatalf("only %d pages listed a topic: the fixture does not exercise the shapes", nonEmpty)
	}
	r.corrupt()
	_, b1 := get(t, r.off, r.tid, "/v1/view/topics", r.reader)
	_, b2 := get(t, on, r.tid, "/v1/view/topics", r.reader)
	if bytes.Equal(b1, b2) {
		t.Fatal("CONTROL: a corrupted head did not change the `on` answer: the head read is not serving")
	}
	t.Logf("%d pages byte-identical off vs on, %d non-empty", pages, nonEmpty)
}

func sep(path string) string {
	if strings.Contains(path, "?") {
		return "&"
	}
	return "?"
}

// TestTopicHeadsShadowServesWalk: shadow answers the walk's bytes; a clean
// head logs no mismatch, a hand-corrupted one exactly one per list (shape,
// tenant, task ids - never a body); after 10 minutes topic_head_shadow logs
// each shape's compared and mismatched counts.
func TestTopicHeadsShadowServesWalk(t *testing.T) {
	r := newHeadsRig(t)
	var mu sync.Mutex
	clock := time.Now()
	var logBuf bytes.Buffer
	sh := headsEnv(t, hub.TopicHeadsShadow, func(o *hub.Options) {
		o.Log = zerolog.New(&syncWriter{w: &logBuf})
		o.Now = func() time.Time { mu.Lock(); defer mu.Unlock(); return clock }
	})
	lines := func(msg string) []map[string]any {
		mu.Lock()
		defer mu.Unlock()
		var out []map[string]any
		for _, l := range strings.Split(logBuf.String(), "\n") {
			var m map[string]any
			if json.Unmarshal([]byte(l), &m) == nil && m["message"] == msg {
				out = append(out, m)
			}
		}
		return out
	}
	check := func(path string) {
		t.Helper()
		_, want := get(t, r.off, r.tid, path, r.reader)
		_, got := get(t, sh, r.tid, path, r.reader)
		if !bytes.Equal(want, got) {
			t.Fatalf("shadow GET %s did not serve the walk:\n walk   %s\n shadow %s", path, want, got)
		}
	}
	check("/v1/view/topics")
	check("/v1/view/topics?dm=true")
	if n := len(lines("topic_head_mismatch")); n != 0 {
		t.Fatalf("clean heads: %d topic_head_mismatch lines", n)
	}
	r.corrupt()
	check("/v1/view/topics")
	mm := lines("topic_head_mismatch")
	if len(mm) != 1 || mm[0]["shape"] != "all" || mm[0]["tenant"] != r.tid || mm[0]["head_tasks"] == nil {
		t.Fatalf("corrupted head: want one topic_head_mismatch {shape all, tenant, task ids}, got %v", mm)
	}
	if strings.Contains(logBuf.String(), "alpha") {
		t.Fatal("a mismatch line carries a body")
	}
	mu.Lock()
	clock = clock.Add(10 * time.Minute)
	mu.Unlock()
	check("/v1/view/topics")
	cnt := map[string][2]float64{}
	for _, l := range lines("topic_head_shadow") {
		cnt[l["shape"].(string)] = [2]float64{l["compared"].(float64), l["mismatched"].(float64)}
	}
	if cnt["all"] != [2]float64{3, 2} || cnt["dm"] != [2]float64{1, 0} {
		t.Fatalf("topic_head_shadow after 10 min: %v, want all {3 2} and dm {1 0}", cnt)
	}
}
