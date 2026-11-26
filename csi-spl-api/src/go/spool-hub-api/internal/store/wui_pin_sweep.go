package store

import (
	"context"
	"sort"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// WUIPinGaps lists the workspaces the hub's box-wui pin sweep may pin (spec
// 158 10.6 item 3, row P2): no pin row for box at all (a revoked row is a
// row), not the system workspace, not suspended, not archived, not unpaid.
// Postgres and Memory implement it.
type WUIPinGaps interface {
	TenantsMissingWUIPin(ctx context.Context, box string) ([]string, error)
}

// wuiPinGapsSQL ($1: the system tenant, $2: the box, $3: the unpaid status).
const wuiPinGapsSQL = `SELECT t.tenant_id FROM tenants t
	WHERE t.tenant_id <> $1 AND t.suspended_at IS NULL AND t.archived_at IS NULL AND t.billing_status <> $3
	  AND NOT EXISTS (SELECT 1 FROM pins p WHERE p.tenant_id = t.tenant_id AND p.box_id = $2)
	ORDER BY t.tenant_id`

// TenantsMissingWUIPin is one operator read, tenant ids in order.
func (s *Postgres) TenantsMissingWUIPin(ctx context.Context, box string) ([]string, error) {
	var out []string
	err := s.asOperatorQuery(ctx, wuiPinGapsSQL, []any{SystemTenant, box, billing.StatusUnpaid}, func(r pgx.Rows) error {
		var id string
		if err := r.Scan(&id); err != nil {
			return err
		}
		out = append(out, id)
		return nil
	})
	return out, err
}

// TenantsMissingWUIPin is the Memory twin of the Postgres read.
func (s *Memory) TenantsMissingWUIPin(_ context.Context, box string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for id, t := range s.tenants {
		if id == SystemTenant || t.Suspended() || !t.ArchivedAt.IsZero() || t.BillingStatus == billing.StatusUnpaid {
			continue
		}
		if _, ok := s.pins[[2]string{id, box}]; !ok {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out, nil
}
