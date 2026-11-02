// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// ApplyChannelCopy is copy mode of spec 169 (row T11, section 7): one
// transaction, asOperator, that gives <DST> its own channel with the set under
// new identities. <SRC> is only read and the audit door (rdb 0251) stays shut.
//
// A copied row names only new ids: every id of the set goes through one old ->
// new map (cp_ids, kept in the journal), and the envelope is rewritten with
// them, so env_sig is ” and copied_from names the signed original, which stays
// in <SRC>. An unsigned row never reaches a box (ChannelBackfill, the fallback
// reads) and UnsignedWUIPosts leaves it out, so a box gets a copied row with
// the new ids or not at all.
type ChannelCopier interface {
	ApplyChannelCopy(ctx context.Context, req ChannelCopyRequest) (ChannelCopyResult, error)
}

var _ ChannelCopier = (*Postgres)(nil)

// ChannelCopyRequest is the plan's request plus what the copy needs.
type ChannelCopyRequest struct {
	ChannelMovePlanRequest
	MoveID    string // the journal's move_id (a uuid)
	GoMsgID   string // the owner's GO answer (8.1)
	StartedBy string // the owner: the copy's only member (section 7)
	// SrcHost and DstHost are the two workspaces' hosts: a link to a copied
	// topic on SrcHost points at DstHost afterwards. "" leaves hosts alone.
	SrcHost, DstHost string

	// The controls of C16, tests only.
	keepItemIDs bool // workspace_doc_item keeps its old ids
	keepLinks   bool // text keeps the old uuids
}

// ChannelCopyResult is what the copy did; IDs is the old -> new map.
type ChannelCopyResult struct {
	ChannelMoveResult
	IDs map[string]string
}

// cpCarried: every Moved table of the catalogue says what a copy does with it
// (spec 169 section 7). true = copyAll's steps carry it; false = it stays out:
// per person or per box, a member's time record, the audit trail, or a link a
// snapshot must not follow. A Moved table with no entry refuses the copy, so a
// table added later cannot be missed.
var cpCarried = map[string]bool{
	"channels": true, "messages": true, "message_revisions": true, "message_reactions": true,
	"message_kind_changes": true, "message_moderation": true, "message_answers": true, "channel_humans": true,
	"topic_heads": true, "topic_head_parts": true, "topic_priorities": true,
	"calendar_events": true, "calendar_guests": true, "hours_jobs": true,
	"issues": true, "issue_events": true, "issue_discussions": true,
	"workspace_doc": true, "workspace_doc_item": true, "workspace_doc_node": true, "workspace_doc_acl": true, "workspace_doc_rev_log": true,
	"channel_move_journal": true, "channel_move_steps": true,

	"deliveries": false, "delivery_live_acks": false, "fallback_deliveries": false, "read_marks": false,
	"channel_invites": false, "channel_subscriptions": false, "dedicated_agents": false,
	"flow_watches": false, "flow_events": false, "issue_opens": false,
	"hours_plan": false, "hours_minutes": false, "hours_entries": false, "hours_entry_spans": false, "hours_adjustments": false,
	"spec_sync_map": false,
	"usage_events":  false, "token_budgets": false, "workspace_events": false, "operator_audit": false,
	"demo_post_audit": false, "sql_query_audit": false,
}

func cpCheckRequest(req ChannelCopyRequest) error {
	if err := mpCheckRequest(req.ChannelMovePlanRequest); err != nil {
		return err
	}
	if !isUUID(req.MoveID) || !isUUID(req.GoMsgID) || strings.TrimSpace(req.StartedBy) == "" {
		return fmt.Errorf("%w: move id %q, go msg id %q and started by %q are all required",
			ErrMoveRequest, req.MoveID, req.GoMsgID, req.StartedBy)
	}
	for _, t := range req.Tables {
		if _, ok := cpCarried[t.Table]; t.Class == MoveClassMoved && !ok {
			return fmt.Errorf("%w: moved table %s has no copy rule (cpCarried)", ErrMoveRequest, t.Table)
		}
	}
	return nil
}

