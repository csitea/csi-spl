package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Workspace CRUD by the operator workspace (rdb 0115, spec 074 phase 1). The
// operator routes create a workspace with CreateTenant, rename it and change
// its settings with SetTenantConfig and its billing with SetBillingStatus, the
// same store calls the shell actions use; this file adds only what had no
// store call: the list of every workspace, suspend / resume / archive, and
// the audit trail of every operator action.

// ErrWorkspaceStateUnavailable: this database has no tenants.suspended_at yet
// (rdb 0115 not applied). The hub answers 503 not_migrated.
var ErrWorkspaceStateUnavailable = errors.New("store: workspace suspend/archive needs rdb 0115")

// Operator audit actions (operator_audit.action CHECK, rdb 0115).
const (
	AuditList    = "list"
	AuditRead    = "read"
	AuditCreate  = "create"
	AuditUpdate  = "update"
	AuditSuspend = "suspend"
	AuditResume  = "resume"
	AuditArchive = "archive"
)

// Workspace is one row of the operator's workspace list.
type Workspace struct {
	ID            string
	DisplayName   string
	BillingStatus string
	PlanID        string
	CreatedAt     time.Time // zero in Memory
	SuspendedAt   time.Time // zero = live
	ArchivedAt    time.Time // zero = not archived
}

// OperatorAudit is one operator_audit row: who (ActorTenant, ActorHum) did
// what (Action, Detail) to which workspace (TenantID) when (At).
type OperatorAudit struct {
	At          time.Time
	TenantID    string
	ActorTenant string
	ActorHum    string
	Action      string
	Detail      map[string]any
}

// OperatorWorkspaces is implemented by Memory and Postgres.
type OperatorWorkspaces interface {
	// ListWorkspaces answers every workspace of the instance, by id. It is
	// the one cross-workspace read of the operator routes (asOperator).
	ListWorkspaces(ctx context.Context) ([]Workspace, error)
	// GetWorkspace answers one workspace's row; ErrNotFound when absent.
	GetWorkspace(ctx context.Context, tenant string) (Workspace, error)
	// SetWorkspaceState suspends (suspended=true) or resumes the workspace;
	// archive also stamps archived_at (and suspends). Resume clears both.
	// ErrNotFound: no such workspace.
	SetWorkspaceState(ctx context.Context, tenant string, suspended, archive bool, now time.Time) error
	// AppendOperatorAudit writes one audit row, in the TARGET workspace.
	AppendOperatorAudit(ctx context.Context, a OperatorAudit) error
	// OperatorAuditOf answers the workspace's trail, oldest first, at most limit rows.
	OperatorAuditOf(ctx context.Context, tenant string, limit int) ([]OperatorAudit, error)
}

var (
	_ OperatorWorkspaces = (*Memory)(nil)
	_ OperatorWorkspaces = (*Postgres)(nil)
)

// Suspended reports whether an operator suspended the workspace (rdb 0115).
func (t Tenant) Suspended() bool { return !t.SuspendedAt.IsZero() }

// hasWorkspaceState is the catalogue probe for rdb 0115. The hub may roll
// before the migration reaches its database, so until the column is there
// tenants are read without it: never a 500.
func (s *Postgres) hasWorkspaceState(ctx context.Context) bool {
	return s.wsState.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('tenants') AND attname = 'suspended_at' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, s.now())
}

// workspaceStateCols is the select-list for suspended_at, archived_at: two
// NULLs before rdb 0115, so one scan shape serves both.
func workspaceStateCols(with bool) string {
	if !with {
		return "NULL::timestamptz, NULL::timestamptz"
	}
	return "suspended_at, archived_at"
}

func timeOf(p *time.Time) time.Time {
	if p == nil {
		return time.Time{}
	}
	return p.UTC()
}

