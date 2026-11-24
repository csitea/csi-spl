package hub_test

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 186 M4 (SPL-6378): the topic_select frame (7.1.2). Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// selectRig is one workspace, an author (a developer) and one topic of each
// kind spec 186 M4 names: a public channel (#feedback), a members-only
// channel the author is in (#mine), one the author is not in (#theirs), the
// lobby, an issue's topic, an archived topic, a DM, and a topic in #feedback
// that touches a box locked to someone else (row B5).
type selectRig struct {
	e                    *env
	tid, author, other   string
	pub, mine, theirs    string
	lob, issue, arch, dm string
	locked               string
}

const lockedTitle = "Wombat secret plan"

func newSelectRig(t *testing.T, mut ...func(*hub.Options)) *selectRig {
	t.Helper()
	e := rbacEnv(t, mut...)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	tid, _ := e.tenant()
	r := &selectRig{e: e, tid: tid, author: seat(t, e, tid, rbac.Developer), other: seat(t, e, tid, rbac.Developer)}
	for _, ch := range []string{"mine", "theirs"} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "hub", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.st.AddChannelHumans(ctx, tid, "mine", []string{r.author}, "hub", now); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "theirs", []string{r.other}, "hub", now); err != nil {
		t.Fatal(err)
	}
	at := func(i int) time.Time { return now.Add(time.Duration(-i) * time.Minute) }
	r.pub = putRow(t, e, tid, uuidV4(), "feedback", r.other, "ALL-0", "Release 2.0 notes", at(1)).TaskID
	r.mine = putRow(t, e, tid, uuidV4(), "mine", r.other, "ALL-0", "Releases of the mine team", at(2)).TaskID
	r.theirs = putRow(t, e, tid, uuidV4(), "theirs", r.other, "ALL-0", "Release plan of theirs", at(3)).TaskID
	r.lob = putRow(t, e, tid, uuidV4(), store.ChannelLobby, r.other, "ALL-0", "RELEASE_party_in_the_lobby", at(4)).TaskID
	r.issue = putRow(t, e, tid, uuidV4(), "feedback", r.other, "ALL-0", "Release issue talk", at(5)).TaskID
	if _, err := e.st.(store.Issues).CreateIssue(ctx, store.Issue{Discussions: []string{testDiscussion}, TenantID: tid,
		Title: "an issue", TaskID: r.issue, CreatedBy: r.author}, now); err != nil {
		t.Fatal(err)
	}
	am := putRow(t, e, tid, uuidV4(), "feedback", r.other, "ALL-0", "Release archived", at(6))
	r.arch = am.TaskID
	if _, err := e.st.SetArchived(ctx, tid, am.MsgID, r.other, now, true); err != nil {
		t.Fatal(err)
	}
	r.dm = putRow(t, e, tid, uuidV4(), "", r.other, r.author, "Release DM", at(7)).TaskID
	own := e.box(tid, "box-own", "CLE-01")
	e.pin(tid, own)
	lr := putRow(t, e, tid, uuidV4(), "feedback", "CLE-01", "ALL-0", lockedTitle, at(8))
	r.locked = lr.TaskID
	r.lockSeat(t, lr)
	lockTo(t, e, tid, own, r.other)
	return r
}

