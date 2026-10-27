package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The lease side of a workspace's own vendor keys (spec 127 v1.4 5.1-5.2,
// row H2; spec 159 v0.2 9, row T5; rdb 0174, 0234): the boxes a manager
// approved for keys, the sealed row a lease opens, the vendor's refusal a box
// reports ("exhausted"), the manager's retry, and the workspace's metered
// fall-back switch (off by default). Every write and its audit row are one
// transaction; nothing here holds a plaintext key.

// Vendor key audit actions this file writes (rdb 0174, 0234).
const (
	VendorKeyLease       = "lease"
	VendorKeyBoxApprove  = "box_approve"
	VendorKeyBoxRevoke   = "box_revoke"
	VendorKeyExhausted   = "exhausted"
	VendorKeyRetry       = "retry"
	VendorKeyFallbackOn  = "fallback_on"
	VendorKeyFallbackOff = "fallback_off"
)

var (
	// ErrVendorKeyExhausted: a box reported the vendor's refusal of this
	// kind's key; no lease until a replace or a retry (159 9, point 2).
	ErrVendorKeyExhausted = errors.New("store: vendor key exhausted")
	// ErrVendorKeyBoxNotApproved: no manager approved this box for keys (127 5.1).
	ErrVendorKeyBoxNotApproved = errors.New("store: box not approved for vendor keys")
)

// VendorKeyLeaseRow is the sealed row a lease opens (internal/vendorkey).
type VendorKeyLeaseRow struct {
	KeyID         string
	Ciphertext    []byte
	WrappedDEK    []byte
	KMSKeyVersion string
	Last4         string
	BaseURL       string
}

// String never prints the ciphertext.
func (r VendorKeyLeaseRow) String() string { return "{key_id:" + r.KeyID + " last4:" + r.Last4 + "}" }

// VendorKeyLeases is implemented by Memory and Postgres.
type VendorKeyLeases interface {
	// ApproveVendorKeyBox approves box for tenant's keys with its
	// box_approve audit row; approving it again is a no-op without a row.
	ApproveVendorKeyBox(ctx context.Context, tenant, box, by string, now time.Time) error
	// RevokeVendorKeyBox takes the approval back with its box_revoke audit
	// row. ErrNotFound: the box was not approved.
	RevokeVendorKeyBox(ctx context.Context, tenant, box, by string, now time.Time) error
	// VendorKeyForLease reads the sealed row of kind for box in the tenant's
	// own scope: ErrVendorKeyBoxNotApproved, ErrNotFound (no key), or
	// ErrVendorKeyExhausted, in that order. It writes nothing.
	VendorKeyForLease(ctx context.Context, tenant, kind, box string) (VendorKeyLeaseRow, error)
	// AuditVendorKeyLease writes the lease audit row of an answered lease.
	AuditVendorKeyLease(ctx context.Context, tenant, kind, box, last4 string, now time.Time) error
	// MarkVendorKeyExhausted marks kind's key exhausted, as box reported;
	// first is false when it already was (no second audit row, no second
	// mail: 159 9 point 5). ErrNotFound: no key of that kind.
	MarkVendorKeyExhausted(ctx context.Context, tenant, kind, box string, now time.Time) (first bool, last4 string, err error)
	// RetryVendorKey clears the exhausted state with its retry audit row;
	// cleared is false (and no row) when the key was not exhausted.
	// ErrNotFound: no key of that kind.
	RetryVendorKey(ctx context.Context, tenant, kind, actor string, now time.Time) (cleared bool, err error)
	// VendorKeyMeteredFallback reads the switch; no row = false (the default).
	VendorKeyMeteredFallback(ctx context.Context, tenant string) (bool, error)
	// SetVendorKeyMeteredFallback sets the switch with its fallback_on or
	// fallback_off audit row (none when unchanged). ErrNotFound: no tenant.
	SetVendorKeyMeteredFallback(ctx context.Context, tenant string, on bool, actor string, now time.Time) error
}

var (
	_ VendorKeyLeases = (*Memory)(nil)
	_ VendorKeyLeases = (*Postgres)(nil)
)

