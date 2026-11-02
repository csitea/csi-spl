// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
	"github.com/jackc/pgx/v5"
)

// Spec 169 row T11, case C16: copy mode. Every case runs on Postgres, on the
// fixture of the move (mvFix), with real envelopes in place of its stand-ins.

const (
	cpSrcHost = "src.example.net"
	cpDstHost = "dst.example.net"
)

// cpFix is mvFix with a human post that links topic A, and a doc, issues, an
// event and hours rows in the set.
type cpFix struct {
	mvFix
	human, doc, event string
	issues            mvIssues
}

func seedCopy(t *testing.T) cpFix {
	t.Helper()
	f := cpFix{mvFix: seedMove(t)}
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	m := msgFor(f.src, f.tA, "box-a", now, now, "env-"+uuid4())
	m.Channel, m.FromBox, m.FromID, m.EnvSig = f.ch, "box-wui", f.both, ""
	m.Body = "see https://" + cpSrcHost + "/t/" + f.tA + " and https://" + cpSrcHost + "/t/" + strings.ToUpper(f.thread)
	if _, err := f.pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	f.human = m.MsgID
	f.doc = seedMoveDoc(t, f.mvFix, "copied")
	f.issues = seedMoveIssues(t, f.mvFix)
	f.event = f.mvEvent(t)
	mvExec(t, f.pg, `UPDATE calendar_events SET remind_at = now() + interval '1 day', props = '{"reminders":[{"amount":1,"unit":"hours"}]}' WHERE event_id = $1`, f.event)
	f.mvHours(t, f.both)
	f.realEnvelopes(t)
	return f
}

// realEnvelopes writes each <SRC> post's envelope from its row, as the hub does.
func (f cpFix) realEnvelopes(t *testing.T) {
	t.Helper()
	mvExec(t, f.pg, `UPDATE messages SET
		msg = jsonb_build_object('v', 1, 'msg_id', msg_id, 'task_id', task_id, 'ts', ts, 'from', from_id, 'to', to_id, 'kind', kind, 'body', body, 'files', '[]'::jsonb),
		env = convert_to(jsonb_build_object('from_box', from_box, 'to_box', to_box, 'channel', channel, 'parent_task_id', parent_task_id,
			'sig', CASE WHEN env_sig = '' THEN NULL ELSE env_sig END,
			'msg', jsonb_build_object('v', 1, 'msg_id', msg_id, 'task_id', task_id, 'ts', ts, 'from', from_id, 'to', to_id, 'kind', kind, 'body', body, 'files', '[]'::jsonb))::text, 'UTF8')
		WHERE tenant_id = $1`, f.src)
}

func (f cpFix) req() ChannelCopyRequest {
	tables, binds := moveCatalogue()
	return ChannelCopyRequest{
		ChannelMovePlanRequest: ChannelMovePlanRequest{Src: f.src, Channel: f.ch, Dst: f.dst, RuleDoc: f.doc, Tables: tables, BindTypes: binds},
		MoveID:                 uuid4(), GoMsgID: uuid4(), StartedBy: f.both, SrcHost: cpSrcHost, DstHost: cpDstHost,
	}
}

// row is one operator-scope read: the test login is bound by RLS.
func (f cpFix) row(sql string, args ...any) cpRow { return cpRow{f.pg, sql, args} }

type cpRow struct {
	pg   *Postgres
	sql  string
	args []any
}

func (r cpRow) Scan(dest ...any) error {
	return r.pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), r.sql, r.args...).Scan(dest...)
	})
}

