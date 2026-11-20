package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 182 v0.3 row L2 (SPL-6032): the fire of a discussion loop. The store
// is a _test double of row L1's store.TopicLoopStore (7.1.1) over
// store.Memory, so these run before L1 lands.
//
// Every negative case waits on the event that makes it final, never a
// sleep: a box session and a browser socket each handle one frame at a
// time, and the loop hook runs after the reply frame, so the next frame's
// reply proves the hook before it has run (barrier, wuiBarrier).
//
// RED CONTROL (the cap): in topic_loop_fire.go loopSend, drop the `|| !fired`
// of the CountTopicLoopFire check, and TestTopicLoopCapHoldsThe13thFire
// fails with 15 prompts, want 12.

// loopDouble is store.Memory plus an in-memory TopicLoopStore with 7.1.1's
// semantics, and a log of every inserted row.
type loopDouble struct {
	*store.Memory
	mu    sync.Mutex
	loops map[string]*store.TopicLoop
	rows  []store.Message
	hasN  atomic.Int64 // TenantHasTopicLoops calls
	onN   atomic.Int64 // TopicLoopsOn calls
}

var _ store.TopicLoopStore = (*loopDouble)(nil)

func newLoopDouble() *loopDouble {
	return &loopDouble{Memory: store.NewMemory(), loops: map[string]*store.TopicLoop{}}
}

func (d *loopDouble) logRow(ok bool, m store.Message) {
	if ok {
		d.mu.Lock()
		d.rows = append(d.rows, m)
		d.mu.Unlock()
	}
}

func (d *loopDouble) InsertMessage(ctx context.Context, m store.Message) (bool, error) {
	ok, err := d.Memory.InsertMessage(ctx, m)
	d.logRow(ok, m)
	return ok, err
}

func (d *loopDouble) InsertMessageSent(ctx context.Context, m store.Message, exp time.Time) (bool, error) {
	ok, err := d.Memory.InsertMessageSent(ctx, m, exp)
	d.logRow(ok, m)
	return ok, err
}

// prompts are the stored loop prompt messages, in insert order.
func (d *loopDouble) prompts() []store.Message {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []store.Message
	for _, m := range d.rows {
		if m.LoopID != "" {
			out = append(out, m)
		}
	}
	return out
}

// rowIndex is the insert position of msgID, -1 when not stored.
func (d *loopDouble) rowIndex(msgID string) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return slices.IndexFunc(d.rows, func(m store.Message) bool { return m.MsgID == msgID })
}

func (d *loopDouble) get(id string) store.TopicLoop {
	d.mu.Lock()
	defer d.mu.Unlock()
	if l, ok := d.loops[id]; ok {
		return *l
	}
	return store.TopicLoop{}
}

func loopValid(l store.TopicLoop) bool {
	if l.Prompt == "" || len(l.Prompt) > store.TopicLoopPromptMax || len(l.Triggers) == 0 || l.SetBy == "" {
		return false
	}
	for _, k := range l.Triggers {
		if !slices.Contains(store.TopicLoopTriggers, k) {
			return false
		}
	}
	has := func(k string) bool { return slices.Contains(l.Triggers, k) }
	inRange := func(n int) bool { return n >= store.TopicLoopIntervalMin && n <= store.TopicLoopIntervalMax }
	if has(store.LoopEveryNMinutes) != (l.IntervalMin != 0) || has(store.LoopNoReplyAfterHuman) != (l.IdleMin != 0) ||
		has(store.LoopPostHasKeyword) != (l.Keyword != "") || has(store.LoopDailyAt) != (l.DailyAt != "") {
		return false
	}
	if (l.IntervalMin != 0 && !inRange(l.IntervalMin)) || (l.IdleMin != 0 && !inRange(l.IdleMin)) || len(l.Keyword) > store.TopicLoopKeywordMax {
		return false
	}
	_, err := time.Parse("15:04", l.DailyAt)
	return l.DailyAt == "" || err == nil
}

// loopDaily is the next DailyAt in DailyTZ after at (zero without daily_at).
func loopDaily(l store.TopicLoop, at time.Time) time.Time {
	hm, err := time.Parse("15:04", l.DailyAt)
	if l.State != store.TopicLoopOn || err != nil {
		return time.Time{}
	}
	tz, err := time.LoadLocation(l.DailyTZ)
	if err != nil {
		tz = time.UTC
	}
	loc := at.In(tz)
	next := time.Date(loc.Year(), loc.Month(), loc.Day(), hm.Hour(), hm.Minute(), 0, 0, tz)
	if !next.After(at) {
		next = next.AddDate(0, 0, 1)
	}
	return next.UTC()
}

// loopDue is 5.1's next_due_at from at.
func loopDue(l store.TopicLoop, at time.Time) time.Time {
	if l.State != store.TopicLoopOn {
		return time.Time{}
	}
	every := time.Duration(0)
	if slices.Contains(l.Triggers, store.LoopEveryHour) {
		every = time.Hour
	}
	if l.IntervalMin > 0 && (every == 0 || time.Duration(l.IntervalMin)*time.Minute < every) {
		every = time.Duration(l.IntervalMin) * time.Minute
	}
	if every == 0 {
		return time.Time{}
	}
	return at.Add(every)
}

func (d *loopDouble) TopicLoops(_ context.Context, tenant, task string) ([]store.TopicLoop, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []store.TopicLoop
	for _, l := range d.loops {
		if l.TenantID == tenant && l.TaskID == strings.ToLower(task) {
			out = append(out, *l)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].SetAt.Before(out[j].SetAt) || (out[i].SetAt.Equal(out[j].SetAt) && out[i].LoopID < out[j].LoopID)
	})
	return out, nil
}

func (d *loopDouble) TopicLoopsOn(ctx context.Context, tenant, task string) ([]store.TopicLoop, error) {
	d.onN.Add(1)
	all, _ := d.TopicLoops(ctx, tenant, task)
	return slices.DeleteFunc(all, func(l store.TopicLoop) bool { return l.State != store.TopicLoopOn }), nil
}

