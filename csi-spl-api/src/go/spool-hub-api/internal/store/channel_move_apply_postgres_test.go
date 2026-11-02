// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 169 row T5: ApplyChannelMove, P4. Every case runs on Postgres, as a
// role RLS binds, on two workspaces of the test database, and has its red
// control. The hub half of C18 (one real sync cycle after the move) needs
// internal/hub: this file proves the store half, see TestApplyChannelMoveC18.

// mvFix is <SRC> with a moving and a staying channel, and <DST>.
type mvFix struct {
	pg                     *Postgres
	src, dst, ch, stay     string
	tA, tB, thread, dm     string
	cardA, reply, stayPost string
	dmPost                 string
	both, only             string // HUM ids: a <DST> member too; <SRC> only
}

func mvExec(t *testing.T, pg *Postgres, sql string, args ...any) {
	t.Helper()
	err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), sql, args...)
		return err
	})
	if err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func mvCount(t *testing.T, pg *Postgres, sql string, args ...any) int {
	t.Helper()
	var n int
	err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), sql, args...).Scan(&n)
	})
	if err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return n
}

func mvHuman(t *testing.T, pg *Postgres, tenants ...string) string {
	t.Helper()
	var h string
	err := pg.pool.QueryRow(context.Background(), `INSERT INTO humans (display_name, created_at) VALUES ('mv', now()) RETURNING human_id`).Scan(&h)
	if err != nil {
		t.Fatal(err)
	}
	for _, tn := range tenants {
		mvExec(t, pg, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES ($1, $2, 'member', $2)`, tn, h)
	}
	return h
}

func seedMove(t *testing.T) mvFix {
	t.Helper()
	pg := rlsStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	f := mvFix{pg: pg, src: newTenant(t, pg), dst: newTenant(t, pg), ch: uid("mv-"), stay: uid("st-"),
		tA: uuid4(), tB: uuid4(), thread: uuid4(), dm: uuid4()}
	// The store suite shares one database: rows left here shift what ANALYZE
	// sees, so a later test's plan flips (TestMarkedUnreadBufferBudget 206 > 200).
	t.Cleanup(func() { f.dropTenants(t) })
	f.both, f.only = mvHuman(t, pg, f.src, f.dst), mvHuman(t, pg, f.src)
	for _, ch := range []string{f.ch, f.stay} {
		if err := pg.CreateChannel(ctx, Channel{TenantID: f.src, ChannelID: ch, Name: ch, CreatedBy: f.both, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	post := func(task, parent, ch, ref, body string, at time.Time) string {
		m := msgFor(f.src, task, "box-a", at, at, "env-"+uuid4())
		m.Channel, m.ParentTaskID, m.Body, m.RefTaskID = ch, parent, body, ref
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m.MsgID
	}
	f.cardA = post(f.tA, "", f.ch, "", "topic A", now)
	f.reply = post(f.tA, "", f.ch, "", "reply in A", now.Add(time.Second))
	post(f.thread, f.tA, "", "", "a thread under A", now.Add(2*time.Second))
	f.stayPost = post(f.tB, "", f.stay, "", "staying", now.Add(3*time.Second))
	f.dmPost = post(f.dm, "", "", f.tA, "a DM about A", now.Add(4*time.Second))
	f.seedMessageFamily(t, now)
	// R1 and W2: the set's box is pinned in <DST> and the seat has its desk there.
	if err := pg.PutPin(ctx, f.dst, "box-a", pubkey(), false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetRoster(ctx, f.dst, "box-a", []string{"c-100"}, now); err != nil {
		t.Fatal(err)
	}
	return f
}

// dropTenants removes both workspaces and all their rows, by the tenant cascade.
func (f mvFix) dropTenants(t *testing.T) {
	t.Helper()
	if err := f.pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE tenant_id = ANY($1)`, []string{f.src, f.dst})
		return err
	}); err != nil {
		t.Errorf("drop the move's workspaces: %v", err)
	}
}

// seedMessageFamily: the rows C3a counts, and the move history of M6b.
func (f mvFix) seedMessageFamily(t *testing.T, now time.Time) {
	t.Helper()
	pg, s := f.pg, f.src
	mvExec(t, pg, `UPDATE messages SET moved_from_channel = $2, moved_from_task = $3 WHERE tenant_id = $1 AND msg_id = $4`, s, f.ch, f.tA, f.stayPost)
	mvExec(t, pg, `UPDATE messages SET files = '[{"mode":"path","name":"a.txt","path":"/x/a.txt"}]', responsible = NULL WHERE tenant_id = $1 AND msg_id = $2`, s, f.reply)
	mvExec(t, pg, `INSERT INTO message_revisions (tenant_id, msg_id, revision, body, edited_by, edited_at) VALUES ($1, $2, 1, 'old', $3, $4)`, s, f.cardA, f.both, now)
	mvExec(t, pg, `INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji, created_at) VALUES ($1, $2, $3, '+1', $4)`, s, f.cardA, f.both, now)
	mvExec(t, pg, `INSERT INTO message_answers (tenant_id, answers, answer_msg_id, seat, gen) VALUES ($1, $2, $3, 'c-100@box-a', 0)`, s, f.cardA, f.reply)
	mvExec(t, pg, `INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at) VALUES ($1, $2, 'box-b', $3)`, s, f.cardA, now.Add(time.Hour))
	mvExec(t, pg, `INSERT INTO delivery_live_acks (tenant_id, msg_id, agent_id, box_id, outcome, acked_at) VALUES ($1, $2, 'c-100', 'box-a', 'shown', $3)`, s, f.cardA, now)
	mvExec(t, pg, `INSERT INTO fallback_deliveries (tenant_id, msg_id, channel_id, box_id, agent_id, delivered_at) VALUES ($1, $2, $3, 'box-a', 'c-100', $4)`, s, f.cardA, f.ch, now)
	for _, h := range []string{f.both, f.only} {
		mvExec(t, pg, `INSERT INTO read_marks (tenant_id, member_id, mark_key, at) VALUES ($1, $2, $3, $4)`, s, h, "t:"+f.tA, now)
		mvExec(t, pg, `INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by) VALUES ($1, $2, $3, $4, $3)`, s, f.ch, h, now)
	}
	mvExec(t, pg, `INSERT INTO flow_watches (tenant_id, task_id, member_id, since) VALUES ($1, $2, $3, $4)`, s, f.tA, f.both, now)
	mvExec(t, pg, `INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at) VALUES ($1, $2, $3, $4, 'reply', $5, $6)`, s, f.both, f.reply, f.tA, now, now.Add(time.Hour))
	mvExec(t, pg, `INSERT INTO topic_priorities (tenant_id, task_id, priority, set_by, set_at) VALUES ($1, $2, 1, $3, $4)`, s, f.tA, f.both, now)
	mvExec(t, pg, `INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES ($1, 'c-100', 'box-a', 'channel', $2, $3)`, s, f.ch, f.both)
	mvExec(t, pg, `UPDATE tenant_memberships SET channel_order = ARRAY[$2, $3] WHERE tenant_id = $1`, s, f.ch, f.stay)
}