// ---- Memory -----------------------------------------------------------------

func (s *Memory) vkAudit(tenant, kind, action, actor, last4, box string, now time.Time) {
	s.vendorKeyAudit = append(s.vendorKeyAudit, memVendorKeyAudit{tenant: tenant, kind: kind, action: action,
		actor: actor, last4: last4, box: box, at: now.UTC()})
}

// ApproveVendorKeyBox approves a key box (VendorKeyLeases).
func (s *Memory) ApproveVendorKeyBox(_ context.Context, tenant, box, by string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if s.vendorKeyBoxes == nil {
		s.vendorKeyBoxes = map[[2]string]bool{}
	}
	if s.vendorKeyBoxes[[2]string{tenant, box}] {
		return nil
	}
	s.vendorKeyBoxes[[2]string{tenant, box}] = true
	s.vkAudit(tenant, "", VendorKeyBoxApprove, by, "", box, now)
	return nil
}

// RevokeVendorKeyBox revokes a key box (VendorKeyLeases).
func (s *Memory) RevokeVendorKeyBox(_ context.Context, tenant, box, by string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.vendorKeyBoxes[[2]string{tenant, box}] {
		return ErrNotFound
	}
	delete(s.vendorKeyBoxes, [2]string{tenant, box})
	s.vkAudit(tenant, "", VendorKeyBoxRevoke, by, "", box, now)
	return nil
}

// VendorKeyForLease reads the sealed row for a lease (VendorKeyLeases).
func (s *Memory) VendorKeyForLease(_ context.Context, tenant, kind, box string) (VendorKeyLeaseRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.vendorKeyBoxes[[2]string{tenant, box}] {
		return VendorKeyLeaseRow{}, ErrVendorKeyBoxNotApproved
	}
	k, ok := s.vendorKeys[tenant][kind]
	if !ok {
		return VendorKeyLeaseRow{}, ErrNotFound
	}
	if !k.exhaustedAt.IsZero() {
		return VendorKeyLeaseRow{}, ErrVendorKeyExhausted
	}
	return VendorKeyLeaseRow{KeyID: k.KeyID, Ciphertext: append([]byte(nil), k.Ciphertext...),
		WrappedDEK: append([]byte(nil), k.WrappedDEK...), KMSKeyVersion: k.KMSKeyVersion, Last4: k.Last4,
		BaseURL: k.BaseURL}, nil
}

// AuditVendorKeyLease writes a lease audit row (VendorKeyLeases).
func (s *Memory) AuditVendorKeyLease(_ context.Context, tenant, kind, box, last4 string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.vkAudit(tenant, kind, VendorKeyLease, box, last4, box, now)
	return nil
}

// MarkVendorKeyExhausted marks a key exhausted (VendorKeyLeases).
func (s *Memory) MarkVendorKeyExhausted(_ context.Context, tenant, kind, box string, now time.Time) (bool, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := s.vendorKeys[tenant][kind]
	if !ok {
		return false, "", ErrNotFound
	}
	if !k.exhaustedAt.IsZero() {
		return false, k.Last4, nil
	}
	k.exhaustedAt = now.UTC()
	s.vendorKeys[tenant][kind] = k
	s.vkAudit(tenant, kind, VendorKeyExhausted, box, k.Last4, box, now)
	return true, k.Last4, nil
}

// RetryVendorKey clears the exhausted state (VendorKeyLeases).
func (s *Memory) RetryVendorKey(_ context.Context, tenant, kind, actor string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := s.vendorKeys[tenant][kind]
	if !ok {
		return false, ErrNotFound
	}
	if k.exhaustedAt.IsZero() {
		return false, nil
	}
	k.exhaustedAt = time.Time{}
	s.vendorKeys[tenant][kind] = k
	s.vkAudit(tenant, kind, VendorKeyRetry, actor, k.Last4, "", now)
	return true, nil
}

// VendorKeyMeteredFallback reads the switch (VendorKeyLeases).
func (s *Memory) VendorKeyMeteredFallback(_ context.Context, tenant string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.vendorKeyFallback[tenant], nil
}