func (d *loopDouble) AddTopicLoop(_ context.Context, tenant string, l store.TopicLoop) (store.TopicLoop, error) {
	if !loopValid(l) {
		return l, store.ErrBadTopicLoop
	}
	if l.LoopID == "" {
		l.LoopID = uid.New()
	}
	l.TenantID, l.TaskID, l.State = tenant, strings.ToLower(l.TaskID), store.TopicLoopOn
	l.NextDueAt, l.DailyDueAt = loopDue(l, l.SetAt), loopDaily(l, l.SetAt)
	d.mu.Lock()
	defer d.mu.Unlock()
	d.loops[l.LoopID] = &l
	return l, nil
}

func (d *loopDouble) EditTopicLoop(_ context.Context, tenant, task, id string, e store.TopicLoopEdit) (store.TopicLoop, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	cur, ok := d.loops[id]
	if !ok || cur.TenantID != tenant || cur.TaskID != strings.ToLower(task) {
		return store.TopicLoop{}, store.ErrNotFound
	}
	l := *cur
	reset := e.Prompt != nil || e.Triggers != nil
	if e.Prompt != nil {
		l.Prompt = *e.Prompt
	}
	if e.Triggers != nil {
		l.Triggers = e.Triggers
	}
	if e.Interval != nil {
		l.IntervalMin = *e.Interval
	}
	if e.State != nil {
		l.State = *e.State
	}
	if e.Keyword != nil {
		l.Keyword = *e.Keyword
	}
	if e.IdleMin != nil {
		l.IdleMin = *e.IdleMin
	}
	if e.DailyAt != nil {
		l.DailyAt = *e.DailyAt
	}
	if e.DailyTZ != nil {
		l.DailyTZ = *e.DailyTZ
	}
	if !loopValid(l) || (l.State != store.TopicLoopOn && l.State != store.TopicLoopPaused) {
		return l, store.ErrBadTopicLoop
	}
	if reset {
		l.HourStart, l.FiresInHour = time.Time{}, 0
	}
	l.SetBy, l.SetAt = e.By, e.At
	l.NextDueAt, l.DailyDueAt = loopDue(l, e.At), loopDaily(l, e.At)
	l.IdleDueAt, l.IdlePost = time.Time{}, ""
	*cur = l
	return l, nil
}

func (d *loopDouble) DeleteTopicLoop(_ context.Context, tenant, task, id string) (bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	l, ok := d.loops[id]
	if !ok || l.TenantID != tenant || l.TaskID != strings.ToLower(task) {
		return false, nil
	}
	delete(d.loops, id)
	return true, nil
}

func (d *loopDouble) DeleteTopicLoops(_ context.Context, tenant, task string) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	n := 0
	for id, l := range d.loops {
		if l.TenantID == tenant && l.TaskID == strings.ToLower(task) {
			delete(d.loops, id)
			n++
		}
	}
	return n, nil
}

func (d *loopDouble) CountTopicLoopFire(_ context.Context, tenant, id string, at time.Time, limit int) (store.TopicLoop, bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	l, ok := d.loops[id]
	if !ok || l.TenantID != tenant || l.State != store.TopicLoopOn {
		return store.TopicLoop{}, false, nil
	}
	switch {
	case l.HourStart.IsZero() || !l.HourStart.After(at.Add(-time.Hour)):
		l.HourStart, l.FiresInHour = at, 1
	case l.FiresInHour < limit:
		l.FiresInHour++
	default:
		return *l, false, nil
	}
	l.FiresTotal++
	l.LastFiredAt = at
	return *l, true, nil
}

func (d *loopDouble) ClaimDueTopicLoops(_ context.Context, at time.Time, limit int) ([]store.TopicLoop, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []store.TopicLoop
	dueAt := func(t time.Time) bool { return !t.IsZero() && !t.After(at) }
	for _, l := range d.loops {
		if len(out) >= limit || l.State != store.TopicLoopOn {
			continue
		}
		var due []string
		var pre time.Time // v0.5 DueAt: the earliest due column before the move
		for _, c := range []time.Time{l.NextDueAt, l.DailyDueAt} {
			if dueAt(c) && (pre.IsZero() || c.Before(pre)) {
				pre = c
			}
		}
		if dueAt(l.NextDueAt) {
			due = append(due, l.Triggers[slices.IndexFunc(l.Triggers, func(k string) bool {
				return k == store.LoopEveryHour || k == store.LoopEveryNMinutes
			})])
			l.NextDueAt = loopDue(*l, at)
		}
		if dueAt(l.DailyDueAt) {
			due = append(due, store.LoopDailyAt)
			l.DailyDueAt = loopDaily(*l, at)
		}
		claimed := *l
		if dueAt(l.IdleDueAt) {
			due = append(due, store.LoopNoReplyAfterHuman)
			l.IdleDueAt, l.IdlePost = time.Time{}, ""
		}
		if len(due) > 0 {
			claimed.Due, claimed.DueAt, claimed.NextDueAt, claimed.DailyDueAt, claimed.IdleDueAt = due, pre, l.NextDueAt, l.DailyDueAt, time.Time{}
			out = append(out, claimed)
		}
	}
	return out, nil
}

func (d *loopDouble) SetTopicLoopAwaiting(_ context.Context, tenant, id, agent string, until time.Time) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if l, ok := d.loops[id]; ok && l.TenantID == tenant {
		l.Awaiting, l.AwaitUntil = agent, until
	}
	return nil
}

func (d *loopDouble) ArmTopicLoopIdle(_ context.Context, tenant, task, post string, at time.Time) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	n := 0
	for _, l := range d.loops {
		if l.TenantID == tenant && l.TaskID == strings.ToLower(task) && l.State == store.TopicLoopOn && l.IdleMin > 0 {
			l.IdleDueAt, l.IdlePost = at.Add(time.Duration(l.IdleMin)*time.Minute), post
			n++
		}
	}
	return n, nil
}

func (d *loopDouble) ClearTopicLoopIdle(_ context.Context, tenant, task string) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	n := 0
	for _, l := range d.loops {
		if l.TenantID == tenant && l.TaskID == strings.ToLower(task) && !l.IdleDueAt.IsZero() {
			l.IdleDueAt, l.IdlePost = time.Time{}, ""
			n++
		}
	}
	return n, nil
}

func (d *loopDouble) TenantHasTopicLoops(_ context.Context, tenant string) (bool, error) {
	d.hasN.Add(1)
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, l := range d.loops {
		if l.TenantID == tenant {
			return true, nil
		}
	}
	return false, nil
}

