package hub_test

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// An unanswered blocker becomes an issue assigned to whoever it tags (owner
// HUM-10, csitea e48433ef msg 2512ff1f; corrected in t1 de3c2cf5 msg
// 26c89f60). Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full).

// blockerClock is the hub clock the sweep reads; tests move it.
type blockerClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *blockerClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *blockerClock) set(t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = t
}

type blockerRig struct {
	e        *env
	clock    *blockerClock
	base     time.Time
	tid      string
	admin    string // the blocker's author, an admin
	target   string // the person it tags
	bystand  string // another member
	agent    string // a roster agent
	otherTID string
}

func newBlockerRig(t *testing.T) *blockerRig {
	t.Helper()
	base := time.Now().UTC().Truncate(time.Second).Add(-30 * time.Minute)
	c := &blockerClock{t: base}
	e := rbacEnv(t, func(o *hub.Options) { o.Now = c.now })
	tid, _ := e.tenant()
	other, _ := e.tenant()
	r := &blockerRig{e: e, clock: c, base: base, tid: tid, otherTID: other, agent: "c-123",
		admin: seat(t, e, tid, rbac.Admin), target: seat(t, e, tid, rbac.Developer), bystand: seat(t, e, tid, rbac.Developer)}
	if err := e.st.SetRoster(context.Background(), tid, "box-a", []string{r.agent}, time.Now()); err != nil {
		t.Fatal(err)
	}
	return r
}

