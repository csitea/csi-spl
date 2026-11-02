// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// ApplyChannelMove is P4 of spec 169 (row T5, section 8.2): one transaction,
// asOperator, that writes the channel's set under <DST> and removes it from
// <SRC>, driven by the catalogue the request carries (channelmove.Catalogue;
// this package cannot import channelmove, see ChannelMovePlanner).
//
// The order is F5's: a composite tenant FK refuses UPDATE ... SET tenant_id on
// a parent (C4), so rows are inserted under <DST> in catalogue order, the
// staying <SRC> rows that point into the set are rewritten, and the set is
// deleted in reverse order. Tables whose primary key is hub-wide (F7 and
// rdb 0139, 0157, 0165) cannot hold the same id twice, so they leave <SRC>
// first, in the same transaction: see mvHubWide and the calendar and Qto
// parts. Nothing is visible to anyone until the commit, and any error rolls
// back both workspaces (C5).
//
// The plan runs again inside the transaction, so the rows moved are the rows
// of the moment of the move and not of P1; the journal is rewritten with them
// (8.3), since the P7 proofs read the ids to look for from it.
//
// Not in this transaction: the pre-P4 Google delete (5.1a, below) and the
// objects (P3, P6, channelmove.Objects).
type ChannelMoveApplier interface {
	ApplyChannelMove(ctx context.Context, req ChannelMoveApplyRequest) (ChannelMoveResult, error)
}

var _ ChannelMoveApplier = (*Postgres)(nil)

// ChannelMoveApplyRequest is the plan's request plus what P4 needs.
type ChannelMoveApplyRequest struct {
	ChannelMovePlanRequest
	MoveID    string // the journal's move_id (a uuid)
	GoMsgID   string // the owner's GO answer for this channel and target (8.1)
	StartedBy string
	// KeepEmails are the channel invites' emails the owner keeps (5.1b, Q5):
	// each gets its <DST> tenant invite first; the others are deleted.
	KeepEmails []string
	// LeaveHours are the members whose hours rows the owner said to leave in
	// <SRC> (5.1a, Q5 or Q8): a kept item (5.6). It clears their hours stops.
	LeaveHours []string
	// GcalDelete deletes one Google event of a member's connection, the way
	// the Out half deletes one (5.1a). The store cannot reach Google, so the
	// hub passes it. Needed only when a moved event has a map row; a Google
	// event already gone is no error. An error stops the move before P4.
	GcalDelete func(ctx context.Context, c GcalConnection, googleID string) error
	// Seats are the channel seats P2 and P2b cleared, "<agent>@<box>" (W2). A
	// seat the plan under the lock finds beyond them refuses the move.
	Seats []string

	// The controls of the cases, tests only.
	skipCopy  map[string]bool // a table whose insert is skipped
	failAfter string          // C5: fail once this table's insert has run
	updateSet string          // C4: this table's rows are moved by UPDATE ... SET tenant_id
	noGcal    bool            // C18: skip the pre-P4 Google delete
	keepQueue bool            // C27: skip the expiry of unverifiable deliveries
	// betweenPlans runs after the check before the transaction: what lands
	// between P2 and the lock. noLockStops lets the plan under the lock pass.
	betweenPlans func()
	noLockStops  bool
}

// ChannelMoveResult is what P4 did; the counts go into the journal's P4 step.
type ChannelMoveResult struct {
	MoveID  string
	Binds   ChannelMoveBinds
	Copied  map[string]int    // rows inserted under <DST>, by table
	Deleted map[string]int    // rows deleted in <SRC>, by table
	NewKeys map[string]string // old issue key -> new key (F6)
	Lost    []string          // channel humans who did not come along (Q5)
	// DeliveriesExpired are the queued or unacked deliveries of agent rows whose
	// sender pin is missing or differs in <DST> (C27); DeliveriesExpiredNoPin those whose
	// to_box has no live pin in <DST>. Nobody receives them: the report says so.
	DeliveriesExpired      int
	DeliveriesExpiredNoPin int
}

// DeliveriesLine is the operator's line on the deliveries P4 expired (C27), with
// the limit a reader cannot see in the counts. The move report prints it.
func (r ChannelMoveResult) DeliveriesLine() string {
	return fmt.Sprintf("deliveries: %d expired (sender pin missing or different in the target), %d expired (addressee box not pinned in the target); "+
		"nobody receives these. Not counted: a row signed before its box re-keyed is refused by the box and lost.",
		r.DeliveriesExpired, r.DeliveriesExpiredNoPin)
}

// ErrChannelMoveRefused: plan names a shared item or an hours stop (5.5, 5.1a).
// The error's text is the stop lines.
var ErrChannelMoveRefused = errors.New("channel move: refused")

// channelMoveTimeout is P4's own statement ceiling; the runtime login's is
// 30 s (SPL-984), which the COMMIT's deferred triggers count against. R3:
// TestApplyChannelMoveLargest times the largest channel.
const channelMoveTimeout = "300s"