// loopRoles: HUM-8 owns the workspace, HUM-9 is an admin, an id in gone
// is not a member; everyone else is a developer.
type loopRoles struct{ gone map[string]bool }

func (r loopRoles) Access(ctx context.Context, hum, tenant string) (rbac.Access, error) {
	if r.gone[hum] {
		return rbac.Access{}, rbac.ErrNotMember
	}
	return roleOf{"HUM-8": rbac.BizOwner, "HUM-9": rbac.Admin}.Access(ctx, hum, tenant)
}

func (r loopRoles) Roles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	return rbac.Fixed(rbac.Developer).Roles(ctx, tenant)
}

// loopRig: CLE-07 on box-a opened a channel-less topic with a note to
// HUM-1; box-wui is pinned; the store is a loopDouble.
type loopRig struct {
	e     *env
	d     *loopDouble
	roles loopRoles
	key   ed25519.PrivateKey
	tid   string
	task  string
	a     *box
}

func newLoopRig(t *testing.T, mut ...func(*hub.Options)) *loopRig {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	r := &loopRig{d: newLoopDouble(), roles: loopRoles{gone: map[string]bool{}}, key: key}
	r.e = newEnv(t, append([]func(*hub.Options){func(o *hub.Options) {
		o.Store, o.ViewDoor, o.LobbyTaskID = r.d, hub.ViewDoorOff, lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.WUIKey, o.WUIDispatch = key, true
		o.Authorizer = r.roles
		o.SessionID = func(q *http.Request, _ string) (string, error) {
			if v := q.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	}}, mut...)...)
	r.e.st = r.d
	r.tid, _ = r.e.tenant()
	r.a = r.e.box(r.tid, "box-a", "CLE-07")
	r.e.pin(r.tid, r.a)
	r.e.pinKey(r.tid, hub.WUIBox, pub)
	r.task = r.agentSay(t, "", "HUM-1", "the outage is over")
	return r
}

// agentSay: CLE-07 posts body to `to` in task ("" = a new task); the msg id.
func (r *loopRig) agentSay(t *testing.T, task, to, body string) string {
	t.Helper()
	res, err := action.SendCtx(context.Background(), r.a.cfg, action.SendArgs{
		From: "CLE-07", To: to, TaskID: task, Kind: "note", Body: body, ToBox: hub.WUIBox, Hub: r.a.c})
	if err != nil {
		t.Fatalf("agent send: %v", err)
	}
	if task == "" {
		return res.TaskID
	}
	return res.MsgID
}

// lobbyTopic makes the rig's topic a #lobby card HUM-1 started, which
// every member reads, with CLE-07's reply in it (the topic's agent).
func (r *loopRig) lobbyTopic(t *testing.T) {
	t.Helper()
	r.task = uuidV4()
	putCard(t, r.e, r.tid, r.task, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC().Add(-time.Minute))
	r.agentSay(t, r.task, "ALL-0", "the deploy finished at 10:02, both environments serve v1.4.2")
}

// barrier: box-a's next frame has been handled, so every hook of its
// earlier frames has run.
func (r *loopRig) barrier(t *testing.T) {
	t.Helper()
	r.agentSay(t, "", "HUM-1", "barrier")
}

// addLoop is POST /v1/topics/{task}/loops as HUM-1; the loop id.
func (r *loopRig) addLoop(t *testing.T, body map[string]any) string {
	t.Helper()
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/topics/"+r.task+"/loops", "HUM-1", body)
	if code != http.StatusCreated {
		t.Fatalf("add loop: %d %v", code, out)
	}
	return out["loop_id"].(string)
}

func loopBody(triggers ...string) map[string]any {
	return map[string]any{"prompt": "export this topic as a PDF", "triggers": triggers}
}

// wuiPost sends body as the member socket's post in the rig's topic; the ack.
func (r *loopRig) wuiPost(t *testing.T, w *websocket.Conn, id, to, body string) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": r.task, "kind": "note", "body": body, "is_parent": 0}
	if to != "" {
		f["to"] = to
	}
	wsjson.Write(context.Background(), w, f) //nolint:errcheck
	return readType(t, w, "ack")
}

// wuiBarrier: the socket's next frame was handled, so wuiAfterStore of the
// one before has run.
func (r *loopRig) wuiBarrier(t *testing.T, w *websocket.Conn) {
	t.Helper()
	wsjson.Write(context.Background(), w, map[string]any{"type": "send", "msg_id": uuidV4(), "task_id": uuidV4(), //nolint:errcheck
		"to": "HUM-2", "kind": "note", "body": "barrier"})
	readType(t, w, "ack")
}

func (r *loopRig) wantPrompts(t *testing.T, label string, n int) []store.Message {
	t.Helper()
	got := r.d.prompts()
	if len(got) != n {
		t.Fatalf("%s: %d loop prompts, want %d", label, len(got), n)
	}
	return got
}

// Each of the four post triggers fires on its own event, and the prompt is
// 4.3's message: task from the author to the topic's agent, signed by
// box-wui for its box, the loop id on the row, the id derived from (loop,
// trigger), the trigger quoted.
func TestTopicLoopAfterHumanReplyFires(t *testing.T) {
	r := newLoopRig(t)
	loop := r.addLoop(t, loopBody(store.LoopAfterHumanReply))
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	post := uuidV4()
	r.wuiPost(t, w, post, "", "is the hub back on prd?")
	r.wuiBarrier(t, w)
	p := r.wantPrompts(t, "after_human_reply", 1)[0]
	if p.LoopID != loop || p.FromID != "HUM-1" || p.FromBox != hub.WUIBox || p.ToID != "CLE-07" || p.ToBox != "box-a" ||
		p.Kind != "task" || p.TaskID != r.task || p.MsgID != uid.FromSeed("topic-loop:"+loop+":"+post) {
		t.Fatalf("prompt row %+v", p)
	}
	for _, want := range []string{"Loop prompt (background; set by @HUM-1, fired by msg:" + post + ")", "export this topic as a PDF", "> is the hub back on prd?"} {
		if !strings.Contains(p.Body, want) {
			t.Fatalf("prompt body lacks %q:\n%s", want, p.Body)
		}
	}
	if st, err := r.d.DeliveryState(context.Background(), r.tid, p.MsgID, "box-a"); err != nil || st != store.StateQueued && st != store.StateSent {
		t.Fatalf("prompt not queued for box-a: %v %v", st, err)
	}
}

