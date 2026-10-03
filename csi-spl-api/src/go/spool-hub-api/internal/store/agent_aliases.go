package store

import (
	"cmp"
	"context"
	"errors"
	"slices"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// AgentAlias is one row of agent_id_aliases (rdb 0101, spec 061 section 5):
// a legacy agent id on a box and the new id it became on that same box
// (owner 2026-10-02: c-NNN@<box> is the unique name). Written once, never
// edited.
type AgentAlias struct {
	OldID    string    `json:"old_id"`
	NewID    string    `json:"new_id"`
	Kind     string    `json:"kind"`
	BoxID    string    `json:"box_id"`
	MappedAt time.Time `json:"mapped_at"`
}

// ErrBadAlias: a row 0101's CHECKs would refuse.
var ErrBadAlias = errors.New("alias must map a legacy agent id (CLE-7) on a box to a new one (c-004) of the same kind")

// AgentAliases is the alias half of the store contract.
type AgentAliases interface {
	// PutAgentAlias records (old, box) -> new once. A second put of the same
	// (old, box) changes nothing and returns the stored row with created false.
	PutAgentAlias(ctx context.Context, tenantID string, a AgentAlias, now time.Time) (got AgentAlias, created bool, err error)
	// ListAgentAliases reads every row of the tenant, oldest mapping first.
	ListAgentAliases(ctx context.Context, tenantID string) ([]AgentAlias, error)
}

// CheckAgentAlias refuses what 0101's CHECKs would, so a refusal is a 400.
func CheckAgentAlias(a AgentAlias) error {
	if !agentid.IsLegacy(a.OldID) || !agentid.IsNew(a.NewID) || agentid.Kind(a.OldID) != agentid.Kind(a.NewID) ||
		a.Kind != agentid.Kind(a.NewID) || !FleetNameRe.MatchString(a.BoxID) {
		return ErrBadAlias
	}
	return nil
}

func sortAliases(as []AgentAlias) {
	slices.SortStableFunc(as, func(a, b AgentAlias) int {
		return cmp.Or(a.MappedAt.Compare(b.MappedAt), cmp.Compare(a.OldID, b.OldID), cmp.Compare(a.BoxID, b.BoxID))
	})
}

func (s *Memory) PutAgentAlias(_ context.Context, tenant string, a AgentAlias, now time.Time) (AgentAlias, bool, error) {
	if err := CheckAgentAlias(a); err != nil {
		return AgentAlias{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.aliases == nil {
		s.aliases = map[[3]string]AgentAlias{}
	}
	k := [3]string{tenant, a.OldID, a.BoxID}
	if got, ok := s.aliases[k]; ok {
		return got, false, nil
	}
	a.MappedAt = now.UTC()
	s.aliases[k] = a
	return a, true, nil
}

func (s *Memory) ListAgentAliases(_ context.Context, tenant string) ([]AgentAlias, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []AgentAlias{}
	for k, a := range s.aliases {
		if k[0] == tenant {
			out = append(out, a)
		}
	}
	sortAliases(out)
	return out, nil
}
