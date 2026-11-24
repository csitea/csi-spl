package store

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// A private workspace's cancel (spec 181 row B9, section 4.5, gap G8, rdb
// 0319). Owner HUM-10, msg 9beaf299, Q-12 C: "The VM is deleted at once;
// only the hub data stays 30 days".
//
// CancelWorkspace is the operator's act, one transaction: the cancellation
// row (purge_after = cancelled_at + 30 days), every live pin of the
// workspace revoked (spec 108 3.7, the T012 revoke, with its pins_history
// row), every open join token revoked, box_join_enabled off and one
// operator_audit row (cancel_workspace). Only a workspace on the private_vm
// plan (rdb 0302) is cancelled here; any other is ErrNotPrivateWorkspace, so
// a fleet or a shared workspace can never be reached by this path. A replay
// returns the first row and changes nothing.
//
// WorkspaceCancellation reads the row in the workspace's own scope: the
// vendor key lease asks it, and a cancelled workspace's seat gets 403.
//
// PurgeDueWorkspaces is the hub tick's: every cancellation whose
// purge_after has passed and that is not purged yet. The workspace's hub
// data goes with DELETE FROM tenants (every ON DELETE CASCADE table), the
// row gets purged_at and one operator_audit row (purge_workspace) is
// written; the cancellation row, operator_audit and the workspace's
// invoices carry no FK (rdb 0322), so all three outlive the purge: the
// invoices stay for bookkeeping (owner, msg f872a556). A workspace with an unpaid invoice is HELD, not
// purged: a non-payment never deletes anything on its own (Q-17 B, 4.4);
// the owner decides it by hand, and the next tick purges it once the
// invoice is marked paid. The VM delete is not the hub's: the orc action
// does it on the owner's go.

// CancelPurgeDays is how long the hub data stays after a cancel (Q-12 C).
const CancelPurgeDays = 30

// The operator_audit actions of a cancel and its purge (rdb 0319).
const (
	AuditCancelWorkspace = "cancel_workspace"
	AuditPurgeWorkspace  = "purge_workspace"
)

// PurgeActor is the operator_audit actor of the hub's purge tick.
const PurgeActor = "hub-purge-tick"

// ErrNotPrivateWorkspace: the workspace is not on the private_vm plan.
var ErrNotPrivateWorkspace = errors.New("store: not a private workspace (price plan private_vm)")

// WorkspaceCancel is one workspace_cancellations row, plus what the cancel
// that wrote it revoked (empty on a replay).
type WorkspaceCancel struct {
	Tenant        string
	CancelledAt   time.Time
	PurgeAfter    time.Time
	PurgedAt      *time.Time
	ActorTenant   string
	ActorHum      string
	RevokedBoxes  []string
	RevokedTokens int
}

// PurgeResult names the workspaces a purge deleted, and those it held for
// an unpaid invoice.
type PurgeResult struct {
	Purged []string
	Held   []string
}

// WorkspaceCancels is implemented by Memory and Postgres.
type WorkspaceCancels interface {
	// CancelWorkspace cancels tenant at now, by (actorTenant, actorHum); see
	// the file comment. created is false on a replay. ErrNotFound without
	// the workspace, ErrNotPrivateWorkspace off the private_vm plan.
	CancelWorkspace(ctx context.Context, tenant, actorTenant, actorHum string, now time.Time) (c WorkspaceCancel, created bool, err error)
	// WorkspaceCancellation reads tenant's row; ErrNotFound when it is not cancelled.
	WorkspaceCancellation(ctx context.Context, tenant string) (WorkspaceCancel, error)
	// PurgeDueWorkspaces deletes every cancelled workspace whose purge_after
	// is at or before now; see the file comment.
	PurgeDueWorkspaces(ctx context.Context, now time.Time) (PurgeResult, error)
}

var (
	_ WorkspaceCancels = (*Memory)(nil)
	_ WorkspaceCancels = (*Postgres)(nil)
)

func newWorkspaceCancel(tenant, actorTenant, actorHum string, now time.Time) WorkspaceCancel {
	at := now.UTC().Truncate(time.Microsecond)
	return WorkspaceCancel{Tenant: tenant, CancelledAt: at, PurgeAfter: at.AddDate(0, 0, CancelPurgeDays),
		ActorTenant: actorTenant, ActorHum: actorHum}
}