// channelMoveGcalLease holds the members' connections through P4 (5.1a), so
// no sync cycle imports an event back in between. A lease is not released:
// it ends by itself, and the next cycle finds the Google event gone.
const channelMoveGcalLease = 10 * time.Minute

func mvCheckRequest(req ChannelMoveApplyRequest) error {
	if err := mpCheckRequest(req.ChannelMovePlanRequest); err != nil {
		return err
	}
	if !isUUID(req.MoveID) || !isUUID(req.GoMsgID) || strings.TrimSpace(req.StartedBy) == "" {
		return fmt.Errorf("%w: move id %q, go msg id %q and started by %q are all required",
			ErrMoveRequest, req.MoveID, req.GoMsgID, req.StartedBy)
	}
	return nil
}

// ApplyChannelMove implements ChannelMoveApplier.
func (s *Postgres) ApplyChannelMove(ctx context.Context, req ChannelMoveApplyRequest) (ChannelMoveResult, error) {
	if err := mvCheckRequest(req); err != nil {
		return ChannelMoveResult{}, err
	}
	plan, err := s.PlanChannelMove(ctx, req.ChannelMovePlanRequest)
	if err != nil {
		return ChannelMoveResult{}, err
	}
	if stops := mvStops(plan, req); len(stops) > 0 {
		return ChannelMoveResult{}, fmt.Errorf("%w: %s", ErrChannelMoveRefused, strings.Join(stops, "; "))
	}
	if !req.noGcal {
		if err := s.mvGcalDelete(ctx, req, plan.Binds.Events); err != nil {
			return ChannelMoveResult{}, err
		}
	}
	if req.betweenPlans != nil {
		req.betweenPlans()
	}
	res := ChannelMoveResult{MoveID: req.MoveID, Copied: map[string]int{}, Deleted: map[string]int{}, NewKeys: map[string]string{}}
	err = s.asOperator(ctx, func(tx pgx.Tx) error {
		m := &pgMove{ctx: ctx, tx: tx, req: req, res: &res, cols: map[string][]string{}}
		return m.mvRun()
	})
	if err != nil {
		return ChannelMoveResult{}, err
	}
	return res, nil
}

// mvStops are plan's stops the request does not clear: a member the owner
// said to leave no longer stops the move.
func mvStops(p ChannelMovePlan, req ChannelMoveApplyRequest) []string {
	left := map[string]bool{}
	for _, m := range req.LeaveHours {
		left[m] = true
	}
	var kept []HoursStop
	for _, h := range p.Hours {
		if !left[h.Member] {
			kept = append(kept, h)
		}
	}
	p.Hours = kept
	return p.Stops()
}

// mvGcalRow is one Google event of a moved calendar event.
type mvGcalRow struct{ human, event, google string }

func (s *Postgres) mvGcalRows(ctx context.Context, src string, events []string) ([]mvGcalRow, error) {
	var rows []mvGcalRow
	err := s.queryTenant(ctx, src, `SELECT c.human_id, m.event_id::text, m.google_id
		FROM gcal_event_map m JOIN gcal_connections c ON c.connection_id = m.connection_id
		WHERE m.tenant_id = $1 AND m.event_id = ANY($2::uuid[]) ORDER BY 1, 2`,
		[]any{src, mpNonNil(events)}, func(r pgx.Rows) error {
			var x mvGcalRow
			err := r.Scan(&x.human, &x.event, &x.google)
			rows = append(rows, x)
			return err
		})
	return rows, err
}

// mvGcalDelete is the pre-P4 half of 5.1a: letting the cascade drop a map row
// leaves the Google event in the member's calendar, and the next In half
// imports it back into <SRC>. So each member's connection is claimed and the
// Google event deleted first; the map row goes at once, so a P4 that then
// fails leaves a hub event the Out half simply writes to Google again.
func (s *Postgres) mvGcalDelete(ctx context.Context, req ChannelMoveApplyRequest, events []string) error {
	rows, err := s.mvGcalRows(ctx, req.Src, events)
	if err != nil || len(rows) == 0 {
		return err
	}
	if req.GcalDelete == nil {
		return fmt.Errorf("%w: %d moved calendar event(s) are mapped in Google and no delete was given", ErrMoveRequest, len(rows))
	}
	type claim struct {
		c GcalConnection
		l GcalLease
	}
	claims := map[string]claim{}
	for _, x := range rows {
		cl, ok := claims[x.human]
		if !ok {
			c, l, err := s.ClaimGcalMember(ctx, req.Src, x.human, time.Now().UTC(), channelMoveGcalLease)
			if err != nil {
				return fmt.Errorf("claim the google calendar connection of %s: %w", x.human, err)
			}
			cl = claim{c, l}
			claims[x.human] = cl
		}
		if err := req.GcalDelete(ctx, cl.c, x.google); err != nil {
			return fmt.Errorf("delete the google event of %s: %w", x.event, err)
		}
		if err := s.DeleteGcalEventMap(ctx, cl.l, x.event); err != nil {
			return err
		}
	}
	return nil
}