// SetVendorKeyMeteredFallback sets the switch (VendorKeyLeases).
func (s *Memory) SetVendorKeyMeteredFallback(_ context.Context, tenant string, on bool, actor string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if s.vendorKeyFallback == nil {
		s.vendorKeyFallback = map[string]bool{}
	}
	if s.vendorKeyFallback[tenant] == on {
		return nil
	}
	s.vendorKeyFallback[tenant] = on
	s.vkAudit(tenant, "", fallbackAction(on), actor, "", "", now)
	return nil
}

func fallbackAction(on bool) string {
	if on {
		return VendorKeyFallbackOn
	}
	return VendorKeyFallbackOff
}

// ---- Postgres ---------------------------------------------------------------

// ApproveVendorKeyBox approves a key box (VendorKeyLeases).
func (s *Postgres) ApproveVendorKeyBox(ctx context.Context, tenant, box, by string, now time.Time) error {
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO workspace_vendor_key_boxes (tenant_id, box_id, approved_by, approved_at)
			VALUES ($1, $2, $3, $4) ON CONFLICT (tenant_id, box_id) DO NOTHING`, tenant, box, by, now.UTC())
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, action, actor, at, box_id)
			VALUES ($1, 'box_approve', $2, $3, $4)`, tenant, by, now.UTC(), box)
		return err
	})
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "23503" { // tenant_id REFERENCES tenants
		return ErrNotFound
	}
	return err
}

// RevokeVendorKeyBox revokes a key box (VendorKeyLeases).
func (s *Postgres) RevokeVendorKeyBox(ctx context.Context, tenant, box, by string, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM workspace_vendor_key_boxes WHERE tenant_id = $1 AND box_id = $2`, tenant, box)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		_, err = tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, action, actor, at, box_id)
			VALUES ($1, 'box_revoke', $2, $3, $4)`, tenant, by, now.UTC(), box)
		return err
	})
}

// VendorKeyForLease reads the sealed row for a lease (VendorKeyLeases). The
// read runs in the tenant's own scope, so a wrong tenant reads 0 rows even
// with the hub's checks gone (127 L1).
func (s *Postgres) VendorKeyForLease(ctx context.Context, tenant, kind, box string) (VendorKeyLeaseRow, error) {
	var (
		r                 VendorKeyLeaseRow
		approved, haveKey bool
		exhausted         bool
	)
	err := s.queryTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM workspace_vendor_key_boxes b
			WHERE b.tenant_id = $1 AND b.box_id = $3),
		k.key_id IS NOT NULL, coalesce(k.exhausted_at IS NOT NULL, false), coalesce(k.key_id::text, ''),
		coalesce(k.ciphertext, ''::bytea), coalesce(k.wrapped_dek, ''::bytea), coalesce(k.kms_key_version, ''),
		coalesce(k.last4, ''), coalesce(k.base_url, '')
		FROM (SELECT 1) one LEFT JOIN workspace_vendor_keys k ON k.tenant_id = $1 AND k.kind = $2`,
		[]any{tenant, kind, box}, func(rows pgx.Rows) error {
			return rows.Scan(&approved, &haveKey, &exhausted, &r.KeyID, &r.Ciphertext, &r.WrappedDEK,
				&r.KMSKeyVersion, &r.Last4, &r.BaseURL)
		})
	switch {
	case err != nil:
		return VendorKeyLeaseRow{}, err
	case !approved:
		return VendorKeyLeaseRow{}, ErrVendorKeyBoxNotApproved
	case !haveKey:
		return VendorKeyLeaseRow{}, ErrNotFound
	case exhausted:
		return VendorKeyLeaseRow{}, ErrVendorKeyExhausted
	}
	return r, nil
}

// AuditVendorKeyLease writes a lease audit row (VendorKeyLeases).
func (s *Postgres) AuditVendorKeyLease(ctx context.Context, tenant, kind, box, last4 string, now time.Time) error {
	_, err := s.execTenant(ctx, tenant, `INSERT INTO workspace_vendor_key_audit (tenant_id, kind, action, actor, at, last4, box_id)
		VALUES ($1, $2, 'lease', $3, $4, $5, $3)`, tenant, kind, box, now.UTC(), last4)
	return err
}

// MarkVendorKeyExhausted marks a key exhausted (VendorKeyLeases).
func (s *Postgres) MarkVendorKeyExhausted(ctx context.Context, tenant, kind, box string, now time.Time) (bool, string, error) {
	var (
		first bool
		last4 string
	)
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// The row lock serialises two reports of one refusal: one is first.
		var was *time.Time
		err := tx.QueryRow(ctx, `SELECT last4, exhausted_at FROM workspace_vendor_keys
			WHERE tenant_id = $1 AND kind = $2 FOR UPDATE`, tenant, kind).Scan(&last4, &was)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil || was != nil {
			return err
		}
		first = true
		if _, err := tx.Exec(ctx, `UPDATE workspace_vendor_keys SET exhausted_at = $3 WHERE tenant_id = $1 AND kind = $2`,
			tenant, kind, now.UTC()); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, kind, action, actor, at, last4, box_id)
			VALUES ($1, $2, 'exhausted', $3, $4, $5, $3)`, tenant, kind, box, now.UTC(), last4)
		return err
	})
	return first, last4, err
}