func (f cpFix) apply(t *testing.T, req ChannelCopyRequest) ChannelCopyResult {
	t.Helper()
	res, err := f.pg.ApplyChannelCopy(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// srcState is <SRC>'s rows and what they say: a copy changes none of it.
func (f cpFix) srcState(t *testing.T) string {
	t.Helper()
	snap := f.snapshot(t)
	var sum string
	err := f.row(`SELECT md5(string_agg(msg_id::text || env_sig || encode(env, 'hex') || body, '' ORDER BY msg_id)) FROM messages WHERE tenant_id = $1`, f.src).Scan(&sum)
	if err != nil {
		t.Fatal(err)
	}
	return snap[:strings.Index(snap, "|")] + sum
}

// C16, the hub rows: <SRC> unchanged, every id new, the rows the copy leaves out.
func TestApplyChannelCopyC16Rows(t *testing.T) {
	f := seedCopy(t)
	before := f.srcState(t)
	res := f.apply(t, f.req())
	if after := f.srcState(t); after != before {
		t.Errorf("the copy changed <SRC>:\n%s\n%s", before, after)
	}
	if len(res.Deleted) != 0 {
		t.Errorf("a copy deleted %v", res.Deleted)
	}
	for old, n := range res.IDs {
		if old == n {
			t.Errorf("id %s kept", old)
		}
	}
	for _, c := range []struct{ name, sql string }{
		{"task", `SELECT count(*) FROM messages WHERE tenant_id = $1 AND task_id = ANY($2::uuid[])`},
		{"msg", `SELECT count(*) FROM messages WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])`},
		{"doc", `SELECT count(*) FROM workspace_doc WHERE tenant_id = $1 AND id = ANY($2::uuid[])`},
		{"node", `SELECT count(*) FROM workspace_doc_node WHERE tenant_id = $1 AND id = ANY($2::uuid[])`},
		{"event", `SELECT count(*) FROM calendar_events WHERE tenant_id = $1 AND event_id = ANY($2::uuid[])`},
	} {
		olds := make([]string, 0, len(res.IDs))
		for o := range res.IDs {
			olds = append(olds, o)
		}
		if n := mvCount(t, f.pg, c.sql, f.dst, olds); n != 0 {
			t.Errorf("%d %s row(s) in <DST> kept an old id", n, c.name)
		}
	}
	want := mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])`, f.src, res.Binds.Msgs)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM messages d JOIN messages s ON s.tenant_id = $2 AND s.msg_id = d.copied_from WHERE d.tenant_id = $1 AND d.env_sig = ''`, f.dst, f.src); n != want {
		t.Errorf("%d rows name their source with no signature, want %d", n, want)
	}
	f.checkFamily(t, res)
	f.checkDoc(t, res)
	f.checkIssues(t, res)
	f.checkLeftOut(t)
	f.checkJournal(t, res)
}

func (f cpFix) checkFamily(t *testing.T, res ChannelCopyResult) {
	t.Helper()
	for table, want := range map[string]int{"message_revisions": 1, "message_reactions": 1, "message_answers": 1, "topic_priorities": 1, "hours_jobs": 1} {
		if n := mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, f.dst); n != want {
			t.Errorf("%s in <DST>: %d, want %d", table, n, want)
		}
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_humans WHERE tenant_id = $1 AND human_id = $2`, f.dst, f.both); n != 1 {
		t.Errorf("the owner is not the copy's member (%d)", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_humans WHERE tenant_id = $1`, f.dst); n != 1 {
		t.Errorf("the copy has %d members, want the owner only", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM topic_heads WHERE tenant_id = $1 AND task_id = $2::uuid`, f.dst, res.IDs[f.tA]); n != 1 {
		t.Errorf("topic A has %d heads in <DST>", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND (claim_state <> 'done' OR responsible IS NOT NULL OR handled_at IS NULL)`, f.dst); n != 0 {
		t.Errorf("%d copied row(s) can still be offered to a seat", n)
	}
	var job string
	if err := f.row(`SELECT task_id FROM hours_jobs WHERE tenant_id = $1`, f.dst).Scan(&job); err != nil || job != res.IDs[f.tA] {
		t.Errorf("the job's task %q, want the new topic %s (%v)", job, res.IDs[f.tA], err)
	}
}

func (f cpFix) checkDoc(t *testing.T, res ChannelCopyResult) {
	t.Helper()
	doc, ok := res.IDs[f.doc]
	if !ok {
		t.Fatalf("the doc is not in the map: %v", res.Binds.Docs)
	}
	for _, c := range []struct{ table, pred string }{
		{"workspace_doc", "id = $2::uuid"}, {"workspace_doc_item", "doc_id = $2::uuid"}, {"workspace_doc_rev_log", "doc_id = $2::uuid"},
		{"workspace_doc_node", "doc_id = $2::uuid"}, {"workspace_doc_acl", "node_id IN (SELECT id FROM workspace_doc_node WHERE doc_id = $2::uuid)"},
	} {
		src, dst := f.docRows(t, c.table, c.pred, f.src, f.doc), f.docRows(t, c.table, c.pred, f.dst, doc)
		if src == 0 || src != dst {
			t.Errorf("%s: <SRC> %d, <DST> %d", c.table, src, dst)
		}
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM workspace_doc_item d JOIN workspace_doc_item s ON s.id = d.id WHERE d.tenant_id = $1 AND s.tenant_id = $2`, f.dst, f.src); n != 0 {
		t.Errorf("%d item(s) share an id", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id = $1 AND op::text LIKE '%' || $2 || '%'`, f.dst, f.doc); n != 0 {
		t.Errorf("%d rev log op(s) name the old doc", n)
	}
}

