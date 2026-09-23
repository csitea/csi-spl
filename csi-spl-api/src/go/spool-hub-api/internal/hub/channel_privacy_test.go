package hub_test

// rdb 0028 — the read door. A channel is something humans are IN, and a DM
// belongs to its two ends. Reported by the owner 2026-09-23: one signed-in
// member of a tenant could read another member's conversation with a bot.
//
// Every refusal here is paired with the SAME read by someone who may do it.
// Without that control, deleting a guard in privacy.go would leave a suite
// that still passes because "nobody can read anything" satisfies every
// assertion about what must not be readable.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// putRow stores one message whose env is VALID JSON, so the view API can
// marshal it (putMsg's "env-<uuid>" cannot be, and a response that fails to
// encode is an empty 200 that reads exactly like an empty topic).
func putRow(t *testing.T, e *env, tenant, task, channel, from, to, body string, at time.Time) store.Message {
	t.Helper()
	inner := `{"v":1,"msg_id":"` + uuidV4() + `","task_id":"` + task + `","from":"` + from +
		`","to":"` + to + `","kind":"note","body":"` + body + `","files":[]}`
	raw := `{"from_box":"box-wui","to_box":"box-wui","channel":"` + channel + `","msg":` + inner + `,"sig":""}`
	m := store.Message{TenantID: tenant, MsgID: uuidV4(), TaskID: task, Channel: channel, TS: at,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: to, Kind: "note", Body: body,
		Files: []byte("[]"), Msg: []byte(inner), Env: []byte(raw),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return m
}

func readTopic(t *testing.T, e *env, tid, task, as string) (int, int) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+task, as, nil)
	msgs, _ := out["messages"].([]any)
	return code, len(msgs)
}

func idSet(t *testing.T, e *env, tid, path, as, key, field string) map[string]bool {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, path, as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET %s as %s: %d %v", path, as, code, out)
	}
	got := map[string]bool{}
	rows, _ := out[key].([]any)
	for _, r := range rows {
		if m, ok := r.(map[string]any); ok {
			if v, ok := m[field].(string); ok {
				got[v] = true
			}
		}
	}
	return got
}

func listedChannels(t *testing.T, e *env, tid, as string) map[string]bool {
	return idSet(t, e, tid, "/v1/view/channels", as, "channels", "channel")
}

func listedTopics(t *testing.T, e *env, tid, as string) map[string]bool {
	return idSet(t, e, tid, "/v1/view/topics?roots=false", as, "topics", "task_id")
}

// privacyRig: two members, one created channel HUM-1 is in and HUM-2 is not,
// one DM between HUM-1 and an agent, and one #lobby post.
type privacyRig struct {
	e                *env
	tid              string
	priv, dm, public string
}

func newPrivacyRig(t *testing.T) privacyRig {
	t.Helper()
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)

	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "live-proof",
		Name: "live-proof", CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "live-proof", []string{"HUM-1"}, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	r := privacyRig{e: e, tid: tid, priv: uuidV4(), dm: uuidV4(), public: uuidV4()}
	putRow(t, e, tid, r.priv, "live-proof", "HUM-1", "CLE-07", "the private channel post", now)
	putRow(t, e, tid, r.dm, "", "HUM-1", "CLE-07", "the private DM", now.Add(time.Second))
	putRow(t, e, tid, r.public, "lobby", "HUM-1", "CLE-07", "the public lobby post", now.Add(2*time.Second))
	return r
}

// The reported defect: "the messages should be public only if both of the
// users are in the same channel".
func TestChannelPrivacyTopicRead(t *testing.T) {
	r := newPrivacyRig(t)
	for _, tc := range []struct {
		what, task, as string
		wantCode, want int
	}{
		// CONTROLS — the reads that must keep working.
		{"HUM-1 reads its own channel", r.priv, "HUM-1", http.StatusOK, 1},
		{"HUM-1 reads its own DM", r.dm, "HUM-1", http.StatusOK, 1},
		{"HUM-1 reads #lobby", r.public, "HUM-1", http.StatusOK, 1},
		{"HUM-2 reads #lobby", r.public, "HUM-2", http.StatusOK, 1},
		// The defect.
		{"HUM-2 reads #live-proof", r.priv, "HUM-2", http.StatusNotFound, 0},
		{"HUM-2 reads another member's DM", r.dm, "HUM-2", http.StatusNotFound, 0},
	} {
		code, n := readTopic(t, r.e, r.tid, tc.task, tc.as)
		if code != tc.wantCode || n != tc.want {
			t.Errorf("%s: got %d with %d messages, want %d with %d", tc.what, code, n, tc.wantCode, tc.want)
		}
	}
}

