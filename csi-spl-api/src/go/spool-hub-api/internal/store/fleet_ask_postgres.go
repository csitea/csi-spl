package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0097. Every statement runs in the tenant scope. An
// update reads the row FOR UPDATE, checks it (askGate) and applies the op in
// Go (applyAskOp, both shared with Memory) and writes it back in the same
// transaction, so two holders closing one ask cannot both win.

const askCols = `ask_id, role, kind, from_agent, topic, summary, state, deadline_at, acked_by, closed_by, reason,
	raised_n, raised_at, escalated_at, writer_box, created_at, updated_at, enqueued_at, placement,
	class, flag, flag_msg, flag_by, flag_at,
	lock_until, lease_s, gen, dedupe_key, issue_key, vendor_allow, needs, not_by, COALESCE(discussion::text, ''),
	COALESCE(priority, 0), COALESCE(priority_by, ''), priority_at, COALESCE(queue_rank, 0), COALESCE(rank_by, ''), rank_at,
	COALESCE(hold_reason, '')`

func scanAsk(row pgx.Row, fleet string, now time.Time) (FleetAsk, error) {
	a := FleetAsk{Fleet: fleet}
	var deadline, raised, escalated, enqueued, flagAt, lockUntil, prioAt, rankAt *time.Time
	if err := row.Scan(&a.AskID, &a.Role, &a.Kind, &a.From, &a.Topic, &a.Summary, &a.State, &deadline, &a.AckedBy, &a.ClosedBy,
		&a.Reason, &a.RaisedN, &raised, &escalated, &a.WriterBox, &a.CreatedAt, &a.UpdatedAt, &enqueued, &a.Placement,
		&a.Class, &a.Flag, &a.FlagMsg, &a.FlagBy, &flagAt,
		&lockUntil, &a.LeaseS, &a.Gen, &a.DedupeKey, &a.IssueKey, &a.VendorAllow, &a.Needs, &a.NotBy, &a.Discussion,
		&a.OwnPriority, &a.PriorityBy, &prioAt, &a.QueueRank, &a.RankBy, &rankAt, &a.HoldReason); err != nil {
		return a, err
	}
	if a.NotBy == nil {
		a.NotBy = []string{}
	}
	for _, p := range []struct {
		src *time.Time
		dst *time.Time
	}{{deadline, &a.DeadlineAt}, {raised, &a.RaisedAt}, {escalated, &a.EscalatedAt}, {enqueued, &a.EnqueuedAt}, {flagAt, &a.FlagAt}, {lockUntil, &a.LockUntil},
		{prioAt, &a.PriorityAt}, {rankAt, &a.RankAt}} {
		if p.src != nil {
			*p.dst = p.src.UTC()
		}
	}
	a.CreatedAt, a.UpdatedAt = a.CreatedAt.UTC(), a.UpdatedAt.UTC()
	askTimes(&a, now)
	return a, nil
}

func (s *Postgres) PutFleetAsk(ctx context.Context, tenant string, a FleetAsk, box string, now time.Time) (FleetAsk, bool, error) {
	a.From = AskAtBox(a.From, box)
	var out FleetAsk
	created := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM fleet_asks WHERE tenant_id = $1 AND fleet = $2
			AND state IN ('done', 'declined', 'dead') AND updated_at < $3`, tenant, a.Fleet, now.Add(-AskClosedTTL)); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO fleet_asks
			(tenant_id, fleet, ask_id, role, kind, from_agent, topic, summary, state, deadline_at, writer_box, created_at, updated_at, discussion)
			VALUES ($1, $2, $3, $11, $4, $5, $6, $7, 'open', $8, $9, $10, $10, NULLIF($12, '')::uuid)
			ON CONFLICT (tenant_id, fleet, ask_id) DO NOTHING`,
			tenant, a.Fleet, a.AskID, a.Kind, a.From, a.Topic, a.Summary, nullTime(a.DeadlineAt), box, now, a.Role, a.Discussion)
		if err != nil {
			return err
		}
		created = tag.RowsAffected() == 1
		if !created && a.Discussion != "" { // spec 150 B10b: the ask predates its discussion; only this column, never overwritten
			if _, err := tx.Exec(ctx, `UPDATE fleet_asks SET discussion = $4::uuid
				WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3 AND discussion IS NULL`, tenant, a.Fleet, a.AskID, a.Discussion); err != nil {
				return err
			}
		}
		out, err = scanAsk(tx.QueryRow(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`, tenant, a.Fleet, a.AskID), a.Fleet, now)
		return err
	})
	return out, created, err
}

func (s *Postgres) UpdateFleetAsk(ctx context.Context, tenant string, u AskUpdate, box string, now time.Time) (FleetAsk, error) {
	u.By = AskAtBox(u.By, box)
	fleet, askID := u.Fleet, u.AskID
	var out FleetAsk
	closed := false
	var gate error
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		a, err := scanAsk(tx.QueryRow(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3 FOR UPDATE`, tenant, fleet, askID), fleet, now)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if !a.Open() {
			out, closed = a, true
			return nil
		}
		if gate = askGate(a, u, now); gate != nil {
			out = a
			return nil
		}
		applyAskOp(&a, u, box, now)
		if err = writeAsk(ctx, tx, tenant, a); err != nil {
			return err
		}
		askTimes(&a, now)
		out = a
		return nil
	})
	if err != nil {
		return FleetAsk{}, err
	}
	if closed {
		return out, ErrConflict
	}
	return out, gate
}