func (f mvFix) req() ChannelMoveApplyRequest {
	tables, binds := moveCatalogue()
	return ChannelMoveApplyRequest{
		ChannelMovePlanRequest: ChannelMovePlanRequest{Src: f.src, Channel: f.ch, Dst: f.dst, Tables: tables, BindTypes: binds},
		MoveID:                 uuid4(), GoMsgID: uuid4(), StartedBy: "HUM-10", Seats: []string{"c-100@box-a"},
	}
}

func (f mvFix) apply(t *testing.T, req ChannelMoveApplyRequest) ChannelMoveResult {
	t.Helper()
	res, err := f.pg.ApplyChannelMove(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// mvWatched are the tables whose rows the snapshot compares.
var mvWatched = []string{"channels", "messages", "message_revisions", "message_reactions", "message_answers", "deliveries",
	"delivery_live_acks", "fallback_deliveries", "read_marks", "channel_humans", "channel_invites", "tenant_invites", "dedicated_agents",
	"flow_watches", "flow_events", "topic_priorities", "calendar_events", "calendar_guests", "hours_jobs", "hours_plan", "hours_entries",
	"hours_minutes", "hours_adjustments", "issues", "issue_events", "issue_discussions", "spec_sync_map", "workspace_doc",
	"workspace_doc_item", "workspace_doc_node", "workspace_doc_rev_log", "channel_move_journal", "channel_move_steps", "workspace_events"}

func (f mvFix) snapshot(t *testing.T) string {
	t.Helper()
	var b strings.Builder
	for _, tn := range []string{f.src, f.dst} {
		for _, table := range mvWatched {
			fmt.Fprintf(&b, "%s=%d ", table, mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, tn))
		}
		b.WriteString("| ")
	}
	return b.String()
}

// C3a: the messages family arrives whole and <SRC> holds none of it.
func TestApplyChannelMoveC3aMessages(t *testing.T) {
	f := seedMove(t)
	cond := []struct {
		table, pred string
		n           int
	}{
		{"messages", `msg_id = ANY($2::uuid[])`, 3},
		{"message_revisions", `msg_id = ANY($2::uuid[])`, 1},
		{"message_reactions", `msg_id = ANY($2::uuid[])`, 1},
		{"message_answers", `answers = ANY($2::uuid[])`, 1},
		{"deliveries", `msg_id = ANY($2::uuid[])`, 1},
		{"delivery_live_acks", `msg_id = ANY($2::uuid[])`, 1},
		{"fallback_deliveries", `msg_id = ANY($2::uuid[])`, 1},
		{"flow_events", `msg_id = ANY($2::uuid[])`, 1},
	}
	res := f.apply(t, f.req())
	msgs := res.Binds.Msgs
	if len(msgs) != 3 {
		t.Fatalf("the set is card, reply and thread, got %v", msgs)
	}
	for _, c := range cond {
		if got := mvCount(t, f.pg, `SELECT count(*) FROM `+c.table+` WHERE tenant_id = $1 AND `+c.pred, f.src, msgs); got != 0 {
			t.Errorf("%s: %d rows left in <SRC>", c.table, got)
		}
		if got := mvCount(t, f.pg, `SELECT count(*) FROM `+c.table+` WHERE tenant_id = $1 AND `+c.pred, f.dst, msgs); got != c.n {
			t.Errorf("%s: %d rows in <DST>, want %d", c.table, got, c.n)
		}
	}
	f.checkStaying(t)
	f.checkMovedRows(t)
}

// checkStaying: the named updates of M6b, M9 and channel_order, and the
// post itself still there.
func (f mvFix) checkStaying(t *testing.T) {
	t.Helper()
	if n := mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND msg_id = $2 AND moved_from_channel IS NULL AND moved_from_task IS NULL`, f.src, f.stayPost); n != 1 {
		t.Error("M6b: the staying post must keep its row with moved_from_* NULL")
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND msg_id = $2 AND ref_task_id IS NULL`, f.src, f.dmPost); n != 1 {
		t.Error("M9: the DM stays with ref_task_id NULL")
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM tenant_memberships WHERE tenant_id = $1 AND $2 = ANY(channel_order)`, f.src, f.ch); n != 0 {
		t.Error("channel_order still names the channel in <SRC>")
	}
}

// checkMovedRows: Q5 on the rows of people who do not come along, W6 on the
// columns, and the journal and the one audit row.
func (f mvFix) checkMovedRows(t *testing.T) {
	t.Helper()
	pg := f.pg
	if n := mvCount(t, pg, `SELECT count(*) FROM channel_humans WHERE tenant_id = $1 AND channel_id = $2`, f.dst, f.ch); n != 1 {
		t.Errorf("channel_humans in <DST>: %d, want the <DST> member only", n)
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM read_marks WHERE tenant_id = $1 AND member_id = $2`, f.dst, f.only); n != 0 {
		t.Error("read_marks of a member who does not come along were carried")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM read_marks WHERE tenant_id = $1 AND mark_key = $2`, f.src, "t:"+f.tA); n != 0 {
		t.Error("read_marks of the set are left in <SRC>")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND msg_id = $2 AND responsible IS NULL AND files @> '[{"mode":"path"}]'`, f.dst, f.reply); n != 1 {
		t.Error("W6: the moved row's responsible or its path attachment changed")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM dedicated_agents WHERE tenant_id = $1 AND scope_id = $2`, f.dst, f.ch); n != 1 {
		t.Error("the channel seat did not move")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM channel_move_steps WHERE tenant_id = $1 AND step = 'P4' AND done_at IS NOT NULL`, f.dst); n != 1 {
		t.Error("the journal has no finished P4 step")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM workspace_events WHERE tenant_id = $1 AND kind = 'channel.moved'`, f.dst); n != 1 {
		t.Error("<DST> must hold the move's one audit row")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM workspace_events WHERE tenant_id = $1 AND kind = 'channel.moved'`, f.src); n != 0 {
		t.Error("C13: the move wrote an audit row in <SRC>")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM channel_move_redirects WHERE src_tenant_id = $1 AND kind = 'task' AND old_ref = $2 AND new_ref = $2 AND dst_tenant_id = $3`, f.src, f.tA, f.dst); n != 1 {
		t.Error("Q2: no redirect for the moved task")
	}
}

// CONTROL of C3a: skip the delivery_live_acks copy, and the cascaded <SRC>
// delete has lost them, so the <DST> count differs.
func TestApplyChannelMoveC3aControl(t *testing.T) {
	f := seedMove(t)
	req := f.req()
	req.skipCopy = map[string]bool{"delivery_live_acks": true}
	f.apply(t, req)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM delivery_live_acks WHERE tenant_id = $1`, f.dst); n != 0 {
		t.Fatalf("CONTROL: skipped, yet <DST> holds %d acks", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM delivery_live_acks WHERE tenant_id = $1`, f.src); n != 0 {
		t.Fatalf("CONTROL: <SRC> kept %d acks, so the detector above proves nothing", n)
	}
}

// deliveriesReq drops R1: plan and the plan under the lock refuse a from_box with
// no live <DST> pin, so a full move cannot reach P4's sender branch while R1
// holds. The branch stays as a defence, and only this way can it run.
func (f mvFix) deliveriesReq() ChannelMoveApplyRequest {
	req := f.req()
	req.noPinCheck = true
	return req
}

// C28: after the move no agent row the addressee's box cannot verify stays
// queued. Run through asOperator with the real pins policies: the spared row is
// the proof that the <SRC> pin is visible, else this is option (a).
func TestApplyChannelMoveC27Deliveries(t *testing.T) {
	f, want := seedMoveDeliveries(t)
	res := f.apply(t, f.deliveriesReq())
	for box, state := range want {
		if got := f.deliveryState(t, box); got != state {
			t.Errorf("delivery to %s = %q, want %q", box, got, state)
		}
	}
	if res.DeliveriesExpired != 4 || res.DeliveriesExpiredNoPin != 2 {
		t.Fatalf("expired %d, no pin %d; want 4 and 2", res.DeliveriesExpired, res.DeliveriesExpiredNoPin)
	}
	if line := res.DeliveriesLine(); !strings.Contains(line, "4 expired") || !strings.Contains(line, "2 expired") || !strings.Contains(line, "re-keyed") {
		t.Fatalf("operator line: %q", line)
	}
	var got string
	if err := f.pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT counts->>'deliveries_expired' || '/' || (counts->>'deliveries_expired_no_pin')
			FROM channel_move_steps WHERE tenant_id = $1 AND step = 'P4'`, f.dst).Scan(&got)
	}); err != nil || got != "4/2" {
		t.Fatalf("P4 step counts %q (%v), want 4/2", got, err)
	}
}