func TestTopicLoopBeforeAgentReplyQueuesPromptFirst(t *testing.T) {
	r := newLoopRig(t)
	r.addLoop(t, loopBody(store.LoopBeforeAgentReply))
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	post := uuidV4()
	if ack := r.wuiPost(t, w, post, "CLE-07", "please check the hub"); ack["to_box"] != "box-a" {
		t.Fatalf("the post went to no agent: %v", ack)
	}
	p := r.wantPrompts(t, "before_agent_reply", 1)[0]
	if pi, qi := r.d.rowIndex(p.MsgID), r.d.rowIndex(post); pi < 0 || qi < 0 || pi > qi {
		t.Fatalf("prompt stored at %d, the post at %d: the box must get the prompt first", pi, qi)
	}
	q, err := r.d.QueuedFor(context.Background(), r.tid, "box-a", time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(q))
	for _, x := range q {
		ids = append(ids, x.MsgID)
	}
	if pi, qi := slices.Index(ids, p.MsgID), slices.Index(ids, post); pi < 0 || qi < 0 || pi > qi {
		t.Fatalf("box-a queue order %v: prompt %s must come before post %s", ids, p.MsgID, post)
	}
	// A browser post that reaches no agent fires nothing.
	r.wuiPost(t, w, uuidV4(), "HUM-2", "a note to a person")
	r.wuiBarrier(t, w)
	r.wantPrompts(t, "a post to a person", 1)
}

func TestTopicLoopAfterAgentReplyFires(t *testing.T) {
	r := newLoopRig(t)
	loop := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	reply := r.agentSay(t, r.task, "ALL-0", "done: the hub is back")
	r.barrier(t)
	p := r.wantPrompts(t, "after_agent_reply", 1)[0]
	if p.ToID != "CLE-07" || p.MsgID != uid.FromSeed("topic-loop:"+loop+":"+reply) || !strings.Contains(p.Body, "> done: the hub is back") {
		t.Fatalf("prompt %+v", p)
	}
	// An agent-to-agent send on the task is not a reply (section 2).
	if _, err := action.SendCtx(context.Background(), r.a.cfg, action.SendArgs{From: "CLE-07", To: "CLE-08", TaskID: r.task,
		Kind: "note", Body: "peer note", ToBox: "box-a", Hub: r.a.c}); err != nil {
		t.Logf("peer send refused (fine, it fires nothing either way): %v", err)
	}
	r.barrier(t)
	r.wantPrompts(t, "agent-to-agent", 1)
}

// A post that matches two checked boxes fires once, and counts once.
func TestTopicLoopTwoBoxesFireOnce(t *testing.T) {
	r := newLoopRig(t)
	agentSide := r.addLoop(t, map[string]any{"prompt": "mail it", "keyword": "PDF",
		"triggers": []string{store.LoopAfterAgentReply, store.LoopPostHasKeyword}})
	humanSide := r.addLoop(t, loopBody(store.LoopBeforeAgentReply, store.LoopAfterHumanReply))
	r.agentSay(t, r.task, "HUM-1", "the PDF is ready")
	r.barrier(t)
	r.wantPrompts(t, "agent reply matching two boxes", 1)
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	r.wuiPost(t, w, uuidV4(), "CLE-07", "a post to the agent")
	r.wuiBarrier(t, w)
	r.wantPrompts(t, "human post matching two boxes", 2)
	for _, id := range []string{agentSide, humanSide} {
		if got := r.d.get(id).FiresTotal; got != 1 {
			t.Fatalf("loop %s counted %d fires, want 1", id, got)
		}
	}
}

// A replay of a stored post fires nothing: neither the after hook (only an
// inserted row) nor the before hook (the post is already stored).
func TestTopicLoopReplayDoesNotFire(t *testing.T) {
	r := newLoopRig(t)
	loop := r.addLoop(t, loopBody(store.LoopBeforeAgentReply, store.LoopAfterHumanReply))
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	post := uuidV4()
	r.wuiPost(t, w, post, "CLE-07", "once")
	r.wuiPost(t, w, post, "CLE-07", "once")
	r.wuiBarrier(t, w)
	r.wantPrompts(t, "replay", 1)
	if got := r.d.get(loop).FiresTotal; got != 1 {
		t.Fatalf("a replay counted a fire: %d", got)
	}
}

// The stored prompt (from the author, box-wui) is not a human post and
// fires no loop, so an after_human_reply loop counts only the real post.
func TestTopicLoopPromptMessageDoesNotFire(t *testing.T) {
	r := newLoopRig(t)
	loop := r.addLoop(t, loopBody(store.LoopAfterHumanReply, store.LoopAfterAgentReply))
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	r.wuiPost(t, w, uuidV4(), "", "one human post")
	r.wuiBarrier(t, w)
	r.barrier(t)
	r.wantPrompts(t, "one post", 1)
	if got := r.d.get(loop).FiresTotal; got != 1 {
		t.Fatalf("the loop prompt fired its loop: %d fires", got)
	}
}

// Q10 A (the default): the agent's next reply after a fire is its answer
// and does not fire that loop; the reply after it does.
func TestTopicLoopAwaitedAnswerDoesNotRefire(t *testing.T) {
	r := newLoopRig(t)
	loop := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	r.agentSay(t, r.task, "ALL-0", "a real reply")
	r.barrier(t)
	if l := r.d.get(loop); l.Awaiting != "CLE-07" || l.AwaitUntil.IsZero() {
		t.Fatalf("the fire set no wait: %+v", l)
	}
	r.agentSay(t, r.task, "ALL-0", "PDF sent")
	r.barrier(t)
	r.wantPrompts(t, "the awaited answer", 1)
	if l := r.d.get(loop); l.Awaiting != "" {
		t.Fatalf("the answer did not clear the wait: %+v", l)
	}
	r.agentSay(t, r.task, "ALL-0", "another real reply")
	r.barrier(t)
	r.wantPrompts(t, "the reply after the answer", 2)
}

