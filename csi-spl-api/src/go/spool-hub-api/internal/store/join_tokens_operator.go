package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The operator join-token mint (spec 181 row B7, 4.2; spec 122 4 point 5):
// the spool-hub admin mints, for a private workspace <tenant>, a one-use join
// token bound to the box id of its private VM <vm>. The token is a spec 073
// token like a workspace admin's (same table, same redeem), with two
// differences: the box id is required, and <vm> serves one workspace only
// (spec 181 Q-3 A), so the mint is refused while <vm> is seated, or bound by
// an open token, in any other workspace. That check reads every workspace's
// pins and tokens, so the mint runs in the operator scope; the token row and
// its operator_audit row (action mint_join_token, rdb 0316) are one
// transaction: no token without its audit row.

// AuditMintJoinToken is the operator_audit action of an operator mint (rdb 0316).
const AuditMintJoinToken = "mint_join_token"

var (
	// ErrJoinTokenUnbound: an operator mint names no box id; it always binds one.
	ErrJoinTokenUnbound = errors.New("store: an operator join token is bound to a box id")
	// ErrVMBoundElsewhere: the box id is live-seated, or bound by an open
	// token, in another workspace; a private VM serves one workspace.
	ErrVMBoundElsewhere = errors.New("store: the box id is seated or bound in another workspace")
)

// OperatorJoinMint is implemented by Memory and Postgres.
type OperatorJoinMint interface {
	// MintOperatorJoinToken stores t (Hash, TenantID, CreatedBy = the
	// operator admin, BoxID, ExpiresAt required) and one operator_audit row
	// in t.TenantID by (actorTenant, t.CreatedBy), in one transaction.
	// ErrJoinTokenUnbound without a box id, ErrNotFound without the
	// workspace, ErrVMBoundElsewhere when another workspace holds the box id.
	MintOperatorJoinToken(ctx context.Context, t JoinToken, actorTenant string) error
}

var (
	_ OperatorJoinMint = (*Memory)(nil)
	_ OperatorJoinMint = (*Postgres)(nil)
)

// operatorMintAudit is the audit row of t: the token's public id and what it
// is bound to, never the token, its hash or its label (free text).
func operatorMintAudit(t JoinToken, actorTenant string) OperatorAudit {
	return OperatorAudit{At: t.CreatedAt.UTC(), TenantID: t.TenantID, ActorTenant: actorTenant, ActorHum: t.CreatedBy,
		Action: AuditMintJoinToken, Detail: map[string]any{"join_token": t.ID(), "box_id": t.BoxID,
			"expires_at": t.ExpiresAt.UTC().Format(time.RFC3339)}}
}

func checkOperatorMint(t JoinToken) error {
	if err := checkTenant(t.TenantID); err != nil {
		return err
	}
	if t.BoxID == "" {
		return ErrJoinTokenUnbound
	}
	return nil
}

// MintOperatorJoinToken is the Memory twin of the Postgres mint: the same
// checks and the same audit row, under mu.
func (s *Memory) MintOperatorJoinToken(_ context.Context, t JoinToken, actorTenant string) error {
	if err := checkOperatorMint(t); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[t.TenantID]; !ok {
		return ErrNotFound
	}
	if t.CreatedAt.IsZero() {
		t.CreatedAt = s.now()
	}
	if s.vmBoundElsewhere(t) {
		return ErrVMBoundElsewhere
	}
	if s.joins == nil {
		s.joins = map[string]*JoinToken{}
	}
	if _, ok := s.joins[t.Hash]; ok {
		return ErrConflict
	}
	s.joins[t.Hash] = &t
	s.opAudit = append(s.opAudit, operatorMintAudit(t, actorTenant))
	return nil
}

// vmBoundElsewhere: t.BoxID is live-pinned, or bound by an open token, in a
// workspace other than t.TenantID. The caller holds mu.
func (s *Memory) vmBoundElsewhere(t JoinToken) bool {
	for k, p := range s.pins {
		if k[0] != t.TenantID && k[1] == t.BoxID && !p.revoked {
			return true
		}
	}
	for _, o := range s.joins {
		if o.TenantID != t.TenantID && o.BoxID == t.BoxID && o.State() == "open" && t.CreatedAt.Before(o.ExpiresAt) {
			return true
		}
	}
	return false
}

// MintOperatorJoinToken runs in the operator scope: the box id check reads
// every workspace (see the file comment). A per-box advisory lock serialises
// two mints of the same box id for two workspaces.
func (s *Postgres) MintOperatorJoinToken(ctx context.Context, t JoinToken, actorTenant string) error {
	if err := checkOperatorMint(t); err != nil {
		return err
	}
	if t.CreatedAt.IsZero() {
		t.CreatedAt = time.Now()
	}
	a := operatorMintAudit(t, actorTenant)
	detail, err := json.Marshal(a.Detail)
	if err != nil {
		return err
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		if err := operatorMintCheck(ctx, tx, t); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO agent_join_tokens
			(token_hash, tenant_id, created_by, for_human, label, box_id, created_at, expires_at)
			VALUES ($1, $2, $3, NULL, $4, $5, $6, $7)`,
			t.Hash, t.TenantID, t.CreatedBy, t.Label, t.BoxID, t.CreatedAt, t.ExpiresAt); err != nil {
			if isUniqueViolation(err) {
				return ErrConflict
			}
			return mapFK(err)
		}
		_, err := tx.Exec(ctx, `INSERT INTO operator_audit (at, tenant_id, actor_tenant, actor_hum, action, detail)
			VALUES ($1, $2, $3, $4, $5, $6::jsonb)`, a.At, a.TenantID, a.ActorTenant, a.ActorHum, a.Action, string(detail))
		return err
	})
}

// operatorMintCheck takes the per-box lock, then answers ErrNotFound without
// the workspace and ErrVMBoundElsewhere when another workspace holds the box.
func operatorMintCheck(ctx context.Context, tx pgx.Tx, t JoinToken) error {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 181))`, "vm:"+t.BoxID); err != nil {
		return err
	}
	var exists, elsewhere bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1),
		EXISTS (SELECT 1 FROM pins WHERE box_id = $2 AND tenant_id <> $1 AND revoked_at IS NULL)
		OR EXISTS (SELECT 1 FROM agent_join_tokens WHERE box_id = $2 AND tenant_id <> $1
			AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > $3)`,
		t.TenantID, t.BoxID, t.CreatedAt).Scan(&exists, &elsewhere); err != nil {
		return err
	}
	switch {
	case !exists:
		return ErrNotFound
	case elsewhere:
		return ErrVMBoundElsewhere
	}
	return nil
}