// pgMove is one P4 run.
type pgMove struct {
	ctx  context.Context
	tx   pgx.Tx
	req  ChannelMoveApplyRequest
	res  *ChannelMoveResult
	plan pgPlan
	b    ChannelMoveBinds
	cols map[string][]string
	kept []string // HUM ids who come along (W1, Q5): <DST> members and req.Keep

	oldNums, newNums []int          // the issue renumbering, parallel (T5b)
	dstPrefix        string         // <DST>'s issue key prefix
	p1Sizes          map[string]int // the list sizes P1 froze, nil with no P1 row
	syncStash        string         // the stash of spec_sync_map's rows (T5b)
}

func (m *pgMove) exec(sql string, args ...any) (int, error) {
	tag, err := m.tx.Exec(m.ctx, sql, args...)
	return int(tag.RowsAffected()), err
}

// mvPart is a table's own copy or delete; a nil func = the default of that
// phase, mvNothing = the part's other table did the work.
type mvPart struct {
	copy, del func(*pgMove, MoveTable) error
}

// mvHubWide are tables whose primary key does not carry tenant_id and whose
// rows nothing references: one statement deletes and re-inserts each.
var mvHubWide = map[string]bool{"operator_audit": true, "sql_query_audit": true}

// mvParts: filled in init, because the parts call back into the frame. T5b
// and T5c add theirs from their own files.
var mvParts = map[string]mvPart{}

// mvPrepare runs before anything moves: a part that must read rows a later
// delete changes.
var mvPrepare []func(*pgMove) error

func mvNothing(*pgMove, MoveTable) error { return nil }

func init() {
	mvParts["calendar_events"] = mvPart{copy: mvCopyCalendar, del: mvNothing}
	mvParts["calendar_guests"] = mvPart{copy: mvNothing, del: mvNothing}
	mvParts["channel_invites"] = mvPart{copy: mvCopyInvites}
}

func (m *pgMove) mvRun() error {
	steps := []func() error{m.mvScope, m.replan, m.checkDst, m.writeJournal, m.prepare, m.copyAll, m.mvExpireDeliveries, m.rewriteStaying, m.deleteAll,
		m.writeRedirects, m.bumpStamps, m.checkResidue, m.finishJournal}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
	}
	return nil
}

// scope: the ceiling, the audit door (rdb 0251) and the lock that stops a
// second move of this channel. Both settings end with the transaction.
func (m *pgMove) mvScope() error {
	if _, err := m.tx.Exec(m.ctx, `SET LOCAL statement_timeout = '`+channelMoveTimeout+`'`); err != nil {
		return err
	}
	if _, err := m.tx.Exec(m.ctx, `SELECT set_config('app.channel_move', 'on', true)`); err != nil {
		return err
	}
	var id string
	err := m.tx.QueryRow(m.ctx, `SELECT channel_id FROM channels WHERE tenant_id = $1 AND channel_id = $2 FOR UPDATE`,
		m.req.Src, m.req.Channel).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("channel %q in %q: %w", m.req.Channel, m.req.Src, ErrNotFound)
	}
	return err
}

// replan computes the set again on this transaction, and who comes along.
func (m *pgMove) replan() error {
	dst, err := mpReadDst(m.ctx, m.tx, m.req.Dst)
	if err != nil {
		return err
	}
	for h := range dst.members {
		m.kept = append(m.kept, h)
	}
	m.kept = append(m.kept, m.req.Keep...)
	plan := ChannelMovePlan{Src: m.req.Src, Channel: m.req.Channel, Dst: m.req.Dst}
	m.plan = pgPlan{ctx: m.ctx, tx: m.tx, req: m.req.ChannelMovePlanRequest, plan: &plan, dst: dst, inDst: func(h string) bool { return dst.members[h] }}
	if err := m.plan.mpRun(); err != nil {
		return err
	}
	if err := m.lockStops(plan); err != nil {
		return err
	}
	m.b = plan.Binds
	m.res.Binds = plan.Binds
	m.res.Lost = plan.Leaving
	return nil
}

// lockStops: the owner's GO and the 5.5 answers cover what plan showed him. A
// post that landed since can bring a shared item, an hours row or a seat, a
// <DST> pin or desk can go, and any of those P2 did not clear refuses here, with
// nothing changed (8.2).
func (m *pgMove) lockStops(plan ChannelMovePlan) error {
	if m.req.noLockStops {
		return nil
	}
	stops := mvStops(plan, m.req)
	cleared := map[string]bool{}
	for _, s := range m.req.Seats {
		cleared[s] = true
	}
	err := eachRow(m.ctx, m.tx, `SELECT agent_id || '@' || box_id FROM dedicated_agents
		WHERE tenant_id = $1 AND scope_type = 'channel' AND scope_id = $2 ORDER BY 1`, []any{m.req.Src, m.req.Channel}, func(r pgx.Rows) error {
		var seat string
		err := r.Scan(&seat)
		if err == nil && !cleared[seat] {
			stops = append(stops, "seat "+seat+": not cleared by P2 (W2)")
		}
		return err
	})
	if err != nil {
		return err
	}
	if len(stops) > 0 {
		return fmt.Errorf("%w: %s", ErrChannelMoveRefused, strings.Join(stops, "; "))
	}
	return nil
}