// Q10 A holds only the loop that fired: the awaited answer still fires
// the topic's other loops (4.2 step 7, 4.4).
func TestTopicLoopAwaitedAnswerFiresOtherLoops(t *testing.T) {
	r := newLoopRig(t)
	first := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	r.agentSay(t, r.task, "ALL-0", "a real reply")
	r.barrier(t)
	r.wantPrompts(t, "the first loop's fire", 1)
	second := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	r.agentSay(t, r.task, "ALL-0", "PDF sent")
	r.barrier(t)
	r.wantPrompts(t, "the answer fires the other loop", 2)
	if a, b := r.d.get(first).FiresTotal, r.d.get(second).FiresTotal; a != 1 || b != 1 {
		t.Fatalf("fires: first %d, second %d, want 1 and 1", a, b)
	}
}

// The cap (answer 4 B): 30 agent replies are 15 fires and 15 awaited
// answers (Q10 A); the loop fires 12 times and the 13th fire in the hour
// does not happen.
func TestTopicLoopCapHoldsThe13thFire(t *testing.T) {
	r := newLoopRig(t)
	loop := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	for i := 0; i < 30; i++ {
		r.agentSay(t, r.task, "ALL-0", "reply")
	}
	r.barrier(t)
	r.wantPrompts(t, "30 agent replies", 12)
	if l := r.d.get(loop); l.FiresInHour != 12 {
		t.Fatalf("fires in hour %d", l.FiresInHour)
	}
	code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/topics/"+r.task+"/loops", "HUM-1", nil)
	loops, _ := out["loops"].([]any)
	if code != http.StatusOK || len(loops) != 1 || loops[0].(map[string]any)["held_until"] == nil {
		t.Fatalf("a capped loop shows no held_until: %d %v", code, out)
	}
}

// A paused loop, a paused topic and an archived topic fire nothing.
func TestTopicLoopHeldLoopsAndTopicsDoNotFire(t *testing.T) {
	r := newLoopRig(t)
	ctx := context.Background()
	loop := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	if code, out := call(t, r.e, r.tid, http.MethodPut, "/v1/topics/"+r.task+"/loops/"+loop, "HUM-1", map[string]any{"state": "paused"}); code != http.StatusOK || out["state"] != "paused" {
		t.Fatalf("pause: %d %v", code, out)
	}
	r.agentSay(t, r.task, "ALL-0", "paused loop")
	r.barrier(t)
	r.wantPrompts(t, "paused loop", 0)
	call(t, r.e, r.tid, http.MethodPut, "/v1/topics/"+r.task+"/loops/"+loop, "HUM-1", map[string]any{"state": "on"})
	if _, err := r.d.SetTopicPaused(ctx, r.tid, r.task, "HUM-1", "hold", time.Now(), true); err != nil {
		t.Fatal(err)
	}
	r.agentSay(t, r.task, "ALL-0", "paused topic")
	r.barrier(t)
	r.wantPrompts(t, "paused topic", 0)
	if _, err := r.d.SetTopicPaused(ctx, r.tid, r.task, "HUM-1", "", time.Now(), false); err != nil {
		t.Fatal(err)
	}
	r.agentSay(t, r.task, "ALL-0", "resumed topic")
	r.barrier(t)
	r.wantPrompts(t, "resumed topic", 1)
}

func TestTopicLoopArchivedTopicDoesNotFire(t *testing.T) {
	r := newLoopRig(t)
	ctx := context.Background()
	loop := r.addLoop(t, map[string]any{"prompt": "summarise", "triggers": []string{store.LoopEveryNMinutes}, "interval_min": 5})
	rows, err := r.d.ViewTopic(ctx, r.tid, store.TopicMsgQuery{TaskID: r.task, Limit: 1, Now: time.Now()})
	if err != nil || len(rows) == 0 {
		t.Fatalf("opening card: %v", err)
	}
	if _, err := r.d.SetArchived(ctx, r.tid, rows[0].MsgID, "HUM-1", time.Now(), true); err != nil {
		t.Fatal(err)
	}
	r.d.mu.Lock()
	r.d.loops[loop].NextDueAt = time.Now().Add(-time.Minute)
	r.d.mu.Unlock()
	if n := r.e.srv.TopicLoopTickOnce(ctx); n != 1 {
		t.Fatalf("claimed %d due loops, want 1", n)
	}
	r.wantPrompts(t, "archived topic", 0)
}

// The author's right is re-checked at every fire (answer 5 A): the policy
// table, and an author who left.
func TestTopicLoopAuthorPolicyTable(t *testing.T) {
	for _, c := range []struct {
		policy, author string
		fires          bool
	}{
		{store.ArchivePolicyEveryone, "HUM-2", true},
		{store.ArchivePolicyAdmins, "HUM-2", false},
		{store.ArchivePolicyAdmins, "HUM-9", true},
		{store.ArchivePolicyStarter, "HUM-2", false},
		{store.ArchivePolicyStarter, "HUM-1", true},
		{store.ArchivePolicyStarter, "HUM-8", true},
	} {
		t.Run(c.policy+"/"+c.author, func(t *testing.T) {
			r := newLoopRig(t)
			r.lobbyTopic(t)
			code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/topics/"+r.task+"/loops", c.author, loopBody(store.LoopAfterAgentReply))
			if code != http.StatusCreated {
				t.Fatalf("add as %s: %d %v", c.author, code, out)
			}
			p := c.policy
			if err := r.d.SetTenantConfig(context.Background(), r.tid, store.TenantConfigPatch{TopicArchivePolicy: &p}); err != nil {
				t.Fatal(err)
			}
			r.agentSay(t, r.task, "ALL-0", "a reply")
			r.barrier(t)
			want := 0
			if c.fires {
				want = 1
			}
			r.wantPrompts(t, c.policy+" "+c.author, want)
		})
	}
	t.Run("author_left", func(t *testing.T) {
		r := newLoopRig(t)
		r.lobbyTopic(t)
		loop := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
		r.roles.gone["HUM-1"] = true
		r.agentSay(t, r.task, "ALL-0", "a reply")
		r.barrier(t)
		r.wantPrompts(t, "author left", 0)
		if code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/topics/"+r.task+"/loops", "HUM-2", nil); code != http.StatusOK ||
			out["loops"].([]any)[0].(map[string]any)["idle"] != "author_left" {
			t.Fatalf("loop %s shows no author_left: %d %v", loop, code, out)
		}
	})
}

