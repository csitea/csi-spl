package store

import (
	"context"
	"errors"
	"slices"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// A workspace's own vendor keys (spec 127 v1.4 4.2-4.3 and 5.1, spec 159 T1;
// rdb 0174, 0232). The hub seals the key before it reaches the store
// (internal/vendorkey), so nothing here ever holds a plaintext key: a row is
// ciphertext, the KMS-wrapped data key, last4 and the keyed fingerprint.
// Every write and its audit row are one transaction.

// VendorKeyKinds are the five kinds of rdb 0174's CHECK, in spec 127's order.
var VendorKeyKinds = []string{"claude", "grok", "agy", "mistral", "qwen"}

// Vendor key audit actions this file writes (rdb 0174 has the rest).
const (
	VendorKeySet          = "set"
	VendorKeyReplace      = "replace"
	VendorKeyRemove       = "remove"
	VendorKeyAdminConfirm = "admin_confirm"
)

// VendorKeyRow is what a read returns: never the ciphertext, the wrapped
// key or the fingerprint.
type VendorKeyRow struct {
	Kind    string
	Last4   string
	BaseURL string
	SetBy   string
	SetAt   time.Time
}

// VendorKeyPut is one sealed key to store.
type VendorKeyPut struct {
	Kind          string
	KeyID         string // a fresh UUID per set or replace
	Ciphertext    []byte
	WrappedDEK    []byte
	KMSKeyVersion string
	Last4         string
	Fingerprint   string
	BaseURL       string // qwen only
	Actor         string // the HUM-* who set it
}

// VendorKeys is implemented by Memory and Postgres.
type VendorKeys interface {
	// VendorKeys is every kind the workspace holds a key for, by kind.
	VendorKeys(ctx context.Context, tenant string) ([]VendorKeyRow, error)
	// PutVendorKey sets or replaces the kind's key and writes its set or
	// replace audit row; replaced says which. ErrNotFound: no tenant.
	PutVendorKey(ctx context.Context, tenant string, p VendorKeyPut, now time.Time) (replaced bool, err error)
	// DeleteVendorKey removes the kind's key and writes its remove audit
	// row, answering the removed key's last4. ErrNotFound: no such key.
	DeleteVendorKey(ctx context.Context, tenant, kind, actor string, now time.Time) (last4 string, err error)
	// VendorKeyManagerConfirmed reports whether human may write keys as far
	// as provenance goes (127 Q-4 A, 159 3): false only for a membership
	// admitted by 'operator' or 'bootstrap', in a workspace that holds a
	// key, with no admin_confirm row naming it since it was admitted.
	// ErrNotFound: not a member.
	VendorKeyManagerConfirmed(ctx context.Context, tenant, human string) (bool, error)
	// ConfirmVendorKeyManager writes the admin_confirm audit row for human
	// by by. ErrNotFound: human is not a member.
	ConfirmVendorKeyManager(ctx context.Context, tenant, human, by string, now time.Time) error
}

var (
	_ VendorKeys = (*Memory)(nil)
	_ VendorKeys = (*Postgres)(nil)
)

// operatorMade is a membership admitted by the operator or the bootstrap.
func operatorMade(admittedBy string) bool {
	return admittedBy == AdmittedOperator || admittedBy == AdmittedBootstrap
}

// ---- Memory -----------------------------------------------------------------

type memVendorKey struct {
	VendorKeyPut
	setAt time.Time
}

type memVendorKeyAudit struct {
	tenant, kind, action, actor, last4, subject string
	at                                          time.Time
}

func (s *Memory) VendorKeys(_ context.Context, tenant string) ([]VendorKeyRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []VendorKeyRow{}
	for _, k := range s.vendorKeys[tenant] {
		out = append(out, VendorKeyRow{Kind: k.Kind, Last4: k.Last4, BaseURL: k.BaseURL, SetBy: k.Actor, SetAt: k.setAt})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Kind < out[j].Kind })
	return out, nil
}

func (s *Memory) PutVendorKey(_ context.Context, tenant string, p VendorKeyPut, now time.Time) (bool, error) {
	if !slices.Contains(VendorKeyKinds, p.Kind) {
		return false, errors.New("store: unknown vendor key kind")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return false, ErrNotFound
	}
	if s.vendorKeys == nil {
		s.vendorKeys = map[string]map[string]memVendorKey{}
	}
	if s.vendorKeys[tenant] == nil {
		s.vendorKeys[tenant] = map[string]memVendorKey{}
	}
	_, replaced := s.vendorKeys[tenant][p.Kind]
	p.Ciphertext, p.WrappedDEK = slices.Clone(p.Ciphertext), slices.Clone(p.WrappedDEK)
	s.vendorKeys[tenant][p.Kind] = memVendorKey{VendorKeyPut: p, setAt: now.UTC()}
	action := VendorKeySet
	if replaced {
		action = VendorKeyReplace
	}
	s.vendorKeyAudit = append(s.vendorKeyAudit, memVendorKeyAudit{tenant: tenant, kind: p.Kind, action: action,
		actor: p.Actor, last4: p.Last4, at: now.UTC()})
	return replaced, nil
}

func (s *Memory) DeleteVendorKey(_ context.Context, tenant, kind, actor string, now time.Time) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := s.vendorKeys[tenant][kind]
	if !ok {
		return "", ErrNotFound
	}
	delete(s.vendorKeys[tenant], kind)
	s.vendorKeyAudit = append(s.vendorKeyAudit, memVendorKeyAudit{tenant: tenant, kind: kind, action: VendorKeyRemove,
		actor: actor, last4: k.Last4, at: now.UTC()})
	return k.Last4, nil
}