func cancelAudit(c WorkspaceCancel) OperatorAudit {
	boxes := c.RevokedBoxes
	if boxes == nil {
		boxes = []string{}
	}
	return OperatorAudit{At: c.CancelledAt, TenantID: c.Tenant, ActorTenant: c.ActorTenant, ActorHum: c.ActorHum,
		Action: AuditCancelWorkspace, Detail: map[string]any{"revoked_boxes": boxes,
			"revoked_join_tokens": c.RevokedTokens, "purge_after": c.PurgeAfter.Format(time.RFC3339)}}
}

func purgeAudit(tenant string, now time.Time) OperatorAudit {
	return OperatorAudit{At: now.UTC(), TenantID: tenant, ActorTenant: PurgeActor, ActorHum: PurgeActor,
		Action: AuditPurgeWorkspace, Detail: map[string]any{}}
}

func checkCancelActor(tenant, actorTenant, actorHum string) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if strings.TrimSpace(actorTenant) == "" || strings.TrimSpace(actorHum) == "" {
		return errors.New("store: a cancel names its actor")
	}
	return nil
}

// Memory side: a map beside the Memory struct, guarded by s.mu.
var memCancels = map[*Memory]map[string]WorkspaceCancel{}

// purgedLocked: tenant's id was purged, so it is retired (rdb 0322); every
// path that makes a tenant row refuses it. The caller holds s.mu.
func (s *Memory) purgedLocked(tenant string) bool {
	c, ok := memCancels[s][tenant]
	return ok && c.PurgedAt != nil
}

