package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// putTopic stores the opening line of a root topic in channel ("" = a DM).
func putTopic(t *testing.T, e *env, tenant, channel, subject string, at time.Time) string {
	t.Helper()
	task := uuidV4()
	inner := `{"v":1,"msg_id":"` + uuidV4() + `","task_id":"` + task + `","from":"HUM-1","to":"c-007","kind":"note","body":"` +
		subject + `\n\nthe body, never listed","files":[]}`
	m := store.Message{TenantID: tenant, MsgID: uuidV4(), TaskID: task, Channel: channel, TS: at, IsParent: 1,
		FromBox: "box-wui", FromID: "HUM-1", ToBox: "box-wui", ToID: "c-007", Kind: "note", Body: subject + "\n\nthe body, never listed",
		Files: []byte("[]"), Msg: []byte(inner), Env: []byte(`{"channel":"` + channel + `","msg":` + inner + `,"sig":""}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return task
}

// agentTopicRig is one tenant with two created channels and a pinned box-a:
// c-007 is seated in #refactoring, c-008 in #private-room, and #refactoring
// holds three root topics, #private-room one, plus a DM.
type agentTopicRig struct {
	e        *env
	tid      string
	a        *box
	sa       *hubclient.Session
	tasks    []string // #refactoring, newest first
	privTask string
}

func newAgentTopicRig(t *testing.T, e *env) agentTopicRig {
	t.Helper()
	ctx := context.Background()
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for _, ch := range []string{"refactoring", "private-room"} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	for _, x := range [][2]string{{"refactoring", "c-007"}, {"private-room", "c-008"}} {
		if err := e.st.InviteChannelAgent(ctx, tid, x[0], "box-a", x[1], now); err != nil {
			t.Fatal(err)
		}
	}
	r := agentTopicRig{e: e, tid: tid}
	for i := 0; i < 3; i++ {
		r.tasks = append([]string{putTopic(t, e, tid, "refactoring", fmt.Sprintf("refactor step %d", i), now.Add(time.Duration(i)*time.Second))}, r.tasks...)
	}
	r.privTask = putTopic(t, e, tid, "private-room", "the private plan", now.Add(5*time.Second))
	putTopic(t, e, tid, "", "a direct message", now.Add(6*time.Second))
	r.a = e.box(tid, "box-a", "c-007", "c-008")
	e.pin(tid, r.a)
	sa, err := r.a.c.Dial(ctx, wire.RoleBox) // announces c-007 and c-008
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeWait(sa) })
	r.sa = sa
	return r
}

type agentTopicReply struct {
	Channel string           `json:"channel"`
	Topics  []map[string]any `json:"topics"`
	Next    *string          `json:"next"`
}

func (r agentTopicRig) read(t *testing.T, in action.TopicsArgs) (agentTopicReply, error) {
	t.Helper()
	in.Hub = r.a.c
	raw, err := action.Topics(context.Background(), r.a.cfg, in)
	var out agentTopicReply
	if err == nil {
		if jerr := json.Unmarshal(raw, &out); jerr != nil {
			t.Fatalf("reply %s: %v", raw, jerr)
		}
	}
	return out, err
}

func topicIDs(p agentTopicReply) []string {
	var ids []string
	for _, x := range p.Topics {
		ids = append(ids, fmt.Sprint(x["task_id"]))
	}
	return ids
}

// t1 1457bb6f: an agent lists a channel's topics over its own box session
// through the real front end (action.Topics == `spool topics`): newest
// first, paged, task id + subject + last_ts only; a channel it is not seated
// in reads 0 topics while a seated agent reads the same channel (control).
func TestAgentTopicList(t *testing.T) {
	r := newAgentTopicRig(t, followEnv(t))

	p1, err := r.read(t, action.TopicsArgs{As: "c-007", Channel: "refactoring", Limit: 2})
	if err != nil {
		t.Fatal(err)
	}
	if got := topicIDs(p1); !slices.Equal(got, r.tasks[:2]) || p1.Next == nil || p1.Channel != "refactoring" {
		t.Fatalf("page 1 = %v next %v, want %v", got, p1.Next, r.tasks[:2])
	}
	for _, x := range p1.Topics {
		if len(x) != 3 || x["subject"] == "" || x["last_ts"] == "" {
			t.Fatalf("row %v: want exactly task_id, subject, last_ts", x)
		}
	}
	if p1.Topics[0]["subject"] != "refactor step 2" {
		t.Fatalf("subject = %q", p1.Topics[0]["subject"])
	}
	p2, err := r.read(t, action.TopicsArgs{As: "c-007", Channel: "#refactoring", Limit: 2, Before: *p1.Next})
	if err != nil {
		t.Fatal(err)
	}
	if got := topicIDs(p2); !slices.Equal(got, r.tasks[2:]) || p2.Next != nil {
		t.Fatalf("page 2 = %v next %v, want %v", got, p2.Next, r.tasks[2:])
	}

	// Not seated: 0 rows, the same answer an unknown channel gets.
	for _, ch := range []string{"private-room", "no-such-channel"} {
		p, err := r.read(t, action.TopicsArgs{As: "c-007", Channel: ch})
		if err != nil || len(p.Topics) != 0 || p.Next != nil {
			t.Fatalf("c-007 in #%s: %v %v, want 0 topics", ch, p, err)
		}
	}
	// CONTROL: the agent seated there reads it.
	if p, err := r.read(t, action.TopicsArgs{As: "c-008", Channel: "private-room"}); err != nil || !slices.Equal(topicIDs(p), []string{r.privTask}) {
		t.Fatalf("CONTROL c-008 in #private-room: %v %v", p, err)
	}

	var he *hubclient.HubError
	if _, err := r.read(t, action.TopicsArgs{As: "GRK-99", Channel: "refactoring"}); !errors.As(err, &he) || he.Token != wire.TokenFromNotAnnounced {
		t.Fatalf("unannounced agent: %v", err)
	}
	if _, err := r.read(t, action.TopicsArgs{As: "c-007", Channel: "refactoring", Limit: 101}); !errors.As(err, &he) || he.Token != "bad_query" {
		t.Fatalf("limit 101: %v", err)
	}
	if _, err := r.sa.TopicList(context.Background(), "c-007", "limit=5"); !errors.As(err, &he) || he.Token != "bad_query" {
		t.Fatalf("no channel: %v", err)
	}
}

// Tenant isolation (FORCE RLS under Postgres): a second tenant with the same
// channel, the same box id and the same seated agent lists only its own
// topics, and the first tenant's are not among them.
func TestAgentTopicListTenantIsolation(t *testing.T) {
	e := followEnv(t)
	r1 := newAgentTopicRig(t, e)
	r2 := newAgentTopicRig(t, e)
	p1, err := r1.read(t, action.TopicsArgs{As: "c-007", Channel: "refactoring"})
	if err != nil {
		t.Fatal(err)
	}
	p2, err := r2.read(t, action.TopicsArgs{As: "c-007", Channel: "refactoring"})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(topicIDs(p1), r1.tasks) || !slices.Equal(topicIDs(p2), r2.tasks) {
		t.Fatalf("tenant 1 %v want %v; tenant 2 %v want %v", topicIDs(p1), r1.tasks, topicIDs(p2), r2.tasks)
	}
	for _, id := range topicIDs(p2) {
		if slices.Contains(r1.tasks, id) {
			t.Fatalf("tenant 2 lists tenant 1's topic %s", id)
		}
	}
}

// Round trips (Postgres only, the counting proxy): a page costs the same (2 measured)
// number of packets whatever its size - the seat read and one topic walk,
// never one read per topic.
func TestAgentTopicListRoundTrips(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	proxy := newPGProxy(t, u.Host)
	u.Host = proxy.ln.Addr().String()
	t.Setenv("SPOOL_TEST_PG_DSN", u.String())
	r := newAgentTopicRig(t, followEnv(t))
	ctx := context.Background()
	count := func(limit int) int64 {
		q := url.Values{"channel": {"refactoring"}, "limit": {fmt.Sprint(limit)}}.Encode()
		if _, err := r.sa.TopicList(ctx, "c-007", q); err != nil { // warm the statement cache
			t.Fatal(err)
		}
		before := proxy.packets.Load()
		if _, err := r.sa.TopicList(ctx, "c-007", q); err != nil {
			t.Fatal(err)
		}
		return proxy.packets.Load() - before
	}
	one, three := count(1), count(3)
	t.Logf("packets: limit 1 = %d, limit 3 = %d", one, three)
	if one != three || one > 2 {
		t.Fatalf("packets per page: limit 1 = %d, limit 3 = %d; want equal and <= 2", one, three)
	}
}
