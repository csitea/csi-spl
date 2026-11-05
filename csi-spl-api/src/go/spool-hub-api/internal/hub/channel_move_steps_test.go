// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// moveFix is one channel ready to move: a GO, a seat with its <DST> desk, an
// orchestrator seat in <DST>, a post with a blob, its task and the blob's id.
type moveFix struct {
	e                  *env
	src, dst, ch, goID string
	task, blobID, seat string
	moveID, op, owner  string
	form, formTask     string
	admin              string // the channel's human in <SRC>, no <DST> member
}

// moveFixture skips on Memory: P4 and the journal are Postgres only.
func moveFixture(t *testing.T, orchestrator bool, mut ...func(*hub.Options)) *moveFix {
	t.Helper()
	op := newTenantID("op")
	e := chanMoveEnv(t, append([]func(*hub.Options){func(o *hub.Options) { o.OperatorTenant = op }}, mut...)...)
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("the journal and P4 need Postgres (SPOOL_TEST_PG_DSN)")
	}
	ctx := context.Background()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(ctx, store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	f := &moveFix{e: e, ch: "mvrun-" + uuid4()[:8], seat: "c-204"}
	f.src, _ = e.tenant()
	f.dst, _ = e.tenant()
	owner := seat(t, e, op, rbac.BizOwner)
	f.admin = seat(t, e, f.src, rbac.Admin)
	f.task = moveChannel(t, e, f.src, f.ch, f.admin)
	movePinBox(t, e, f.dst)
	agents := []string{f.seat}
	if orchestrator {
		agents = append(agents, "c-001")
	}
	if err := e.st.SetRoster(ctx, f.dst, "box-a", agents, time.Now()); err != nil {
		t.Fatal(err)
	}
	moveExec(t, e, `INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by)
		VALUES ($1, $2, 'box-a', 'channel', $3, 'test')`, f.src, f.seat, f.ch)
	f.blobID = moveBlobPost(t, f)
	at := time.Now().UTC().Truncate(time.Second)
	formID, formTask := uuid4(), uuid4()
	movePost(t, e, op, formID, formTask, "", "c-001", "Move "+f.src+"/"+f.ch+" to "+f.dst+"?", at)
	f.goID = uuid4()
	movePost(t, e, op, f.goID, formTask, "", owner, "Poll: "+formID+"\nAnswer: GO — Go", at)
	f.op, f.owner, f.form, f.formTask = op, owner, formID, formTask
	return f
}

// moveExec runs one statement under the operator scope, as a fixture.
func moveExec(t *testing.T, e *env, sql string, args ...any) {
	t.Helper()
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, sql, args...)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// moveBlobPost stores a blob and sets it on the channel's post.
func moveBlobPost(t *testing.T, f *moveFix) string {
	t.Helper()
	data := []byte("the channel's file " + f.ch)
	sum := sha256.Sum256(data)
	id := hex.EncodeToString(sum[:])
	key, err := blob.Key(f.src, id)
	if err != nil {
		t.Fatal(err)
	}
	if err := (blob.Dir{Root: f.e.blobs}).Put(context.Background(), key, data); err != nil {
		t.Fatal(err)
	}
	moveExec(t, f.e, `UPDATE messages SET files = jsonb_build_array(jsonb_build_object('mode', 'blob', 'kind', 'file', 'file_id', $3::text, 'name', 'a.txt', 'bytes', $4::bigint))
		WHERE tenant_id = $1 AND task_id = $2::uuid`, f.src, f.task, id, len(data))
	return id
}