// checkDst: P2's name check under the lock, and no map row left of a moved
// event (one written since the pre-P4 delete would be cascaded without its
// Google delete, and the In half would bring the event back: 5.1a).
func (m *pgMove) checkDst() error {
	var taken, maps int
	err := m.tx.QueryRow(m.ctx, `SELECT (SELECT count(*) FROM channels WHERE tenant_id = $1 AND channel_id = $2),
			(SELECT count(*) FROM gcal_event_map WHERE tenant_id = $3 AND event_id = ANY($4::uuid[]))`,
		m.req.Dst, m.req.Channel, m.req.Src, mpNonNil(m.b.Events)).Scan(&taken, &maps)
	if err != nil {
		return err
	}
	if taken > 0 {
		return fmt.Errorf("channel %q already exists in %q: %w", m.req.Channel, m.req.Dst, ErrConflict)
	}
	if maps > 0 && !m.req.noGcal {
		return fmt.Errorf("%d google map row(s) appeared since the pre-P4 delete, run again: %w", maps, ErrConflict)
	}
	return nil
}

// mvJournalBinds are the frozen id lists, keyed by the channelmove.Binds names.
func mvJournalBinds(b ChannelMoveBinds) map[string]any {
	return map[string]any{"channel": b.Channel, "tasks": mpNonNil(b.Tasks), "msgs": mpNonNil(b.Msgs), "mark_keys": mpNonNil(b.MarkKeys),
		"events": mpNonNil(b.Events), "jobs": mpNonNil(b.Jobs), "targets": mpNonNil(b.Targets), "numbers": mpNonNilInts(b.Numbers),
		"issue_keys": mpNonNil(b.IssueKeys), "docs": mpNonNil(b.Docs), "nodes": mpNonNil(b.Nodes), "ids": mpNonNil(b.IDs)}
}

// writeJournal keeps the current move's row in <DST> (8.3). P1 wrote it, or
// this does. frozen ends as the set P4 moved, which the P7 proofs read; what
// P1 froze goes on record in the P4 step (finishJournal). A row of another GO
// or channel refuses, and a move whose P4 step is done is refused: P5..P7
// resume from the journal, and nothing replaces frozen after P4.
func (m *pgMove) writeJournal() error {
	frozen, err := json.Marshal(mvJournalBinds(m.b))
	if err != nil {
		return err
	}
	var done int
	err = m.tx.QueryRow(m.ctx, `SELECT count(*) FROM channel_move_steps WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P4' AND done_at IS NOT NULL`,
		m.req.Dst, m.req.MoveID).Scan(&done)
	if err != nil {
		return err
	}
	if done > 0 {
		return fmt.Errorf("move %s: P4 is already done: %w", m.req.MoveID, ErrConflict)
	}
	if err := m.readP1(); err != nil {
		return err
	}
	_, err = m.exec(`INSERT INTO channel_move_journal (tenant_id, move_id, mode, src_tenant_id, src_channel_id, channel_id, frozen, go_msg_id, started_by)
		VALUES ($1, $2::uuid, 'move', $3, $4, $4, $5::jsonb, $6::uuid, $7)
		ON CONFLICT (tenant_id, move_id) DO UPDATE SET frozen = EXCLUDED.frozen`,
		m.req.Dst, m.req.MoveID, m.req.Src, m.req.Channel, string(frozen), m.req.GoMsgID, m.req.StartedBy)
	return err
}

// readP1 checks the row P1 wrote, if any, and keeps the size of each list it froze.
func (m *pgMove) readP1() error {
	var raw []byte
	var goMsg, src, channel string
	err := m.tx.QueryRow(m.ctx, `SELECT frozen, go_msg_id::text, src_tenant_id, src_channel_id FROM channel_move_journal
		WHERE tenant_id = $1 AND move_id = $2::uuid`, m.req.Dst, m.req.MoveID).Scan(&raw, &goMsg, &src, &channel)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if !strings.EqualFold(goMsg, m.req.GoMsgID) || src != m.req.Src || channel != m.req.Channel {
		return fmt.Errorf("move %s: its journal row has GO %s for %s/%s: %w", m.req.MoveID, goMsg, src, channel, ErrConflict)
	}
	m.p1Sizes, err = mvListSizes(raw)
	return err
}

// mvListSizes are the lengths of the id lists of a frozen set.
func mvListSizes(frozen []byte) (map[string]int, error) {
	var lists map[string]any
	if err := json.Unmarshal(frozen, &lists); err != nil {
		return nil, err
	}
	out := map[string]int{}
	for k, v := range lists {
		if l, ok := v.([]any); ok {
			out[k] = len(l)
		}
	}
	return out, nil
}