// No browser socket ever gets a frame of a loop prompt row (5.2): the
// author's socket, a party of the row, sees the next post's frame and never
// the prompt's.
func TestTopicLoopPromptReachesNoBrowser(t *testing.T) {
	r := newLoopRig(t)
	r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	wsjson.Write(context.Background(), w, map[string]any{"type": "subscribe", "task_id": r.task}) //nolint:errcheck
	r.agentSay(t, r.task, "HUM-1", "a reply to the author")
	r.barrier(t)
	p := r.wantPrompts(t, "fired", 1)[0]
	mark := r.agentSay(t, r.task, "HUM-1", "the marker")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f map[string]any
		if err := wsjson.Read(ctx, w, &f); err != nil {
			t.Fatalf("the marker frame never came: %v", err)
		}
		raw, _ := f["env"].(map[string]any)
		inner, _ := raw["msg"].(map[string]any)
		id, _ := inner["msg_id"].(string)
		if id == "" {
			id, _ = f["msg_id"].(string)
		}
		if id == p.MsgID || strings.Contains(asText(f), "Loop prompt (background") {
			t.Fatalf("a browser got the loop prompt: %v", f)
		}
		if f["type"] == "message" && strings.Contains(asText(f), mark) {
			return
		}
	}
}

func asText(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// A tenant with no loop costs no loop read per post once its bit is
// cached (4.2 step 6): TenantHasTopicLoops once per TTL, TopicLoopsOn never.
func TestTopicLoopNoLoopTenantPaysNoRead(t *testing.T) {
	r := newLoopRig(t)
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	r.wuiPost(t, w, uuidV4(), "", "warm the bit")
	r.wuiBarrier(t, w)
	has := r.d.hasN.Load()
	for i := 0; i < 5; i++ {
		r.wuiPost(t, w, uuidV4(), "CLE-07", "a post")
		r.agentSay(t, r.task, "ALL-0", "a reply")
	}
	r.wuiBarrier(t, w)
	r.barrier(t)
	if got := r.d.hasN.Load(); got != has {
		t.Fatalf("TenantHasTopicLoops read %d more times inside the TTL", got-has)
	}
	if got := r.d.onN.Load(); got != 0 {
		t.Fatalf("TopicLoopsOn read %d times on a tenant with no loop", got)
	}
}

// The time ticker: a due loop fires once per claim; two hub instances on one
// store fire one tick once; a loop overdue by hours fires once, no burst.
func TestTopicLoopTimerFiresOncePerDueTick(t *testing.T) {
	r := newLoopRig(t)
	ctx := context.Background()
	loop := r.addLoop(t, map[string]any{"prompt": "status?", "triggers": []string{store.LoopEveryHour}})
	other, err := hub.New(hub.Options{Store: r.d, Blob: blob.Dir{Root: t.TempDir()}, Log: zerolog.Nop(), WUIKey: r.key, Authorizer: r.roles,
		TenantHostPattern: "{tenant}" + domain, QueueTTL: time.Hour, QueueMaxPerBox: 1000, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if n := r.e.srv.TopicLoopTickOnce(ctx); n != 0 {
		t.Fatalf("a loop due in an hour was claimed: %d", n)
	}
	r.d.mu.Lock()
	r.d.loops[loop].NextDueAt = time.Now().Add(-3 * time.Hour)
	r.d.mu.Unlock()
	if a, b := r.e.srv.TopicLoopTickOnce(ctx), other.TopicLoopTickOnce(ctx); a+b != 1 {
		t.Fatalf("two instances claimed %d+%d, want 1", a, b)
	}
	p := r.wantPrompts(t, "one due tick", 1)[0]
	if !strings.Contains(p.Body, "fired by its timer") || !strings.Contains(p.Body, "> the outage is over") {
		t.Fatalf("time prompt body:\n%s", p.Body)
	}
	if n := r.e.srv.TopicLoopTickOnce(ctx); n != 0 {
		t.Fatalf("an overdue loop fired a catch-up burst: %d more", n)
	}
	if due := r.d.get(loop).NextDueAt; !due.After(time.Now().Add(50 * time.Minute)) {
		t.Fatalf("next_due_at not moved on: %v", due)
	}
}

// --- v0.4: the six extra triggers (1.2 rows 7-12) ---

// wuiPostKind is wuiPost with a kind.
func (r *loopRig) wuiPostKind(t *testing.T, w *websocket.Conn, id, to, kind, body string) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": r.task, "kind": kind, "body": body, "is_parent": 0}
	if to != "" {
		f["to"] = to
	}
	wsjson.Write(context.Background(), w, f) //nolint:errcheck
	return readType(t, w, "ack")
}

// tick runs the ticker once at now: the loop's due column moved into the past.
func (r *loopRig) dueNow(t *testing.T, loop string, set func(l *store.TopicLoop)) {
	t.Helper()
	r.d.mu.Lock()
	set(r.d.loops[loop])
	r.d.mu.Unlock()
}

func TestTopicLoopKeywordAtWordEdges(t *testing.T) {
	r := newLoopRig(t)
	r.addLoop(t, map[string]any{"prompt": "mail it", "triggers": []string{store.LoopPostHasKeyword}, "keyword": "PDF"})
	r.agentSay(t, r.task, "ALL-0", "two pdfs are attached to the release notes")
	r.barrier(t)
	r.wantPrompts(t, "inside a word", 0)
	r.agentSay(t, r.task, "ALL-0", "the pdf, as asked, is in the release folder")
	r.barrier(t)
	r.wantPrompts(t, "agent reply with the keyword", 1)
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	r.wuiPost(t, w, uuidV4(), "", "send me the PDF again please")
	r.wuiBarrier(t, w)
	r.wantPrompts(t, "human post with the keyword", 2)
}

func TestTopicLoopFilePostFires(t *testing.T) {
	r := newLoopRig(t)
	r.addLoop(t, loopBody(store.LoopPostHasFile))
	r.agentSay(t, r.task, "ALL-0", "the report is ready, no attachment this time")
	r.barrier(t)
	r.wantPrompts(t, "a plain post", 0)
	f := t.TempDir() + "/report.txt"
	if err := writeFile(f, "quarterly numbers"); err != nil {
		t.Fatal(err)
	}
	if _, err := action.SendCtx(context.Background(), r.a.cfg, action.SendArgs{From: "CLE-07", To: "ALL-0", TaskID: r.task,
		Kind: "note", Body: "the report is attached", PutFiles: []string{f}, ToBox: hub.WUIBox, Hub: r.a.c}); err != nil {
		t.Fatal(err)
	}
	r.barrier(t)
	r.wantPrompts(t, "a post with a file", 1)
}

// blocker_posted fires from an agent-to-agent send, a browser post and a
// kind change; the kind change back does not.
func TestTopicLoopBlockerFromThreePlaces(t *testing.T) {
	r := newLoopRig(t)
	r.addLoop(t, loopBody(store.LoopBlockerPosted))
	r.e.pin(r.tid, r.e.box(r.tid, "box-b", "CLE-08"))
	if _, err := action.SendCtx(context.Background(), r.a.cfg, action.SendArgs{From: "CLE-07", To: "CLE-08", TaskID: r.task,
		Kind: "blocker", Body: "the build cache is corrupt, cannot continue", ToBox: "box-b", Hub: r.a.c}); err != nil {
		t.Fatalf("agent-to-agent blocker: %v", err)
	}
	r.barrier(t)
	if p := r.wantPrompts(t, "agent-to-agent blocker", 1)[0]; p.ToID != "CLE-07" {
		t.Fatalf("an agent's blocker goes to that agent: %+v", p.ToID)
	}
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	r.wuiPostKind(t, w, uuidV4(), "", "blocker", "the deploy key expired, nobody can push")
	r.wuiBarrier(t, w)
	r.wantPrompts(t, "browser blocker", 2)
	note := uuidV4()
	r.wuiPost(t, w, note, "", "the vpn is down for the whole office")
	r.wuiBarrier(t, w)
	r.wantPrompts(t, "a plain browser post", 2)
	if code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/messages/"+note+"/kind", "HUM-1", map[string]string{"kind": "blocker"}); code != http.StatusOK {
		t.Fatalf("mark blocker: %d %v", code, out)
	}
	r.wantPrompts(t, "marked a blocker", 3)
	if code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/messages/"+note+"/kind", "HUM-1", map[string]string{"kind": "note"}); code != http.StatusOK {
		t.Fatalf("unmark: %d %v", code, out)
	}
	r.wantPrompts(t, "the kind change back", 3)
}

