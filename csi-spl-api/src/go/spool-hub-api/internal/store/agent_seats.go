package store

import (
	"context"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// seatsRecheck is how often a hub that found no agent_seats table looks again.
const seatsRecheck = time.Minute

// seatsProbe says whether rdb 0107's agent_seats table exists (spec 061 3.6,
// lane L10). The hub may roll before the migration reaches its database (a
// trunk push deploys dev and prd together), so until the table is there the
// roster is read and written without seats: no seated_at, never a 500. Once
// seen, the table is assumed for the life of the process (forward-only).
type seatsProbe struct {
	mu      sync.Mutex
	ok      bool
	checked time.Time
	// check overrides the catalogue lookup (tests).
	check func(ctx context.Context) (bool, error)
}

// present reports whether the probed relation exists: true once seen (for the
// life of the process); a miss is rechecked only after seatsRecheck past the
// last lookup at now. A lookup error counts as a miss.
func (p *seatsProbe) present(ctx context.Context, lookup func(ctx context.Context) (bool, error), now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ok {
		return true
	}
	if !p.checked.IsZero() && now.Sub(p.checked) < seatsRecheck {
		return false
	}
	p.checked = now
	if p.check != nil {
		lookup = p.check
	}
	if ok, err := lookup(ctx); err == nil {
		p.ok = ok
	}
	return p.ok
}

// catalogQuerier is where a probe asks: the pool, or the transaction its
// caller already holds (*pgxpool.Pool and pgx.Tx both are).
type catalogQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// hasAgentSeats is the probe against this database's catalogue, asked on q.
// Inside a transaction q must be that transaction: the pool would hand the
// probe a second connection while the first is held, and with every
// connection in such a transaction no probe ever gets one (SPL-2238, the
// cold-instance hello deadlock).
func (s *Postgres) hasAgentSeats(ctx context.Context, q catalogQuerier) bool {
	return s.seats.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = q.QueryRow(ctx, `SELECT to_regclass('agent_seats') IS NOT NULL`).Scan(&ok)
		return ok, err
	}, s.now())
}