// CONTROL: with the expiry skipped the same rows stay undelivered, so the case
// above can see the difference.
func TestApplyChannelMoveC27Control(t *testing.T) {
	f, _ := seedMoveDeliveries(t)
	req := f.deliveriesReq()
	req.keepQueue = true
	if res := f.apply(t, req); res.DeliveriesExpired != 0 || res.DeliveriesExpiredNoPin != 0 {
		t.Fatalf("CONTROL: skipped, yet counted %+v", res)
	}
	if got := f.deliveryState(t, "box-diff"); got != "queued" {
		t.Fatalf("CONTROL: skipped, yet box-diff is %q", got)
	}
}

// seedMoveDeliveries plants one delivery per reason, each on its own to_box, and
// returns the state each must end in. Sender box-a's key differs in the two
// workspaces; box-same's is the one live in <DST>, its <SRC> pin revoked;
// box-nowhere has no <DST> pin; box-revoked's <DST> pin is revoked.
func seedMoveDeliveries(t *testing.T) (mvFix, map[string]string) {
	t.Helper()
	f := seedMove(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	mvExec(t, f.pg, `DELETE FROM deliveries WHERE tenant_id = $1`, f.src)
	pin := func(tn, box string, pub []byte, revoked bool) {
		t.Helper()
		mvExec(t, f.pg, `INSERT INTO pins (tenant_id, box_id, pubkey, revoked_at) VALUES ($1, $2, $3, CASE WHEN $4 THEN now() END)`, tn, box, pub, revoked)
	}
	key := func() []byte { return []byte(pubkey()) }
	same, gone := key(), key()
	pin(f.src, "box-a", key(), false)
	pin(f.src, "box-same", same, true)
	pin(f.dst, "box-same", same, false)
	pin(f.src, "box-revoked", gone, false)
	pin(f.dst, "box-revoked", gone, true)
	want := map[string]string{}
	deliver := func(fromBox, toBox, state string, acked bool, wantState string) {
		t.Helper()
		m := msgFor(f.src, uuid4(), toBox, now, now, "env-"+uuid4())
		m.FromBox, m.Channel = fromBox, f.ch
		if fromBox == "box-wui" {
			m.EnvSig = ""
		}
		if _, err := f.pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		mvExec(t, f.pg, `INSERT INTO deliveries (tenant_id, msg_id, to_box, state, expires_at, sent_at, acked_at)
			VALUES ($1, $2, $3, $4, $5, $6, CASE WHEN $7 THEN $6::timestamptz END)`, f.src, m.MsgID, toBox, state, now.Add(time.Hour), now, acked)
		want[toBox] = wantState
		if toBox != "box-wui" && toBox != "box-gone" && toBox != "box-gone2" {
			pin(f.dst, toBox, key(), false)
		}
	}
	deliver("box-same", "box-spared", "queued", false, "queued")
	deliver("box-a", "box-diff", "queued", false, "expired")
	deliver("box-a", "box-unacked", "sent", false, "expired")
	deliver("box-a", "box-acked", "sent", true, "sent")
	deliver("box-nowhere", "box-nosender", "queued", false, "expired")
	deliver("box-revoked", "box-revsender", "queued", false, "expired")
	deliver("box-wui", "box-human", "queued", false, "queued")
	deliver("box-a", "box-wui", "queued", false, "queued")
	// no <DST> pin on the to_box: expired whatever the key, counted apart
	deliver("box-wui", "box-gone", "queued", false, "expired")
	deliver("box-same", "box-gone2", "sent", false, "expired")
	return f, want
}

// deliveryState is the state of the one delivery to box in <DST>.
func (f mvFix) deliveryState(t *testing.T, box string) string {
	t.Helper()
	var st string
	if err := f.pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT state FROM deliveries WHERE tenant_id = $1 AND to_box = $2`, f.dst, box).Scan(&st)
	}); err != nil {
		t.Fatalf("delivery to %s: %v", box, err)
	}
	return st
}

// C4: the move never updates tenant_id on a parent. CONTROL: an UPDATE of the
// channels row is refused by the FK of its children, and <SRC> is unchanged.
func TestApplyChannelMoveC4UpdateRefused(t *testing.T) {
	f := seedMove(t)
	before := f.snapshot(t)
	req := f.req()
	req.updateSet = "channels"
	_, err := f.pg.ApplyChannelMove(context.Background(), req)
	if err == nil || !strings.Contains(err.Error(), "foreign key") {
		t.Fatalf("CONTROL: UPDATE ... SET tenant_id on a parent must hit an FK, got %v", err)
	}
	if after := f.snapshot(t); after != before {
		t.Errorf("a refused move changed rows:\n%s\n%s", before, after)
	}
}

// C5: a failure half way through leaves both workspaces as they were. Every
// table is a place to fail; these are one early, one middle, one late.
func TestApplyChannelMoveC5Rollback(t *testing.T) {
	f := seedMove(t)
	before := f.snapshot(t)
	for _, at := range []string{"messages", "topic_priorities", "workspace_events"} {
		req := f.req()
		req.failAfter = at
		_, err := f.pg.ApplyChannelMove(context.Background(), req)
		if err == nil || !strings.Contains(err.Error(), "planted failure") {
			t.Fatalf("failAfter %s: %v", at, err)
		}
		if after := f.snapshot(t); after != before {
			t.Errorf("failure after %s changed rows:\n%s\n%s", at, before, after)
		}
	}
	// CONTROL: the snapshot sees a real move, so its equality above means something.
	f.apply(t, f.req())
	if after := f.snapshot(t); after == before {
		t.Fatal("CONTROL: a finished move left the snapshot equal")
	}
}

// C9: after the move the counters equal a fresh count, in both workspaces,
// and the topic heads equal a rebuild. CONTROL: a broken head and a broken
// counter are seen by the same two readers.
func TestApplyChannelMoveC9Counters(t *testing.T) {
	f := seedMove(t)
	stamp := func(tn string) int {
		return mvCount(t, f.pg, `SELECT coalesce(sum(n), 0)::int FROM tenant_change_stamps WHERE tenant_id = $1`, tn)
	}
	srcStamp, dstStamp := stamp(f.src), stamp(f.dst)
	f.apply(t, f.req())
	counted := func(tn string) (int, int) {
		return mvCount(t, f.pg, `SELECT coalesce(sum(messages), 0)::int FROM message_period_counts WHERE tenant_id = $1`, tn),
			mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1`, tn)
	}
	heads := func(tn string) int {
		return mvCount(t, f.pg, `SELECT count(*) FROM topic_head_diff($1)`, tn)
	}
	for _, tn := range []string{f.src, f.dst} {
		if c, n := counted(tn); c != n {
			t.Errorf("%s: message_period_counts %d, a fresh count %d", tn, c, n)
		}
		if d := heads(tn); d != 0 {
			t.Errorf("%s: %d topic heads differ from a rebuild", tn, d)
		}
	}
	if stamp(f.src) <= srcStamp || stamp(f.dst) <= dstStamp {
		t.Error("change stamps must bump in both workspaces (W7)")
	}
	mvExec(t, f.pg, `UPDATE message_period_counts SET messages = messages + 1 WHERE tenant_id = $1`, f.dst)
	if c, n := counted(f.dst); c == n {
		t.Fatal("CONTROL: a broken counter still equals the fresh count")
	}
	mvExec(t, f.pg, `UPDATE topic_heads SET last_at = last_at + interval '1 day' WHERE tenant_id = $1`, f.dst)
	if heads(f.dst) == 0 {
		t.Fatal("CONTROL: a broken head reads as equal to a rebuild")
	}
}