// ApplyChannelCopy implements ChannelCopier.
func (s *Postgres) ApplyChannelCopy(ctx context.Context, req ChannelCopyRequest) (ChannelCopyResult, error) {
	if err := cpCheckRequest(req); err != nil {
		return ChannelCopyResult{}, err
	}
	res := ChannelCopyResult{ChannelMoveResult: ChannelMoveResult{MoveID: req.MoveID, Copied: map[string]int{}, Deleted: map[string]int{}, NewKeys: map[string]string{}},
		IDs: map[string]string{}}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		mv := ChannelMoveApplyRequest{ChannelMovePlanRequest: req.ChannelMovePlanRequest, MoveID: req.MoveID, GoMsgID: req.GoMsgID, StartedBy: req.StartedBy}
		c := &pgCopy{pgMove: &pgMove{ctx: ctx, tx: tx, req: mv, res: &res.ChannelMoveResult, cols: map[string][]string{}}, creq: req, out: &res}
		return c.cpRun()
	})
	if err != nil {
		return ChannelCopyResult{}, err
	}
	return res, nil
}

// pgCopy is one copy run. It borrows pgMove's plan, columns and Qto and issue
// helpers; none of pgMove's writes to <SRC> run.
type pgCopy struct {
	*pgMove
	creq ChannelCopyRequest
	out  *ChannelCopyResult
}

func (c *pgCopy) cpRun() error {
	steps := []func() error{c.cpScope, c.planSet, c.buildMap, c.copyChannel, c.copyMessages, c.copyMessageChildren, c.copyCalendar, c.copyJobs,
		c.copyIssues, c.copyDocs, c.writeJournal, c.cpFinish}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
	}
	return nil
}

// scope: the ceiling and a share lock, so a move of this channel waits. No
// audit door: a copy deletes nothing.
func (c *pgCopy) cpScope() error {
	if _, err := c.tx.Exec(c.ctx, `SET LOCAL statement_timeout = '`+channelMoveTimeout+`'`); err != nil {
		return err
	}
	var id string
	err := c.tx.QueryRow(c.ctx, `SELECT channel_id FROM channels WHERE tenant_id = $1 AND channel_id = $2 FOR SHARE`,
		c.req.Src, c.req.Channel).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("channel %q in %q: %w", c.req.Channel, c.req.Src, ErrNotFound)
	}
	if err != nil {
		return err
	}
	var taken int
	if err := c.tx.QueryRow(c.ctx, `SELECT count(*) FROM channels WHERE tenant_id = $1 AND channel_id = $2`, c.req.Dst, c.req.Channel).Scan(&taken); err != nil {
		return err
	}
	if taken > 0 {
		return fmt.Errorf("channel %q already exists in %q: %w", c.req.Channel, c.req.Dst, ErrConflict)
	}
	return nil
}

// planSet: the set of this moment. A copy has no stops: <SRC> keeps a shared
// item, and a seat or an hours row is not carried.
func (c *pgCopy) planSet() error {
	members := map[string]bool{}
	err := eachRow(c.ctx, c.tx, `SELECT human_id FROM tenant_memberships WHERE tenant_id = $1`, []any{c.req.Dst}, func(r pgx.Rows) error {
		var h string
		err := r.Scan(&h)
		members[h] = true
		c.kept = append(c.kept, h)
		return err
	})
	if err != nil {
		return err
	}
	plan := ChannelMovePlan{Src: c.req.Src, Channel: c.req.Channel, Dst: c.req.Dst}
	c.plan = pgPlan{ctx: c.ctx, tx: c.tx, req: c.req.ChannelMovePlanRequest, plan: &plan, inDst: func(h string) bool { return members[h] }}
	if err := c.plan.mpRun(); err != nil {
		return err
	}
	c.b, c.res.Binds = plan.Binds, plan.Binds
	return nil
}

