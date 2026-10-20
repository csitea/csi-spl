package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of agent_caps.go (rdb 0212, spec 147).

// ErrAgentCapsUnavailable: this database has no tenant_agent_caps yet (rdb
// 0212 not applied). The hub answers 503 not_migrated; the gate admits.
var ErrAgentCapsUnavailable = errors.New("store: agent caps need rdb 0212")

// hasAgentCaps is the catalogue probe for rdb 0212: the hub may roll before
// the migration reaches its database, and SetRoster must not fail then.
func (s *Postgres) hasAgentCaps(ctx context.Context, q catalogQuerier) bool {
	return s.caps.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = q.QueryRow(ctx, `SELECT to_regclass('tenant_agent_caps') IS NOT NULL`).Scan(&ok)
		return ok, err
	}, s.now())
}

const agentCapsSQL = `SELECT vendor, max_live, updated_at, updated_by FROM tenant_agent_caps WHERE tenant_id = $1`

// scanAgentCaps folds agentCapsSQL rows into c.
func scanAgentCaps(c *AgentCaps) func(pgx.Rows) error {
	return func(r pgx.Rows) error {
		var v, by string
		var n int
		var at time.Time
		if err := r.Scan(&v, &n, &at, &by); err != nil {
			return err
		}
		c.Caps[v] = n
		if at.After(c.UpdatedAt) {
			c.UpdatedAt, c.UpdatedBy = at.UTC(), by
		}
		return nil
	}
}

// capRosterSQL is the workspace's roster pairs with their box's presence
// stamp; $2 is the oldest stamp that is still live.
const capRosterSQL = `SELECT r.box_id, r.agent_id, COALESCE(b.last_hello_at >= $2, false)
	FROM roster r LEFT JOIN boxes b ON b.tenant_id = r.tenant_id AND b.box_id = r.box_id
	WHERE r.tenant_id = $1`

func scanCapRoster(out *[]capRosterRow) func(pgx.Rows) error {
	return func(r pgx.Rows) error {
		var row capRosterRow
		if err := r.Scan(&row.box, &row.agent, &row.live); err != nil {
			return err
		}
		*out = append(*out, row)
		return nil
	}
}

// vendorCapGate runs inside SetRoster's transaction, AFTER botSeatGate: its
// tenants row lock (FOR NO KEY UPDATE) serialises two boxes racing for a
// vendor's last seat (spec 147 2.3, control C5). No cap row = no count.
func (s *Postgres) vendorCapGate(ctx context.Context, tx pgx.Tx, tenant, box string, agents []string, now time.Time) error {
	if len(agents) == 0 || !s.hasAgentCaps(ctx, tx) {
		return nil
	}
	c := AgentCaps{Caps: map[string]int{}}
	if err := eachRow(ctx, tx, agentCapsSQL, []any{tenant}, scanAgentCaps(&c)); err != nil || len(c.Caps) == 0 {
		return err
	}
	var rows []capRosterRow
	if err := eachRow(ctx, tx, capRosterSQL, []any{tenant, now.Add(-CapPresenceTTL)}, scanCapRoster(&rows)); err != nil {
		return err
	}
	return overVendorCap(tenant, box, c.Caps, rows, agents)
}

// AgentCaps reads in the workspace scope; no rdb 0212 yet = no caps.
func (s *Postgres) AgentCaps(ctx context.Context, tenant string) (AgentCaps, error) {
	c := AgentCaps{TenantID: tenant, Caps: map[string]int{}}
	if !s.hasAgentCaps(ctx, s.pool) {
		return c, nil
	}
	err := s.queryTenant(ctx, tenant, agentCapsSQL, []any{tenant}, scanAgentCaps(&c))
	return c, err
}

// LiveAgents counts live roster pairs per vendor (spec 147 4.1).
func (s *Postgres) LiveAgents(ctx context.Context, tenant string, now time.Time) (map[string]int, error) {
	var rows []capRosterRow
	err := s.queryTenant(ctx, tenant, capRosterSQL, []any{tenant, now.Add(-CapPresenceTTL)}, scanCapRoster(&rows))
	return liveByVendor(rows), err
}