// A channel you are not in is not listed at all (owner's call: hidden, not
// greyed out and not joinable).
func TestChannelPrivacyListings(t *testing.T) {
	r := newPrivacyRig(t)

	mine, theirs := listedChannels(t, r.e, r.tid, "HUM-1"), listedChannels(t, r.e, r.tid, "HUM-2")
	if !mine["live-proof"] {
		t.Errorf("CONTROL: HUM-1 lost its own channel: %v", mine)
	}
	if theirs["live-proof"] {
		t.Errorf("LEAK: #live-proof listed to a non-member: %v", theirs)
	}
	for _, d := range store.DefaultChannels {
		if !mine[d] || !theirs[d] {
			t.Errorf("default channel %s must stay tenant-wide: HUM-1=%v HUM-2=%v", d, mine[d], theirs[d])
		}
	}

	seen := listedTopics(t, r.e, r.tid, "HUM-1")
	if !seen[r.priv] || !seen[r.dm] || !seen[r.public] {
		t.Errorf("CONTROL: HUM-1's own topic list is incomplete: %v", seen)
	}
	seen = listedTopics(t, r.e, r.tid, "HUM-2")
	if seen[r.priv] || seen[r.dm] {
		t.Errorf("LEAK: HUM-2's topic list carries another member's topics: %v", seen)
	}
	if !seen[r.public] {
		t.Errorf("the #lobby topic must stay visible to every member: %v", seen)
	}
}

// Search is a read path too, and it answered from every channel of the tenant.
func TestChannelPrivacySearch(t *testing.T) {
	r := newPrivacyRig(t)
	found := func(as string) []string {
		_, _, res, _ := searchGet(t, r.e, r.tid, "type:message private", "", memberHeader, as)
		var out []string
		for _, m := range res.Groups["messages"].Results {
			out = append(out, m["snippet"].(map[string]any)["text"].(string))
		}
		return out
	}
	if got := found("HUM-1"); len(got) != 2 { // CONTROL: its channel post AND its DM
		t.Errorf("CONTROL: HUM-1 search found %d rows, want 2: %v", len(got), got)
	}
	if got := found("HUM-2"); len(got) != 0 {
		t.Errorf("LEAK: HUM-2 search found another member's text: %v", got)
	}
}

// The live socket: subscribing is not a way around the door, and the fan-out
// reaches members only.
func TestChannelPrivacyLive(t *testing.T) {
	r := newPrivacyRig(t)
	ctx := context.Background()

	member := dialMember(t, r.e, r.tid, "HUM-1", "HUM-1")
	outsider := dialMember(t, r.e, r.tid, "HUM-2", "HUM-2")

	// CONTROL: the member subscribes to the channel and to the topic.
	wsjson.Write(ctx, member, map[string]string{"type": "subscribe", "channel": "live-proof"}) //nolint:errcheck
	if f := readType(t, member, "subscribed"); f["type"] != "subscribed" {
		t.Fatalf("CONTROL: the member was refused its own channel: %v", f)
	}
	wsjson.Write(ctx, member, map[string]string{"type": "subscribe", "task_id": r.priv}) //nolint:errcheck
	if f := readType(t, member, "subscribed"); f["type"] != "subscribed" {
		t.Fatalf("CONTROL: the member was refused its own topic: %v", f)
	}

	// The outsider is refused with the SAME token a channel that does not
	// exist gets, so the name is not an oracle for which channels do.
	for _, tc := range []struct {
		what  string
		frame map[string]string
		want  string
	}{
		{"channel", map[string]string{"type": "subscribe", "channel": "live-proof"}, "unknown_channel"},
		{"channel topic", map[string]string{"type": "subscribe", "task_id": r.priv}, "not_found"},
		{"another member's DM", map[string]string{"type": "subscribe", "task_id": r.dm}, "not_found"},
	} {
		wsjson.Write(ctx, outsider, tc.frame) //nolint:errcheck
		if f := readType(t, outsider, "error"); f["error"] != tc.want {
			t.Errorf("outsider subscribing to %s: %v, want %s", tc.what, f, tc.want)
		}
	}

	// A follow-everything subscription is not a back door either.
	wsjson.Write(ctx, outsider, map[string]any{"type": "subscribe", "all": true}) //nolint:errcheck
	readType(t, outsider, "subscribed")

	// The member posts into its own channel, through the real send path.
	wsjson.Write(ctx, member, map[string]any{"type": "send", "task_id": r.priv, //nolint:errcheck
		"channel": "live-proof", "body": "a later private post"})
	if f := readType(t, member, "ack"); f["type"] != "ack" {
		t.Fatalf("CONTROL: the member could not post to its own channel: %v", f)
	}
	quiet(t, outsider, "a non-member received a private channel's live post")
}