func (s *Postgres) workspaceSQL(ctx context.Context) string {
	return `SELECT tenant_id, COALESCE(display_name, ''), billing_status, plan_id, created_at, ` +
		workspaceStateCols(s.hasWorkspaceState(ctx)) + ` FROM tenants`
}

func scanWorkspace(r pgx.Row) (Workspace, error) {
	var w Workspace
	var sus, arc *time.Time
	err := r.Scan(&w.ID, &w.DisplayName, &w.BillingStatus, &w.PlanID, &w.CreatedAt, &sus, &arc)
	w.CreatedAt, w.SuspendedAt, w.ArchivedAt = w.CreatedAt.UTC(), timeOf(sus), timeOf(arc)
	return w, err
}

func (s *Postgres) ListWorkspaces(ctx context.Context) ([]Workspace, error) {
	var out []Workspace
	err := s.asOperatorQuery(ctx, s.workspaceSQL(ctx)+` WHERE tenant_id <> $1 ORDER BY tenant_id`, []any{SystemTenant}, func(r pgx.Rows) error {
		w, err := scanWorkspace(r)
		out = append(out, w)
		return err
	})
	return out, err
}

func (s *Postgres) GetWorkspace(ctx context.Context, tenant string) (Workspace, error) {
	var w Workspace
	err := s.tenantBatch(ctx, tenant, s.workspaceSQL(ctx)+` WHERE tenant_id = $1`, []any{tenant},
		func(br pgx.BatchResults) (err error) {
			w, err = scanWorkspace(br.QueryRow())
			return err
		})
	if errors.Is(err, pgx.ErrNoRows) {
		return Workspace{}, ErrNotFound
	}
	return w, err
}