// post stores one message in tenant tid, topic task, received at: a DM when
// it is to a person, else a #devel post.
func (r *blockerRig) post(t *testing.T, tid, task, from, to, kind, body string, at time.Time) string {
	t.Helper()
	id, channel := uid.New(), "devel"
	if strings.HasPrefix(to, "HUM-") {
		channel = ""
	}
	m := store.Message{TenantID: tid, MsgID: id, TaskID: task, Channel: channel, TS: at,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: to, Kind: kind, Body: body,
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte(`{"env":1}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := r.e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return id
}

// sweep runs one sweep at base + d.
func (r *blockerRig) sweep(d time.Duration) hub.BlockerSweepResult {
	r.clock.set(r.base.Add(d))
	return r.e.srv.SweepBlockerIssues(context.Background(), time.Hour)
}

// blockerIssues is the tenant's issues labelled blocker, archived ones too:
// a blocker epic closes and archives itself with its issues when its last
// open one closes (SPL-1729), so the hub's epics are unarchived first.
func (r *blockerRig) blockerIssues(t *testing.T, tid string) []store.Issue {
	t.Helper()
	r.unarchiveBlockerEpics(t, tid)
	all, err := r.e.st.(store.Issues).ListIssues(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.Issue
	for _, i := range all {
		for _, l := range i.Labels {
			if l == store.BlockerIssueLabel {
				out = append(out, i)
			}
		}
	}
	return out
}

// unarchiveBlockerEpics restores every blocker epic the hub made in tid,
// with its issues; their statuses stay.
func (r *blockerRig) unarchiveBlockerEpics(t *testing.T, tid string) {
	t.Helper()
	ctx := context.Background()
	for prev := 0; ; {
		ref, err := r.e.st.(store.BlockerIssues).IssueByTask(ctx, tid, hub.BlockerEpicTask(tid, prev))
		if err != nil {
			return
		}
		if ref.Status == "" {
			r.e.st.(store.Issues).UnarchiveIssue(ctx, tid, ref.Number, "test", time.Now(), true) //nolint:errcheck
		}
		prev = ref.Number
	}
}

// resolvedBy is who set issue number done, from its history: the row's
// updated_by is the unarchive's once blockerIssues restored it.
func (r *blockerRig) resolvedBy(t *testing.T, number int) string {
	t.Helper()
	evs, err := r.e.st.(store.IssueHistories).IssueHistory(context.Background(), r.tid, number)
	if err != nil {
		t.Fatal(err)
	}
	by := ""
	for _, e := range evs {
		if e.Event == store.IssueEventChanged && e.Field == "status" && e.New != nil && *e.New == store.IssueDone {
			by = e.Actor
		}
	}
	return by
}

func (r *blockerRig) kindOf(t *testing.T, msgID string) string {
	t.Helper()
	m, err := r.e.st.GetEditable(context.Background(), r.tid, msgID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m.Kind
}

func TestBlockerUnansweredBecomesIssue(t *testing.T) {
	r := newBlockerRig(t)
	task := uid.New()
	id := r.post(t, r.tid, task, r.admin, r.target, "blocker", "Need the prd key rotated\nsecond line", r.base)

	if got := r.sweep(2 * time.Minute); got.Created != 0 {
		t.Fatalf("before N (3 min) the sweep made %d issues", got.Created)
	}
	if got := r.sweep(4 * time.Minute); got.Created != 1 {
		t.Fatalf("after N: created %d, want 1", got.Created)
	}
	is := r.blockerIssues(t, r.tid)
	if len(is) != 1 {
		t.Fatalf("want exactly 1 blocker issue, got %d", len(is))
	}
	i := is[0]
	if i.Assignee != r.target || i.CreatedBy != r.admin || i.Status != store.IssueTodo ||
		i.Title != "Need the prd key rotated" || !strings.Contains(i.Description, "(/m/"+id+")") {
		t.Fatalf("issue %+v", i)
	}
	if i.TaskID != store.BlockerIssueTask(r.tid, id, r.target) {
		t.Fatalf("issue topic %s is not the derived one", i.TaskID)
	}
	// A second tick, and a second hub process's tick, make no duplicate.
	if got := r.sweep(5 * time.Minute); got.Created != 0 {
		t.Fatalf("second tick created %d", got.Created)
	}
	if n := len(r.blockerIssues(t, r.tid)); n != 1 {
		t.Fatalf("after a second tick: %d issues, want 1", n)
	}
	// Another workspace sees nothing.
	if n := len(r.blockerIssues(t, r.otherTID)); n != 0 {
		t.Fatalf("the other workspace got %d issues", n)
	}
}

func TestBlockerAnsweredInTimeMakesNoIssue(t *testing.T) {
	r := newBlockerRig(t)
	task := uid.New()
	r.post(t, r.tid, task, r.admin, "ALL-0", "blocker", "@"+r.target+" which bucket?", r.base)
	r.post(t, r.tid, task, r.target, "ALL-0", "note", "the dev one", r.base.Add(time.Minute))
	if got := r.sweep(4 * time.Minute); got.Created != 0 {
		t.Fatalf("an answer by the tagged person before N: created %d, want 0", got.Created)
	}
}

func TestBlockerAnswerBySomeoneElseStillConverts(t *testing.T) {
	r := newBlockerRig(t)
	task := uid.New()
	r.post(t, r.tid, task, r.admin, "ALL-0", "blocker", "@"+r.target+" which bucket?", r.base)
	r.post(t, r.tid, task, r.bystand, "ALL-0", "note", "not me", r.base.Add(time.Minute))
	r.sweep(4 * time.Minute)
	is := r.blockerIssues(t, r.tid)
	if len(is) != 1 || is[0].Assignee != r.target {
		t.Fatalf("a reply by someone else: want 1 issue for %s, got %+v", r.target, is)
	}
}

func TestBlockerSettingOffMakesNoIssue(t *testing.T) {
	r := newBlockerRig(t)
	code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/tenant/settings", r.admin,
		map[string]any{"settings": map[string]any{store.BlockerKeyIssueMinutes: 0}})
	if code != http.StatusOK {
		t.Fatalf("setting N=0: %d %v", code, out)
	}
	r.post(t, r.tid, uid.New(), r.admin, r.target, "blocker", "stuck", r.base)
	if got := r.sweep(30 * time.Minute); got.Created != 0 {
		t.Fatalf("N=0 (off): created %d", got.Created)
	}
	// The setting reads back in force; a value above a day is refused.
	if code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/tenant/settings", r.admin, nil); code != http.StatusOK ||
		out["settings"].(map[string]any)[store.BlockerKeyIssueMinutes] != float64(0) {
		t.Fatalf("read back: %d %v", code, out)
	}
	if code, _ := call(t, r.e, r.tid, http.MethodPatch, "/v1/tenant/settings", r.admin,
		map[string]any{"settings": map[string]any{store.BlockerKeyIssueMinutes: 1441}}); code != http.StatusBadRequest {
		t.Fatalf("N=1441: %d, want 400", code)
	}
}

func TestBlockerToAgentConverts(t *testing.T) {
	r := newBlockerRig(t)
	task := uid.New()
	r.post(t, r.tid, task, r.admin, "ALL-0", "blocker", "@"+r.agent+" the build is red", r.base)
	r.post(t, r.tid, uid.New(), r.admin, "ALL-0", "blocker", "@c-999 nobody here", r.base) // not a roster agent
	r.sweep(4 * time.Minute)
	is := r.blockerIssues(t, r.tid)
	if len(is) != 1 || is[0].Assignee != r.agent {
		t.Fatalf("a blocker to an agent: want 1 issue for %s, got %+v", r.agent, is)
	}
	// The agent answers (from its box, as <id>@<box>): the issue resolves.
	r.post(t, r.tid, task, r.agent+"@box-a", "ALL-0", "result", "fixed in abc123", r.base.Add(6*time.Minute))
	if got := r.sweep(7 * time.Minute); got.Resolved != 1 {
		t.Fatalf("agent answer: resolved %d, want 1", got.Resolved)
	}
}

func TestBlockerLateAnswerResolvesIssueAndClearsMark(t *testing.T) {
	r := newBlockerRig(t)
	task := uid.New()
	id := r.post(t, r.tid, task, r.admin, r.target, "blocker", "which bucket?", r.base)
	r.sweep(4 * time.Minute)
	reply := r.post(t, r.tid, task, r.target, r.admin, "note", "the dev bucket, sorry", r.base.Add(10*time.Minute))
	if got := r.sweep(11 * time.Minute); got.Resolved != 1 {
		t.Fatalf("late answer: resolved %d, want 1", got.Resolved)
	}
	is := r.blockerIssues(t, r.tid)
	if len(is) != 1 || is[0].Status != store.IssueDone || r.resolvedBy(t, is[0].Number) != r.target {
		t.Fatalf("issue after the late answer: %+v", is)
	}
	// The answer is the resolving comment, on the issue's topic.
	note, ok, err := r.e.st.(store.BlockerIssues).FirstPostAfter(context.Background(), r.tid, is[0].TaskID, hub.PublicNoticeFrom, r.base)
	if err != nil || !ok || !strings.Contains(note.Body, "the dev bucket, sorry") || !strings.Contains(note.Body, "(/m/"+reply+")") {
		t.Fatalf("resolving comment: ok=%v err=%v %q", ok, err, note.Body)
	}
	if k := r.kindOf(t, id); k == "blocker" {
		t.Fatalf("the blocker mark stayed after the issue resolved")
	}
	if got := r.sweep(12 * time.Minute); got.Created+got.Resolved != 0 {
		t.Fatalf("a tick after resolution did %+v", got)
	}
}

func TestBlockerClearingMarkResolvesIssue(t *testing.T) {
	r := newBlockerRig(t)
	id := r.post(t, r.tid, uid.New(), r.admin, r.target, "blocker", "which bucket?", r.base)
	r.sweep(4 * time.Minute)
	code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/messages/"+id+"/kind", r.admin, map[string]string{"kind": "note"})
	if code != http.StatusOK {
		t.Fatalf("clear mark: %d %v", code, out)
	}
	is := r.blockerIssues(t, r.tid)
	if len(is) != 1 || is[0].Status != store.IssueDone {
		t.Fatalf("clearing the mark: issue %+v, want done", is)
	}
}

func TestBlockerResolvingIssueClearsMark(t *testing.T) {
	r := newBlockerRig(t)
	id := r.post(t, r.tid, uid.New(), r.admin, "ALL-0", "blocker", "@"+r.target+" and @"+r.bystand+" which bucket?", r.base)
	r.sweep(4 * time.Minute)
	is := r.blockerIssues(t, r.tid)
	if len(is) != 2 {
		t.Fatalf("two tagged people: %d issues, want 2", len(is))
	}
	code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/issues/"+is[0].Key(), r.target, map[string]any{"status": store.IssueDone})
	if code != http.StatusOK {
		t.Fatalf("resolve issue: %d %v", code, out)
	}
	if k := r.kindOf(t, id); k != "note" {
		t.Fatalf("message kind %q after its issue resolved, want note", k)
	}
	// The mark is gone, so the other issue made from it resolves too.
	for _, i := range r.blockerIssues(t, r.tid) {
		if i.Status != store.IssueDone {
			t.Fatalf("issue %s still %s after the mark cleared", i.Key(), i.Status)
		}
	}
}