// A non-member cannot post INTO the channel either: that would place text in
// a conversation they cannot read back, and show it to everyone who can.
func TestChannelPrivacySendRefused(t *testing.T) {
	r := newPrivacyRig(t)
	ctx := context.Background()
	outsider := dialMember(t, r.e, r.tid, "HUM-2", "HUM-2")
	wsjson.Write(ctx, outsider, map[string]any{"type": "send", "task_id": r.priv, //nolint:errcheck
		"channel": "live-proof", "body": "let me in"})
	if f := readType(t, outsider, "ack"); f["error"] != "unknown_channel" {
		t.Errorf("outsider posting to a private channel: %v", f)
	}
	// CONTROL: the same send into #lobby, which is public, is accepted.
	wsjson.Write(ctx, outsider, map[string]any{"type": "send", "task_id": lobby, "body": "hello"}) //nolint:errcheck
	if f := readType(t, outsider, "ack"); f["type"] != "ack" {
		t.Errorf("CONTROL: a member could not post in #lobby: %v", f)
	}
}

// Creating a channel puts the creator in it: a members-only channel born
// empty would be lost the moment it was made.
func TestCreatedChannelKeepsItsCreator(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	code, out := call(t, e, tid, http.MethodPost, "/v1/channels", "HUM-1",
		map[string]string{"channel": "mine", "name": "mine"})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	if got := listedChannels(t, e, tid, "HUM-1"); !got["mine"] {
		t.Errorf("the creator lost the channel it just made: %v", got)
	}
	if got := listedChannels(t, e, tid, "HUM-2"); got["mine"] {
		t.Errorf("a created channel is visible to a non-member: %v", got)
	}
}