// SetAgentCaps writes in the operator scope: rdb 0212's tenant_scope policy
// is FOR SELECT, so no workspace-scoped call can write a cap. The caps, the
// audit rows and the read back are one transaction.
func (s *Postgres) SetAgentCaps(ctx context.Context, tenant string, caps map[string]*int, by AgentCapActor, now time.Time) (AgentCaps, error) {
	if err := checkTenant(tenant); err != nil {
		return AgentCaps{}, err
	}
	if err := checkAgentCaps(caps); err != nil {
		return AgentCaps{}, err
	}
	if !s.hasAgentCaps(ctx, s.pool) {
		return AgentCaps{}, ErrAgentCapsUnavailable
	}
	now = now.UTC()
	out := AgentCaps{TenantID: tenant, Caps: map[string]int{}}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1)`, tenant).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		prev := AgentCaps{Caps: map[string]int{}}
		if err := eachRow(ctx, tx, agentCapsSQL, []any{tenant}, scanAgentCaps(&prev)); err != nil {
			return err
		}
		for _, c := range agentCapChanges(tenant, prev.Caps, caps, by, now) {
			if err := s.writeAgentCap(ctx, tx, c, by.Hum, now); err != nil {
				return err
			}
		}
		return eachRow(ctx, tx, agentCapsSQL, []any{tenant}, scanAgentCaps(&out))
	})
	return out, err
}

// writeAgentCap applies one change and its audit row, on the operator tx.
func (s *Postgres) writeAgentCap(ctx context.Context, tx pgx.Tx, c agentCapChange, hum string, now time.Time) error {
	a, v := c.audit, c.vendor
	if c.n == nil {
		if _, err := tx.Exec(ctx, `DELETE FROM tenant_agent_caps WHERE tenant_id = $1 AND vendor = $2`, a.TenantID, v); err != nil {
			return err
		}
	} else if _, err := tx.Exec(ctx, `INSERT INTO tenant_agent_caps (tenant_id, vendor, max_live, created_at, updated_at, updated_by)
		VALUES ($1, $2, $3, $4, $4, $5)
		ON CONFLICT (tenant_id, vendor) DO UPDATE SET max_live = EXCLUDED.max_live,
			updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by`,
		a.TenantID, v, *c.n, now, hum); err != nil {
		return mapFK(err)
	}
	detail, err := json.Marshal(a.Detail)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO operator_audit (at, tenant_id, actor_tenant, actor_hum, action, detail)
		VALUES ($1, $2, $3, $4, $5, $6::jsonb)`, a.At, a.TenantID, a.ActorTenant, a.ActorHum, a.Action, string(detail))
	return err
}

// agentCapChange is one vendor's write (n nil = remove) and its audit row.
type agentCapChange struct {
	vendor string
	n      *int
	audit  OperatorAudit
}

// agentCapChanges is every vendor whose cap the request changes, in
// AgentCapVendors order; an unchanged value writes nothing.
func agentCapChanges(tenant string, prev map[string]int, caps map[string]*int, by AgentCapActor, now time.Time) []agentCapChange {
	var out []agentCapChange
	for _, v := range AgentCapVendors {
		n, asked := caps[v]
		if !asked {
			continue
		}
		old, had := prev[v]
		var previous any
		if had {
			previous = old
		}
		a := OperatorAudit{At: now, TenantID: tenant, ActorTenant: by.Tenant, ActorHum: by.Hum}
		switch {
		case n == nil && !had, n != nil && had && *n == old:
			continue
		case n == nil:
			a.Action, a.Detail = AuditDeleteAgentCap, map[string]any{"vendor": v, "max_live": nil, "previous": previous}
		default:
			a.Action, a.Detail = AuditSetAgentCaps, map[string]any{"vendor": v, "max_live": *n, "previous": previous}
		}
		out = append(out, agentCapChange{vendor: v, n: n, audit: a})
	}
	return out
}