func (f *moveFix) blobIn(t *testing.T, tenant string) bool {
	t.Helper()
	key, err := blob.Key(tenant, f.blobID)
	if err != nil {
		t.Fatal(err)
	}
	ok, err := (blob.Dir{Root: f.e.blobs}).Exists(context.Background(), key)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// call is one op. "move_id" is the fixture's unless extra names another.
func (f *moveFix) call(t *testing.T, op, step string, extra map[string]any) (int, map[string]any) {
	t.Helper()
	body := map[string]any{"go_msg_id": f.goID}
	if f.moveID != "" {
		body["move_id"] = f.moveID
	}
	if step != "" {
		body["step"] = step
	}
	for k, v := range extra {
		body[k] = v
	}
	return opCall(t, f.e, f.src, http.MethodPost, moveURL, "good", chanMoveBody(op, f.src, f.ch, f.dst, body))
}

// must is a step that has to answer 200.
func (f *moveFix) must(t *testing.T, op, step string, extra map[string]any) map[string]any {
	t.Helper()
	code, out := f.call(t, op, step, extra)
	if code != http.StatusOK {
		t.Fatalf("%s %s: %d %v", op, step, code, out)
	}
	return out
}

// refused is a step that has to answer 409 naming what.
func (f *moveFix) refused(t *testing.T, op, step, what string, extra map[string]any) {
	t.Helper()
	code, out := f.call(t, op, step, extra)
	detail, _ := out["detail"].(string)
	if code != http.StatusConflict || !strings.Contains(detail, what) {
		t.Errorf("%s %s: %d %v, want 409 naming %q", op, step, code, out, what)
	}
}

// probe stores the seat's probe DM on the move's topic in <DST>, as P2b sends it.
func (f *moveFix) probe(t *testing.T) string {
	t.Helper()
	id := uuid4()
	movePost(t, f.e, f.dst, id, f.moveID, "", f.seat, "Channel move "+f.moveID+": desk probe", time.Now().UTC().Truncate(time.Second))
	return id
}

func (f *moveFix) probes(id string) map[string]any {
	return map[string]any{"detail": map[string]any{"probes": []map[string]any{{"agent": f.seat, "msg_id": id}}}}
}

// toP3 runs P1, P2, P2b, P3.
func (f *moveFix) toP3(t *testing.T) {
	t.Helper()
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	f.must(t, "step", "P2", nil)
	f.must(t, "mark", "P2b", f.probes(f.probe(t)))
	f.must(t, "step", "P3", nil)
}

func steps(out map[string]any) map[string]any {
	m, _ := out["steps"].(map[string]any)
	return m
}

// The whole of 8.2 through the endpoint on one channel, with the journal read
// the way the shell resumes from it. CONTROLS in the same run: the channel is in
// <SRC> before P4 and not after it; a post to the moved task is refused (C8); the
// blob is in both places after P3 and only in <DST> after P6.
func TestChannelMoveRunsWhole(t *testing.T) {
	f := moveFixture(t, true)
	empty := f.must(t, "journal", "", nil)
	if empty["move_id"] != nil || len(steps(empty)) != 0 {
		t.Fatalf("no journal yet: %v", empty)
	}
	plan := f.must(t, "plan", "", nil)
	if seats, _ := plan["seats"].([]any); len(seats) != 1 || seats[0].(map[string]any)["agent"] != f.seat {
		t.Errorf("plan lists the seat (T4d): %v", plan["seats"])
	}
	if listLen(plan["refuse"]) != 0 {
		t.Errorf("a seat with its desk refuses nothing: %v", plan["refuse"])
	}
	f.toP3(t)
	j := f.must(t, "journal", "", nil)
	if j["move_id"] != f.moveID || steps(j)["P3"] != "done" {
		t.Fatalf("journal after P3: %v", j)
	}
	seats, _ := j["seats"].([]any)
	if len(seats) != 1 || seats[0].(map[string]any)["agent"] != f.seat || seats[0].(map[string]any)["box"] != "box-a" {
		t.Errorf("the journal's seats are what P2b probes: %v", j["seats"])
	}
	if !f.blobIn(t, f.src) || !f.blobIn(t, f.dst) {
		t.Errorf("after P3 the blob is in both: src %v dst %v", f.blobIn(t, f.src), f.blobIn(t, f.dst))
	}
	if taskRows(t, f.e, f.src, f.task) == 0 {
		t.Fatal("before P4 the task is in <SRC>")
	}
	p4 := f.must(t, "step", "P4", nil)
	if rep, _ := p4["report"].([]any); len(rep) != 1 || !strings.HasPrefix(rep[0].(string), "deliveries: 0 expired") {
		t.Errorf("P4's report carries the deliveries line: %v", p4)
	}
	if n := taskRows(t, f.e, f.src, f.task); n != 0 {
		t.Errorf("after P4 <SRC> holds %d rows of the task", n)
	}
	if n := taskRows(t, f.e, f.dst, f.task); n == 0 {
		t.Error("after P4 <DST> holds the task")
	}
	f.refused(t, "step", "P4", "P4 committed", nil)
	f.refused(t, "step", "P2", "P4 committed", nil)
	f.must(t, "mark", "P5", map[string]any{"detail": map[string]any{"box": "rule-rows,lane-notes"}})
	f.must(t, "step", "P6", nil)
	if f.blobIn(t, f.src) || !f.blobIn(t, f.dst) {
		t.Errorf("after P6 only <DST> has the blob: src %v dst %v", f.blobIn(t, f.src), f.blobIn(t, f.dst))
	}
	p7 := f.must(t, "step", "P7", nil)
	proofs, _ := p7["proofs"].([]any)
	if len(proofs) == 0 {
		t.Fatalf("P7 lists the proofs: %v", p7)
	}
	for _, p := range proofs {
		if m := p.(map[string]any); m["count"].(float64) != 0 {
			t.Errorf("proof %v", m)
		}
	}
	if listLen(p7["kept"]) == 0 || listLen(p7["report"]) != 1 {
		t.Errorf("P7 prints the kept list and the report: %v", p7)
	}
	j = f.must(t, "journal", "", nil)
	for _, s := range []string{"P1", "P2", "P2b", "P3", "P4", "P5", "P6", "P7"} {
		if steps(j)[s] != "done" {
			t.Errorf("step %s: %v", s, steps(j)[s])
		}
	}
	if j["done"] != true {
		t.Errorf("the journal is closed after P7: %v", j)
	}
}

// 5.3: a post that lands between P3 and P4 moves with its row, so P6 copies its
// blob before it deletes. CONTROL: the blob of the first post (TestChannelMoveRunsWhole).
func TestChannelMoveP6CopiesLateBlob(t *testing.T) {
	f := moveFixture(t, true)
	f.toP3(t)
	first := f.blobID
	f.ch2Post(t)
	if f.blobIn(t, f.dst) {
		t.Fatal("P3 ran before the post: the late blob is not in <DST> yet")
	}
	f.must(t, "step", "P4", nil)
	f.must(t, "mark", "P5", nil)
	f.must(t, "step", "P6", nil)
	if !f.blobIn(t, f.dst) || f.blobIn(t, f.src) {
		t.Errorf("late blob %s: dst %v src %v, want only in <DST>", f.blobID, f.blobIn(t, f.dst), f.blobIn(t, f.src))
	}
	f.blobID = first
	if !f.blobIn(t, f.dst) {
		t.Error("the first blob stays in <DST>")
	}
}

// ch2Post is a second post in the task with its own blob.
func (f *moveFix) ch2Post(t *testing.T) {
	t.Helper()
	data := []byte("a late file " + f.ch)
	sum := sha256.Sum256(data)
	f.blobID = hex.EncodeToString(sum[:])
	key, err := blob.Key(f.src, f.blobID)
	if err != nil {
		t.Fatal(err)
	}
	if err := (blob.Dir{Root: f.e.blobs}).Put(context.Background(), key, data); err != nil {
		t.Fatal(err)
	}
	id := uuid4()
	movePost(t, f.e, f.src, id, f.task, f.ch, "GRK-03", "a late post", time.Now().UTC().Truncate(time.Second))
	moveExec(t, f.e, `UPDATE messages SET files = jsonb_build_array(jsonb_build_object('mode', 'blob', 'kind', 'file', 'file_id', $3::text, 'name', 'b.txt', 'bytes', 1))
		WHERE tenant_id = $1 AND msg_id = $2::uuid`, f.src, id, f.blobID)
}

// W4: after P4 the journal names each lane whose issue key changed, old and new,
// the shape channel-workspace-move-box.sh lane-notes reads.
func TestChannelMoveLanesW4(t *testing.T) {
	f := moveFixture(t, true)
	pg := f.e.st.(*store.Postgres)
	issue, err := pg.CreateIssue(context.Background(), store.Issue{TenantID: f.src, Title: "the channel's work", TaskID: f.task, Discussions: []string{f.task}, CreatedBy: "c-204"}, time.Now().UTC().Truncate(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	old := issue.Prefix + "-" + strconv.Itoa(issue.Number)
	// <DST>'s next number is 50: the moved issue takes that key, which a lane of a
	// staying issue in <SRC> also holds, and that lane's key did not change.
	moveExec(t, f.e, `INSERT INTO issue_counters (tenant_id, prefix, last_number) VALUES ($1, $2, 49)
		ON CONFLICT (tenant_id) DO UPDATE SET prefix = EXCLUDED.prefix, last_number = 49`, f.dst, issue.Prefix)
	lane := `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, writer_box, state, issue_key, topic) VALUES ($1, 'main', $2, 'box-a', 'box-a', $3, $4, $5)`
	moveExec(t, f.e, lane, f.src, "c-100", "live", old, f.task)
	moveExec(t, f.e, lane, f.src, "c-101", "done", old, store.LaneUnknown)
	moveExec(t, f.e, lane, f.src, "c-102", "live", issue.Prefix+"-50", store.LaneUnknown)
	f.toP3(t)
	if j := f.must(t, "journal", "", nil); listLen(j["lanes"]) != 0 {
		t.Errorf("before P4 no key changed: %v", j["lanes"])
	}
	f.must(t, "step", "P4", nil)
	lanes, _ := f.must(t, "journal", "", nil)["lanes"].([]any)
	if len(lanes) != 1 {
		t.Fatalf("one lane: a done one has no reader, a staying key did not change: %v", lanes)
	}
	l := lanes[0].(map[string]any)
	if l["agent"] != "c-100" || l["old_key"] != old || l["topic"] != f.task || l["new_key"] != issue.Prefix+"-50" {
		t.Errorf("lane: %v, old key %s", l, old)
	}
}

// 8.2's order, and the journal's GO and move id: a call out of order or for
// another move changes nothing.
func TestChannelMoveStepOrder(t *testing.T) {
	f := moveFixture(t, true)
	f.refused(t, "step", "P2", "run P1 first", map[string]any{"move_id": uuid4()})
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	f.refused(t, "step", "P2", "move_id must be", map[string]any{"move_id": uuid4()})
	for _, c := range [][3]string{{"step", "P3", "needs P2b"}, {"step", "P4", "needs P3"}, {"step", "P6", "needs P5"}, {"step", "P7", "needs P6"}, {"mark", "P2b", "needs P2"}, {"mark", "P5", "needs P4"}} {
		f.refused(t, c[0], c[1], c[2], nil)
	}
	if code, out := f.call(t, "step", "P2b", nil); code != http.StatusBadRequest || out["error"] != "bad_step" {
		t.Errorf("P2b is the box's, a mark: %d %v", code, out)
	}
	if code, out := f.call(t, "mark", "P3", nil); code != http.StatusBadRequest || out["error"] != "bad_step" {
		t.Errorf("P3 is the hub's, a step: %d %v", code, out)
	}
	if code, out := f.call(t, "step", "", nil); code != http.StatusBadRequest || out["error"] != "bad_step" {
		t.Errorf("no step: %d %v", code, out)
	}
	// P1 runs again until P4: the same move, frozen anew. CONTROL: the row is the same.
	if again, _ := f.must(t, "step", "P1", nil)["move_id"].(string); again != f.moveID {
		t.Errorf("P1 again: move %s, want %s", again, f.moveID)
	}
	if n := taskRows(t, f.e, f.src, f.task); n == 0 {
		t.Error("P1 changes nothing in <SRC>")
	}
}

// W2: P2b stands only on a stored probe per seat, from that agent, on the move's
// topic in <DST>. CONTROL: the real probe passes.
func TestChannelMoveProbes(t *testing.T) {
	f := moveFixture(t, true)
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	f.must(t, "step", "P2", nil)
	f.refused(t, "mark", "P2b", "has no probe", nil)
	f.refused(t, "mark", "P2b", "is not on the move's topic", f.probes(uuid4()))
	other := uuid4()
	movePost(t, f.e, f.dst, other, uuid4(), "", f.seat, "another topic", time.Now().UTC().Truncate(time.Second))
	f.refused(t, "mark", "P2b", "is not on the move's topic", f.probes(other))
	wrong := uuid4()
	movePost(t, f.e, f.dst, wrong, f.moveID, "", "c-999", "someone else", time.Now().UTC().Truncate(time.Second))
	f.refused(t, "mark", "P2b", "is not on the move's topic", f.probes(wrong))
	f.must(t, "mark", "P2b", f.probes(f.probe(t)))
	// A seat P2 clears on a re-run has no probe yet, so P4 refuses it, with nothing moved.
	moveExec(t, f.e, `INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by)
		VALUES ($1, 'c-205', 'box-a', 'channel', $2, 'test')`, f.src, f.ch)
	if err := f.e.st.SetRoster(context.Background(), f.dst, "box-a", []string{f.seat, "c-205", "c-001"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	f.must(t, "step", "P2", nil)
	f.must(t, "step", "P3", nil)
	f.refused(t, "step", "P4", "seat c-205 has no probe", nil)
	if taskRows(t, f.e, f.src, f.task) == 0 {
		t.Error("a refused P4 moves nothing")
	}
}

// P2's stops: W2's recipient, and every stop in the one refusal. CONTROL: the same
// channel with the seat added passes.
func TestChannelMoveP2Refuses(t *testing.T) {
	f := moveFixture(t, false)
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	f.refused(t, "step", "P2", "no orchestrator seat", nil)
	j := f.must(t, "journal", "", nil)
	if steps(j)["P2"] != "started" {
		t.Errorf("a refused P2 is not done: %v", steps(j))
	}
	if err := f.e.st.SetRoster(context.Background(), f.dst, "box-a", []string{f.seat, "c-001"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	f.must(t, "step", "P2", nil)
}

// P2 refuses on the plan's own stops: here R1, a box not pinned in <DST>. CONTROL:
// with the pin back the same move passes.
func TestChannelMoveP2PlanStops(t *testing.T) {
	f := moveFixture(t, true)
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	moveExec(t, f.e, `UPDATE pins SET revoked_at = now() WHERE tenant_id = $1`, f.dst)
	f.refused(t, "step", "P2", "is not pinned in "+f.dst, nil)
	moveExec(t, f.e, `UPDATE pins SET revoked_at = NULL WHERE tenant_id = $1`, f.dst)
	f.must(t, "step", "P2", nil)
}

// W4: a moved issue that keeps its number keeps its key, so its lane gets no note.
// CONTROL: TestChannelMoveLanesW4, where the key changes.
func TestChannelMoveLanesSameKey(t *testing.T) {
	f := moveFixture(t, true)
	issue, err := f.e.st.(*store.Postgres).CreateIssue(context.Background(), store.Issue{TenantID: f.src, Title: "the channel's work", TaskID: f.task, Discussions: []string{f.task}, CreatedBy: "c-204"}, time.Now().UTC().Truncate(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	old := issue.Prefix + "-" + strconv.Itoa(issue.Number)
	moveExec(t, f.e, `INSERT INTO issue_counters (tenant_id, prefix, last_number) VALUES ($1, $2, $3)
		ON CONFLICT (tenant_id) DO UPDATE SET prefix = EXCLUDED.prefix, last_number = EXCLUDED.last_number`, f.dst, issue.Prefix, issue.Number-1)
	moveExec(t, f.e, `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, writer_box, state, topic, issue_key) VALUES ($1, 'main', 'c-100', 'box-a', 'box-a', 'live', 't-1', $2)`, f.src, old)
	f.toP3(t)
	out := f.must(t, "step", "P4", nil)
	if keys, _ := out["new_keys"].(map[string]any); keys[old] != old {
		t.Fatalf("the fixture must keep the key: %v", out["new_keys"])
	}
	if lanes := f.must(t, "journal", "", nil)["lanes"]; listLen(lanes) != 0 {
		t.Errorf("the key did not change: %v", lanes)
	}
}

// P2's file quota: the channel's files count against <DST>. CONTROL: with no
// quota the same channel passes (TestChannelMoveRunsWhole).
func TestChannelMoveP2Quota(t *testing.T) {
	f := moveFixture(t, true, func(o *hub.Options) { o.QuotaFileBytes = 1 })
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	f.refused(t, "step", "P2", "file quota", nil)
}

// A GO other than the journal's: P1 again refuses it, and so does any later step
// (8.3), with nothing changed.
func TestChannelMoveOtherGoRefused(t *testing.T) {
	f := moveFixture(t, true)
	f.moveID, _ = f.must(t, "step", "P1", nil)["move_id"].(string)
	second := uuid4()
	movePost(t, f.e, f.op, second, f.formTask, "", f.owner, "Poll: "+f.form+"\nAnswer: GO — Go", time.Now().UTC().Truncate(time.Second))
	f.refused(t, "step", "P1", "another GO", map[string]any{"go_msg_id": second})
	f.refused(t, "step", "P2", "another GO", map[string]any{"go_msg_id": second})
	f.must(t, "step", "P2", nil)
}

// C14, 5.2: the fleet topic ids are the scan's one known hit, reported with their
// count; any other hit fails, P7 stays not done, and a re-run after the row is
// gone closes the move. The red control that the count is what lets the hit pass:
// go test -overlay with channelMoveFleetTopics answering nothing fails this test.
func TestChannelMoveScanKnownC14(t *testing.T) {
	f := moveFixture(t, true)
	moveExec(t, f.e, `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, topic, issue_key, state, writer_box)
		VALUES ($1, 'main', 'c-204', 'box-a', $2, 'SPL-1', 'live', 'box-a')`, f.src, f.task)
	moveExec(t, f.e, `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, topic, state, writer_box)
		VALUES ($1, 'main', $2, 'task', 'c-204', $3, 'open', 'box-a')`, f.src, uuid4(), f.task)
	f.toP3(t)
	f.must(t, "step", "P4", nil)
	f.must(t, "mark", "P5", nil)
	f.must(t, "step", "P6", nil)
	// A plant the scan must fail on, in a column that is not the exception.
	moveExec(t, f.e, `INSERT INTO workspace_events (tenant_id, at, kind, level, actor, message, origin_kind, origin_ref)
		VALUES ($1, now(), 'channel.moved', 'info', 'test', $2, '', '')`, f.src, "about "+f.ch)
	out := f.must(t, "step", "P7", nil)
	if !moveProofFails(out, "scan workspace_events.message") {
		t.Fatalf("the plant must fail the scan: %v", out["proofs"])
	}
	failed := f.must(t, "journal", "", nil)
	if s := steps(failed)["P7"]; s != "started" {
		t.Errorf("a failed P7 is not done: %v", s)
	}
	if failed["done"] != false {
		t.Errorf("a failed P7 must leave the journal open: %v", failed["done"])
	}
	moveExec(t, f.e, `DELETE FROM workspace_events WHERE tenant_id = $1 AND actor = 'test'`, f.src)
	out = f.must(t, "step", "P7", nil)
	for _, name := range []string{"scan fleet_lanes.topic (known 1 of 1", "scan fleet_asks.topic (known 1 of 1"} {
		if !moveProofLine(out, name) {
			t.Errorf("no %q line, count 0: %v", name, out["proofs"])
		}
	}
	held := f.must(t, "journal", "", nil)
	if s := steps(held)["P7"]; s != "done" {
		t.Errorf("P7 after the row left: %v", s)
	}
	if held["done"] != true {
		t.Errorf("a P7 that held closes the journal: %v", held["done"])
	}
}

func moveProofFails(out map[string]any, name string) bool {
	proofs, _ := out["proofs"].([]any)
	for _, p := range proofs {
		m := p.(map[string]any)
		if m["name"] == name && m["count"].(float64) > 0 {
			return true
		}
	}
	return false
}

func moveProofLine(out map[string]any, name string) bool {
	proofs, _ := out["proofs"].([]any)
	for _, p := range proofs {
		m := p.(map[string]any)
		if strings.HasPrefix(m["name"].(string), name) && m["count"].(float64) == 0 {
			return true
		}
	}
	return false
}

// A hub with no journal (Memory) answers 501, not a false empty journal.
func TestChannelMoveJournalNeedsItsStore(t *testing.T) {
	t.Setenv("SPOOL_TEST_PG_DSN", "")
	e := chanMoveEnv(t)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	if code, out := opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("journal", src, "proj-x", dst, nil)); code != http.StatusNotImplemented || out["error"] != "unsupported" {
		t.Errorf("journal on Memory: %d %v", code, out)
	}
}