// A second P4 of one move is refused (the journal says it committed, C17's
// store half); a channel name <DST> already holds is refused (P2).
func TestApplyChannelMoveRefusals(t *testing.T) {
	f := seedMove(t)
	ctx := context.Background()
	if err := f.pg.CreateChannel(ctx, Channel{TenantID: f.dst, ChannelID: f.ch, Name: f.ch, CreatedBy: f.both, CreatedAt: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pg.ApplyChannelMove(ctx, f.req()); !errors.Is(err, ErrConflict) {
		t.Fatalf("a channel of that name in <DST>: %v, want ErrConflict", err)
	}
	mvExec(t, f.pg, `DELETE FROM channels WHERE tenant_id = $1 AND channel_id = $2`, f.dst, f.ch)
	req := f.req()
	req.GoMsgID = ""
	if _, err := f.pg.ApplyChannelMove(ctx, req); !errors.Is(err, ErrMoveRequest) {
		t.Fatalf("no GO msg id: %v, want ErrMoveRequest", err)
	}
	req = f.req()
	f.apply(t, req)
	if _, err := f.pg.ApplyChannelMove(ctx, req); err == nil {
		t.Fatal("the same move ran P4 twice")
	}
}

// mvEvent seeds a calendar event on the topic with one human guest each.
func (f mvFix) mvEvent(t *testing.T) string {
	t.Helper()
	ev := uuid4()
	mvExec(t, f.pg, `INSERT INTO calendar_events (event_id, tenant_id, title, kind, starts_at, ends_at, creator_type, creator_id, topic_id, source_key)
		VALUES ($1, $2, 'moved event', 'other', now(), now() + interval '1 hour', 'human', $3, $4, 'src-key-1')`, ev, f.src, f.both, f.tA)
	for _, g := range []string{f.both, f.only} {
		mvExec(t, f.pg, `INSERT INTO calendar_guests (tenant_id, event_id, guest_type, guest_id, invited_by) VALUES ($1, $2, 'human', $3, $3)`, f.src, ev, g)
	}
	return ev
}

func (f mvFix) mvGcalMap(t *testing.T, ev string) GcalConnection {
	t.Helper()
	now := time.Now().UTC()
	c, err := f.pg.ConnectGcal(context.Background(), GcalConnection{Tenant: f.src, Human: f.both, GoogleEmail: "m@example.com"},
		GcalTokens{AccessSealed: "v1.a", RefreshSealed: "v1.r", KMSKeyID: "fake-kms/1", AccessExpiry: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	mvExec(t, f.pg, `INSERT INTO gcal_event_map (connection_id, tenant_id, event_id, google_id, sync_hash) VALUES ($1::uuid, $2, $3::uuid, 'g-1', repeat('0', 64))`, c.ID, f.src, ev)
	return c
}

// C18, the store half: the Google event is deleted before P4, under the
// member's lease, and a failed delete stops the move with nothing changed.
// The other half of the case, "after one sync cycle <SRC> has no event with
// that source_key", is the In half in internal/hub: not run here.
func TestApplyChannelMoveC18Google(t *testing.T) {
	f := seedMove(t)
	ev := f.mvEvent(t)
	c := f.mvGcalMap(t, ev)
	before := f.snapshot(t)
	req := f.req()
	req.GcalDelete = func(context.Context, GcalConnection, string) error { return errors.New("google said no") }
	if _, err := f.pg.ApplyChannelMove(context.Background(), req); err == nil || !strings.Contains(err.Error(), "google said no") {
		t.Fatalf("a failed Google call must stop the move, got %v", err)
	}
	if after := f.snapshot(t); after != before {
		t.Errorf("a failed Google call changed rows:\n%s\n%s", before, after)
	}
	mvExec(t, f.pg, `UPDATE gcal_connections SET sync_lease_until = NULL WHERE connection_id = $1::uuid`, c.ID)

	var deleted []string
	req = f.req()
	req.GcalDelete = func(_ context.Context, got GcalConnection, google string) error {
		if got.Human != f.both {
			t.Errorf("the connection of %s, want %s", got.Human, f.both)
		}
		if n := mvCount(t, f.pg, `SELECT count(*) FROM calendar_events WHERE tenant_id = $1 AND event_id = $2`, f.src, ev); n != 1 {
			t.Error("the Google delete must run before P4")
		}
		if n := mvCount(t, f.pg, `SELECT count(*) FROM gcal_connections WHERE connection_id = $1::uuid AND sync_lease_until > now()`, c.ID); n != 1 {
			t.Error("the connection must be claimed around the Google delete")
		}
		deleted = append(deleted, google)
		return nil
	}
	f.apply(t, req)
	if len(deleted) != 1 || deleted[0] != "g-1" {
		t.Errorf("Google deletes: %v", deleted)
	}
	f.checkCalendar(t, ev)
}

func (f mvFix) checkCalendar(t *testing.T, ev string) {
	t.Helper()
	pg := f.pg
	if n := mvCount(t, pg, `SELECT count(*) FROM gcal_event_map WHERE event_id = $1`, ev); n != 0 {
		t.Error("the map row outlived the move")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM calendar_events WHERE tenant_id = $1 AND source_key = 'src-key-1'`, f.src); n != 0 {
		t.Error("<SRC> still holds the event's source key")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM calendar_events WHERE tenant_id = $1 AND event_id = $2`, f.dst, ev); n != 1 {
		t.Error("the event is not in <DST>")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM calendar_guests WHERE tenant_id = $1 AND event_id = $2 AND guest_id = $3`, f.dst, ev, f.both); n != 1 {
		t.Error("the <DST> member's guest row did not move")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM calendar_guests WHERE event_id = $1 AND guest_id = $2`, ev, f.only); n != 0 {
		t.Error("Q5: a guest who does not come along was carried")
	}
}

// CONTROL of C18: without the pre-P4 delete the cascade drops the map row and
// nobody tells Google: the event stays in the member's calendar, the state the
// In half imports back into <SRC>. And with a map row and no delete function
// the move refuses outright.
func TestApplyChannelMoveC18Control(t *testing.T) {
	f := seedMove(t)
	ev := f.mvEvent(t)
	f.mvGcalMap(t, ev)
	if _, err := f.pg.ApplyChannelMove(context.Background(), f.req()); !errors.Is(err, ErrMoveRequest) {
		t.Fatalf("a map row and no delete function: %v, want ErrMoveRequest", err)
	}
	called := 0
	req := f.req()
	req.noGcal = true
	req.GcalDelete = func(context.Context, GcalConnection, string) error { called++; return nil }
	f.apply(t, req)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM gcal_event_map WHERE event_id = $1`, ev); n != 0 || called != 0 {
		t.Fatalf("CONTROL: map rows %d, Google deletes %d: the map row went without a word to Google", n, called)
	}
}

// mvHours seeds a job with a plan slot, and entries on each target kind.
func (f mvFix) mvHours(t *testing.T, member string) (day string) {
	t.Helper()
	pg, s := f.pg, f.src
	job, day := uid("job-"), "2026-06-10"
	mvExec(t, pg, `INSERT INTO hours_jobs (tenant_id, job_id, name, task_id, updated_by) VALUES ($1, $2, 'job', $3, $4)`, s, job, f.tA, member)
	mvExec(t, pg, `INSERT INTO hours_plan (tenant_id, member_id, day, slot, job_id, start_at, end_at, updated_by)
		VALUES ($1, $2, $3::date, 1, $4, '2026-06-10 08:00Z', '2026-06-10 09:00Z', $2)`, s, member, day, job)
	for _, target := range []string{"job:" + job, "t:" + f.tA, "ch:" + f.ch} {
		mvExec(t, pg, `INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by, entered_by)
			VALUES ($1, $2, $3::date, $4, 30, 'proposed', $2, $2)`, s, member, day, target)
	}
	return day
}

// C19: the job and its hours move whole; an entry inside an approved period
// makes plan refuse, naming it. CONTROL: with the period gone the same rows
// move, so the refusal was the period's.
func TestApplyChannelMoveC19Hours(t *testing.T) {
	f := seedMove(t)
	f.mvHours(t, f.both)
	mvExec(t, f.pg, `INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end, state, decided_by)
		VALUES ($1, $2, '2026-06-01', '2026-06-30', 'approved', 'HUM-10')`, f.src, f.both)
	_, err := f.pg.ApplyChannelMove(context.Background(), f.req())
	if !errors.Is(err, ErrChannelMoveRefused) || !strings.Contains(err.Error(), f.both+" 3 rows inside a frozen or approved sheet (Q8)") {
		t.Fatalf("an approved period must refuse naming the member: %v", err)
	}
	mvExec(t, f.pg, `DELETE FROM hours_periods WHERE tenant_id = $1`, f.src)
	f.apply(t, f.req())
	for table, want := range map[string]int{"hours_jobs": 1, "hours_plan": 1, "hours_entries": 3} {
		if n := mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, f.dst); n != want {
			t.Errorf("%s in <DST>: %d, want %d", table, n, want)
		}
		if n := mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, f.src); n != 0 {
			t.Errorf("%s in <SRC>: %d left", table, n)
		}
	}
}

// C21: the Q5 stop, its text, both lines, and each cleared on its own. The
// owner's "leave the rows" keeps them in <SRC> and lets the move go on.
func TestApplyChannelMoveC21HoursQ5(t *testing.T) {
	f := seedMove(t)
	for _, target := range []string{"t:" + f.tA, "ch:" + f.ch} {
		mvExec(t, f.pg, `INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by, entered_by)
			VALUES ($1, $2, '2026-06-10', $3, 30, 'proposed', $2, $2)`, f.src, f.only, target)
	}
	ctx := context.Background()
	q5 := "hours: " + f.only + " 2 rows not coming to " + f.dst + " (Q5)"
	_, err := f.pg.ApplyChannelMove(ctx, f.req())
	if !errors.Is(err, ErrChannelMoveRefused) || !strings.Contains(err.Error(), q5) {
		t.Fatalf("got %v, want %q", err, q5)
	}
	mvExec(t, f.pg, `INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end, state, decided_by)
		VALUES ($1, $2, '2026-06-01', '2026-06-30', 'approved', 'HUM-10')`, f.src, f.only)
	_, err = f.pg.ApplyChannelMove(ctx, f.req())
	if err == nil || !strings.Contains(err.Error(), q5) || !strings.Contains(err.Error(), "(Q8)") {
		t.Fatalf("both lines expected, got %v", err)
	}
	req := f.req()
	req.Keep = []string{f.only}
	_, err = f.pg.ApplyChannelMove(ctx, req)
	if err == nil || strings.Contains(err.Error(), "(Q5)") || !strings.Contains(err.Error(), "(Q8)") {
		t.Fatalf("adding the member clears only the Q5 line, got %v", err)
	}
	req = f.req()
	req.LeaveHours = []string{f.only}
	f.apply(t, req)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM hours_entries WHERE tenant_id = $1 AND member_id = $2`, f.src, f.only); n != 2 {
		t.Errorf("rows the owner said to leave: %d in <SRC>, want 2", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM hours_entries WHERE tenant_id = $1`, f.dst); n != 0 {
		t.Errorf("rows the owner said to leave were carried: %d", n)
	}
}

// C20: a kept email's channel invite moves with its new <DST> workspace invite;
// the other invite is deleted; <SRC>'s workspace invites stay. A channel with
// an embed visitor refuses. CONTROL: the invite without its parent hits the
// FK, and P4 rolls back.
func TestApplyChannelMoveC20Parents(t *testing.T) {
	f := seedMove(t)
	for _, e := range []string{"kept@example.com", "gone@example.com"} {
		mvExec(t, f.pg, `INSERT INTO tenant_invites (tenant_id, email, role, invited_by, expires_at) VALUES ($1, $2, 'member', $3, now() + interval '1 day')`, f.src, e, f.both)
		mvExec(t, f.pg, `INSERT INTO channel_invites (tenant_id, channel_id, email, added_by) VALUES ($1, $2, $3, $4)`, f.src, f.ch, e, f.both)
	}
	before := f.snapshot(t)
	req := f.req()
	req.KeepEmails = []string{"kept@example.com"}
	req.skipCopy = map[string]bool{"tenant_invites": true}
	if _, err := f.pg.ApplyChannelMove(context.Background(), req); err == nil || !strings.Contains(err.Error(), "foreign key") {
		t.Fatalf("CONTROL: no <DST> workspace invite must hit the FK, got %v", err)
	}
	if after := f.snapshot(t); after != before {
		t.Errorf("the refused move changed rows:\n%s\n%s", before, after)
	}
	req = f.req()
	req.KeepEmails = []string{"kept@example.com"}
	f.apply(t, req)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_invites WHERE tenant_id = $1 AND email = 'kept@example.com'`, f.dst); n != 1 {
		t.Error("the kept invite did not move")
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM tenant_invites WHERE tenant_id = $1`, f.dst); n != 1 {
		t.Errorf("<DST> workspace invites: %d, want the kept email only", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_invites WHERE tenant_id = ANY($1::text[]) AND email = 'gone@example.com'`, []string{f.src, f.dst}); n != 0 {
		t.Error("the invite that was not kept must be deleted")
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM tenant_invites WHERE tenant_id = $1`, f.src); n != 2 {
		t.Errorf("<SRC>'s workspace invites: %d, want both kept", n)
	}
}

func TestApplyChannelMoveC20EmbedRefuses(t *testing.T) {
	f := seedMove(t)
	embed := uid("emb-")
	mvExec(t, f.pg, `INSERT INTO embed_customers (tenant_id, embed_id) VALUES ($1, $2)`, f.src, embed)
	mvExec(t, f.pg, `INSERT INTO embed_visitors (tenant_id, embed_id, visitor_id, token_hash, human_id, channel_id, expires_at)
		VALUES ($1, $2, gen_random_uuid(), decode(md5(random()::text) || md5(random()::text), 'hex'), $3, $4, now() + interval '1 day')`, f.src, embed, f.only, f.ch)
	before := f.snapshot(t)
	_, err := f.pg.ApplyChannelMove(context.Background(), f.req())
	if !errors.Is(err, ErrChannelMoveRefused) || !strings.Contains(err.Error(), "embed_visitors") {
		t.Fatalf("got %v", err)
	}
	if after := f.snapshot(t); after != before {
		t.Errorf("the refused move changed rows:\n%s\n%s", before, after)
	}
}

// The audit door (rdb 0251): P4 moves the rows of the three append-only tables.
func TestApplyChannelMoveAuditRows(t *testing.T) {
	f := seedMove(t)
	f.seedAudit(t)
	f.apply(t, f.req())
	for _, table := range []string{"usage_events", "sql_query_audit", "demo_post_audit"} {
		if n := mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, f.dst); n != 1 {
			t.Errorf("%s: %d in <DST>, want 1", table, n)
		}
		if n := mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, f.src); n != 0 {
			t.Errorf("%s: %d left in <SRC>", table, n)
		}
	}
}

func (f mvFix) seedAudit(t *testing.T) {
	t.Helper()
	mvExec(t, f.pg, `INSERT INTO usage_events (tenant_id, channel_id, kind, turn_id, key_source) VALUES ($1, $2, 'unmetered', 'turn-1', 'hub')`, f.src, f.ch)
	mvExec(t, f.pg, `INSERT INTO sql_query_audit (audit_id, tenant_id, human_id, query_text, duration_ms) VALUES ($1::uuid, $2, $3, $4, 1)`,
		uuid4(), f.src, f.both, "select "+f.tA)
	mvExec(t, f.pg, `INSERT INTO demo_post_audit (tenant_id, action, human_id, msg_id, channel, body) VALUES ($1, 'post', $2, $3, $4, 'b')`, f.src, f.both, f.cardA, f.ch)
}

// The controls of the door: a DELETE without the setting raises; with it but
// outside the operator scope raises; an UPDATE with both raises; the setting
// does not outlive the transaction.
func TestChannelMoveAuditDoorControls(t *testing.T) {
	f := seedMove(t)
	f.seedAudit(t)
	ctx := context.Background()
	const refused = "append-only"
	updates := map[string]string{
		"usage_events": `UPDATE usage_events SET agent_id = 'x' WHERE tenant_id = $1`, "sql_query_audit": `UPDATE sql_query_audit SET row_count = 9 WHERE tenant_id = $1`,
		"demo_post_audit": `UPDATE demo_post_audit SET body = 'x' WHERE tenant_id = $1`}
	on := `SELECT set_config('app.channel_move', 'on', true)`
	for table, update := range updates {
		del := `DELETE FROM ` + table + ` WHERE tenant_id = $1`
		err := f.pg.asOperator(ctx, func(tx pgx.Tx) error { _, e := tx.Exec(ctx, del, f.src); return e })
		if err == nil || !strings.Contains(err.Error(), refused) {
			t.Errorf("%s: a DELETE without the setting: %v", table, err)
		}
		err = f.pg.inTenant(ctx, f.src, func(tx pgx.Tx) error {
			if _, e := tx.Exec(ctx, on); e != nil {
				return e
			}
			_, e := tx.Exec(ctx, del, f.src)
			return e
		})
		if err == nil || !strings.Contains(err.Error(), refused) {
			t.Errorf("%s: the setting outside the operator scope: %v", table, err)
		}
		err = f.pg.asOperator(ctx, func(tx pgx.Tx) error {
			if _, e := tx.Exec(ctx, on); e != nil {
				return e
			}
			_, e := tx.Exec(ctx, update, f.src)
			return e
		})
		if err == nil || !strings.Contains(err.Error(), refused) {
			t.Errorf("%s: an UPDATE with both: %v", table, err)
		}
		// GREEN side: with both, the DELETE passes; rolled back, so the rows stay.
		errBack := errors.New("rollback")
		err = f.pg.asOperator(ctx, func(tx pgx.Tx) error {
			if _, e := tx.Exec(ctx, on); e != nil {
				return e
			}
			if _, e := tx.Exec(ctx, del, f.src); e != nil {
				return e
			}
			return errBack
		})
		if !errors.Is(err, errBack) {
			t.Errorf("%s: the DELETE with both must pass, got %v", table, err)
		}
	}
	f.checkDoorEndsWithTx(t)
}

func (f mvFix) checkDoorEndsWithTx(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	conn, err := f.pg.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT set_config('app.channel_move', 'on', true)`); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var after string
	if err := conn.QueryRow(ctx, `SELECT coalesce(current_setting('app.channel_move', true), '')`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after == "on" {
		t.Fatal("app.channel_move outlived its transaction")
	}
}

// P1 inserts the journal row before P4 (spec 8.2, T7): P4 finds it, keeps who
// started it, freezes the set it really moved, and adds only its own step.
func TestApplyChannelMoveAfterP1Row(t *testing.T) {
	f := seedMove(t)
	req := f.req()
	mvExec(t, f.pg, `INSERT INTO channel_move_journal (tenant_id, move_id, mode, src_tenant_id, src_channel_id, channel_id, frozen, go_msg_id, started_by)
		VALUES ($1, $2::uuid, 'move', $3, $4, $4, '{"p1":true,"msgs":["x"]}', $5::uuid, 'HUM-1')`, f.dst, req.MoveID, f.src, f.ch, req.GoMsgID)
	mvExec(t, f.pg, `INSERT INTO channel_move_steps (tenant_id, move_id, channel_id, step, done_at) VALUES ($1, $2::uuid, $3, 'P1', now())`, f.dst, req.MoveID, f.ch)
	f.apply(t, req)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_journal WHERE tenant_id = $1 AND move_id = $2::uuid AND started_by = 'HUM-1' AND NOT frozen ? 'p1'`, f.dst, req.MoveID); n != 1 {
		t.Error("P4 must keep the P1 row and replace its frozen set")
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_steps WHERE tenant_id = $1 AND move_id = $2::uuid AND step IN ('P1', 'P4') AND done_at IS NOT NULL`, f.dst, req.MoveID); n != 2 {
		t.Errorf("steps P1 and P4 done: %d, want 2", n)
	}
	// A set that grew since P1 is on record: one msg frozen, three moved.
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_steps WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P4'
		AND counts #>> '{p1_lists,msgs}' = '1' AND counts #>> '{moved_lists,msgs}' = '3'`, f.dst, req.MoveID); n != 1 {
		t.Error("the P4 step must record the P1 count and the moved count per list")
	}
	// After P4 nothing replaces frozen: the re-run is refused and it stays.
	frozen := func() int {
		return mvCount(t, f.pg, `SELECT count(*) FROM channel_move_journal WHERE tenant_id = $1 AND move_id = $2::uuid AND jsonb_array_length(frozen->'msgs') = 3`, f.dst, req.MoveID)
	}
	if frozen() != 1 {
		t.Fatal("frozen is not the set P4 moved")
	}
	if _, err := f.pg.ApplyChannelMove(context.Background(), req); err == nil {
		t.Fatal("P4 ran twice")
	}
	if frozen() != 1 {
		t.Error("a refused re-run replaced frozen")
	}
}