// RetryVendorKey clears the exhausted state (VendorKeyLeases).
func (s *Postgres) RetryVendorKey(ctx context.Context, tenant, kind, actor string, now time.Time) (bool, error) {
	var cleared bool
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var (
			last4 string
			was   *time.Time
		)
		err := tx.QueryRow(ctx, `SELECT last4, exhausted_at FROM workspace_vendor_keys
			WHERE tenant_id = $1 AND kind = $2 FOR UPDATE`, tenant, kind).Scan(&last4, &was)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil || was == nil {
			return err
		}
		cleared = true
		if _, err := tx.Exec(ctx, `UPDATE workspace_vendor_keys SET exhausted_at = NULL WHERE tenant_id = $1 AND kind = $2`,
			tenant, kind); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, kind, action, actor, at, last4)
			VALUES ($1, $2, 'retry', $3, $4, $5)`, tenant, kind, actor, now.UTC(), last4)
		return err
	})
	return cleared, err
}

// VendorKeyMeteredFallback reads the switch (VendorKeyLeases).
func (s *Postgres) VendorKeyMeteredFallback(ctx context.Context, tenant string) (bool, error) {
	var on bool
	err := s.queryRowTenant(ctx, tenant, `SELECT metered_fallback FROM workspace_vendor_key_settings WHERE tenant_id = $1`,
		[]any{tenant}, &on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return on, err
}

// SetVendorKeyMeteredFallback sets the switch (VendorKeyLeases).
func (s *Postgres) SetVendorKeyMeteredFallback(ctx context.Context, tenant string, on bool, actor string, now time.Time) error {
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// Changed: no row and on, or a row whose value differs.
		var changed bool
		err := tx.QueryRow(ctx, `WITH prev AS (SELECT metered_fallback FROM workspace_vendor_key_settings
				WHERE tenant_id = $1 FOR UPDATE),
			up AS (INSERT INTO workspace_vendor_key_settings (tenant_id, metered_fallback, set_by, set_at)
				VALUES ($1, $2, $3, $4) ON CONFLICT (tenant_id) DO UPDATE SET metered_fallback = EXCLUDED.metered_fallback,
				set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at
				WHERE workspace_vendor_key_settings.metered_fallback IS DISTINCT FROM EXCLUDED.metered_fallback
				RETURNING 1)
			SELECT coalesce((SELECT metered_fallback FROM prev), false) IS DISTINCT FROM $2`,
			tenant, on, actor, now.UTC()).Scan(&changed)
		if err != nil || !changed {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, action, actor, at)
			VALUES ($1, $3, $2, $4)`, tenant, actor, fallbackAction(on), now.UTC())
		return err
	})
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "23503" {
		return ErrNotFound
	}
	return err
}