// columns are the table's writable columns other than tenant_id: a generated
// column is the database's, and an identity column is hub-wide (issue_events,
// workspace_events, usage_events, ...), so <DST> takes a new value.
func (m *pgMove) columns(table string) ([]string, error) {
	if c, ok := m.cols[table]; ok {
		return c, nil
	}
	var out []string
	err := eachRow(m.ctx, m.tx, `SELECT column_name FROM information_schema.columns
		WHERE table_schema = current_schema() AND table_name = $1 AND is_generated = 'NEVER' AND is_identity = 'NO'
			AND column_name <> 'tenant_id' ORDER BY ordinal_position`, []any{table}, func(r pgx.Rows) error {
		var c string
		err := r.Scan(&c)
		out = append(out, pgx.Identifier{c}.Sanitize())
		return err
	})
	if err == nil && len(out) == 0 {
		err = fmt.Errorf("no columns")
	}
	m.cols[table] = out
	return out, err
}

func (m *pgMove) prepare() error {
	for _, fn := range mvPrepare {
		if err := fn(m); err != nil {
			return err
		}
	}
	return nil
}

func (m *pgMove) copyAll() error {
	for _, t := range m.req.Tables {
		if t.Class != MoveClassMoved || m.req.skipCopy[t.Table] {
			continue
		}
		var err error
		if part := mvParts[t.Table]; part.copy != nil {
			err = part.copy(m, t)
		} else if mvHubWide[t.Table] {
			err = m.moveAtOnce(t)
		} else {
			err = m.copyDefault(t)
		}
		if err != nil {
			return fmt.Errorf("move %s: %w", t.Table, err)
		}
		if m.req.failAfter == t.Table {
			return fmt.Errorf("move %s: planted failure", t.Table)
		}
	}
	return nil
}

// copyFilter narrows a table's insert: the rows of people who do not come
// along are deleted, not carried (W1, Q5).
func (m *pgMove) copyFilter(table string, args *[]any) string {
	kept := func(col string) string {
		*args = append(*args, mpNonNil(m.kept))
		return col + ` = ANY($` + strconv.Itoa(len(*args)) + `::text[])`
	}
	switch table {
	case "channel_humans":
		return ` AND ` + kept("human_id")
	case "read_marks":
		return ` AND (member_id NOT LIKE 'HUM-%' OR ` + kept("member_id") + `)`
	}
	return m.leaveFilter(table, args)
}

// leaveFilter: hours rows the owner said to leave are neither carried nor
// deleted (5.1a); they stay in <SRC> as a kept item (5.6).
func (m *pgMove) leaveFilter(table string, args *[]any) string {
	switch table {
	case "hours_minutes", "hours_entries", "hours_entry_spans", "hours_adjustments":
		*args = append(*args, mpNonNil(m.req.LeaveHours))
		return ` AND NOT member_id = ANY($` + strconv.Itoa(len(*args)) + `::text[])`
	}
	return ""
}

// mvExpireDeliveries (C27): a moved agent row stays signed with its <SRC> key
// and the addressee's box checks it against the <DST> pin of from_box, so a
// delivery of a row it cannot verify is refused and lost with nobody told.
// Expire those and count them. Kept: to_box box-wui (the browser fan-out, no
// verify), a person's row from box-wui, and a row whose sender key is the one
// live in <DST> (its <SRC> pin revoked or not). A to_box with no live <DST> pin
// can never pull its row, whoever wrote it. Current pins only, not pins_history:
// a row signed before a re-key is still lost, uncounted (section 7).
func (m *pgMove) mvExpireDeliveries() error {
	if m.req.keepQueue {
		return nil
	}
	return m.tx.QueryRow(m.ctx, `WITH x AS (
			SELECT d.msg_id, d.to_box, tp.box_id IS NULL AS no_pin
			FROM deliveries d
			JOIN messages mm ON mm.tenant_id = d.tenant_id AND mm.msg_id = d.msg_id
			LEFT JOIN pins sp ON sp.tenant_id = $1 AND sp.box_id = mm.from_box
			LEFT JOIN pins dp ON dp.tenant_id = $2 AND dp.box_id = mm.from_box AND dp.revoked_at IS NULL
			LEFT JOIN pins tp ON tp.tenant_id = $2 AND tp.box_id = d.to_box AND tp.revoked_at IS NULL
			WHERE d.tenant_id = $2 AND d.msg_id = ANY($3::uuid[]) AND d.to_box <> 'box-wui'
			AND (d.state = 'queued' OR (d.state = 'sent' AND d.acked_at IS NULL))
			AND (tp.box_id IS NULL OR (mm.from_box <> 'box-wui' AND
				(dp.pubkey IS NULL OR sp.pubkey IS NULL OR dp.pubkey <> sp.pubkey)))
		), u AS (
			UPDATE deliveries d SET state = 'expired' FROM x
			WHERE d.tenant_id = $2 AND d.msg_id = x.msg_id AND d.to_box = x.to_box
			RETURNING x.no_pin
		) SELECT count(*) FILTER (WHERE NOT no_pin), count(*) FILTER (WHERE no_pin) FROM u`,
		m.req.Src, m.req.Dst, mpNonNil(m.b.Msgs)).Scan(&m.res.DeliveriesExpired, &m.res.DeliveriesExpiredNoPin)
}

