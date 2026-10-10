package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// EmbedAdmin is the workspace owner's side of embed_customers (specs/121
// T203, the embed admin API): list, create, change the origins or the
// switch, and store the PUBLIC half of a new per-embed key. Every call runs
// under the tenant scope; the private half never reaches the store (rdb
// 0169's CHECK refuses a pasted one too).
type EmbedAdmin interface {
	EmbedCustomers(ctx context.Context, tenant string) ([]EmbedCustomer, error)
	CreateEmbedCustomer(ctx context.Context, tenant, embedID string, origins []string) (EmbedCustomer, error)
	UpdateEmbedCustomer(ctx context.Context, tenant, embedID string, origins []string, enabled *bool) (EmbedCustomer, error)
	SetEmbedKey(ctx context.Context, tenant, embedID, publicKeyPEM, keyID string) (EmbedCustomer, error)
}

var (
	// ErrEmbedExists: the embed id is taken (it is unique hub-wide).
	ErrEmbedExists = errors.New("store: embed id already taken")
	// ErrBadEmbed: a value rdb 0169's checks refuse (id shape, more than 32
	// origins, '*', a key that is not a public one).
	ErrBadEmbed = errors.New("store: bad embed value")
)

// embedErr maps the errors of an embed_customers write.
func embedErr(err error) error {
	var pe *pgconn.PgError
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return ErrNotFound
	case errors.As(err, &pe) && pe.Code == "23505":
		return ErrEmbedExists
	case errors.As(err, &pe) && pe.Code == "23514":
		return ErrBadEmbed
	}
	return err
}

// embedWrite runs one embed_customers write under tenant's scope and reads
// the row it wrote back.
func (s *Postgres) embedWrite(ctx context.Context, tenant, sql string, args ...any) (EmbedCustomer, error) {
	var e EmbedCustomer
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) (err error) {
		e, err = scanEmbedCustomer(tx.QueryRow(ctx, sql+` RETURNING `+pgEmbedCustomerCols, args...))
		return err
	})
	return e, embedErr(err)
}

// CreateEmbedCustomer adds a new embed of tenant, disabled and keyless.
func (s *Postgres) CreateEmbedCustomer(ctx context.Context, tenant, embedID string, origins []string) (EmbedCustomer, error) {
	if origins == nil {
		origins = []string{}
	}
	return s.embedWrite(ctx, tenant, `INSERT INTO embed_customers (tenant_id, embed_id, allowed_origins)
		VALUES ($1, $2, $3)`, tenant, embedID, origins)
}

// UpdateEmbedCustomer replaces the origins (nil = keep) and sets the switch
// (nil = keep). ErrNotFound when tenant has no such embed.
func (s *Postgres) UpdateEmbedCustomer(ctx context.Context, tenant, embedID string, origins []string, enabled *bool) (EmbedCustomer, error) {
	return s.embedWrite(ctx, tenant, `UPDATE embed_customers
		SET allowed_origins = coalesce($3::text[], allowed_origins), enabled = coalesce($4::boolean, enabled), updated_at = now()
		WHERE tenant_id = $1 AND embed_id = $2`, tenant, embedID, origins, enabled)
}

// SetEmbedKey stores a new public key and its id, replacing the old pair:
// a JWT signed with the old key stops verifying at once.
func (s *Postgres) SetEmbedKey(ctx context.Context, tenant, embedID, publicKeyPEM, keyID string) (EmbedCustomer, error) {
	return s.embedWrite(ctx, tenant, `UPDATE embed_customers
		SET jwt_public_key = $3, jwt_key_id = $4, updated_at = now()
		WHERE tenant_id = $1 AND embed_id = $2`, tenant, embedID, publicKeyPEM, keyID)
}
