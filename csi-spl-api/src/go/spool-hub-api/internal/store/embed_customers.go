package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// EmbedCustomer is one embed_customers row (rdb 0169, specs/121 section 5):
// one site that embeds a workspace's visitor chat. JWTPublicKey is only the
// PUBLIC half of the per-embed key; the private half is the customer's and
// never reaches the hub.
type EmbedCustomer struct {
	TenantID       string
	EmbedID        string
	AllowedOrigins []string
	JWTPublicKey   string // "" = no signed-in customer path
	JWTKeyID       string
	Enabled        bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

const pgEmbedCustomerCols = `tenant_id, embed_id, allowed_origins, coalesce(jwt_public_key, ''), coalesce(jwt_key_id, ''),
	enabled, created_at, updated_at`

func scanEmbedCustomer(r pgx.Row) (EmbedCustomer, error) {
	var e EmbedCustomer
	err := r.Scan(&e.TenantID, &e.EmbedID, &e.AllowedOrigins, &e.JWTPublicKey, &e.JWTKeyID, &e.Enabled, &e.CreatedAt, &e.UpdatedAt)
	return e, err
}

// EmbedCustomer reads one embed by its id, the e= of the iframe URL and the
// <embed-id> of /v1/embed/<embed-id>/* (unique hub-wide). The visitor's
// request names no workspace, so the row is read under the operator scope
// and names it; the caller checks Enabled. ErrNotFound when there is none.
func (s *Postgres) EmbedCustomer(ctx context.Context, embedID string) (EmbedCustomer, error) {
	var e EmbedCustomer
	found := false
	err := s.asOperatorQuery(ctx, `SELECT `+pgEmbedCustomerCols+` FROM embed_customers WHERE embed_id = $1`,
		[]any{embedID}, func(r pgx.Rows) (err error) {
			e, err = scanEmbedCustomer(r)
			found = err == nil
			return err
		})
	if err == nil && !found {
		err = ErrNotFound
	}
	return e, err
}

// EmbedCustomers lists tenant's embeds, oldest first: the staff side (the
// embed admin page, T203), under the tenant scope.
func (s *Postgres) EmbedCustomers(ctx context.Context, tenant string) ([]EmbedCustomer, error) {
	var out []EmbedCustomer
	err := s.queryTenant(ctx, tenant, `SELECT `+pgEmbedCustomerCols+` FROM embed_customers
		WHERE tenant_id = $1 ORDER BY created_at, embed_id`, []any{tenant}, func(r pgx.Rows) error {
		e, err := scanEmbedCustomer(r)
		out = append(out, e)
		return err
	})
	return out, err
}

// embedEnabledTx reports, inside a visitor transaction, whether embed is an
// enabled embed of the transaction's tenant: ErrNotFound when it is not.
func embedEnabledTx(ctx context.Context, tx pgx.Tx, tenant, embed string) error {
	var on bool
	err := tx.QueryRow(ctx, `SELECT enabled FROM embed_customers WHERE tenant_id = $1 AND embed_id = $2`, tenant, embed).Scan(&on)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !on) {
		return ErrNotFound
	}
	return err
}