// writeAsk writes back every column an op may change.
func writeAsk(ctx context.Context, tx pgx.Tx, tenant string, a FleetAsk) error {
	_, err := tx.Exec(ctx, `UPDATE fleet_asks SET state = $4, acked_by = $5, closed_by = $6, reason = $7,
		raised_n = $8, raised_at = $9, escalated_at = $10, writer_box = $11, updated_at = $12,
		enqueued_at = $13, placement = $14, lock_until = $15, gen = $16, not_by = $17,
		class = $18, flag = $19, flag_msg = $20, flag_by = $21, flag_at = $22
		WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`,
		tenant, a.Fleet, a.AskID, a.State, a.AckedBy, a.ClosedBy, a.Reason, a.RaisedN,
		nullTime(a.RaisedAt), nullTime(a.EscalatedAt), a.WriterBox, a.UpdatedAt,
		nullTime(a.EnqueuedAt), a.Placement, nullTime(a.LockUntil), a.Gen, notByArr(a.NotBy),
		a.Class, a.Flag, a.FlagMsg, a.FlagBy, nullTime(a.FlagAt))
	return err
}

func notByArr(n []string) []string {
	if n == nil {
		return []string{}
	}
	return n
}

func (s *Postgres) ListFleetAsks(ctx context.Context, tenant, fleet, role string, all bool, now time.Time) ([]FleetAsk, error) {
	out := []FleetAsk{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND ($4 = '' OR role = $4)
			AND ($3 OR state IN ('open', 'acked', 'queued', 'needs_owner'))`, tenant, fleet, all, role)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			a, err := scanAsk(rows, fleet, now)
			if err != nil {
				return err
			}
			out = append(out, a)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		return askListPriorities(ctx, tx, tenant, out)
	})
	sortAsks(out)
	askPositions(out)
	return out, err
}

// askListPriorities fills each ask's effective Priority from its own and
// its discussion's topic_priorities row (rdb 0214, 0323; spec 153 3.22.6),
// one primary-key probe for the list's distinct discussions, in the list's
// own transaction.
func askListPriorities(ctx context.Context, tx pgx.Tx, tenant string, as []FleetAsk) error {
	prio := map[string]TopicPriority{}
	if ds := askDiscussions(as); len(ds) > 0 {
		rows, err := tx.Query(ctx, `SELECT task_id::text, priority, set_at FROM topic_priorities
			WHERE tenant_id = $1 AND task_id = ANY ($2::uuid[])`, tenant, ds)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var p TopicPriority
			if err := rows.Scan(&p.TaskID, &p.Priority, &p.SetAt); err != nil {
				return err
			}
			p.SetAt = p.SetAt.UTC()
			prio[p.TaskID] = p
		}
		if err := rows.Err(); err != nil {
			return err
		}
	}
	askFillPriorities(as, prio)
	return nil
}

// The order ops (spec 153 3.22.6-3.22.7, rdb 0323). A move locks the role's
// queued rows FOR UPDATE in ask_id order (two moves at once serialise and
// never deadlock), plans it in Go (askPlanMove, shared with Memory) and
// writes the changed rows in the same transaction.

// SetFleetAskPriority implements FleetAskOrder on the Postgres store.
func (s *Postgres) SetFleetAskPriority(ctx context.Context, tenant string, p AskPrioritySet, now time.Time) (FleetAsk, error) {
	var a FleetAsk
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		if a, err = pgAskQueued(ctx, tx, tenant, p.Fleet, p.AskID, true, now); err != nil {
			return err
		}
		askSetPriority(&a, p, now)
		return pgAskWriteOrder(ctx, tx, tenant, a)
	})
	if err != nil {
		return a, err
	}
	as, err := s.ListFleetAsks(ctx, tenant, a.Fleet, a.Role, false, now)
	return askFind(as, a, err)
}

// MoveFleetAsk implements FleetAskOrder on the Postgres store.
func (s *Postgres) MoveFleetAsk(ctx context.Context, tenant string, m AskMove, now time.Time) (FleetAsk, error) {
	var a FleetAsk
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		// Unlocked: the queue below is locked in ask_id order, and locking
		// the moved row first could deadlock two moves. A row that leaves
		// the queue in between is not in the locked queue: askPlanMove
		// answers ErrAskNotQueued.
		if a, err = pgAskQueued(ctx, tx, tenant, m.Fleet, m.AskID, false, now); err != nil {
			return err
		}
		queue, err := pgAskLockQueue(ctx, tx, tenant, m.Fleet, a.Role, now)
		if err != nil {
			return err
		}
		writes, err := askPlanMove(queue, m, now)
		if err != nil {
			return err
		}
		for _, w := range writes {
			if err := pgAskWriteOrder(ctx, tx, tenant, w); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return a, err
	}
	as, err := s.ListFleetAsks(ctx, tenant, a.Fleet, a.Role, false, now)
	return askFind(as, a, err)
}

// pgAskQueued reads one ask, FOR UPDATE when lock (the state it answers on
// then holds to the commit): ErrNotFound, or ErrAskNotQueued with the row.
func pgAskQueued(ctx context.Context, tx pgx.Tx, tenant, fleet, askID string, lock bool, now time.Time) (FleetAsk, error) {
	q := `SELECT ` + askCols + ` FROM fleet_asks WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`
	if lock {
		q += ` FOR UPDATE`
	}
	a, err := scanAsk(tx.QueryRow(ctx, q, tenant, fleet, askID), fleet, now)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return a, ErrNotFound
	case err != nil:
		return a, err
	case a.State != "queued":
		return a, ErrAskNotQueued
	}
	return a, nil
}

// pgAskLockQueue locks the role's queued rows and answers them filled and in
// queue order. A row that left the queue before the lock is not among them,
// so a move naming it is stale.
func pgAskLockQueue(ctx context.Context, tx pgx.Tx, tenant, fleet, role string, now time.Time) ([]FleetAsk, error) {
	rows, err := tx.Query(ctx, `SELECT `+askCols+` FROM fleet_asks
		WHERE tenant_id = $1 AND fleet = $2 AND role = $3 AND state = 'queued'
		ORDER BY ask_id FOR UPDATE`, tenant, fleet, role)
	if err != nil {
		return nil, err
	}
	queue := []FleetAsk{}
	for rows.Next() {
		a, err := scanAsk(rows, fleet, now)
		if err != nil {
			rows.Close()
			return nil, err
		}
		queue = append(queue, a)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := askListPriorities(ctx, tx, tenant, queue); err != nil {
		return nil, err
	}
	askPositions(queue)
	return askRoleQueue(queue, role), nil
}

// pgAskWriteOrder writes a queued row's own priority and rank columns;
// ErrAskNotQueued when the row is no longer queued.
func pgAskWriteOrder(ctx context.Context, tx pgx.Tx, tenant string, a FleetAsk) error {
	tag, err := tx.Exec(ctx, `UPDATE fleet_asks SET priority = NULLIF($4, 0)::smallint, priority_by = NULLIF($5, ''),
		priority_at = $6, queue_rank = NULLIF($7, 0)::bigint, rank_by = NULLIF($8, ''), rank_at = $9
		WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3 AND state = 'queued'`,
		tenant, a.Fleet, a.AskID, a.OwnPriority, a.PriorityBy, nullTime(a.PriorityAt),
		a.QueueRank, a.RankBy, nullTime(a.RankAt))
	if err == nil && tag.RowsAffected() == 0 {
		return ErrAskNotQueued
	}
	return err
}
