package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0110. A poll is spec 068 4.1's one statement per
// step: the subquery picks the free rows FOR UPDATE SKIP LOCKED, so two
// seats polling at once take disjoint messages and neither waits; a row
// another poll just claimed and committed is re-checked against the new
// lock (READ COMMITTED re-evaluation) and skipped. Every statement reads the
// partial index messages_needs_peer. A release or close reads the row FOR
// UPDATE, decides in Go (claimRefusal, shared with Memory) and writes it back
// in the same transaction.

const claimCols = `msg_id::text, task_id::text, coalesce(channel, ''), ts, from_box, from_id, to_box, to_id, kind, msg::text,
	coalesce(responsible, ''), locked_until, responsible_gen, claim_n, handled_at, coalesce(handled_how, ''), not_by, needs_peer`

// claimFreeSQL is claimFree; $1 tenant, $2 now.
const claimFreeSQL = `tenant_id = $1 AND needs_peer AND handled_at IS NULL
	AND (responsible IS NULL OR locked_until IS NULL OR locked_until < $2)`

func scanClaim(row pgx.Row, tenant string) (Message, error) {
	m := Message{TenantID: tenant}
	var msg string
	var locked, handled *time.Time
	if err := row.Scan(&m.MsgID, &m.TaskID, &m.Channel, &m.TS, &m.FromBox, &m.FromID, &m.ToBox, &m.ToID, &m.Kind, &msg,
		&m.Responsible, &locked, &m.ResponsibleGen, &m.ClaimN, &handled, &m.HandledHow, &m.NotBy, &m.NeedsPeer); err != nil {
		return m, err
	}
	m.Msg, m.TS = []byte(msg), m.TS.UTC()
	if locked != nil {
		m.LockedUntil = locked.UTC()
	}
	if handled != nil {
		m.HandledAt = handled.UTC()
	}
	if len(m.NotBy) == 0 {
		m.NotBy = nil
	}
	return m, nil
}

func scanClaims(rows pgx.Rows, tenant string) ([]Message, error) {
	defer rows.Close()
	out := []Message{}
	for rows.Next() {
		m, err := scanClaim(rows, tenant)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Postgres) PollMessageClaims(ctx context.Context, tenant string, p ClaimPoll, now time.Time) ([]Message, []Message, error) {
	var claimed, dead []Message
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `UPDATE messages SET handled_at = $2, handled_how = 'dead', locked_until = NULL
			WHERE (tenant_id, msg_id) IN (
				SELECT tenant_id, msg_id FROM messages
				WHERE `+claimFreeSQL+` AND claim_n >= $3
				ORDER BY ts, msg_id LIMIT $4 FOR UPDATE SKIP LOCKED)
			RETURNING `+claimCols, tenant, now, ClaimMax, ClaimPollMax)
		if err != nil {
			return err
		}
		if dead, err = scanClaims(rows, tenant); err != nil {
			return err
		}
		rows, err = tx.Query(ctx, `UPDATE messages SET responsible = $5, locked_until = $6,
				responsible_gen = responsible_gen + 1, claim_n = claim_n + 1
			WHERE (tenant_id, msg_id) IN (
				SELECT tenant_id, msg_id FROM messages
				WHERE `+claimFreeSQL+` AND claim_n < $3 AND NOT ($7 = ANY (not_by))
				ORDER BY ts, msg_id LIMIT $4 FOR UPDATE SKIP LOCKED)
			RETURNING `+claimCols, tenant, now, ClaimMax, p.Max, p.Seat, now.Add(p.TTL), p.Harness)
		if err != nil {
			return err
		}
		claimed, err = scanClaims(rows, tenant)
		return err
	})
	if err != nil {
		return nil, nil, err
	}
	sortClaims(claimed)
	sortClaims(dead)
	return claimed, dead, nil
}

func (s *Postgres) RenewMessageClaims(ctx context.Context, tenant, seat string, ttl time.Duration, now time.Time) ([]Message, error) {
	var out []Message
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE messages SET locked_until = $3
			WHERE tenant_id = $1 AND needs_peer AND handled_at IS NULL AND responsible = $2
			AND (locked_until IS NULL OR locked_until < $4)`, tenant, seat, now.Add(ttl), now.Add(ttl/2)); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT `+claimCols+` FROM messages
			WHERE tenant_id = $1 AND needs_peer AND handled_at IS NULL AND responsible = $2
			ORDER BY ts, msg_id`, tenant, seat)
		if err != nil {
			return err
		}
		out, err = scanClaims(rows, tenant)
		return err
	})
	return out, err
}

// claimUpdate reads c.MsgID FOR UPDATE, refuses what claimRefusal (or
// refuse) refuses with the current row, else applies apply and writes the
// claim columns back.
func (s *Postgres) claimUpdate(ctx context.Context, tenant string, c ClaimClose, refuse func(*Message) error, apply func(*Message)) (Message, error) {
	var out Message
	var refused error
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		m, err := scanClaim(tx.QueryRow(ctx, `SELECT `+claimCols+` FROM messages
			WHERE tenant_id = $1 AND msg_id = $2 FOR UPDATE`, tenant, c.MsgID), tenant)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		out = m
		if refused = claimRefusal(&m, c); refused == nil && refuse != nil {
			refused = refuse(&m)
		}
		if refused != nil {
			return nil
		}
		apply(&m)
		notBy := m.NotBy
		if notBy == nil {
			notBy = []string{}
		}
		var responsible, how any
		if m.Responsible != "" {
			responsible = m.Responsible
		}
		if m.HandledHow != "" {
			how = m.HandledHow
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET responsible = $3, locked_until = $4, handled_at = $5,
			handled_how = $6, not_by = $7 WHERE tenant_id = $1 AND msg_id = $2`,
			tenant, c.MsgID, responsible, nullTime(m.LockedUntil), nullTime(m.HandledAt), how, notBy); err != nil {
			return err
		}
		out = m
		return nil
	})
	if err != nil {
		return Message{}, err
	}
	return out, refused
}

func (s *Postgres) ReleaseMessageClaim(ctx context.Context, tenant string, c ClaimClose, _ time.Time) (Message, error) {
	return s.claimUpdate(ctx, tenant, c, func(m *Message) error {
		if !m.NeedsPeer {
			return ErrNotPeerMessage
		}
		return nil
	}, func(m *Message) { applyRelease(m, c) })
}

func (s *Postgres) CloseMessageClaim(ctx context.Context, tenant string, c ClaimClose, now time.Time) (Message, error) {
	return s.claimUpdate(ctx, tenant, c, nil, func(m *Message) { applyClose(m, c.How, now) })
}

// sortClaims is the oldest-first order both drivers return.
func sortClaims(ms []Message) {
	sort.Slice(ms, func(i, j int) bool {
		if !ms[i].TS.Equal(ms[j].TS) {
			return ms[i].TS.Before(ms[j].TS)
		}
		return ms[i].MsgID < ms[j].MsgID
	})
}