func (s *Postgres) SetWorkspaceState(ctx context.Context, tenant string, suspended, archive bool, now time.Time) error {
	if !s.hasWorkspaceState(ctx) {
		return ErrWorkspaceStateUnavailable
	}
	defer s.hot.forget() // suspended_at rides the cached tenant row (getTenant)
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET
		suspended_at = CASE WHEN $2 THEN COALESCE(suspended_at, $4) ELSE NULL END,
		archived_at  = CASE WHEN $2 AND $3 THEN COALESCE(archived_at, $4) WHEN $2 THEN archived_at ELSE NULL END
		WHERE tenant_id = $1`, tenant, suspended || archive, archive, now.UTC())
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) AppendOperatorAudit(ctx context.Context, a OperatorAudit) error {
	if a.Detail == nil {
		a.Detail = map[string]any{}
	}
	detail, err := json.Marshal(a.Detail)
	if err != nil {
		return err
	}
	_, err = s.execTenant(ctx, a.TenantID, `INSERT INTO operator_audit (at, tenant_id, actor_tenant, actor_hum, action, detail)
		VALUES ($2, $1, $3, $4, $5, $6::jsonb)`, a.TenantID, a.At.UTC(), a.ActorTenant, a.ActorHum, a.Action, string(detail))
	return err
}

func (s *Postgres) OperatorAuditOf(ctx context.Context, tenant string, limit int) ([]OperatorAudit, error) {
	var out []OperatorAudit
	err := s.queryTenant(ctx, tenant, `SELECT at, tenant_id, actor_tenant, actor_hum, action, detail::text
		FROM (SELECT id, at, tenant_id, actor_tenant, actor_hum, action, detail FROM operator_audit WHERE tenant_id = $1 ORDER BY at DESC, id DESC LIMIT $2) a
		ORDER BY at, id`, []any{tenant, limit}, func(r pgx.Rows) error {
		var a OperatorAudit
		var detail string
		if err := r.Scan(&a.At, &a.TenantID, &a.ActorTenant, &a.ActorHum, &a.Action, &detail); err != nil {
			return err
		}
		a.At = a.At.UTC()
		out = append(out, a)
		return json.Unmarshal([]byte(detail), &out[len(out)-1].Detail)
	})
	return out, err
}

func workspaceOf(t Tenant) Workspace {
	return Workspace{ID: t.ID, DisplayName: t.DisplayName, BillingStatus: t.BillingStatus, PlanID: t.PlanID,
		SuspendedAt: t.SuspendedAt, ArchivedAt: t.ArchivedAt}
}

func (s *Memory) ListWorkspaces(context.Context) ([]Workspace, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Workspace, 0, len(s.tenants))
	for _, t := range s.tenants {
		out = append(out, workspaceOf(t))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (s *Memory) GetWorkspace(_ context.Context, tenant string) (Workspace, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[tenant]
	if !ok {
		return Workspace{}, ErrNotFound
	}
	return workspaceOf(t), nil
}

func (s *Memory) SetWorkspaceState(_ context.Context, tenant string, suspended, archive bool, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[tenant]
	if !ok {
		return ErrNotFound
	}
	now = now.UTC()
	switch {
	case !suspended && !archive:
		t.SuspendedAt, t.ArchivedAt = time.Time{}, time.Time{}
	default:
		if t.SuspendedAt.IsZero() {
			t.SuspendedAt = now
		}
		if archive && t.ArchivedAt.IsZero() {
			t.ArchivedAt = now
		}
	}
	s.tenants[tenant] = t
	return nil
}

func (s *Memory) AppendOperatorAudit(_ context.Context, a OperatorAudit) error {
	if err := checkTenant(a.TenantID); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	a.At = a.At.UTC()
	s.opAudit = append(s.opAudit, a)
	return nil
}

func (s *Memory) OperatorAuditOf(_ context.Context, tenant string, limit int) ([]OperatorAudit, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []OperatorAudit
	for _, a := range s.opAudit {
		if a.TenantID == tenant {
			out = append(out, a)
		}
	}
	if len(out) > limit {
		out = out[len(out)-limit:]
	}
	return out, nil
}

// FleetSeating is spec 158's per-workspace switch (4.2.1, rdb 0230
// tenants.fleet_seating): true lets the fleet desk boxes enrol a key into
// the workspace and seat the role seats in it. The create route sets it
// (true unless the request says false); only the operator workspace writes
// it after that (PATCH /v1/operator/workspaces/{id}, audited), never the
// workspace's own admin.
type FleetSeating interface {
	// FleetSeating reads the switch; ErrNotFound when no such tenant.
	FleetSeating(ctx context.Context, tenant string) (bool, error)
	// SetFleetSeating writes it; ErrNotFound when no such tenant.
	SetFleetSeating(ctx context.Context, tenant string, on bool) error
}

var (
	_ FleetSeating = (*Memory)(nil)
	_ FleetSeating = (*Postgres)(nil)
)

// FleetSeating reads tenants.fleet_seating in the tenant scope.
func (s *Postgres) FleetSeating(ctx context.Context, tenant string) (bool, error) {
	var on bool
	err := s.queryRowTenant(ctx, tenant, `SELECT fleet_seating FROM tenants WHERE tenant_id = $1`,
		[]any{tenant}, &on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	return on, err
}

// SetFleetSeating writes tenants.fleet_seating in the tenant scope.
func (s *Postgres) SetFleetSeating(ctx context.Context, tenant string, on bool) error {
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET fleet_seating = $2 WHERE tenant_id = $1`, tenant, on)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// FleetSeating reads the in-memory switch; missing = off.
func (s *Memory) FleetSeating(_ context.Context, tenant string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return false, ErrNotFound
	}
	return s.fleetSeating[tenant], nil
}

// SetFleetSeating writes the in-memory switch; off deletes the key.
func (s *Memory) SetFleetSeating(_ context.Context, tenant string, on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if s.fleetSeating == nil {
		s.fleetSeating = map[string]bool{}
	}
	if on {
		s.fleetSeating[tenant] = true
	} else {
		delete(s.fleetSeating, tenant)
	}
	return nil
}
