package store

import (
	"context"
	"sort"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The month-end invoice issuer's read (spec 181 row B14, gap G15; Q-20 A):
// every private workspace (price_plans.kind = 'private_vm', rdb 0302) with
// its human-member count, the seats its month's invoice charges (agents are
// not seats, Q-6 A). The count is CountMembers' rule on each driver: on
// Postgres the members whose human is not technical and whose role is not
// channel guest (seats_postgres.go), on Memory every membership row. The box
// action do_spl_private_ws_invoice_issue reads it over the hub's operator
// route, so a dry run prints the quotes with no write; the hub's issue route
// reads it again for the one workspace it invoices, so the count is the
// hub's, never the box's.

// PrivateWorkspace is one private workspace and its human-member count.
type PrivateWorkspace struct {
	Tenant string
	Humans int64
}

// PrivateWorkspaces is the operator-scope read of the private workspaces.
// Optional: a store without it lists none.
type PrivateWorkspaces interface {
	// PrivateWorkspaceMembers answers every workspace on the private_vm plan,
	// by id, each with CountMembers' count; with a non-empty tenant only that
	// one (none when it is not on the plan).
	PrivateWorkspaceMembers(ctx context.Context, tenant string) ([]PrivateWorkspace, error)
}

var (
	_ PrivateWorkspaces = (*Memory)(nil)
	_ PrivateWorkspaces = (*Postgres)(nil)
)

// PrivateWorkspaceMembers lists the private workspaces (PrivateWorkspaces).
func (s *Memory) PrivateWorkspaceMembers(_ context.Context, tenant string) ([]PrivateWorkspace, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []PrivateWorkspace{}
	for id, p := range memPlans[s] {
		if p.Kind != PlanKindPrivateVM || (tenant != "" && id != tenant) {
			continue
		}
		out = append(out, PrivateWorkspace{Tenant: id, Humans: int64(s.hum.memberCount(id))})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Tenant < out[j].Tenant })
	return out, nil
}

// privateWorkspacesSQL: CountMembers' count (seats_postgres.go) per private
// workspace; $1 the channel guest role, $2 one workspace or empty for all.
const privateWorkspacesSQL = `SELECT p.tenant_id, (SELECT count(*) FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = p.tenant_id AND NOT h.technical AND m.role <> $1)
	FROM price_plans p
	WHERE p.kind = '` + PlanKindPrivateVM + `' AND ($2::text = '' OR p.tenant_id = $2::text)
	ORDER BY p.tenant_id`

// PrivateWorkspaceMembers lists the private workspaces (PrivateWorkspaces).
// It runs in the operator scope: the list spans every workspace
// (TestOperatorScopeCallers).
func (s *Postgres) PrivateWorkspaceMembers(ctx context.Context, tenant string) ([]PrivateWorkspace, error) {
	out := []PrivateWorkspace{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, privateWorkspacesSQL, rbac.ChannelGuest, tenant)
		if err != nil {
			return err
		}
		got, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (PrivateWorkspace, error) {
			var w PrivateWorkspace
			return w, r.Scan(&w.Tenant, &w.Humans)
		})
		out = append(out, got...)
		return err
	})
	return out, err
}
