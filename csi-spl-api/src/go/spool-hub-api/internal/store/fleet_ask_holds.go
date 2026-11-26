package store

import (
	"context"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// The placer's hold, readable by the hub (spec 153 3.22.8, row Q3, rdb
// 0323 fleet_asks.hold_reason): ask_op holds hands the whole map of the
// asks the placer passed over on its last tick to their reasons. A row of
// the role's line that the map names gets its reason; a row the map leaves
// out is cleared (it waits for room). Only a row whose reason changes is
// written, so a second tick with the same map writes nothing. The line is
// what the placer reads (spl_spawn_q_rows): state queued, or acked with an
// enqueued_at. A map key that is no row of the line is ignored.

// AskHoldsMax caps the map one holds op carries.
const AskHoldsMax = 500

// AskHolds is one holds op: the role's line in Fleet, the reasons by ask id.
type AskHolds struct {
	Fleet, Role string
	Holds       map[string]string
}

// FleetAskHolder is the hold write; Memory and Postgres implement it.
type FleetAskHolder interface {
	// SetFleetAskHolds writes the changed reasons in one transaction and
	// answers the rows it wrote, each with its new HoldReason; none when
	// nothing changed. The rows' updated_at is not touched: a hold is the
	// placer's reading, not activity on the ask.
	SetFleetAskHolds(ctx context.Context, tenantID string, h AskHolds, now time.Time) ([]FleetAsk, error)
}

// AskInLine reports whether a is in the placer's line: queued, or placing
// (acked with an enqueued_at). The queue view lists the same rows.
func AskInLine(a FleetAsk) bool {
	return a.State == "queued" || (a.State == "acked" && !a.EnqueuedAt.IsZero())
}

// askPlanHolds answers the rows of line whose reason the map changes, with
// the new reason set, in ask id order (both drivers share it).
func askPlanHolds(line []FleetAsk, h AskHolds) []FleetAsk {
	out := []FleetAsk{}
	for _, a := range line {
		if a.Role != h.Role || !AskInLine(a) {
			continue
		}
		if want := h.Holds[a.AskID]; want != a.HoldReason {
			a.HoldReason = want
			out = append(out, a)
		}
	}
	slices.SortFunc(out, func(a, b FleetAsk) int {
		if a.AskID < b.AskID {
			return -1
		}
		if a.AskID > b.AskID {
			return 1
		}
		return 0
	})
	return out
}

// SetFleetAskHolds implements FleetAskHolder on the Memory store.
func (s *Memory) SetFleetAskHolds(_ context.Context, tenant string, h AskHolds, now time.Time) ([]FleetAsk, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	line := []FleetAsk{}
	for k, a := range s.asks {
		if k[0] == tenant && k[1] == h.Fleet {
			line = append(line, a)
		}
	}
	out := askPlanHolds(line, h)
	for i, a := range out {
		s.asks[[3]string{tenant, h.Fleet, a.AskID}] = a
		askTimes(&out[i], now)
	}
	return out, nil
}

// SetFleetAskHolds implements FleetAskHolder on the Postgres store: the
// role's line is locked in ask_id order (as a move locks it), so two ticks
// at once serialise.
func (s *Postgres) SetFleetAskHolds(ctx context.Context, tenant string, h AskHolds, now time.Time) ([]FleetAsk, error) {
	var out []FleetAsk
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND role = $3
			AND (state = 'queued' OR (state = 'acked' AND enqueued_at IS NOT NULL))
			ORDER BY ask_id FOR UPDATE`, tenant, h.Fleet, h.Role)
		if err != nil {
			return err
		}
		line, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (FleetAsk, error) { return scanAsk(r, h.Fleet, now) })
		if err != nil {
			return err
		}
		out = askPlanHolds(line, h)
		for _, a := range out {
			if _, err := tx.Exec(ctx, `UPDATE fleet_asks SET hold_reason = NULLIF($4, '')
				WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`, tenant, h.Fleet, a.AskID, a.HoldReason); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