func (f cpFix) checkIssues(t *testing.T, res ChannelCopyResult) {
	t.Helper()
	if len(res.NewKeys) == 0 {
		t.Fatal("no issue was renumbered")
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM issues WHERE tenant_id = $1`, f.src); n != 3 {
		t.Errorf("<SRC> holds %d issues, want its 3", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM issue_events WHERE tenant_id = $1 AND new_value LIKE 'copied from %'`, f.dst); n != len(res.NewKeys) {
		t.Errorf("%d first events name the source, want %d", n, len(res.NewKeys))
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM issue_discussions d WHERE d.tenant_id = $1 AND NOT d.task_id IN (SELECT task_id FROM messages WHERE tenant_id = $1)`, f.dst); n != 0 {
		t.Errorf("%d discussion link(s) point outside the copy", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM fleet_lanes WHERE tenant_id = $1 AND issue_key = ANY($2::text[])`, f.src, cpKeys(res.NewKeys)); n != 1 {
		t.Errorf("a copy must leave <SRC>'s lane on its old key: %d", n)
	}
}

func cpKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func (f cpFix) checkLeftOut(t *testing.T) {
	t.Helper()
	for _, table := range []string{"deliveries", "delivery_live_acks", "fallback_deliveries", "read_marks", "channel_invites", "channel_subscriptions",
		"dedicated_agents", "flow_watches", "flow_events", "issue_opens", "hours_plan", "hours_minutes", "hours_entries", "hours_entry_spans", "hours_adjustments",
		"spec_sync_map", "usage_events", "token_budgets", "operator_audit", "demo_post_audit", "sql_query_audit", "gcal_event_map"} {
		if n := mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1`, f.dst); n != 0 {
			t.Errorf("%s in <DST>: %d, a copy carries none", table, n)
		}
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM workspace_events WHERE tenant_id = $1`, f.dst); n != 1 {
		t.Errorf("workspace_events in <DST>: %d, want the one channel.copied", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM workspace_events WHERE tenant_id = $1 AND kind = 'channel.copied'`, f.dst); n != 1 {
		t.Errorf("no channel.copied event (%d)", n)
	}
}

func (f cpFix) checkJournal(t *testing.T, res ChannelCopyResult) {
	t.Helper()
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_journal WHERE tenant_id = $1 AND mode = 'copy' AND frozen->'id_map'->>$2 = $3`, f.dst, f.tA, res.IDs[f.tA]); n != 1 {
		t.Errorf("the journal's map misses topic A (%d)", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channel_move_steps WHERE tenant_id = $1 AND step = 'P4' AND done_at IS NOT NULL`, f.dst); n != 1 {
		t.Errorf("the P4 step is missing (%d)", n)
	}
}

// C16, what the copied row says: its envelope parses, names only new ids, and
// a link points at the copied topic on <DST>'s host.
func TestApplyChannelCopyC16Envelope(t *testing.T) {
	f := seedCopy(t)
	res := f.apply(t, f.req())
	var raw []byte
	var body, msgCol string
	err := f.row(`SELECT env, body, msg::text FROM messages WHERE tenant_id = $1 AND msg_id = $2::uuid`, f.dst, res.IDs[f.human]).Scan(&raw, &body, &msgCol)
	if err != nil {
		t.Fatal(err)
	}
	e, err := wire.ParseEnvelope(raw)
	if err != nil {
		t.Fatalf("the rewritten envelope: %v\n%s", err, raw)
	}
	if e.Sig != "" {
		t.Errorf("a rewritten envelope kept a signature %q", e.Sig)
	}
	m, err := msg.Parse(e.Msg)
	if err != nil {
		t.Fatalf("the rewritten msg: %v\n%s", err, e.Msg)
	}
	if m.MsgID != res.IDs[f.human] || m.TaskID != res.IDs[f.tA] {
		t.Errorf("the envelope names msg %s task %s, want %s %s", m.MsgID, m.TaskID, res.IDs[f.human], res.IDs[f.tA])
	}
	link := "https://" + cpDstHost + "/t/" + res.IDs[f.tA]
	for name, text := range map[string]string{"body": body, "env.msg.body": m.Body} {
		if !strings.Contains(text, link) {
			t.Errorf("%s has no link to the copied topic: %s", name, text)
		}
		if !strings.Contains(text, res.IDs[f.thread]) {
			t.Errorf("%s keeps an upper-case old link: %s", name, text)
		}
	}
	for old := range res.IDs {
		for name, text := range map[string]string{"env": string(raw), "msg": msgCol, "body": body} {
			if strings.Contains(strings.ToLower(text), old) {
				t.Errorf("%s still names the old id %s", name, old)
			}
		}
	}
	if !strings.Contains(string(raw), f.ch) {
		t.Errorf("the envelope lost its channel: %s", raw)
	}
}

// C16, what a box sees: an unsigned copied row is not back-filled, and were it
// signed, it would be filed under the new topic.
func TestApplyChannelCopyC16Box(t *testing.T) {
	f := seedCopy(t)
	res := f.apply(t, f.req())
	ctx, now := context.Background(), time.Now().UTC()
	rows, err := f.pg.ChannelBackfill(ctx, f.dst, f.ch, now.Add(-time.Hour), now, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("%d copied row(s) reach a box", len(rows))
	}
	src, err := f.pg.ChannelBackfill(ctx, f.src, f.ch, now.Add(-time.Hour), now, 100)
	if err != nil || len(src) == 0 {
		t.Fatalf("control: <SRC>'s signed rows back-fill: %d, %v", len(src), err)
	}
	mvExec(t, f.pg, `UPDATE messages SET env_sig = 'x' WHERE tenant_id = $1`, f.dst)
	rows, err = f.pg.ChannelBackfill(ctx, f.dst, f.ch, now.Add(-time.Hour), now, 100)
	if err != nil || len(rows) == 0 {
		t.Fatalf("control: a signed row back-fills: %d, %v", len(rows), err)
	}
	for _, r := range rows {
		e, err := wire.ParseEnvelope(r.Env)
		if err != nil {
			t.Fatal(err)
		}
		m, err := msg.Parse(e.Msg)
		if err != nil {
			t.Fatal(err)
		}
		if m.TaskID != r.TaskID || m.MsgID != r.MsgID {
			t.Errorf("a box would file task %s msg %s, the row is %s %s", m.TaskID, m.MsgID, r.TaskID, r.MsgID)
		}
		if _, isOld := res.IDs[m.TaskID]; isOld {
			t.Errorf("a box would file the old task %s", m.TaskID)
		}
	}
}

// A copied human post has the shape of an unsigned WUI post, and replay must
// not re-sign and deliver it (c-001 fc977008). The control: the same row with
// no copied_from is listed.
func TestApplyChannelCopyNotReplayed(t *testing.T) {
	f := seedCopy(t)
	res := f.apply(t, f.req())
	ctx, now := context.Background(), time.Now().UTC()
	rows, err := f.pg.UnsignedWUIPosts(ctx, f.dst, now.Add(-time.Hour), now, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("%d copied post(s) would be replayed", len(rows))
	}
	got, err := f.pg.GetEditable(ctx, f.dst, res.IDs[f.human], now)
	if err != nil || got.CopiedFrom != f.human || got.EnvSig != "" {
		t.Errorf("GetEditable of a copy: copied from %q sig %q, want %s (%v)", got.CopiedFrom, got.EnvSig, f.human, err)
	}
	mvExec(t, f.pg, `UPDATE messages SET copied_from = NULL WHERE tenant_id = $1 AND msg_id = $2::uuid`, f.dst, res.IDs[f.human])
	rows, err = f.pg.UnsignedWUIPosts(ctx, f.dst, now.Add(-time.Hour), now, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Errorf("control: a post with no copied_from: %d listed, want 1", len(rows))
	}
}

func TestUnsignedWUIPostsSkipsCopyMemory(t *testing.T) {
	s := NewMemory()
	ctx, now := context.Background(), time.Now().UTC()
	tn := uid("t")
	m := msgFor(tn, uuid4(), "box-a", now, now, "env")
	m.Channel, m.FromBox, m.FromID, m.EnvSig = "lobby", "box-wui", "HUM-1", ""
	if _, err := s.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	if rows, err := s.UnsignedWUIPosts(ctx, tn, now.Add(-time.Hour), now, 10); err != nil || len(rows) != 1 {
		t.Fatalf("control: %d rows, %v", len(rows), err)
	}
	s.mu.Lock()
	for k := range s.messages {
		if k[0] == tn {
			s.messages[k].CopiedFrom = m.MsgID
		}
	}
	s.mu.Unlock()
	if rows, err := s.UnsignedWUIPosts(ctx, tn, now.Add(-time.Hour), now, 10); err != nil || len(rows) != 0 {
		t.Errorf("a copied post: %d rows, %v", len(rows), err)
	}
}

// A copied event reaches nobody: no reminder, no Google map row, and a key the
// Out half never pushes without one.
func TestApplyChannelCopyCalendarSilent(t *testing.T) {
	f := seedCopy(t)
	res := f.apply(t, f.req())
	ev := res.IDs[f.event]
	var key string
	var remind *time.Time
	var reminders bool
	err := f.row(`SELECT source_key, remind_at, props ? 'reminders' FROM calendar_events WHERE tenant_id = $1 AND event_id = $2::uuid`, f.dst, ev).Scan(&key, &remind, &reminders)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(key, "gcal:") || remind != nil || reminders {
		t.Errorf("the copied event: key %q, remind_at %v, reminders %v", key, remind, reminders)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM gcal_event_map WHERE tenant_id = $1`, f.dst); n != 0 {
		t.Errorf("%d Google map row(s)", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM calendar_guests WHERE tenant_id = $1 AND event_id = $2::uuid`, f.dst, ev); n != 1 {
		t.Errorf("guests: %d, want the one <DST> member", n)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM calendar_events WHERE tenant_id = $1 AND event_id = $2 AND remind_at IS NOT NULL`, f.src, f.event); n != 1 {
		t.Errorf("<SRC>'s reminder changed (%d)", n)
	}
}

// The red controls of C16: an old item id breaks the primary key, and old
// uuids in a link point at nothing in <DST>.
func TestApplyChannelCopyC16Controls(t *testing.T) {
	f := seedCopy(t)
	channels := mvCount(t, f.pg, `SELECT count(*) FROM channels WHERE tenant_id = $1`, f.dst)
	req := f.req()
	req.keepItemIDs = true
	if _, err := f.pg.ApplyChannelCopy(context.Background(), req); err == nil || !strings.Contains(err.Error(), "workspace_doc_item") {
		t.Errorf("an old item id must break the primary key: %v", err)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM channels WHERE tenant_id = $1`, f.dst); n != channels {
		t.Errorf("a failed copy changed <DST>'s channels: %d, was %d", n, channels)
	}
	req = f.req()
	req.keepLinks = true
	res := f.apply(t, req)
	var body string
	if err := f.row(`SELECT body FROM messages WHERE tenant_id = $1 AND msg_id = $2::uuid`, f.dst, res.IDs[f.human]).Scan(&body); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(body, f.tA) {
		t.Errorf("control: the old link is gone without the rewrite: %s", body)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND task_id = $2::uuid`, f.dst, f.tA); n != 0 {
		t.Errorf("control: the old link resolves in <DST> (%d)", n)
	}
}

func TestApplyChannelCopyRefusals(t *testing.T) {
	f := seedCopy(t)
	f.apply(t, f.req())
	if _, err := f.pg.ApplyChannelCopy(context.Background(), f.req()); !errors.Is(err, ErrConflict) {
		t.Errorf("a second copy into the same workspace: %v", err)
	}
	req := f.req()
	req.Tables = append(append([]MoveTable{}, req.Tables...), MoveTable{Table: "a_new_table", Class: MoveClassMoved, Set: "true"})
	if _, err := f.pg.ApplyChannelCopy(context.Background(), req); !errors.Is(err, ErrMoveRequest) || !strings.Contains(err.Error(), "a_new_table") {
		t.Errorf("a moved table with no copy rule must refuse: %v", err)
	}
	req = f.req()
	req.GoMsgID = ""
	if _, err := f.pg.ApplyChannelCopy(context.Background(), req); !errors.Is(err, ErrMoveRequest) {
		t.Errorf("no GO must refuse: %v", err)
	}
}

// Every Moved table of the catalogue has a copy rule, and each rule names one.
func TestChannelCopyRulesMatchCatalogue(t *testing.T) {
	tables, _ := moveCatalogue()
	moved := map[string]bool{}
	for _, m := range tables {
		if m.Class != MoveClassMoved {
			continue
		}
		moved[m.Table] = true
		if _, ok := cpCarried[m.Table]; !ok {
			t.Errorf("moved table %s has no copy rule", m.Table)
		}
	}
	for table := range cpCarried {
		if !moved[table] {
			t.Errorf("copy rule %s names no moved table", table)
		}
	}
}