// buildMap makes cp_ids: one new uuid per old uuid of the set. A row's msg_id
// can be a task id too, and one map keeps that true of the copy.
func (c *pgCopy) buildMap() error {
	if _, err := c.exec(`CREATE TEMP TABLE cp_ids (old uuid PRIMARY KEY, new uuid NOT NULL) ON COMMIT DROP`); err != nil {
		return err
	}
	if _, err := c.exec(`INSERT INTO cp_ids (old, new) SELECT o, gen_random_uuid() FROM (
			SELECT unnest($1::uuid[]) AS o UNION SELECT unnest($2::uuid[]) UNION SELECT unnest($3::uuid[])
			UNION SELECT unnest($4::uuid[]) UNION SELECT unnest($5::uuid[])
			UNION SELECT id FROM workspace_doc_item WHERE tenant_id = $6 AND doc_id = ANY($4::uuid[])
		) ids`, mpNonNil(c.b.Tasks), mpNonNil(c.b.Msgs), mpNonNil(c.b.Events), mpNonNil(c.b.Docs), mpNonNil(c.b.Nodes), c.req.Src); err != nil {
		return err
	}
	err := eachRow(c.ctx, c.tx, `SELECT old::text, new::text FROM cp_ids`, nil, func(r pgx.Rows) error {
		var o, n string
		err := r.Scan(&o, &n)
		c.out.IDs[o] = n
		return err
	})
	if err != nil {
		return err
	}
	if c.creq.keepItemIDs {
		_, err = c.exec(`UPDATE cp_ids SET new = old WHERE old IN (SELECT id FROM workspace_doc_item WHERE tenant_id = $1 AND doc_id = ANY($2::uuid[]))`,
			c.req.Src, mpNonNil(c.b.Docs))
	}
	return err
}

// cpNew maps a uuid column; an id outside the set reads NULL, since no row of
// the copy may name a row it cannot reach.
func cpNew(col string) string { return `(SELECT new FROM cp_ids WHERE old = x.` + col + `)` }

// insert copies table's rows under <DST>: over replaces a column's value with
// an expression over x, the <SRC> row, and join and where narrow them. $1 is
// <DST>, $2 <SRC>, and args follow.
func (c *pgCopy) cpInsert(table string, over map[string]string, join, where string, args ...any) error {
	cols, err := c.columns(table)
	if err != nil {
		return err
	}
	sel := make([]string, len(cols))
	for i, col := range cols {
		sel[i] = "x." + col
		if e, ok := over[strings.Trim(col, `"`)]; ok {
			sel[i] = e
		}
	}
	id := pgx.Identifier{table}.Sanitize()
	n, err := c.exec(`INSERT INTO `+id+` (tenant_id, `+strings.Join(cols, ", ")+`) SELECT $1, `+strings.Join(sel, ", ")+
		` FROM `+id+` x `+join+` WHERE x.tenant_id = $2 AND `+where, append([]any{c.req.Dst, c.req.Src}, args...)...)
	if err != nil {
		return fmt.Errorf("copy %s: %w", table, err)
	}
	c.res.Copied[table] = n
	return nil
}

// copyChannel: the owner is the copy's only member (section 7).
func (c *pgCopy) copyChannel() error {
	if err := c.cpInsert("channels", nil, "", `x.channel_id = $3`, c.req.Channel); err != nil {
		return err
	}
	n, err := c.exec(`INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by) VALUES ($1, $2, $3, now(), $3)`,
		c.req.Dst, c.req.Channel, c.req.StartedBy)
	c.res.Copied["channel_humans"] = n
	return err
}

// copyMessages inserts the rows under their new ids, then rewrites what they
// say. A copied row's history of 045 moves names <SRC>'s ids, so it is cleared;
// its claim is done, so no later seat is offered an old post (the triggers on
// insert fill claims in as for a new post).
func (c *pgCopy) copyMessages() error {
	over := map[string]string{"msg_id": "mi.new", "task_id": "ti.new", "parent_task_id": cpNew("parent_task_id"), "ref_task_id": cpNew("ref_task_id"),
		"mirror_of": cpNew("mirror_of"), "env_sig": "''", "copied_from": "x.msg_id",
		"moved_at": "NULL", "moved_by": "NULL", "moved_from_channel": "NULL", "moved_from_task": "NULL", "moved_from_parent": "NULL"}
	if err := c.cpInsert("messages", over, `JOIN cp_ids mi ON mi.old = x.msg_id JOIN cp_ids ti ON ti.old = x.task_id`,
		`x.msg_id = ANY($3::uuid[])`, mpNonNil(c.b.Msgs)); err != nil {
		return err
	}
	if _, err := c.exec(`UPDATE messages SET responsible = NULL, locked_until = NULL, needs_peer = false, claim_state = 'done',
			handled_at = coalesce(handled_at, now()), handled_how = coalesce(handled_how, 'no-reply:copied'),
			offer_set = '{}', offer_until = NULL, parked_until = NULL, park_reason = NULL, wait_token = NULL
		WHERE tenant_id = $1 AND copied_from IS NOT NULL AND msg_id IN (SELECT new FROM cp_ids)`, c.req.Dst); err != nil {
		return fmt.Errorf("copied claims: %w", err)
	}
	return c.rewriteEnvelopes()
}