// P4 refuses a GO that differs from the one P1 recorded, and keeps that row as
// it is. CONTROL: the same row with the same GO goes through.
func TestApplyChannelMoveDifferingGO(t *testing.T) {
	f := seedMove(t)
	req := f.req()
	p1GO := req.GoMsgID
	mvExec(t, f.pg, `INSERT INTO channel_move_journal (tenant_id, move_id, mode, src_tenant_id, src_channel_id, channel_id, go_msg_id, started_by)
		VALUES ($1, $2::uuid, 'move', $3, $4, $4, $5::uuid, 'HUM-1')`, f.dst, req.MoveID, f.src, f.ch, p1GO)
	before := f.snapshot(t)
	req.GoMsgID = uuid4()
	if _, err := f.pg.ApplyChannelMove(context.Background(), req); !errors.Is(err, ErrConflict) {
		t.Fatalf("a differing GO: %v, want ErrConflict", err)
	}
	if after := f.snapshot(t); after != before {
		t.Errorf("the refused move changed rows:\n%s\n%s", before, after)
	}
	req.GoMsgID = p1GO
	f.apply(t, req)
}

// What lands between P2 and the lock can stop the move: the plan under the
// lock refuses a stop P2 did not clear, and nothing changes. CONTROL: with
// that check off each of the same requests commits, so the check is the guard.
func TestApplyChannelMoveStopUnderLock(t *testing.T) {
	cases := []struct {
		name, want string
		land       func(f mvFix)
	}{
		{"hours", "(Q5)", func(f mvFix) {
			mvExec(t, f.pg, `INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by, entered_by)
				VALUES ($1, $2, '2026-06-10', $3, 30, 'proposed', $2, $2)`, f.src, f.only, "t:"+f.tA)
		}},
		{"seat", "seat c-777@box-a", func(f mvFix) {
			mvExec(t, f.pg, `INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES ($1, 'c-777', 'box-a', 'channel', $2, $3)`, f.src, f.ch, f.both)
		}},
		{"pin", "box box-a is not pinned", func(f mvFix) {
			mvExec(t, f.pg, `UPDATE pins SET revoked_at = now() WHERE tenant_id = $1 AND box_id = 'box-a'`, f.dst)
		}},
		{"desk", "seat c-100 on box-a has no desk", func(f mvFix) {
			mvExec(t, f.pg, `DELETE FROM roster WHERE tenant_id = $1 AND agent_id = 'c-100'`, f.dst)
		}},
		{"shared item", "shared epic", func(f mvFix) {
			x, err := f.pg.CreateIssue(context.Background(), Issue{TenantID: f.src, Title: "epic of both", Kind: IssueKindEpic, TaskID: f.tA, Discussions: []string{f.tA}, CreatedBy: f.both}, time.Now().UTC())
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.pg.CreateIssue(context.Background(), Issue{TenantID: f.src, Title: "staying child", Parent: x.Number, TaskID: f.tB, Discussions: []string{f.tB}, CreatedBy: f.both}, time.Now().UTC()); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := seedMove(t)
			req := f.req()
			var before string
			req.betweenPlans = func() { c.land(f); before = f.snapshot(t) }
			_, err := f.pg.ApplyChannelMove(context.Background(), req)
			if !errors.Is(err, ErrChannelMoveRefused) || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want a refusal with %q", err, c.want)
			}
			if after := f.snapshot(t); after != before {
				t.Errorf("the refused move changed rows:\n%s\n%s", before, after)
			}
			f = seedMove(t)
			req = f.req()
			req.noLockStops = true
			req.betweenPlans = func() { c.land(f) }
			if _, err := f.pg.ApplyChannelMove(context.Background(), req); errors.Is(err, ErrChannelMoveRefused) {
				t.Fatalf("CONTROL: with the check off it still refuses, so the check proves nothing: %v", err)
			}
		})
	}
}