// no_reply_after_human: armed by a human post, fired once by the ticker
// quoting that post, never after an agent reply, re-armed by a later post.
func TestTopicLoopIdleFiresOnceWithoutReply(t *testing.T) {
	r := newLoopRig(t)
	ctx := context.Background()
	loop := r.addLoop(t, map[string]any{"prompt": "nudge the agent", "triggers": []string{store.LoopNoReplyAfterHuman}, "idle_min": 15})
	w := dialMember(t, r.e, r.tid, "Owner", "HUM-1")
	first := uuidV4()
	r.wuiPost(t, w, first, "", "can someone check the backup job?")
	r.wuiBarrier(t, w)
	if l := r.d.get(loop); l.IdlePost != first || l.IdleDueAt.IsZero() {
		t.Fatalf("the human post did not arm: %+v", l)
	}
	r.agentSay(t, r.task, "ALL-0", "the backup job ran at 02:00 and finished")
	r.barrier(t)
	if l := r.d.get(loop); !l.IdleDueAt.IsZero() {
		t.Fatalf("the agent reply did not clear: %+v", l)
	}
	r.e.srv.TopicLoopTickOnce(ctx)
	r.wantPrompts(t, "after an agent reply", 0)
	second := uuidV4()
	r.wuiPost(t, w, second, "", "and the restore test?")
	r.wuiBarrier(t, w)
	r.dueNow(t, loop, func(l *store.TopicLoop) { l.IdleDueAt = time.Now().Add(-time.Second) })
	r.e.srv.TopicLoopTickOnce(ctx)
	p := r.wantPrompts(t, "idle", 1)[0]
	if p.MsgID != uid.FromSeed("topic-loop:"+loop+":"+second) || !strings.Contains(p.Body, "> and the restore test?") {
		t.Fatalf("idle prompt %s:\n%s", p.MsgID, p.Body)
	}
	r.e.srv.TopicLoopTickOnce(ctx)
	r.wantPrompts(t, "idle fires once per arming", 1)
}

func TestTopicLoopDailyFiresOnceADay(t *testing.T) {
	r := newLoopRig(t)
	ctx := context.Background()
	loop := r.addLoop(t, map[string]any{"prompt": "daily digest", "triggers": []string{store.LoopDailyAt},
		"daily_at": "08:00", "daily_tz": "Europe/Helsinki"})
	code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/topics/"+r.task+"/loops", "HUM-1", nil)
	l0 := out["loops"].([]any)[0].(map[string]any)
	if code != http.StatusOK || l0["daily_at"] != "08:00" || l0["daily_tz"] != "Europe/Helsinki" || l0["daily_due_at"] == nil {
		t.Fatalf("daily fields: %d %v", code, l0)
	}
	r.dueNow(t, loop, func(l *store.TopicLoop) { l.DailyDueAt = time.Now().Add(-time.Minute) })
	if n := r.e.srv.TopicLoopTickOnce(ctx); n != 1 {
		t.Fatalf("claimed %d", n)
	}
	r.e.srv.TopicLoopTickOnce(ctx)
	r.wantPrompts(t, "daily", 1)
	if due := r.d.get(loop).DailyDueAt; !due.After(time.Now()) || due.After(time.Now().Add(25*time.Hour)) {
		t.Fatalf("next daily due %v", due)
	}
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/topics/"+r.task+"/loops", "HUM-1", map[string]any{"prompt": "x",
		"triggers": []string{store.LoopDailyAt}, "daily_at": "08:00", "daily_tz": "Mars/Olympus"}); code != http.StatusBadRequest || out["error"] != "bad_loop" {
		t.Fatalf("an unknown zone: %d %v", code, out)
	}
}