// cpUUID finds a uuid in text. Every uuid of the set is lower case in storage,
// and a link may have been typed in any case.
var cpUUID = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`)

// rewrite puts the new ids (and <DST>'s host, on a link to a copied topic)
// into a text.
func (c *pgCopy) cpRewrite(s string) string {
	if c.creq.keepLinks {
		return s
	}
	out := cpUUID.ReplaceAllStringFunc(s, func(id string) string {
		if n, ok := c.out.IDs[strings.ToLower(id)]; ok {
			return n
		}
		return id
	})
	if c.creq.SrcHost == "" || c.creq.DstHost == "" {
		return out
	}
	re := regexp.MustCompile(`//` + regexp.QuoteMeta(c.creq.SrcHost) + `/t/(` + cpUUID.String() + `)`)
	return re.ReplaceAllStringFunc(out, func(link string) string {
		id := link[strings.LastIndex(link, "/")+1:]
		for _, n := range c.out.IDs {
			if n == strings.ToLower(id) {
				return `//` + c.creq.DstHost + `/t/` + id
			}
		}
		return link
	})
}

// rewriteEnvelope is one copied row's envelope: the new ids everywhere, no
// signature, and no ref_task_id once its topic is outside the set.
func (c *pgCopy) rewriteEnvelope(raw []byte, ref *string) ([]byte, []byte, error) {
	var env map[string]json.RawMessage
	if err := json.Unmarshal([]byte(c.cpRewrite(string(raw))), &env); err != nil {
		return nil, nil, fmt.Errorf("the envelope is not an object, and a copy keeps no old id: %w", err)
	}
	delete(env, "sig")
	var inner map[string]json.RawMessage
	if err := json.Unmarshal(env["msg"], &inner); err != nil {
		return nil, nil, fmt.Errorf("the envelope has no msg object: %w", err)
	}
	if ref == nil {
		delete(inner, "ref_task_id")
	}
	msg, err := json.Marshal(inner)
	if err != nil {
		return nil, nil, err
	}
	env["msg"] = msg
	out, err := json.Marshal(env)
	return out, msg, err
}

// rewriteEnvelopes rewrites every copied row in one UPDATE.
func (c *pgCopy) rewriteEnvelopes() error {
	var ids, bodies, msgs []string
	var envs [][]byte
	err := eachRow(c.ctx, c.tx, `SELECT msg_id::text, env, body, ref_task_id::text FROM messages
		WHERE tenant_id = $1 AND msg_id IN (SELECT new FROM cp_ids) AND copied_from IS NOT NULL`, []any{c.req.Dst}, func(r pgx.Rows) error {
		var id, body string
		var env []byte
		var ref *string
		if err := r.Scan(&id, &env, &body, &ref); err != nil {
			return err
		}
		e, m, err := c.rewriteEnvelope(env, ref)
		if err != nil {
			return fmt.Errorf("message %s: %w", id, err)
		}
		ids, bodies, msgs, envs = append(ids, id), append(bodies, c.cpRewrite(body)), append(msgs, string(m)), append(envs, e)
		return nil
	})
	if err != nil {
		return err
	}
	_, err = c.exec(`UPDATE messages m SET env = x.e, msg = x.m::jsonb, body = x.b
		FROM unnest($2::uuid[], $3::bytea[], $4::text[], $5::text[]) AS x (i, e, m, b)
		WHERE m.tenant_id = $1 AND m.msg_id = x.i`, c.req.Dst, ids, envs, msgs, bodies)
	return err
}

