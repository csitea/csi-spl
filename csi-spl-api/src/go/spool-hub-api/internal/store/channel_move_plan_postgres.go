// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"fmt"
	"sort"
	"strconv"

	"github.com/jackc/pgx/v5"
)

// PlanChannelMove computes the plan of spec 169 T4 (channel_move_plan.go)
// on Postgres: <DST>'s members, live pins and roster in one read, then
// everything else in one READ ONLY transaction scoped to <SRC>. It needs no
// operator scope: every row it reads is <SRC>'s or <DST>'s.
func (s *Postgres) PlanChannelMove(ctx context.Context, req ChannelMovePlanRequest) (ChannelMovePlan, error) {
	if err := mpCheckRequest(req); err != nil {
		return ChannelMovePlan{}, err
	}
	dst, err := s.planReadDst(ctx, req.Dst)
	if err != nil {
		return ChannelMovePlan{}, err
	}
	plan := ChannelMovePlan{Src: req.Src, Channel: req.Channel, Dst: req.Dst}
	err = s.planRead(ctx, req.Src, func(tx pgx.Tx) error {
		p := &pgPlan{ctx: ctx, tx: tx, req: req, plan: &plan, dst: dst, inDst: func(h string) bool { return dst.members[h] }}
		return p.mpRun()
	})
	if err != nil {
		return ChannelMovePlan{}, err
	}
	return plan, nil
}

// planDst is what plan reads of <DST>.
type planDst struct {
	members map[string]bool   // tenant_memberships.human_id
	pinned  map[string]bool   // pins.box_id, not revoked
	desks   map[MoveSeat]bool // roster
}

func (s *Postgres) planReadDst(ctx context.Context, tenant string) (planDst, error) {
	dst := planDst{members: map[string]bool{}, pinned: map[string]bool{}, desks: map[MoveSeat]bool{}}
	err := s.planRead(ctx, tenant, func(tx pgx.Tx) error {
		sets := []struct {
			sql string
			set map[string]bool
		}{
			{`SELECT human_id FROM tenant_memberships WHERE tenant_id = $1`, dst.members},
			{`SELECT box_id FROM pins WHERE tenant_id = $1 AND revoked_at IS NULL`, dst.pinned},
		}
		for _, q := range sets {
			if err := eachRow(ctx, tx, q.sql, []any{tenant}, func(r pgx.Rows) error {
				var v string
				err := r.Scan(&v)
				q.set[v] = true
				return err
			}); err != nil {
				return err
			}
		}
		return eachRow(ctx, tx, `SELECT agent_id, box_id FROM roster WHERE tenant_id = $1`, []any{tenant}, func(r pgx.Rows) error {
			var seat MoveSeat
			err := r.Scan(&seat.Agent, &seat.Box)
			dst.desks[seat] = true
			return err
		})
	})
	return dst, err
}