// issue_status_changed: a status change fires the loops of each linked
// topic once; a priority-only change does not.
func TestTopicLoopIssueStatusChange(t *testing.T) {
	r := newLoopRig(t)
	r.lobbyTopic(t)
	first := r.task
	r.addLoop(t, loopBody(store.LoopIssueStatusChanged))
	r.lobbyTopic(t)
	r.addLoop(t, loopBody(store.LoopIssueStatusChanged))
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/issues", "HUM-1", map[string]any{"title": "Backup restore fails",
		"discussions": []string{first, r.task}})
	if code != http.StatusCreated {
		t.Fatalf("create issue: %d %v", code, out)
	}
	key, _ := issueOf(t, out)["key"].(string)
	if code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/issues/"+key, "HUM-1", map[string]any{"priority": 1}); code != http.StatusOK {
		t.Fatalf("priority: %d %v", code, out)
	}
	r.wantPrompts(t, "a priority-only change", 0)
	if code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/issues/"+key, "HUM-1", map[string]any{"status": "wip"}); code != http.StatusOK {
		t.Fatalf("status: %d %v", code, out)
	}
	ps := r.wantPrompts(t, "a status change, two linked topics", 2)
	if ps[0].TaskID == ps[1].TaskID || !strings.Contains(ps[0].Body, key+" Backup restore fails: ") || !strings.Contains(ps[0].Body, "-> wip, by HUM-1") {
		t.Fatalf("issue prompts: %s / %s\n%s", ps[0].TaskID, ps[1].TaskID, ps[0].Body)
	}
}

func writeFile(p, body string) error { return os.WriteFile(p, []byte(body), 0o600) }

// --- v0.5: spec 182 section 8.2 ---

// Point 1: a loop with every_n_minutes and daily_at whose daily fire
// follows an interval fire sends both. The seed is the pre-move due time
// (DueAt); the post-move columns would seed both fires alike.
func TestTopicLoopDailyAfterIntervalFiresBoth(t *testing.T) {
	r := newLoopRig(t)
	ctx := context.Background()
	loop := r.addLoop(t, map[string]any{"prompt": "digest", "triggers": []string{store.LoopEveryNMinutes, store.LoopDailyAt},
		"interval_min": 60, "daily_at": "09:00", "daily_tz": "UTC"})
	now := time.Now().UTC()
	r.dueNow(t, loop, func(l *store.TopicLoop) {
		l.NextDueAt, l.DailyDueAt = now.Add(-30*time.Minute), now.Add(time.Hour)
	})
	if n := r.e.srv.TopicLoopTickOnce(ctx); n != 1 {
		t.Fatalf("interval tick claimed %d", n)
	}
	moved := r.d.get(loop).NextDueAt
	r.dueNow(t, loop, func(l *store.TopicLoop) { l.DailyDueAt = now.Add(-time.Minute) })
	if r.d.get(loop).NextDueAt != moved || !moved.After(now) {
		t.Fatalf("next_due_at %v, want the moved %v", r.d.get(loop).NextDueAt, moved)
	}
	if n := r.e.srv.TopicLoopTickOnce(ctx); n != 1 {
		t.Fatalf("daily tick claimed %d", n)
	}
	p := r.wantPrompts(t, "interval then daily", 2)
	if p[0].MsgID == p[1].MsgID {
		t.Fatalf("the daily fire reused the interval fire's msg_id %s", p[0].MsgID)
	}
}

// Point 2: archiving or deleting the topic leaves no loop; unarchiving
// brings none back. HUM-1 started the #lobby card, so it may do both.
func TestTopicLoopArchiveAndDeleteDropLoops(t *testing.T) {
	r := newLoopRig(t)
	r.lobbyTopic(t)
	ctx := context.Background()
	card := func() string {
		rows, err := r.d.ViewTopic(ctx, r.tid, store.TopicMsgQuery{TaskID: r.task, Limit: 1, Now: time.Now()})
		if err != nil || len(rows) == 0 {
			t.Fatalf("opening card: %v", err)
		}
		return rows[0].MsgID
	}
	count := func() int {
		ls, _ := r.d.TopicLoops(ctx, r.tid, r.task)
		return len(ls)
	}
	r.addLoop(t, loopBody(store.LoopAfterHumanReply))
	r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	id := card()
	if code, out := call(t, r.e, r.tid, http.MethodPut, "/v1/messages/"+id+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	if n := count(); n != 0 {
		t.Fatalf("archived topic keeps %d loops", n)
	}
	if code, out := call(t, r.e, r.tid, http.MethodDelete, "/v1/messages/"+id+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d %v", code, out)
	}
	if n := count(); n != 0 {
		t.Fatalf("unarchive brought back %d loops", n)
	}
	r.addLoop(t, loopBody(store.LoopAfterHumanReply))
	if code, out := call(t, r.e, r.tid, http.MethodDelete, "/v1/messages/"+id+"/topic", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("delete topic: %d %v", code, out)
	}
	if n := count(); n != 0 {
		t.Fatalf("deleted topic keeps %d loops", n)
	}
}

// Point 3: a member whose session id is not a v:1 id sets a loop. SetBy
// stores that member id; the JSON and the fired prompt speak as the
// HUM-<n> the hub derives for it, as editorID does for its posts.
func TestTopicLoopMemberIDIsNotTheV1ID(t *testing.T) {
	const member = "HUM-google-sub-1@t1"
	r := newLoopRig(t)
	r.lobbyTopic(t)
	ctx := context.Background()
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/topics/"+r.task+"/loops", member,
		map[string]any{"prompt": "status?", "triggers": []string{store.LoopEveryHour}})
	if code != http.StatusCreated {
		t.Fatalf("add loop: %d %v", code, out)
	}
	loop, from := out["loop_id"].(string), out["set_by"].(string)
	if got := r.d.get(loop).SetBy; got != member {
		t.Fatalf("SetBy %q, want the member id %q", got, member)
	}
	if !msg.ValidID(from) || from == member {
		t.Fatalf("set_by %q is not a derived v:1 id", from)
	}
	r.dueNow(t, loop, func(l *store.TopicLoop) { l.NextDueAt = time.Now().Add(-time.Minute) })
	if n := r.e.srv.TopicLoopTickOnce(ctx); n != 1 {
		t.Fatalf("claimed %d", n)
	}
	p := r.wantPrompts(t, "member id loop", 1)[0]
	if p.FromID != from || !strings.Contains(p.Body, "set by @"+from+",") {
		t.Fatalf("prompt from %q body:\n%s\nwant from %q", p.FromID, p.Body, from)
	}
}