// copyMessageChildren: a child row names its message or topic through the map.
func (c *pgCopy) copyMessageChildren() error {
	for _, t := range []struct{ table, col string }{
		{"message_revisions", "msg_id"}, {"message_reactions", "msg_id"}, {"message_kind_changes", "msg_id"},
		{"message_moderation", "msg_id"}, {"topic_priorities", "task_id"},
	} {
		if err := c.cpInsert(t.table, map[string]string{t.col: "a.new"}, `JOIN cp_ids a ON a.old = x.`+t.col, `true`); err != nil {
			return err
		}
	}
	if err := c.cpInsert("message_answers", map[string]string{"answers": "a.new", "answer_msg_id": "b.new"},
		`JOIN cp_ids a ON a.old = x.answers JOIN cp_ids b ON b.old = x.answer_msg_id`, `true`); err != nil {
		return err
	}
	return c.rewriteText("message_revisions", "body", "text", `msg_id IN (SELECT new FROM cp_ids)`)
}

// rewriteText puts the new ids into one column of the <DST> rows where finds.
func (c *pgCopy) rewriteText(table, col, typ, where string) error {
	type row struct{ key, val string }
	var rows []row
	id, qc := pgx.Identifier{table}.Sanitize(), pgx.Identifier{col}.Sanitize()
	err := eachRow(c.ctx, c.tx, `SELECT ctid::text, `+qc+`::text FROM `+id+` WHERE tenant_id = $1 AND `+where, []any{c.req.Dst}, func(r pgx.Rows) error {
		var x row
		if err := r.Scan(&x.key, &x.val); err != nil {
			return err
		}
		if n := c.cpRewrite(x.val); n != x.val {
			x.val = n
			rows = append(rows, x)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, x := range rows {
		if _, err := c.exec(`UPDATE `+id+` SET `+qc+` = $2::`+typ+` WHERE tenant_id = $1 AND ctid = $3::tid`, c.req.Dst, x.val, x.key); err != nil {
			return fmt.Errorf("%s.%s: %w", table, col, err)
		}
	}
	return nil
}

// copyCalendar: a copied event reaches nobody (c-001 fc977008). It has no
// Google map row, and its source_key is in the family the Out half never pushes
// without one (gcal_sync.go push); the key also keeps a synced event's own key
// free in <DST>. remind_at and the stored reminders are gone, so nothing fires.
// No send reads calendar_guests: an invite goes out from the handler that adds
// the guest, so the people who are <DST> members come along, and no agent guest:
// a copy carries no seat. An exception whose series is outside the set has nothing
// to be an exception of.
func (c *pgCopy) copyCalendar() error {
	if len(c.b.Events) == 0 {
		return nil
	}
	over := map[string]string{"event_id": "a.new", "recurring_event_id": cpNew("recurring_event_id"), "remind_at": "NULL", "props": `x.props - 'reminders'`,
		"topic_id":   `coalesce((SELECT new::text FROM cp_ids WHERE old::text = x.topic_id), x.topic_id)`,
		"source_key": `'gcal:copied:' || a.new::text`}
	if err := c.cpInsert("calendar_events", over, `JOIN cp_ids a ON a.old = x.event_id`,
		`x.event_id = ANY($3::uuid[]) AND (x.recurring_event_id IS NULL OR x.recurring_event_id = ANY($3::uuid[]))`, c.b.Events); err != nil {
		return err
	}
	if err := c.cpInsert("calendar_guests", map[string]string{"event_id": "a.new"}, `JOIN cp_ids a ON a.old = x.event_id
		JOIN calendar_events e ON e.tenant_id = $1 AND e.event_id = a.new`, `x.guest_type = 'human' AND x.guest_id = ANY($3::text[])`, mpNonNil(c.kept)); err != nil {
		return err
	}
	return c.rewriteText("calendar_events", "description", "text", `event_id IN (SELECT new FROM cp_ids)`)
}

// copyJobs: job_id is a per-workspace key, and a new one keeps the copy apart
// from <SRC>'s job. No plan slot or hour comes along.
func (c *pgCopy) copyJobs() error {
	if len(c.b.Jobs) == 0 {
		return nil
	}
	return c.cpInsert("hours_jobs", map[string]string{"job_id": `'copy-' || gen_random_uuid()::text`,
		"task_id": `(SELECT new::text FROM cp_ids WHERE old::text = x.task_id)`}, "", `x.job_id = ANY($3::text[])`, c.b.Jobs)
}

// copyIssues: new numbers from <DST>'s counter, as a move (F6). <SRC> keeps its
// lanes and asks, so nothing is rewritten there.
func (c *pgCopy) copyIssues() error {
	if len(c.b.Numbers) == 0 {
		return nil
	}
	if err := c.mvRenumber(); err != nil {
		return err
	}
	if err := c.copyIssueLabels(); err != nil {
		return err
	}
	over := map[string]string{"number": "mp.new", "parent_number": "pp.new", "task_id": cpNew("task_id")}
	join := `JOIN unnest($3::int[], $4::int[]) AS mp (old, new) ON mp.old = x.number
		LEFT JOIN unnest($3::int[], $4::int[]) AS pp (old, new) ON pp.old = x.parent_number`
	if err := c.cpInsert("issues", over, join, `true`, c.oldNums, c.newNums); err != nil {
		return err
	}
	if err := c.copyIssueEvents(); err != nil {
		return err
	}
	if err := c.cpInsert("issue_discussions", map[string]string{"number": "mp.new", "task_id": "a.new"},
		`JOIN unnest($3::int[], $4::int[]) AS mp (old, new) ON mp.old = x.number JOIN cp_ids a ON a.old = x.task_id`, `true`, c.oldNums, c.newNums); err != nil {
		return err
	}
	olds, news := c.oldNewKeys()
	for i, o := range olds {
		c.res.NewKeys[o] = news[i]
	}
	if _, err := c.exec(`UPDATE issue_events e SET new_value = 'copied from ' || k.old_key
		FROM unnest($2::int[], $3::text[]) AS k (num, old_key)
		WHERE e.tenant_id = $1 AND e.number = k.num
			AND e.id = (SELECT min(f.id) FROM issue_events f WHERE f.tenant_id = $1 AND f.number = k.num)`,
		c.req.Dst, c.newNums, olds); err != nil {
		return err
	}
	_, err := c.exec(`UPDATE calendar_events e SET issue_keys = (
			SELECT array_agg(coalesce(k.n, y.key) ORDER BY y.ord)
			FROM unnest(e.issue_keys) WITH ORDINALITY AS y (key, ord)
			LEFT JOIN unnest($2::text[], $3::text[]) AS k (o, n) ON k.o = y.key)
		WHERE e.tenant_id = $1 AND e.event_id IN (SELECT new FROM cp_ids) AND e.issue_keys && $2::text[]`, c.req.Dst, olds, news)
	if err != nil {
		return err
	}
	return c.rewriteText("issues", "description", "text", `number = ANY(`+cpIntArray(c.newNums)+`)`)
}

// cpIntArray is a literal int[]: numbers the counter just gave, never input.
func cpIntArray(ns []int) string {
	parts := make([]string, len(ns))
	for i, n := range ns {
		parts[i] = strconv.Itoa(n)
	}
	return `ARRAY[` + strings.Join(parts, ",") + `]::int[]`
}

// copyDocs: new ids for the doc and every row under it (F7), and the doc nodes
// placed as a move places them. The rev log has no UPDATE for the runtime login
// (rdb 0157), so its op is rewritten on the way in.
func (c *pgCopy) copyDocs() error {
	if len(c.b.Docs) == 0 {
		return nil
	}
	nodes, err := c.srcDocNodes()
	if err != nil {
		return err
	}
	if err := c.cpInsert("workspace_doc", map[string]string{"id": "a.new"}, `JOIN cp_ids a ON a.old = x.id`, `true`); err != nil {
		return err
	}
	if err := c.cpInsert("workspace_doc_item", map[string]string{"id": "a.new", "doc_id": "d.new", "parent_id": cpNew("parent_id")},
		`JOIN cp_ids a ON a.old = x.id JOIN cp_ids d ON d.old = x.doc_id`, `true`); err != nil {
		return err
	}
	if err := c.copyRevLog(); err != nil {
		return err
	}
	placed := make([]mvDocNode, len(nodes))
	for i, n := range nodes {
		n.id, n.doc = c.out.IDs[n.id], c.out.IDs[n.doc]
		placed[i] = n
	}
	if err := c.placeDocNodes(placed); err != nil {
		return err
	}
	if err := c.cpInsert("workspace_doc_acl", map[string]string{"id": "gen_random_uuid()", "node_id": "a.new"}, `JOIN cp_ids a ON a.old = x.node_id`, `true`); err != nil {
		return err
	}
	for _, col := range []struct{ col, typ string }{{"body", "text"}, {"attrs", "jsonb"}} {
		if err := c.rewriteText("workspace_doc_item", col.col, col.typ, `doc_id IN (SELECT new FROM cp_ids)`); err != nil {
			return err
		}
	}
	return nil
}

func (c *pgCopy) copyRevLog() error {
	var docs, ops, actors, ats []string
	var revs []int64
	err := eachRow(c.ctx, c.tx, `SELECT doc_id::text, rev, op::text, actor, created_at::text FROM workspace_doc_rev_log
		WHERE tenant_id = $1 AND doc_id = ANY($2::uuid[])`, []any{c.req.Src, c.b.Docs}, func(r pgx.Rows) error {
		var doc, op, actor, at string
		var rev int64
		if err := r.Scan(&doc, &rev, &op, &actor, &at); err != nil {
			return err
		}
		docs, revs, ops, actors, ats = append(docs, c.out.IDs[doc]), append(revs, rev), append(ops, c.cpRewrite(op)), append(actors, actor), append(ats, at)
		return nil
	})
	if err != nil {
		return err
	}
	n, err := c.exec(`INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor, created_at)
		SELECT $1, d, v, o::jsonb, a, t::timestamptz FROM unnest($2::uuid[], $3::bigint[], $4::text[], $5::text[], $6::text[]) AS x (d, v, o, a, t)`,
		c.req.Dst, docs, revs, ops, actors, ats)
	c.res.Copied["workspace_doc_rev_log"] = n
	return err
}

// writeJournal keeps the copy's row in <DST> with the old -> new map (section
// 7). P1 wrote the row, or this does.
func (c *pgCopy) writeJournal() error {
	lists := mvJournalBinds(c.b)
	lists["id_map"] = c.out.IDs
	frozen, err := json.Marshal(lists)
	if err != nil {
		return err
	}
	if err := c.readP1(); err != nil {
		return err
	}
	_, err = c.exec(`INSERT INTO channel_move_journal (tenant_id, move_id, mode, src_tenant_id, src_channel_id, channel_id, frozen, go_msg_id, started_by)
		VALUES ($1, $2::uuid, 'copy', $3, $4, $4, $5::jsonb, $6::uuid, $7)
		ON CONFLICT (tenant_id, move_id) DO UPDATE SET frozen = EXCLUDED.frozen`,
		c.req.Dst, c.req.MoveID, c.req.Src, c.req.Channel, string(frozen), c.req.GoMsgID, c.req.StartedBy)
	return err
}

// finish: the P4 step, the one event, and <DST>'s views refetch. <SRC> changed
// nothing, so nothing of it is bumped.
func (c *pgCopy) cpFinish() error {
	counts, err := json.Marshal(map[string]any{"copied": c.res.Copied, "new_keys": c.res.NewKeys, "ids": len(c.out.IDs)})
	if err != nil {
		return err
	}
	if _, err := c.exec(`INSERT INTO channel_move_steps (tenant_id, move_id, channel_id, step, counts, done_at)
		VALUES ($1, $2::uuid, $3, 'P4', $4::jsonb, clock_timestamp())
		ON CONFLICT (tenant_id, move_id, step) DO UPDATE SET counts = EXCLUDED.counts, done_at = EXCLUDED.done_at`,
		c.req.Dst, c.req.MoveID, c.req.Channel, string(counts)); err != nil {
		return err
	}
	if _, err := c.exec(`INSERT INTO workspace_events (tenant_id, at, kind, level, actor, message, origin_kind, origin_ref)
		VALUES ($1, clock_timestamp(), 'channel.copied', 'info', $2, 'channel ' || $3::text || ' copied in, copy ' || $4::text, '', '')`,
		c.req.Dst, c.req.StartedBy, c.req.Channel, c.req.MoveID); err != nil {
		return err
	}
	_, err = c.tx.Exec(c.ctx, `SELECT tenant_change_bump_kind($1, true)`, c.req.Dst)
	return err
}