func (m *pgMove) copyDefault(t MoveTable) error {
	if m.req.updateSet == t.Table {
		return m.plantedUpdate(t)
	}
	cols, err := m.columns(t.Table)
	if err != nil {
		return err
	}
	args, at := []any{m.req.Src, m.req.Dst}, map[string]int{}
	pred := m.plan.mpBound(t.Set, &args, at)
	filter := m.copyFilter(t.Table, &args)
	list := strings.Join(cols, ", ")
	id := pgx.Identifier{t.Table}.Sanitize()
	n, err := m.exec(`INSERT INTO `+id+` (tenant_id, `+list+`) SELECT $2, `+list+` FROM `+id+` WHERE tenant_id = $1 AND (`+pred+`)`+filter, args...)
	m.res.Copied[t.Table] = n
	if err == nil && t.Table == "messages" {
		err = m.restoreMessages()
	}
	return err
}

// plantedUpdate is the red control of C4: the parent row is moved the way F5
// says cannot work.
func (m *pgMove) plantedUpdate(t MoveTable) error {
	args, at := []any{m.req.Src, m.req.Dst}, map[string]int{}
	pred := m.plan.mpBound(t.Set, &args, at)
	_, err := m.exec(`UPDATE `+pgx.Identifier{t.Table}.Sanitize()+` SET tenant_id = $2 WHERE tenant_id = $1 AND (`+pred+`)`, args...)
	return err
}

// restoreMessages undoes messages_claim_defaults (rdb 0110), which fills in a
// claim on any inserted row whose responsible is NULL: the columns of a moved
// row travel as they are (W6).
func (m *pgMove) restoreMessages() error {
	_, err := m.exec(`UPDATE messages d SET responsible = s.responsible, needs_peer = s.needs_peer
		FROM messages s
		WHERE d.tenant_id = $1 AND s.tenant_id = $2 AND d.msg_id = s.msg_id AND d.msg_id = ANY($3::uuid[])
			AND (d.responsible, d.needs_peer) IS DISTINCT FROM (s.responsible, s.needs_peer)`,
		m.req.Dst, m.req.Src, mpNonNil(m.b.Msgs))
	return err
}

// moveAtOnce is the insert and the delete as one statement, for a hub-wide
// key: each row is gone from <SRC> before its <DST> row is checked.
func (m *pgMove) moveAtOnce(t MoveTable) error {
	cols, err := m.columns(t.Table)
	if err != nil {
		return err
	}
	args, at := []any{m.req.Src, m.req.Dst}, map[string]int{}
	pred := m.plan.mpBound(t.Set, &args, at)
	list := strings.Join(cols, ", ")
	id := pgx.Identifier{t.Table}.Sanitize()
	n, err := m.exec(`WITH gone AS (DELETE FROM `+id+` WHERE tenant_id = $1 AND (`+pred+`) RETURNING `+list+`)
		INSERT INTO `+id+` (tenant_id, `+list+`) SELECT $2, `+list+` FROM gone`, args...)
	m.res.Copied[t.Table], m.res.Deleted[t.Table] = n, n
	return err
}

// stash keeps a table's rows in a transaction-local table, for children of a
// hub-wide parent: the parent's delete cascades to them before their insert
// can run. It answers the stash's name and the columns it holds.
func (m *pgMove) stash(table, pred string, args ...any) (string, string, error) {
	cols, err := m.columns(table)
	if err != nil {
		return "", "", err
	}
	name := pgx.Identifier{"mv_" + table}.Sanitize()
	list := strings.Join(cols, ", ")
	if _, err := m.exec(`CREATE TEMP TABLE `+name+` ON COMMIT DROP AS
		SELECT `+list+` FROM `+pgx.Identifier{table}.Sanitize()+` WHERE tenant_id = $1 AND (`+pred+`)`, args...); err != nil {
		return "", "", err
	}
	return `pg_temp.` + name, list, nil
}

// mvCopyCalendar moves events and guests (M6): event_id is hub-wide (rdb 0139)
// and a guest row's key has no tenant either. The delete cascades to guests
// and to any exception of a recurring event, so an exception that is not in
// the set stops the move instead of vanishing.
func mvCopyCalendar(m *pgMove, t MoveTable) error {
	if len(m.b.Events) == 0 {
		return nil
	}
	var strays int
	err := m.tx.QueryRow(m.ctx, `SELECT count(*) FROM calendar_events WHERE recurring_event_id = ANY($1::uuid[]) AND NOT event_id = ANY($1::uuid[])`,
		m.b.Events).Scan(&strays)
	if err != nil {
		return err
	}
	if strays > 0 {
		return fmt.Errorf("%d exception(s) of a moved recurring event have no topic in the set: %w", strays, ErrConflict)
	}
	guests, list, err := m.stash("calendar_guests", `event_id = ANY($2::uuid[])`, m.req.Src, m.b.Events)
	if err != nil {
		return err
	}
	if err := m.moveAtOnce(t); err != nil {
		return err
	}
	n, err := m.exec(`INSERT INTO calendar_guests (tenant_id, `+list+`) SELECT $1, `+list+` FROM `+guests+`
		WHERE guest_type <> 'human' OR guest_id = ANY($2::text[])`, m.req.Dst, mpNonNil(m.kept))
	m.res.Copied["calendar_guests"] = n
	return err
}

