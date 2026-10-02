package store

import (
	"context"
	"regexp"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// FleetLease is one role's fleet-wide lease (rdb 0094, CLE-77911): exactly
// one orchestrator and one master dispatcher act at a time across every
// machine of a fleet. Gen counts the writes (0 = no row yet); Age is how long
// ago it was last written, on the hub's clock.
type FleetLease struct {
	Fleet     string
	Role      string
	Holder    string // "<agent id>@<box>", the fleet's session name (owner, t1 2efb3e78)
	Box       string // the box that wrote it (from the authenticated hello)
	Gen       int64
	RenewedAt time.Time
	Age       time.Duration
}

// The shapes 0094/0095's CHECKs accept, so a refusal is a 400, not a 500.
var (
	FleetNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
)

// ValidFleetHolder is a lease holder, <agent id>@<box>, the id in either
// grammar (spec 061, agentid).
func ValidFleetHolder(s string) bool { return agentid.IsAtBox(s) }

// FleetLeases is the lease half of the store contract.
type FleetLeases interface {
	// GetFleetLease reads (fleet, role); no row is Gen 0, Holder "".
	GetFleetLease(ctx context.Context, tenantID, fleet, role string, now time.Time) (FleetLease, error)
	// CASFleetLease writes holder (by box) only while the row's gen is still
	// ifGen (0 = no row yet), stamps renewed_at = now and bumps gen. A lost
	// race is ErrConflict with the CURRENT row, so the caller decides again
	// without a second read.
	CASFleetLease(ctx context.Context, tenantID, fleet, role, holder, box string, ifGen int64, now time.Time) (FleetLease, error)
}

type memLease struct {
	holder, box string
	gen         int64
	at          time.Time
}

func (s *Memory) GetFleetLease(_ context.Context, tenant, fleet, role string, now time.Time) (FleetLease, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.fleetLeaseLocked(tenant, fleet, role, now), nil
}

func (s *Memory) fleetLeaseLocked(tenant, fleet, role string, now time.Time) FleetLease {
	l := FleetLease{Fleet: fleet, Role: role}
	if r, ok := s.leases[[3]string{tenant, fleet, role}]; ok {
		l.Holder, l.Box, l.Gen, l.RenewedAt, l.Age = r.holder, r.box, r.gen, r.at, now.Sub(r.at)
	}
	return l
}

func (s *Memory) CASFleetLease(_ context.Context, tenant, fleet, role, holder, box string, ifGen int64, now time.Time) (FleetLease, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [3]string{tenant, fleet, role}
	cur := s.leases[k]
	if cur.gen != ifGen {
		return s.fleetLeaseLocked(tenant, fleet, role, now), ErrConflict
	}
	if s.leases == nil {
		s.leases = map[[3]string]memLease{}
	}
	s.leases[k] = memLease{holder: holder, box: box, gen: ifGen + 1, at: now}
	return s.fleetLeaseLocked(tenant, fleet, role, now), nil
}