// CancelWorkspace is the Memory twin of the Postgres cancel (WorkspaceCancels).
func (s *Memory) CancelWorkspace(_ context.Context, tenant, actorTenant, actorHum string, now time.Time) (WorkspaceCancel, bool, error) {
	if err := checkCancelActor(tenant, actorTenant, actorHum); err != nil {
		return WorkspaceCancel{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return WorkspaceCancel{}, false, ErrNotFound
	}
	if p, ok := memPlans[s][tenant]; !ok || p.Kind != PlanKindPrivateVM {
		return WorkspaceCancel{}, false, ErrNotPrivateWorkspace
	}
	if old, ok := memCancels[s][tenant]; ok {
		return old, false, nil
	}
	c := newWorkspaceCancel(tenant, actorTenant, actorHum, now)
	c.RevokedBoxes = s.revokeTenantPins(tenant, c.CancelledAt)
	for _, j := range s.joins {
		if j.TenantID == tenant && j.State() == "open" {
			at := c.CancelledAt
			j.RevokedAt = &at
			c.RevokedTokens++
		}
	}
	delete(s.boxJoinOn, tenant)
	if memCancels[s] == nil {
		memCancels[s] = map[string]WorkspaceCancel{}
	}
	memCancels[s][tenant] = c
	s.opAudit = append(s.opAudit, cancelAudit(c))
	return c, true, nil
}

// revokeTenantPins revokes every live pin of tenant, sorted box ids out.
// The caller holds mu.
func (s *Memory) revokeTenantPins(tenant string, at time.Time) []string {
	var boxes []string
	for k, p := range s.pins {
		if k[0] != tenant || p.revoked {
			continue
		}
		p.revoked = true
		s.history = append(s.history, memHist{tenant: tenant, box: k[1], reason: "revoke",
			pub: append(ed25519.PublicKey(nil), p.pub...), at: at})
		boxes = append(boxes, k[1])
	}
	sort.Strings(boxes)
	return boxes
}

// WorkspaceCancellation reads tenant's cancellation (WorkspaceCancels).
func (s *Memory) WorkspaceCancellation(_ context.Context, tenant string) (WorkspaceCancel, error) {
	if err := checkTenant(tenant); err != nil {
		return WorkspaceCancel{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := memCancels[s][tenant]
	if !ok {
		return WorkspaceCancel{}, ErrNotFound
	}
	c.RevokedBoxes, c.RevokedTokens = nil, 0
	return c, nil
}

// PurgeDueWorkspaces is the Memory twin of the Postgres purge: it drops the
// workspace and the rows the Memory store keys by it (WorkspaceCancels).
func (s *Memory) PurgeDueWorkspaces(_ context.Context, now time.Time) (PurgeResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var res PurgeResult
	at := now.UTC().Truncate(time.Microsecond)
	for tenant, c := range memCancels[s] {
		if c.PurgedAt != nil || c.PurgeAfter.After(at) {
			continue
		}
		if s.unpaidInvoice(tenant) {
			res.Held = append(res.Held, tenant)
			continue
		}
		s.dropTenant(tenant)
		c.PurgedAt = &at
		memCancels[s][tenant] = c
		s.opAudit = append(s.opAudit, purgeAudit(tenant, at))
		res.Purged = append(res.Purged, tenant)
	}
	sort.Strings(res.Purged)
	sort.Strings(res.Held)
	return res, nil
}

// unpaidInvoice: tenant holds an invoice with no paid_at. The caller holds mu.
func (s *Memory) unpaidInvoice(tenant string) bool {
	for _, inv := range memInvoices[s] {
		if inv.Tenant == tenant && inv.PaidAt == nil {
			return true
		}
	}
	return false
}

// dropTenant removes tenant and what the Memory store keys by it, as the
// cascade does in Postgres; its invoices stay (rdb 0322). The caller holds mu.
func (s *Memory) dropTenant(tenant string) {
	delete(s.tenants, tenant)
	for k := range s.pins {
		if k[0] == tenant {
			delete(s.pins, k)
		}
	}
	for h, j := range s.joins {
		if j.TenantID == tenant {
			delete(s.joins, h)
		}
	}
	delete(memPlans[s], tenant)
	delete(s.boxJoinOn, tenant)
	delete(s.vendorKeys, tenant)
}

// Postgres side.
const (
	cancelCols    = `tenant_id, cancelled_at, purge_after, purged_at, actor_tenant, actor_hum`
	cancelReadSQL = `SELECT ` + cancelCols + ` FROM workspace_cancellations WHERE tenant_id = $1`
	cancelPutSQL  = `INSERT INTO workspace_cancellations (tenant_id, cancelled_at, purge_after, actor_tenant, actor_hum)
		VALUES ($1, $2, $3, $4, $5) ON CONFLICT (tenant_id) DO NOTHING`
	cancelPinsSQL = `WITH r AS (UPDATE pins SET revoked_at = $2 WHERE tenant_id = $1 AND revoked_at IS NULL
			RETURNING box_id, pubkey),
		h AS (INSERT INTO pins_history (tenant_id, box_id, pubkey, at, reason)
			SELECT $1, box_id, pubkey, $2, 'revoke' FROM r)
		SELECT box_id FROM r ORDER BY box_id`
	cancelTokensSQL = `UPDATE agent_join_tokens SET revoked_at = $2
		WHERE tenant_id = $1 AND consumed_at IS NULL AND revoked_at IS NULL`
	cancelAuditSQL = `INSERT INTO operator_audit (at, tenant_id, actor_tenant, actor_hum, action, detail)
		VALUES ($1, $2, $3, $4, $5, $6::jsonb)`
	purgeDueSQL = `SELECT tenant_id FROM workspace_cancellations
		WHERE purged_at IS NULL AND purge_after <= $1 ORDER BY tenant_id`
)

func scanCancel(r pgx.Row) (WorkspaceCancel, error) {
	var c WorkspaceCancel
	err := r.Scan(&c.Tenant, &c.CancelledAt, &c.PurgeAfter, &c.PurgedAt, &c.ActorTenant, &c.ActorHum)
	return c, err
}

func writeOperatorAudit(ctx context.Context, tx pgx.Tx, a OperatorAudit) error {
	detail, err := json.Marshal(a.Detail)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, cancelAuditSQL, a.At, a.TenantID, a.ActorTenant, a.ActorHum, a.Action, string(detail))
	return err
}

// CancelWorkspace runs in the operator scope: it writes the operator-only
// cancellation row and operator_audit (WorkspaceCancels).
func (s *Postgres) CancelWorkspace(ctx context.Context, tenant, actorTenant, actorHum string, now time.Time) (WorkspaceCancel, bool, error) {
	if err := checkCancelActor(tenant, actorTenant, actorHum); err != nil {
		return WorkspaceCancel{}, false, err
	}
	defer s.hot.forget()
	c := newWorkspaceCancel(tenant, actorTenant, actorHum, now)
	created := false
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if err := cancelTarget(ctx, tx, tenant); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, cancelPutSQL, tenant, c.CancelledAt, c.PurgeAfter, actorTenant, actorHum)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			c, err = scanCancel(tx.QueryRow(ctx, cancelReadSQL, tenant))
			return err
		}
		created = true
		return cancelRevoke(ctx, tx, &c)
	})
	if err != nil {
		return WorkspaceCancel{}, false, err
	}
	return c, created, nil
}