// mvCopyInvites is 5.1b: a kept email's invite needs its <DST> workspace invite
// first, which is what invites the person (Q5). <SRC>'s workspace invite is
// the workspace's, not the channel's, and stays.
func mvCopyInvites(m *pgMove, _ MoveTable) error {
	emails := mpNonNil(m.req.KeepEmails)
	if !m.req.skipCopy["tenant_invites"] {
		if _, err := m.exec(`INSERT INTO tenant_invites (tenant_id, email, role, invited_by, created_at, expires_at, ordered_by, ordered_via)
			SELECT $2, email, role, invited_by, created_at, expires_at, ordered_by, ordered_via FROM tenant_invites
			WHERE tenant_id = $1 AND email = ANY($3::text[])
				AND email IN (SELECT email FROM channel_invites WHERE tenant_id = $1 AND channel_id = $4)
			ON CONFLICT DO NOTHING`, m.req.Src, m.req.Dst, emails, m.req.Channel); err != nil {
			return err
		}
	}
	n, err := m.exec(`INSERT INTO channel_invites (tenant_id, channel_id, email, added_by, created_at)
		SELECT $2, channel_id, email, added_by, created_at FROM channel_invites
		WHERE tenant_id = $1 AND channel_id = $3 AND email = ANY($4::text[])`,
		m.req.Src, m.req.Dst, m.req.Channel, emails)
	m.res.Copied["channel_invites"] = n
	return err
}

// rewriteStaying: the named updates of C13 on rows that stay in <SRC>. Every
// statement names only the columns the spec names.
func (m *pgMove) rewriteStaying() error {
	src, ch, tasks, msgs := m.req.Src, m.req.Channel, mpNonNil(m.b.Tasks), mpNonNil(m.b.Msgs)
	if _, err := m.exec(`UPDATE messages SET moved_from_channel = NULL, moved_from_task = NULL, moved_from_parent = NULL
		WHERE tenant_id = $1 AND NOT msg_id = ANY($4::uuid[])
			AND (moved_from_channel = $2 OR moved_from_task = ANY($3::uuid[]) OR moved_from_parent = ANY($3::uuid[]))`,
		src, ch, tasks, msgs); err != nil {
		return fmt.Errorf("M6b: %w", err)
	}
	if _, err := m.exec(`UPDATE messages SET ref_task_id = NULL
		WHERE tenant_id = $1 AND NOT msg_id = ANY($3::uuid[]) AND ref_task_id = ANY($2::uuid[])`, src, tasks, msgs); err != nil {
		return fmt.Errorf("M9: %w", err)
	}
	if _, err := m.exec(`UPDATE tenant_memberships d SET channel_order = array_append(d.channel_order, $3::text)
		FROM tenant_memberships s
		WHERE d.tenant_id = $1 AND s.tenant_id = $2 AND d.human_id = s.human_id AND $3::text = ANY(s.channel_order)
			AND cardinality(d.channel_order) > 0 AND NOT $3::text = ANY(d.channel_order)`, m.req.Dst, src, ch); err != nil {
		return fmt.Errorf("channel_order in the target: %w", err)
	}
	if _, err := m.exec(`UPDATE tenant_memberships SET channel_order = array_remove(channel_order, $2::text)
		WHERE tenant_id = $1 AND $2::text = ANY(channel_order)`, src, ch); err != nil {
		return fmt.Errorf("channel_order: %w", err)
	}
	return nil
}

// deleteAll removes the set in <SRC>, children first (the reverse of the
// catalogue's insert order, F5).
func (m *pgMove) deleteAll() error {
	for i := len(m.req.Tables) - 1; i >= 0; i-- {
		t := m.req.Tables[i]
		if t.Class != MoveClassMoved || mvHubWide[t.Table] {
			continue
		}
		var err error
		if part := mvParts[t.Table]; part.del != nil {
			err = part.del(m, t)
		} else {
			err = m.deleteDefault(t)
		}
		if err != nil {
			return fmt.Errorf("delete %s: %w", t.Table, err)
		}
	}
	return nil
}