// The membership API, on REAL seated memberships and real roles.
func TestChannelMembersAPI(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	owner := seat(t, e, tid, "developer") // holds channels.manage
	other := seat(t, e, tid, "developer") // a member of the tenant, not of the channel
	weak := seat(t, e, tid, "tester")     // IN the channel, but without channels.manage

	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "live-proof",
		Name: "live-proof", CreatedBy: owner, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "live-proof", []string{owner, weak}, owner, now); err != nil {
		t.Fatal(err)
	}
	task := uuidV4()
	putRow(t, e, tid, task, "live-proof", owner, "CLE-07", "the private channel post", now)

	// A non-member cannot see who is in it, and gets the 404 a channel that
	// does not exist gets.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/channels/live-proof/members", other, nil); code != http.StatusNotFound {
		t.Errorf("non-member listing members: %d, want 404", code)
	}
	// CONTROL: a member can.
	code, out := call(t, e, tid, http.MethodGet, "/v1/channels/live-proof/members", owner, nil)
	if code != http.StatusOK {
		t.Fatalf("CONTROL: member listing members: %d %v", code, out)
	}
	if ms, _ := out["members"].([]any); len(ms) != 2 {
		t.Errorf("members: %v, want the 2 seeded", out["members"])
	}

	// Adding makes the topic readable; that is the whole point of the table.
	if c, n := readTopic(t, e, tid, task, other); c != http.StatusNotFound {
		t.Fatalf("precondition: %s already reads it (%d, %d messages)", other, c, n)
	}
	if code, out = call(t, e, tid, http.MethodPost, "/v1/channels/live-proof/members", owner,
		map[string]string{"human_id": other}); code != http.StatusCreated {
		t.Fatalf("add member: %d %v", code, out)
	}
	if c, n := readTopic(t, e, tid, task, other); c != http.StatusOK || n != 1 {
		t.Errorf("after being added, %s reads %d with %d messages, want 200 with 1", other, c, n)
	}

	// A member of the channel without channels.manage cannot add anyone...
	if code, _ = call(t, e, tid, http.MethodPost, "/v1/channels/live-proof/members", weak,
		map[string]string{"human_id": other}); code != http.StatusForbidden {
		t.Errorf("tester-role add: %d, want 403", code)
	}
	// ...but may always leave by itself.
	if code, _ = call(t, e, tid, http.MethodDelete, "/v1/channels/live-proof/members/"+other, other, nil); code != http.StatusNoContent {
		t.Errorf("leaving: %d, want 204", code)
	}
	if c, _ := readTopic(t, e, tid, task, other); c != http.StatusNotFound {
		t.Errorf("after leaving, %s still reads it: %d", other, c)
	}

	// A human who is not in the TENANT cannot be put in one of its channels.
	if code, _ = call(t, e, tid, http.MethodPost, "/v1/channels/live-proof/members", owner,
		map[string]string{"human_id": "HUM-does-not-exist"}); code != http.StatusNotFound {
		t.Errorf("adding a non-member of the tenant: %d, want 404", code)
	}
	// A default channel has no membership to manage.
	if code, _ = call(t, e, tid, http.MethodPost, "/v1/channels/lobby/members", owner,
		map[string]string{"human_id": other}); code != http.StatusConflict {
		t.Errorf("adding to #lobby: %d, want 409", code)
	}
}

var _ = websocket.StatusNormalClosure

// The shape of the topic the owner actually reported, taken from dev t1
// 57e6f191-582e-45b1-a08e-389c0b034803: five UNTAGGED messages between one
// member and an agent, then a sixth from a DIFFERENT member carrying a
// channel tag, because the WUI posts a reply from whichever channel page it
// is on. The leak was read first and answered second, so the intruder ends up
// inside the topic.
//
// Access to the topic must therefore not be a property of the TOPIC. If it
// were, appending that one message would buy the five private ones before it.
func TestMixedTopicHidesTheDMHalf(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)

	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "live-proof",
		Name: "live-proof", CreatedBy: "HUM-9", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	// HUM-9 is in #live-proof; HUM-17 is not. HUM-17 owns the DM.
	if err := e.st.AddChannelHumans(ctx, tid, "live-proof", []string{"HUM-9"}, "HUM-9", now); err != nil {
		t.Fatal(err)
	}
	task := uuidV4()
	for i, body := range []string{"can you see this msg", "Also reply in this topic if you can see it",
		"so this is the reply", "@CLE-3444 can you see this msg", "hello"} {
		putRow(t, e, tid, task, "", "HUM-17", "CLE-3444", body, now.Add(time.Duration(i)*time.Second))
	}
	putRow(t, e, tid, task, "live-proof", "HUM-9", "ALL-0", "test", now.Add(time.Minute))

	bodies := func(as string) []string {
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+task, as, nil)
		if code != http.StatusOK {
			t.Fatalf("%s reading the topic: %d %v", as, code, out)
		}
		var got []string
		for _, m := range out["messages"].([]any) {
			env := m.(map[string]any)["env"].(map[string]any)
			got = append(got, env["msg"].(map[string]any)["body"].(string))
		}
		return got
	}

	// CONTROL: the DM's own end still reads all five of its messages.
	if got := bodies("HUM-17"); len(got) != 5 {
		t.Errorf("CONTROL: the DM owner reads %d of its own 5 messages: %v", len(got), got)
	}
	// The intruder is a party of the TOPIC and a member of the channel the
	// sixth message carries, so the topic opens - and hands back that one
	// message and nothing else.
	got := bodies("HUM-9")
	if len(got) != 1 || got[0] != "test" {
		t.Errorf("LEAK: HUM-9 reads %d messages of another member's DM: %v", len(got), got)
	}
}