// lockSeat stores a second line of the locked topic from CLE-01 on box-own,
// so the topic touches the locked box.
func (r *selectRig) lockSeat(t *testing.T, first store.Message) {
	t.Helper()
	m := first
	m.MsgID, m.FromBox, m.ReceivedAt = uuidV4(), "box-own", first.ReceivedAt.Add(time.Second)
	m.TS = m.ReceivedAt
	if _, err := r.e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

// bulkAnswer is a topic_selected or multicast_checked frame.
type bulkAnswer struct {
	Type    string      `json:"type"`
	ReqID   string      `json:"req_id"`
	OK      bool        `json:"ok"`
	Error   string      `json:"error"`
	Detail  string      `json:"detail"`
	Topics  []bulkTopic `json:"topics"`
	Targets []bulkTopic `json:"targets"`
	raw     string
}

type bulkTopic struct {
	TaskID  string `json:"task_id"`
	Channel string `json:"channel"`
	Title   string `json:"title"`
	OK      bool   `json:"ok"`
	Error   string `json:"error"`
}

// bulkCall writes frame f (a req_id is added) and reads its answer of type want.
func bulkCall(t *testing.T, c *websocket.Conn, want string, f map[string]any) bulkAnswer {
	t.Helper()
	id := uuidV4()
	f["req_id"] = id
	c.SetReadLimit(-1) // 1200 targets are over the client's 32 KiB default
	if err := wsjson.Write(context.Background(), c, f); err != nil {
		t.Fatal(err)
	}
	return readBulk(t, c, want, id)
}

// readBulk reads frames until the answer of type want to req_id id.
func readBulk(t *testing.T, c *websocket.Conn, want, id string) bulkAnswer {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for {
		_, p, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("waiting for %s %s: %v", want, id, err)
		}
		var a bulkAnswer
		if json.Unmarshal(p, &a) != nil || a.Type != want || a.ReqID != id {
			continue
		}
		a.raw = string(p)
		return a
	}
}

func selectFrame(patterns []string, ticks ...string) map[string]any {
	return map[string]any{"type": "topic_select", "action": "multicast", "task_ids": ticks, "patterns": patterns}
}

func (r *selectRig) dial(t *testing.T, hum string) *websocket.Conn {
	t.Helper()
	return dialMember(t, r.e, r.tid, "x", hum)
}

func bulkIDs(ts []bulkTopic) []string {
	out := make([]string, 0, len(ts))
	for _, x := range ts {
		out = append(out, x.TaskID)
	}
	slices.Sort(out)
	return out
}

func sortIDs(ids ...string) []string {
	slices.Sort(ids)
	return ids
}

// `*` in scope is exactly the public topic, the members-only topic the
// author is in and the lobby topic: never the other channel, the issue's
// topic, the archived one, the DM, nor the box-locked one, whose title is
// in no answer. RED CONTROLS: drop NoIssues and the issue topic comes back;
// drop the box-lock filter and the locked topic and its title come back;
// drop the trim and " * " compiles as a pattern that misses the lobby
// title, which has no space.
func TestTopicSelectStarScope(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	want := sortIDs(r.pub, r.mine, r.lob)
	for _, pats := range [][]string{{"*"}, {" * "}, {"  ", "*"}} {
		a := bulkCall(t, c, "topic_selected", selectFrame(pats))
		if !a.OK || !slices.Equal(bulkIDs(a.Topics), want) {
			t.Errorf("patterns %q: ok=%v %s, want exactly %v", pats, a.OK, a.raw, want)
		}
	}
	for _, pats := range [][]string{{"*"}, {"."}, {"wombat"}} {
		a := bulkCall(t, c, "topic_selected", selectFrame(pats, r.locked))
		if slices.Contains(bulkIDs(a.Topics), r.locked) || strings.Contains(strings.ToLower(a.raw), "wombat") {
			t.Errorf("patterns %q: the box-locked topic or its title came back: %s", pats, a.raw)
		}
	}
	// the owner of the lock reads it
	a := bulkCall(t, r.dial(t, r.other), "topic_selected", selectFrame([]string{"wombat"}))
	if !slices.Equal(bulkIDs(a.Topics), []string{r.locked}) || a.Topics[0].Title != lockedTitle {
		t.Errorf("the lock owner's wombat: %s, want the locked topic", a.raw)
	}
}