func (m *pgMove) deleteDefault(t MoveTable) error {
	args, at := []any{m.req.Src}, map[string]int{}
	pred := m.plan.mpBound(t.Set, &args, at)
	filter := m.leaveFilter(t.Table, &args)
	n, err := m.exec(`DELETE FROM `+pgx.Identifier{t.Table}.Sanitize()+` WHERE tenant_id = $1 AND (`+pred+`)`+filter, args...)
	m.res.Deleted[t.Table] = n
	return err
}

// writeRedirects is Q2 = A: 30 days of task and msg ids from <SRC> to <DST>,
// ids only (C13). The expiry is the table's default.
func (m *pgMove) writeRedirects() error {
	// A move back home: the channel's ids resolve in <DST> again.
	if _, err := m.exec(`DELETE FROM channel_move_redirects WHERE src_tenant_id = $1 AND kind IN ('task', 'msg') AND old_ref = ANY($2::text[])`,
		m.req.Dst, append(mpNonNil(m.b.Tasks), m.b.Msgs...)); err != nil {
		return err
	}
	for _, kind := range []struct {
		name string
		ids  []string
	}{{"task", m.b.Tasks}, {"msg", m.b.Msgs}} {
		if err := m.redirect(kind.name, kind.ids, kind.ids); err != nil {
			return err
		}
	}
	var olds, news []string
	for o, n := range m.res.NewKeys {
		olds, news = append(olds, o), append(news, n)
	}
	return m.redirect("issue", olds, news)
}

func (m *pgMove) redirect(kind string, olds, news []string) error {
	_, err := m.exec(`INSERT INTO channel_move_redirects (src_tenant_id, kind, old_ref, dst_tenant_id, new_ref, move_id)
		SELECT $1, $2, o, $3, n, $4::uuid FROM unnest($5::text[], $6::text[]) AS x (o, n)
		ON CONFLICT (src_tenant_id, kind, old_ref) DO UPDATE SET dst_tenant_id = EXCLUDED.dst_tenant_id, new_ref = EXCLUDED.new_ref,
			move_id = EXCLUDED.move_id, created_at = now(), expires_at = now() + interval '30 days'`,
		m.req.Src, kind, m.req.Dst, m.req.MoveID, mpNonNil(olds), mpNonNil(news))
	if err != nil {
		return fmt.Errorf("redirects %s: %w", kind, err)
	}
	return nil
}

// bumpStamps: every cached view of both workspaces refetches (W7). The
// message counters and the topic heads need no step here: their own triggers
// followed each insert and delete (rdb 0023, 0144; C9 reads them). quota_counts
// holds per-person rate windows and names no channel, so it is left.
func (m *pgMove) bumpStamps() error {
	for _, tn := range []string{m.req.Src, m.req.Dst} {
		if _, err := m.tx.Exec(m.ctx, `SELECT tenant_change_bump_kind($1, true)`, tn); err != nil {
			return err
		}
	}
	return nil
}

// checkResidue: a post that landed in the channel while this ran. It would
// stay behind in <SRC>, so the move rolls back and runs again.
func (m *pgMove) checkResidue() error {
	var n int
	err := m.tx.QueryRow(m.ctx, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND (channel = $2 OR task_id = ANY($3::uuid[]))`,
		m.req.Src, m.req.Channel, mpNonNil(m.b.Tasks)).Scan(&n)
	if err != nil {
		return err
	}
	if n > 0 {
		return fmt.Errorf("%d post(s) landed in the channel during the move, run again: %w", n, ErrConflict)
	}
	return nil
}

// finishJournal: the P4 step, and the one <DST> audit row (5.2); <SRC> gets
// none (C13).
func (m *pgMove) finishJournal() error {
	frozen, err := json.Marshal(mvJournalBinds(m.b))
	if err != nil {
		return err
	}
	moved, err := mvListSizes(frozen)
	if err != nil {
		return err
	}
	counts, err := json.Marshal(map[string]any{"copied": m.res.Copied, "deleted": m.res.Deleted, "new_keys": m.res.NewKeys,
		"p1_lists": m.p1Sizes, "moved_lists": moved,
		"deliveries_expired": m.res.DeliveriesExpired, "deliveries_expired_no_pin": m.res.DeliveriesExpiredNoPin})
	if err != nil {
		return err
	}
	if _, err := m.exec(`INSERT INTO channel_move_steps (tenant_id, move_id, channel_id, step, counts, done_at)
		VALUES ($1, $2::uuid, $3, 'P4', $4::jsonb, clock_timestamp())
		ON CONFLICT (tenant_id, move_id, step) DO UPDATE SET counts = EXCLUDED.counts, done_at = EXCLUDED.done_at`,
		m.req.Dst, m.req.MoveID, m.req.Channel, string(counts)); err != nil {
		return err
	}
	_, err = m.exec(`INSERT INTO workspace_events (tenant_id, at, kind, level, actor, message, origin_kind, origin_ref)
		VALUES ($1, clock_timestamp(), 'channel.moved', 'info', $2, 'channel ' || $3::text || ' moved in, move ' || $4::text, '', '')`,
		m.req.Dst, m.req.StartedBy, m.req.Channel, m.req.MoveID)
	return err
}