// cancelTarget: ErrNotFound without the workspace, ErrNotPrivateWorkspace
// off the private_vm plan.
func cancelTarget(ctx context.Context, tx pgx.Tx, tenant string) error {
	var exists, private bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1),
		EXISTS (SELECT 1 FROM price_plans WHERE tenant_id = $1 AND kind = $2)`, tenant, PlanKindPrivateVM).
		Scan(&exists, &private); err != nil {
		return err
	}
	switch {
	case !exists:
		return ErrNotFound
	case !private:
		return ErrNotPrivateWorkspace
	}
	return nil
}

// cancelRevoke revokes c's pins and open join tokens, turns its joins off
// and writes the audit row, inside the cancel's transaction.
func cancelRevoke(ctx context.Context, tx pgx.Tx, c *WorkspaceCancel) error {
	rows, err := tx.Query(ctx, cancelPinsSQL, c.Tenant, c.CancelledAt)
	if err != nil {
		return err
	}
	if c.RevokedBoxes, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, cancelTokensSQL, c.Tenant, c.CancelledAt)
	if err != nil {
		return err
	}
	c.RevokedTokens = int(tag.RowsAffected())
	if _, err := tx.Exec(ctx, `UPDATE tenants SET box_join_enabled = false WHERE tenant_id = $1`, c.Tenant); err != nil {
		return err
	}
	return writeOperatorAudit(ctx, tx, cancelAudit(*c))
}

// WorkspaceCancellation reads the row in tenant's own scope (WorkspaceCancels).
func (s *Postgres) WorkspaceCancellation(ctx context.Context, tenant string) (WorkspaceCancel, error) {
	if err := checkTenant(tenant); err != nil {
		return WorkspaceCancel{}, err
	}
	var c WorkspaceCancel
	err := s.queryRowTenant(ctx, tenant, cancelReadSQL, []any{tenant},
		&c.Tenant, &c.CancelledAt, &c.PurgeAfter, &c.PurgedAt, &c.ActorTenant, &c.ActorHum)
	if errors.Is(err, pgx.ErrNoRows) {
		return WorkspaceCancel{}, ErrNotFound
	}
	return c, err
}

// PurgeDueWorkspaces lists the due rows in the operator scope, then purges
// each in its own operator transaction, so one that fails holds back no
// other (WorkspaceCancels).
func (s *Postgres) PurgeDueWorkspaces(ctx context.Context, now time.Time) (PurgeResult, error) {
	at := now.UTC().Truncate(time.Microsecond)
	var due []string
	if err := s.asOperatorQuery(ctx, purgeDueSQL, []any{at}, func(r pgx.Rows) error {
		var t string
		err := r.Scan(&t)
		due = append(due, t)
		return err
	}); err != nil {
		return PurgeResult{}, err
	}
	var res PurgeResult
	var errs []error
	for _, tenant := range due {
		purged, err := s.purgeWorkspace(ctx, tenant, at)
		switch {
		case err != nil:
			errs = append(errs, err)
		case purged:
			res.Purged = append(res.Purged, tenant)
		default:
			res.Held = append(res.Held, tenant)
		}
	}
	if len(res.Purged) > 0 {
		s.hot.forget()
	}
	return res, errors.Join(errs...)
}

// purgeWorkspace deletes one due workspace (false = held for an unpaid
// invoice, or purged meanwhile by another hub instance).
func (s *Postgres) purgeWorkspace(ctx context.Context, tenant string, at time.Time) (bool, error) {
	purged := false
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var due, unpaid bool
		err := tx.QueryRow(ctx, `SELECT purged_at IS NULL AND purge_after <= $2 FROM workspace_cancellations
			WHERE tenant_id = $1 FOR UPDATE`, tenant, at).Scan(&due)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !due) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM private_workspace_invoices
			WHERE tenant_id = $1 AND paid_at IS NULL)`, tenant).Scan(&unpaid); err != nil || unpaid {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, tenant); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE workspace_cancellations SET purged_at = $2 WHERE tenant_id = $1`,
			tenant, at); err != nil {
			return err
		}
		purged = true
		return writeOperatorAudit(ctx, tx, purgeAudit(tenant, at))
	})
	return purged && err == nil, err
}