// A move back home: spec 5.1 treats it as a real state. The first move's
// journal row comes home with the channel (rdb 0251 dropped the CHECK that
// refused it), and the old redirect, which would now point away from where
// the channel is, is gone.
func TestApplyChannelMoveBackHome(t *testing.T) {
	f := seedMove(t)
	f.apply(t, f.req())
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	if err := f.pg.PutPin(ctx, f.src, "box-a", pubkey(), false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := f.pg.SetRoster(ctx, f.src, "box-a", []string{"c-100"}, now); err != nil {
		t.Fatal(err)
	}
	back := f
	back.src, back.dst = f.dst, f.src
	f.apply(t, back.req())
	if n := mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND task_id = $2`, f.src, f.tA); n != 2 {
		t.Errorf("topic A is back with %d posts, want 2", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_journal WHERE tenant_id = $1 AND src_tenant_id = $1`, f.src); n != 1 {
		t.Errorf("the first move's journal row: %d at home, want 1", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_redirects WHERE src_tenant_id = $1 AND old_ref = $2`, f.src, f.tA); n != 0 {
		t.Errorf("%d redirect(s) send the channel's home away from it", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_redirects WHERE src_tenant_id = $1 AND old_ref = $2`, f.dst, f.tA); n != 1 {
		t.Errorf("the workspace it left has %d redirect(s), want 1", n)
	}
}

// A new move with <SRC> = <DST> is refused by the request check, now the only
// guard: the DDL allows such a journal row. CONTROL: the same request past
// the check does not get that refusal, and the row inserts.
func TestApplyChannelMoveSameWorkspaceRefused(t *testing.T) {
	f := seedMove(t)
	ctx := context.Background()
	req := f.req()
	req.Dst = req.Src
	before := f.snapshot(t)
	if _, err := f.pg.ApplyChannelMove(ctx, req); !errors.Is(err, ErrMoveRequest) {
		t.Fatalf("<SRC> = <DST>: %v, want ErrMoveRequest", err)
	}
	if after := f.snapshot(t); after != before {
		t.Errorf("the refused move changed rows:\n%s\n%s", before, after)
	}
	res := ChannelMoveResult{Copied: map[string]int{}, Deleted: map[string]int{}, NewKeys: map[string]string{}}
	err := f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		return (&pgMove{ctx: ctx, tx: tx, req: req, res: &res, cols: map[string][]string{}}).mvRun()
	})
	if errors.Is(err, ErrMoveRequest) {
		t.Fatal("CONTROL: past the check the run still answers ErrMoveRequest, so the check proves nothing")
	}
	errBack := errors.New("rollback")
	err = f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, e := tx.Exec(ctx, `INSERT INTO channel_move_journal (tenant_id, move_id, mode, src_tenant_id, src_channel_id, channel_id, go_msg_id, started_by)
			VALUES ($1, $2::uuid, 'move', $1, 'c', 'c', $3::uuid, 'HUM-10')`, f.src, uuid4(), uuid4()); e != nil {
			return e
		}
		return errBack
	})
	if !errors.Is(err, errBack) {
		t.Fatalf("CONTROL: the DDL must allow the row, so only the check stops it: %v", err)
	}
}

// R3: the largest channel on prd (F13, 3,650 posts) timed, with the runtime
// ceilings P4 lifts for itself. The number is T13's to record.
func TestApplyChannelMoveLargest(t *testing.T) {
	if testing.Short() {
		t.Skip("short")
	}
	f := seedMove(t)
	mvExec(t, f.pg, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at, is_parent)
		SELECT $1, gen_random_uuid(), CASE WHEN i % 10 = 0 THEN gen_random_uuid() ELSE $3::uuid END, $2, now(), 'box-a', 'c-100', 'box-b', 'c-101', 'msg', 'post ' || i, '[]', '{"v":1}', 'sig', ('env-' || i)::bytea, now(), now() + interval '30 days', 1
		FROM generate_series(1, 3650) i`, f.src, f.ch, f.tA)
	start := time.Now()
	res := f.apply(t, f.req())
	took := time.Since(start)
	t.Logf("R3: %d posts, %d tasks moved in %s", len(res.Binds.Msgs), len(res.Binds.Tasks), took)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND channel = $2`, f.dst, f.ch); n < 3650 {
		t.Fatalf("%d posts in <DST>", n)
	}
	if took > 5*time.Minute {
		t.Errorf("P4 took %s, over its own ceiling", took)
	}
}
