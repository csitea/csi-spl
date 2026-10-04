package store

import (
	"context"
	"errors"
	"slices"

	"github.com/jackc/pgx/v5"
)

// The fleet load target (rdb 0118, owner HUM-10 t1 c13e8023): the band a
// box's load should stay in (% of cores, load5 / cpus) and the order the
// boxes take new agent lanes. It is the INSTANCE's setting: the hub reads and
// writes it on the operator workspace's row only (rdb 0116), and only that
// workspace's admin changes it. NULL = the default below, as in rdb 0105.

// FleetLoad is the target in force.
type FleetLoad struct {
	Low      int      `json:"low"`
	High     int      `json:"high"`
	BoxOrder []string `json:"box_order"` // empty = the box's cnf seed order
}

// FleetLoadStored is what the row holds; nil = unset (the default).
type FleetLoadStored struct {
	Low      *int     `json:"low"`
	High     *int     `json:"high"`
	BoxOrder []string `json:"box_order"` // nil = unset
}

// FleetLoadPatch changes the fields whose Set flag is true; a nil value
// with its flag set resets that field to the default.
type FleetLoadPatch struct {
	LowSet, HighSet, OrderSet bool
	Low, High                 *int
	BoxOrder                  []string
}

// MaxFleetBoxes is the rdb 0118 CHECK on cardinality(fleet_box_order).
const MaxFleetBoxes = 32

// DefaultFleetLoad is the owner's band (50..75 %) with no order of its own.
func DefaultFleetLoad() FleetLoad { return FleetLoad{Low: 50, High: 75, BoxOrder: []string{}} }

// ErrBadFleetLoad: a mark outside the rdb checks, low >= high, or a box
// order that is not distinct box ids.
var ErrBadFleetLoad = errors.New("store: bad fleet load target")

// Effective is the target in force for a stored row.
func (f FleetLoadStored) Effective() FleetLoad {
	out := DefaultFleetLoad()
	if f.Low != nil {
		out.Low = *f.Low
	}
	if f.High != nil {
		out.High = *f.High
	}
	if f.BoxOrder != nil {
		out.BoxOrder = slices.Clone(f.BoxOrder)
	}
	return out
}

// apply is f with p applied.
func (f FleetLoadStored) apply(p FleetLoadPatch) FleetLoadStored {
	if p.LowSet {
		f.Low = p.Low
	}
	if p.HighSet {
		f.High = p.High
	}
	if p.OrderSet {
		f.BoxOrder = slices.Clone(p.BoxOrder)
		if len(f.BoxOrder) == 0 {
			f.BoxOrder = nil
		}
	}
	return f
}

// CheckFleetLoad is nil when the stored row is valid: each set mark within
// the rdb 0118 range, low < high on the values in force, and the order
// distinct box ids, at most MaxFleetBoxes.
func CheckFleetLoad(f FleetLoadStored) error {
	if f.Low != nil && (*f.Low < 1 || *f.Low > 99) {
		return ErrBadFleetLoad
	}
	if f.High != nil && (*f.High < 2 || *f.High > 100) {
		return ErrBadFleetLoad
	}
	if e := f.Effective(); e.Low >= e.High {
		return ErrBadFleetLoad
	}
	if len(f.BoxOrder) > MaxFleetBoxes {
		return ErrBadFleetLoad
	}
	seen := map[string]bool{}
	for _, b := range f.BoxOrder {
		if !FleetNameRe.MatchString(b) || seen[b] {
			return ErrBadFleetLoad
		}
		seen[b] = true
	}
	return nil
}

// FleetLoadTarget is implemented by Memory and Postgres.
type FleetLoadTarget interface {
	// FleetLoadOf reads the tenant's stored target; ErrNotFound: no tenant.
	FleetLoadOf(ctx context.Context, tenant string) (FleetLoadStored, error)
	// SetFleetLoad applies p and answers the stored row after it;
	// ErrBadFleetLoad leaves the row as it was.
	SetFleetLoad(ctx context.Context, tenant string, p FleetLoadPatch) (FleetLoadStored, error)
}

var (
	_ FleetLoadTarget = (*Memory)(nil)
	_ FleetLoadTarget = (*Postgres)(nil)
)

// ---- Memory -----------------------------------------------------------------

func (s *Memory) FleetLoadOf(_ context.Context, tenant string) (FleetLoadStored, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return FleetLoadStored{}, ErrNotFound
	}
	return s.fleetLoad[tenant], nil
}

func (s *Memory) SetFleetLoad(_ context.Context, tenant string, p FleetLoadPatch) (FleetLoadStored, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return FleetLoadStored{}, ErrNotFound
	}
	next := s.fleetLoad[tenant].apply(p)
	if err := CheckFleetLoad(next); err != nil {
		return FleetLoadStored{}, err
	}
	if s.fleetLoad == nil {
		s.fleetLoad = map[string]FleetLoadStored{}
	}
	s.fleetLoad[tenant] = next
	return next, nil
}

// ---- Postgres ---------------------------------------------------------------

const fleetLoadCols = `fleet_load_low, fleet_load_high, fleet_box_order`

func scanFleetLoad(row pgx.Row) (FleetLoadStored, error) {
	var f FleetLoadStored
	var low, high *int16
	if err := row.Scan(&low, &high, &f.BoxOrder); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return FleetLoadStored{}, ErrNotFound
		}
		return FleetLoadStored{}, err
	}
	if low != nil {
		v := int(*low)
		f.Low = &v
	}
	if high != nil {
		v := int(*high)
		f.High = &v
	}
	return f, nil
}

func (s *Postgres) FleetLoadOf(ctx context.Context, tenant string) (FleetLoadStored, error) {
	var f FleetLoadStored
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) (err error) {
		f, err = scanFleetLoad(tx.QueryRow(ctx, `SELECT `+fleetLoadCols+` FROM tenants WHERE tenant_id = $1`, tenant))
		return err
	})
	return f, err
}

func (s *Postgres) SetFleetLoad(ctx context.Context, tenant string, p FleetLoadPatch) (FleetLoadStored, error) {
	var next FleetLoadStored
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		cur, err := scanFleetLoad(tx.QueryRow(ctx, `SELECT `+fleetLoadCols+` FROM tenants WHERE tenant_id = $1 FOR UPDATE`, tenant))
		if err != nil {
			return err
		}
		next = cur.apply(p)
		if err := CheckFleetLoad(next); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE tenants SET fleet_load_low = $2, fleet_load_high = $3, fleet_box_order = $4
			WHERE tenant_id = $1`, tenant, next.Low, next.High, next.BoxOrder)
		return err
	})
	if err != nil {
		return FleetLoadStored{}, err
	}
	return next, nil
}