// Patterns are case-insensitive and unanchored; `^` anchors; two patterns
// and a tick are unioned and deduplicated; a line of spaces is dropped.
// RED CONTROL: drop (?i) and "^rel" misses "Release 2.0 notes".
func TestTopicSelectPatterns(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	a := bulkCall(t, c, "topic_selected", selectFrame([]string{"^rel"}))
	if !slices.Equal(bulkIDs(a.Topics), sortIDs(r.pub, r.mine, r.lob)) {
		t.Errorf("^rel: %s", a.raw)
	}
	pre := putRow(t, r.e, r.tid, uuidV4(), "feedback", r.other, "ALL-0", "pre-release checks", time.Now().UTC()).TaskID
	a = bulkCall(t, c, "topic_selected", selectFrame([]string{"^rel"}))
	if slices.Contains(bulkIDs(a.Topics), pre) {
		t.Errorf("^rel matched pre-release: %s", a.raw)
	}
	a = bulkCall(t, c, "topic_selected", selectFrame([]string{"2\\.0", "   ", "lobby", "release"}, r.pub, r.mine, r.pub))
	if want := sortIDs(r.pub, r.mine, r.lob, pre); !a.OK || !slices.Equal(bulkIDs(a.Topics), want) {
		t.Errorf("union: %s, want %v once each", a.raw, want)
	}
	// a tick out of scope reads as absent
	a = bulkCall(t, c, "topic_selected", selectFrame(nil, r.theirs, r.dm, r.arch, r.issue, r.mine))
	if !a.OK || !slices.Equal(bulkIDs(a.Topics), []string{r.mine}) {
		t.Errorf("ticks: %s, want %s only", a.raw, r.mine)
	}
}

// A role without notes.send selects nothing for multicast, though it reads
// the channels. RED CONTROL: drop the action's permission and `*` answers
// the three topics.
func TestTopicSelectNeedsActionPermission(t *testing.T) {
	r := newSelectRig(t)
	reader := seat(t, r.e, r.tid, rbac.InternalAccountant)
	if err := r.e.st.AddChannelHumans(context.Background(), r.tid, "mine", []string{reader}, "hub", time.Now()); err != nil {
		t.Fatal(err)
	}
	a := bulkCall(t, r.dial(t, reader), "topic_selected", selectFrame([]string{"*"}, r.pub))
	if !a.OK || len(a.Topics) != 0 {
		t.Errorf("no notes.send: %s, want ok and no topics", a.raw)
	}
}

// A bad pattern answers topic_select_bad_pattern naming its line; an
// unknown action, both lists empty and a bad req_id answer bad_json.
func TestTopicSelectRefusals(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	a := bulkCall(t, c, "topic_selected", selectFrame([]string{"ok", "(unclosed"}))
	if a.OK || a.Error != "topic_select_bad_pattern" || !strings.Contains(a.Detail, "line 2") || len(a.Topics) != 0 {
		t.Errorf("bad pattern: %s", a.raw)
	}
	f := selectFrame([]string{"*"})
	f["action"] = "explode"
	if a := bulkCall(t, c, "topic_selected", f); a.OK || a.Error != "bad_json" {
		t.Errorf("unknown action: %s", a.raw)
	}
	if a := bulkCall(t, c, "topic_selected", selectFrame(nil)); a.OK || a.Error != "bad_json" {
		t.Errorf("both empty: %s", a.raw)
	}
	eleven := make([]string, 11)
	for i := range eleven {
		eleven[i] = "x"
	}
	if a := bulkCall(t, c, "topic_selected", selectFrame(eleven)); a.OK || a.Error != "bad_json" {
		t.Errorf("11 patterns: %s", a.raw)
	}
}

// A tenant with 450 topics (more than two pages of 200) resolves all 450
// under `*`. RED CONTROL: stop paging after the first page and 200 come back.
func TestTopicSelectPagesToTheEnd(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	author := seat(t, e, tid, rbac.Developer)
	now := time.Now().UTC().Truncate(time.Second)
	want := make([]string, 0, 450)
	for i := range 450 {
		want = append(want, putRow(t, e, tid, uuidV4(), "feedback", author, "ALL-0", "topic", now.Add(time.Duration(-i)*time.Second)).TaskID)
	}
	slices.Sort(want)
	a := bulkCall(t, dialMember(t, e, tid, "x", author), "topic_selected", selectFrame([]string{"*"}))
	if got := bulkIDs(a.Topics); !a.OK || !slices.Equal(got, want) {
		t.Errorf("450 topics: ok=%v, %d back, want all 450", a.OK, len(got))
	}
}