// planRead runs fn in a tenant transaction the server holds READ ONLY: a
// write in fn fails with "cannot execute ... in a read-only transaction"
// (C1). Going read-only after the scope's set_config is allowed; only the
// way back to read-write is refused once a query ran.
func (s *Postgres) planRead(ctx context.Context, tenant string, fn func(pgx.Tx) error) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SET TRANSACTION READ ONLY`); err != nil {
			return err
		}
		return fn(tx)
	})
}

// pgPlan is one plan run inside planRead.
type pgPlan struct {
	ctx    context.Context
	tx     pgx.Tx
	req    ChannelMovePlanRequest
	plan   *ChannelMovePlan
	dst    planDst
	inDst  func(string) bool
	prefix string
}

func (p *pgPlan) mpRun() error {
	p.plan.Binds.Channel = p.req.Channel
	steps := []func() error{p.mpChannel, p.mpWalk, p.mpTopicState, p.mpIssues, p.mpDocs}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
	}
	p.plan.Binds.mpFinish()
	steps = []func() error{p.mpCounts, p.mpFiles, p.mpMentions, p.mpHours, p.mpLeaving, p.mpSeats}
	if !p.req.noSharedCheck {
		steps = append(steps, p.mpSharedIssues, p.mpSharedSpecSync)
	}
	if !p.req.noPinCheck {
		steps = append(steps, p.mpMissingPins)
	}
	if !p.req.noDeskCheck {
		steps = append(steps, p.mpMissingDesks)
	}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
	}
	return nil
}

func (p *pgPlan) mpEach(sql string, args []any, each func(pgx.Rows) error) error {
	return eachRow(p.ctx, p.tx, sql, args, each)
}

func (p *pgPlan) mpStrings(sql string, args ...any) ([]string, error) {
	var out []string
	err := p.mpEach(sql, args, func(r pgx.Rows) error {
		var v string
		err := r.Scan(&v)
		out = append(out, v)
		return err
	})
	return out, err
}

func (p *pgPlan) mpPairs(sql string, args ...any) ([][2]string, error) {
	var out [][2]string
	err := p.mpEach(sql, args, func(r pgx.Rows) error {
		var a, b string
		err := r.Scan(&a, &b)
		out = append(out, [2]string{a, b})
		return err
	})
	return out, err
}

func (p *pgPlan) mpChannel() error {
	ids, err := p.mpStrings(`SELECT channel_id FROM channels WHERE tenant_id = $1 AND channel_id = $2`, p.req.Src, p.req.Channel)
	if err == nil && len(ids) == 0 {
		err = fmt.Errorf("channel %q in %q: %w", p.req.Channel, p.req.Src, ErrNotFound)
	}
	return err
}

// walk is M2: the channel's rows, then every row whose task_id or
// parent_task_id is a task found so far (walkTopic's rule: a row's msg_id
// is a task too), until a round finds nothing new.
func (p *pgPlan) mpWalk() error {
	rows, err := p.mpPairs(`SELECT msg_id::text, task_id::text FROM messages WHERE tenant_id = $1 AND channel = $2`, p.req.Src, p.req.Channel)
	seenMsg, seenTask := map[string]bool{}, map[string]bool{}
	b := &p.plan.Binds
	for round := 0; err == nil && len(rows) > 0; round++ {
		if round > maxTopicWalk {
			return fmt.Errorf("channel %q: topics nest deeper than %d: %w", p.req.Channel, maxTopicWalk, ErrConflict)
		}
		var next []string
		for _, r := range rows {
			if seenMsg[r[0]] {
				continue
			}
			seenMsg[r[0]] = true
			b.Msgs = append(b.Msgs, r[0])
			for _, t := range r {
				if !seenTask[t] {
					seenTask[t] = true
					b.Tasks = append(b.Tasks, t)
					next = append(next, t)
				}
			}
		}
		if len(next) == 0 {
			break
		}
		rows, err = p.mpPairs(`SELECT msg_id::text, task_id::text FROM messages
			WHERE tenant_id = $1 AND (task_id = ANY($2::uuid[]) OR parent_task_id = ANY($2::uuid[]))`, p.req.Src, next)
	}
	return err
}

// topicState is M6: the calendar events and hours jobs of the set's topics.
func (p *pgPlan) mpTopicState() error {
	b := &p.plan.Binds
	var err error
	b.Events, err = p.mpStrings(`SELECT event_id::text FROM calendar_events WHERE tenant_id = $1 AND topic_id = ANY($2::text[])`, p.req.Src, mpNonNil(b.Tasks))
	if err != nil {
		return err
	}
	b.Jobs, err = p.mpStrings(`SELECT job_id FROM hours_jobs WHERE tenant_id = $1 AND task_id = ANY($2::text[])`, p.req.Src, mpNonNil(b.Tasks))
	return err
}

// issues is M7: issues whose own topic is in the set, or that a discussion
// link ties to a topic of the set.
func (p *pgPlan) mpIssues() error {
	prefixes, err := p.mpStrings(`SELECT prefix FROM issue_counters WHERE tenant_id = $1`, p.req.Src)
	if err != nil {
		return err
	}
	p.prefix = IssuePrefixDefault
	if len(prefixes) == 1 {
		p.prefix = prefixes[0]
	}
	b := &p.plan.Binds
	return p.mpEach(`SELECT i.number FROM issues i WHERE i.tenant_id = $1 AND (i.task_id = ANY($2::uuid[])
			OR i.number IN (SELECT d.number FROM issue_discussions d WHERE d.tenant_id = $1 AND d.task_id = ANY($2::uuid[])))
		ORDER BY i.number`, []any{p.req.Src, mpNonNil(b.Tasks)}, func(r pgx.Rows) error {
		var n int
		err := r.Scan(&n)
		b.Numbers = append(b.Numbers, n)
		b.IssueKeys = append(b.IssueKeys, planIssueKey(p.prefix, n))
		return err
	})
}

// planStayingSQL is "a staying post" of <SRC> as messages m: not in the set
// ($2 channel, $3 tasks, $4 msgs). channel and parent_task_id may be NULL.
const planStayingSQL = `m.tenant_id = $1 AND m.channel IS DISTINCT FROM $2 AND NOT m.task_id = ANY($3::uuid[])
	AND NOT coalesce(m.parent_task_id = ANY($3::uuid[]), false) AND NOT m.msg_id = ANY($4::uuid[])`

func (p *pgPlan) mpStayingArgs() []any {
	b := p.plan.Binds
	return []any{p.req.Src, p.req.Channel, mpNonNil(b.Tasks), mpNonNil(b.Msgs)}
}

// docs is M8: the box rule's doc and every doc whose id a post of the set
// carries. A doc a staying post also carries is shared (5.5): listed, left
// out of the set.
func (p *pgPlan) mpDocs() error {
	b := &p.plan.Binds
	args := append(p.mpStayingArgs(), p.req.RuleDoc)
	err := p.mpEach(`SELECT d.id::text, EXISTS (SELECT 1 FROM messages m WHERE `+planStayingSQL+` AND strpos(m.body, d.id::text) > 0)
		FROM workspace_doc d WHERE d.tenant_id = $1 AND (d.id::text = $5
			OR EXISTS (SELECT 1 FROM messages s WHERE s.tenant_id = $1 AND s.msg_id = ANY($4::uuid[]) AND strpos(s.body, d.id::text) > 0))
		ORDER BY d.id`, args, func(r pgx.Rows) error {
		var id string
		var shared bool
		if err := r.Scan(&id, &shared); err != nil {
			return err
		}
		if shared && !p.req.noSharedCheck {
			p.plan.Shared = append(p.plan.Shared, SharedItem{Kind: "doc", ID: id, Why: "a post outside the channel links it too"})
			return nil
		}
		b.Docs = append(b.Docs, id)
		return nil
	})
	if err != nil {
		return err
	}
	b.Nodes, err = p.mpStrings(`SELECT id::text FROM workspace_doc_node WHERE tenant_id = $1 AND doc_id = ANY($2::uuid[])`, p.req.Src, mpNonNil(b.Docs))
	return err
}

// bound replaces each @bind of pred with a positional parameter cast to its
// channelmove.Binds type, appending its value to args.
func (p *pgPlan) mpBound(pred string, args *[]any, at map[string]int) string {
	return moveBindRe.ReplaceAllStringFunc(pred, func(m string) string {
		name := m[1:]
		if _, ok := at[name]; !ok {
			v, _ := p.plan.Binds.mpValue(name)
			*args = append(*args, v)
			at[name] = len(*args)
		}
		return "$" + strconv.Itoa(at[name]) + "::" + p.req.BindTypes[name]
	})
}

// counts runs every catalogue predicate in <SRC>: the Set rows of a moved or
// refuse table, the Refs rows outside the set. A refuse table with a row is
// a shared item (5.1b).
func (p *pgPlan) mpCounts() error {
	for _, t := range p.req.Tables {
		if t.Set == "" && t.Refs == "" {
			continue
		}
		c := MoveCount{Table: t.Table, Class: t.Class}
		from := ` FROM ` + pgx.Identifier{t.Table}.Sanitize() + ` WHERE tenant_id = $1`
		args, at := []any{p.req.Src}, map[string]int{}
		set := ""
		if t.Set != "" {
			set = p.mpBound(t.Set, &args, at)
		}
		q := `SELECT count(*) FILTER (WHERE ` + mpOrFalse(set) + `), `
		if t.Refs != "" {
			q += `count(*) FILTER (WHERE (` + p.mpBound(t.Refs, &args, at) + `) AND NOT ` + mpOrFalse(set) + `)`
		} else {
			q += `0`
		}
		if err := p.tx.QueryRow(p.ctx, q+from, args...).Scan(&c.Set, &c.Refs); err != nil {
			return fmt.Errorf("plan count %s: %w", t.Table, err)
		}
		p.plan.Counts = append(p.plan.Counts, c)
		if t.Class == MoveClassRefuse && c.Set > 0 && !p.req.noSharedCheck {
			p.plan.Shared = append(p.plan.Shared, SharedItem{Kind: "table", ID: t.Table,
				Why: fmt.Sprintf("%d row(s) the move cannot carry", c.Set)})
		}
	}
	return nil
}

func mpOrFalse(pred string) string {
	if pred == "" {
		return "false"
	}
	return "coalesce((" + pred + "), false)"
}

// sharedIssues is C7: an issue of the set linked to a topic that lives
// outside the set (its own topic or a discussion link), and an epic link
// that crosses the set's edge.
func (p *pgPlan) mpSharedIssues() error {
	b := p.plan.Binds
	args := []any{p.req.Src, mpNonNilInts(b.Numbers), mpNonNil(b.Tasks)}
	err := p.mpEach(`SELECT l.number, l.task_id::text, coalesce(m.channel, '') FROM (
			SELECT number, task_id FROM issues WHERE tenant_id = $1 AND number = ANY($2::int[])
			UNION SELECT number, task_id FROM issue_discussions WHERE tenant_id = $1 AND number = ANY($2::int[])) l
		CROSS JOIN LATERAL (SELECT x.channel FROM messages x WHERE x.tenant_id = $1 AND (x.task_id = l.task_id OR x.msg_id = l.task_id) LIMIT 1) m
		WHERE NOT l.task_id = ANY($3::uuid[]) ORDER BY 1, 2`, args, func(r pgx.Rows) error {
		var n int
		var task, ch string
		err := r.Scan(&n, &task, &ch)
		p.plan.Shared = append(p.plan.Shared, SharedItem{Kind: "issue", ID: planIssueKey(p.prefix, n),
			Why: fmt.Sprintf("also linked to topic %s in %s", task, mpChannelLabel(ch))})
		return err
	})
	if err != nil {
		return err
	}
	return p.mpEach(`SELECT number, parent_number FROM issues WHERE tenant_id = $1 AND parent_number IS NOT NULL
			AND (number = ANY($2::int[])) <> (parent_number = ANY($2::int[])) ORDER BY 1`, args[:2], func(r pgx.Rows) error {
		var n, parent int
		err := r.Scan(&n, &parent)
		p.plan.Shared = append(p.plan.Shared, SharedItem{Kind: "epic", ID: planIssueKey(p.prefix, parent),
			Why: fmt.Sprintf("its child %s is on the other side of the move", planIssueKey(p.prefix, n))})
		return err
	})
}

func mpChannelLabel(ch string) string {
	if ch == "" {
		return "a DM"
	}
	return "#" + ch
}

// sharedSpecSync: a spec_sync_map row of the set that a staying issue or
// doc also needs; the move would NULL its link (rdb 0208 ON DELETE SET NULL).
func (p *pgPlan) mpSharedSpecSync() error {
	b := p.plan.Binds
	return p.mpEach(`SELECT spec_path, spec_task_id FROM spec_sync_map WHERE tenant_id = $1
			AND (issue_number = ANY($2::int[]) OR qto_doc_id = ANY($3::uuid[]))
			AND ((issue_number IS NOT NULL AND NOT issue_number = ANY($2::int[])) OR (qto_doc_id IS NOT NULL AND NOT qto_doc_id = ANY($3::uuid[])))
		ORDER BY 1, 2`, []any{p.req.Src, mpNonNilInts(b.Numbers), mpNonNil(b.Docs)}, func(r pgx.Rows) error {
		var path, task string
		err := r.Scan(&path, &task)
		p.plan.Shared = append(p.plan.Shared, SharedItem{Kind: "spec_sync", ID: path + "#" + task,
			Why: "a staying issue or doc keeps this spec link"})
		return err
	})
}

// planFilesSQL lists the blob file ids of messages m (F8, M4).
const planFilesSQL = `SELECT DISTINCT f->>'file_id' FROM messages m
	CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(m.files) = 'array' THEN m.files ELSE '[]'::jsonb END) f
	WHERE f->>'mode' = 'blob' AND coalesce(f->>'file_id', '') <> '' AND `

// files lists the set's blob attachments a staying post also lists (T6
// keeps the <SRC> copy of those, C6).
func (p *pgPlan) mpFiles() error {
	set, err := p.mpStrings(planFilesSQL+`m.tenant_id = $1 AND m.msg_id = ANY($2::uuid[])`, p.req.Src, mpNonNil(p.plan.Binds.Msgs))
	if err != nil || len(set) == 0 {
		return err
	}
	p.plan.SharedFiles, err = p.mpStrings(planFilesSQL+planStayingSQL+` AND f->>'file_id' = ANY($5::text[]) ORDER BY 1`, append(p.mpStayingArgs(), set)...)
	return err
}

// mentions is 5.4: staying posts and staying Qto items that name the
// channel or an id of the set. A cheap SQL prefilter, then mentionMatcher.
func (p *pgPlan) mpMentions() error {
	mm := mpNewMentionMatcher(p.plan.Binds)
	err := p.mpEach(`SELECT m.msg_id::text, m.task_id::text, coalesce(m.channel, ''), m.from_id, m.body FROM messages m WHERE `+planStayingSQL+`
			AND (strpos(m.body, '#' || $2) > 0 OR m.body ~ $5) ORDER BY m.received_at, m.msg_id`,
		append(p.mpStayingArgs(), planUUIDSQL), func(r pgx.Rows) error {
			var c Mention
			var body string
			if err := r.Scan(&c.MsgID, &c.TaskID, &c.Channel, &c.Author, &body); err != nil {
				return err
			}
			for _, line := range mm.mpLines(body) {
				c.Line = line
				p.plan.Mentions = append(p.plan.Mentions, c)
			}
			return nil
		})
	if err != nil {
		return err
	}
	return p.mpEach(`SELECT doc_id::text, id::text, body FROM workspace_doc_item WHERE tenant_id = $1 AND NOT doc_id = ANY($2::uuid[])
			AND (strpos(body, '#' || $3) > 0 OR body ~ $4) ORDER BY doc_id, id`,
		[]any{p.req.Src, mpNonNil(p.plan.Binds.Docs), p.req.Channel, planUUIDSQL}, func(r pgx.Rows) error {
			var c Mention
			var body string
			if err := r.Scan(&c.DocID, &c.ItemID, &body); err != nil {
				return err
			}
			for _, line := range mm.mpLines(body) {
				c.Line = line
				p.plan.Mentions = append(p.plan.Mentions, c)
			}
			return nil
		})
}

// planHoursSQL counts, per member, the hours rows that name the set (M6c:
// minutes, entries, adjustments; spans follow their entry) and how many of
// them fall inside a frozen or approved <SRC> period (5.1a, Q8).
const planHoursSQL = `WITH r AS (
		SELECT member_id, (minute AT TIME ZONE tz)::date AS day FROM hours_minutes WHERE tenant_id = $1 AND target = ANY($2::text[])
		UNION ALL SELECT member_id, day FROM hours_entries WHERE tenant_id = $1 AND target = ANY($2::text[])
		UNION ALL SELECT member_id, period_start FROM hours_adjustments WHERE tenant_id = $1 AND target = ANY($2::text[]))
	SELECT r.member_id, count(*), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM hours_periods hp WHERE hp.tenant_id = $1
			AND hp.member_id = r.member_id AND r.day BETWEEN hp.period_start AND hp.period_end AND hp.state IN ('frozen', 'approved')))
	FROM r GROUP BY r.member_id`

func (p *pgPlan) mpHours() error {
	total, signed := map[string]int{}, map[string]int{}
	err := p.mpEach(planHoursSQL, []any{p.req.Src, mpNonNil(p.plan.Binds.Targets)}, func(r pgx.Rows) error {
		var m string
		var n, in int
		err := r.Scan(&m, &n, &in)
		total[m], signed[m] = n, in
		return err
	})
	p.plan.Hours = mpHoursStops(total, signed, p.inDst, p.req.Keep)
	return err
}

// leaving is W1 / Q5: the channel's humans who will not come along.
func (p *pgPlan) mpLeaving() error {
	humans, err := p.mpStrings(`SELECT human_id FROM channel_humans WHERE tenant_id = $1 AND channel_id = $2`, p.req.Src, p.req.Channel)
	sort.Strings(humans)
	p.plan.Leaving = mpLeavingOf(humans, p.inDst, p.req.Keep)
	return err
}

// missingPins is R1: the boxes that signed the set's rows, checked against
// <DST>'s live pins.
func (p *pgPlan) mpMissingPins() error {
	boxes, err := p.mpStrings(`SELECT DISTINCT from_box FROM messages WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])`,
		p.req.Src, mpNonNil(p.plan.Binds.Msgs))
	p.plan.MissingPins = mpMissingPins(boxes, func(box string) bool { return p.dst.pinned[box] })
	return err
}

// mpSeats is M5's agents, by invite (ChannelMembers' rule: a removed row is
// out, an old announce row on a default channel grants nothing) or as the
// channel's dedicated agents. M5 only: W2's other source, the F14 box rule
// rows, lives on the box, out of the hub's reach.
func (p *pgPlan) mpSeats() error {
	rows, err := p.mpPairs(`SELECT agent_id, box_id FROM channel_subscriptions WHERE tenant_id = $1 AND channel_id = $2
			AND origin <> 'removed' AND NOT (origin = 'announce' AND channel_id = ANY($3::text[]))
		UNION SELECT agent_id, box_id FROM dedicated_agents WHERE tenant_id = $1 AND scope_type = $4 AND scope_id = $2`,
		p.req.Src, p.req.Channel, DefaultChannels, ScopeChannel)
	seats := make([]MoveSeat, 0, len(rows))
	for _, r := range rows {
		seats = append(seats, MoveSeat{Agent: r[0], Box: r[1]})
	}
	p.plan.Seats = mpSeats(seats)
	return err
}

// mpMissingDesks is W2: the seats checked against <DST>'s roster.
func (p *pgPlan) mpMissingDesks() error {
	p.plan.MissingDesks = mpMissingDesks(p.plan.Seats, func(seat MoveSeat) bool { return p.dst.desks[seat] })
	return nil
}
