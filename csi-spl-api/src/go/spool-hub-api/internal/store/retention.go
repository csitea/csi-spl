package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 059 §11.1 S4 retention: a committed delivery row (state 'sent',
// acked_at set) is pruned once its commit is older than CommittedRetention.
// Queued rows still expire after QueueTTL, messages keep their tiered
// retention (and take their deliveries with them, ON DELETE CASCADE), and an
// uncommitted row is never pruned here: it is consumer lag (lag.go).
//
// The window is not shorter because a delivery row is also evidence a reader
// still uses while its message lives: BoxTaskEnvelopes and FileReadableByBox
// (a box reads what was delivered to it) and the WUI's delivery states. The
// default equals the longest default message retention
// (SPOOL_HUB_RETENTION_CHANNELS, 720h), so on defaults no reader loses a row;
// SPOOL_HUB_COMMITTED_RETENTION sets it.
var CommittedRetention = 720 * time.Hour

// pruneCommitted is Sweep's last step: it deletes committed rows past the
// window, sweepChunk rows per transaction, and returns r with Pruned set.
func (s *Postgres) pruneCommitted(ctx context.Context, now time.Time, r SweepResult) (SweepResult, error) {
	cutoff := now.Add(-CommittedRetention)
	for {
		var n int64
		if err := s.asOperator(ctx, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, `DELETE FROM deliveries
				WHERE state = 'sent' AND acked_at < $1 AND (tenant_id, msg_id, to_box) IN (
					SELECT tenant_id, msg_id, to_box FROM deliveries
					WHERE state = 'sent' AND acked_at < $1 LIMIT $2)`, cutoff, sweepChunk)
			n = tag.RowsAffected()
			return err
		}); err != nil {
			return SweepResult{}, err
		}
		r.Pruned += int(n)
		if n < sweepChunk {
			return r, nil
		}
	}
}

// pruneCommittedLocked is the memory store's twin; s.mu is held. The memory
// row keeps no commit time, so sent_at stands in for it (a commit is never
// before its send, so memory prunes no later than Postgres does).
func (s *Memory) pruneCommittedLocked(now time.Time, r SweepResult) SweepResult {
	cutoff := now.Add(-CommittedRetention)
	for k, d := range s.deliveries {
		if d.state == StateSent && d.acked && d.sentAt.Before(cutoff) {
			delete(s.deliveries, k)
			r.Pruned++
		}
	}
	return r
}