func (s *Memory) VendorKeyManagerConfirmed(_ context.Context, tenant, human string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.hum.members[[2]string{tenant, human}]
	if !ok {
		return false, ErrNotFound
	}
	if !operatorMade(m.admittedBy) || len(s.vendorKeys[tenant]) == 0 {
		return true, nil
	}
	for _, a := range s.vendorKeyAudit {
		if a.tenant == tenant && a.action == VendorKeyAdminConfirm && a.subject == human && !a.at.Before(m.since) {
			return true, nil
		}
	}
	return false, nil
}

func (s *Memory) ConfirmVendorKeyManager(_ context.Context, tenant, human, by string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.hum.members[[2]string{tenant, human}]; !ok {
		return ErrNotFound
	}
	s.vendorKeyAudit = append(s.vendorKeyAudit, memVendorKeyAudit{tenant: tenant, action: VendorKeyAdminConfirm,
		actor: by, subject: human, at: now.UTC()})
	return nil
}

// ---- Postgres ---------------------------------------------------------------

func (s *Postgres) VendorKeys(ctx context.Context, tenant string) ([]VendorKeyRow, error) {
	out := []VendorKeyRow{}
	err := s.queryTenant(ctx, tenant, `SELECT kind, last4, coalesce(base_url, ''), set_by, set_at
		FROM workspace_vendor_keys WHERE tenant_id = $1 ORDER BY kind`, []any{tenant}, func(rows pgx.Rows) error {
		var r VendorKeyRow
		if err := rows.Scan(&r.Kind, &r.Last4, &r.BaseURL, &r.SetBy, &r.SetAt); err != nil {
			return err
		}
		r.SetAt = r.SetAt.UTC()
		out = append(out, r)
		return nil
	})
	return out, err
}

func (s *Postgres) PutVendorKey(ctx context.Context, tenant string, p VendorKeyPut, now time.Time) (bool, error) {
	var replaced bool
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// xmax <> 0 on the returned row: the ON CONFLICT branch ran (a replace).
		if err := tx.QueryRow(ctx, `INSERT INTO workspace_vendor_keys
			(tenant_id, kind, key_id, ciphertext, wrapped_dek, kms_key_version, last4, fingerprint, base_url, set_by, set_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULLIF($9, ''), $10, $11)
			ON CONFLICT (tenant_id, kind) DO UPDATE SET key_id = EXCLUDED.key_id, ciphertext = EXCLUDED.ciphertext,
				wrapped_dek = EXCLUDED.wrapped_dek, kms_key_version = EXCLUDED.kms_key_version, last4 = EXCLUDED.last4,
				fingerprint = EXCLUDED.fingerprint, base_url = EXCLUDED.base_url, set_by = EXCLUDED.set_by,
				set_at = EXCLUDED.set_at
			RETURNING xmax <> 0`, tenant, p.Kind, p.KeyID, p.Ciphertext, p.WrappedDEK, p.KMSKeyVersion, p.Last4,
			p.Fingerprint, p.BaseURL, p.Actor, now.UTC()).Scan(&replaced); err != nil {
			return err
		}
		action := VendorKeySet
		if replaced {
			action = VendorKeyReplace
		}
		_, err := tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, kind, action, actor, at, last4)
			VALUES ($1, $2, $3, $4, $5, $6)`, tenant, p.Kind, action, p.Actor, now.UTC(), p.Last4)
		return err
	})
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "23503" { // tenant_id REFERENCES tenants
		return false, ErrNotFound
	}
	return replaced, err
}

func (s *Postgres) DeleteVendorKey(ctx context.Context, tenant, kind, actor string, now time.Time) (string, error) {
	var last4 string
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `DELETE FROM workspace_vendor_keys WHERE tenant_id = $1 AND kind = $2 RETURNING last4`,
			tenant, kind).Scan(&last4)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, kind, action, actor, at, last4)
			VALUES ($1, $2, 'remove', $3, $4, $5)`, tenant, kind, actor, now.UTC(), last4)
		return err
	})
	return last4, err
}

func (s *Postgres) VendorKeyManagerConfirmed(ctx context.Context, tenant, human string) (bool, error) {
	var confirmed, found bool
	err := s.queryTenant(ctx, tenant, `SELECT m.admitted_by NOT IN ('operator', 'bootstrap')
			OR NOT EXISTS (SELECT 1 FROM workspace_vendor_keys k WHERE k.tenant_id = m.tenant_id)
			OR EXISTS (SELECT 1 FROM workspace_vendor_key_audit a WHERE a.tenant_id = m.tenant_id
				AND a.action = 'admin_confirm' AND a.subject = m.human_id AND a.at >= m.created_at)
		FROM tenant_memberships m WHERE m.tenant_id = $1 AND m.human_id = $2`, []any{tenant, human}, func(rows pgx.Rows) error {
		found = true
		return rows.Scan(&confirmed)
	})
	if err == nil && !found {
		return false, ErrNotFound
	}
	return confirmed, err
}

func (s *Postgres) ConfirmVendorKeyManager(ctx context.Context, tenant, human, by string, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO workspace_vendor_key_audit (tenant_id, action, actor, at, subject)
			SELECT $1, 'admin_confirm', $3, $4, $2
			WHERE EXISTS (SELECT 1 FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2)`,
			tenant, human, by, now.UTC())
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}
