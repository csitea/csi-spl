package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres side of tax.go (rdb 0326). Only the two scopes below open
// these tables; inTenant alone, asOperator and the Reporting SQL tab read 0
// of their rows.

// pgScopeTaxReader is the tenant scope plus the session's human, in one
// statement: rdb 0326's tax_read then passes a person seated in the tenant.
// Only tax_postgres.go and netvisor_postgres.go set app.human_id
// (TestNetvisorHumanScopeCallers).
const pgScopeTaxReader = `SELECT set_config('app.tenant_id', $1, true), set_config('app.human_id', $2, true)`

// pgScopeTaxIngest is the tenant scope plus rdb 0326's ingest scope, the
// one scope that writes.
const pgScopeTaxIngest = `SELECT set_config('app.tenant_id', $1, true), set_config('app.rls_scope', 'tax_ingest', true)`

// inTaxReader runs fn in one transaction scoped to tenant AND human: it
// reads the tax rows only when human holds a person seat in tenant, and
// writes none.
func (s *Postgres) inTaxReader(ctx context.Context, tenant, human string, fn func(pgx.Tx) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if err := checkHuman(human); err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, budgeted(ctx, pgScopeTaxReader), tenant, human); err != nil {
			return err
		}
		return fn(tx)
	})
}

// inTaxIngest runs fn in one transaction in tenant's tax ingest scope.
func (s *Postgres) inTaxIngest(ctx context.Context, tenant string, fn func(pgx.Tx) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, budgeted(ctx, pgScopeTaxIngest), tenant); err != nil {
			return err
		}
		return fn(tx)
	})
}

// TaxIngest is Tax.TaxIngest.
func (s *Postgres) TaxIngest(ctx context.Context, tenant string, snap TaxSnapshot) (TaxSnapshot, error) {
	snap, err := normTaxSnapshot(snap)
	if err != nil {
		return TaxSnapshot{}, err
	}
	snap.Tenant = tenant
	err = s.inTaxIngest(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO tax_snapshots (tenant_id, snapshot_id, tax_year, taken_at, row_count, filed_by)
			VALUES ($1, $2::uuid, $3, $4, $5, $6) ON CONFLICT (tenant_id, snapshot_id) DO NOTHING`,
			tenant, snap.SnapshotID, snap.TaxYear, snap.TakenAt, len(snap.Documents), snap.FiledBy)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrTaxDuplicate
		}
		if err := taxInsertDocuments(ctx, tx, snap); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM tax_snapshots WHERE tenant_id = $1 AND tax_year = $2
			AND taken_at < $3::timestamptz - make_interval(weeks => $4)
			AND snapshot_id NOT IN (SELECT snapshot_id FROM tax_snapshots WHERE tenant_id = $1 AND tax_year = $2
				ORDER BY taken_at DESC, created_at DESC LIMIT 2)`, tenant, snap.TaxYear, snap.TakenAt, TaxKeepWeeks)
		return err
	})
	if err != nil {
		return TaxSnapshot{}, err
	}
	return snap, nil
}

// taxInsertDocuments files snap's documents with one batched round trip.
func taxInsertDocuments(ctx context.Context, tx pgx.Tx, snap TaxSnapshot) error {
	if len(snap.Documents) == 0 {
		return nil
	}
	b := &pgx.Batch{}
	for _, d := range snap.Documents {
		b.Queue(`INSERT INTO tax_documents (tenant_id, snapshot_id, row_no, arrival_date, kind, doc_type, tax_type, period,
			due_date, category, content_sha256) VALUES ($1, $2::uuid, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
			snap.Tenant, snap.SnapshotID, d.RowNo, d.ArrivalDate, d.Kind, d.DocType, d.TaxType, d.Period,
			nvsDate(d.DueDate), d.Category, d.ContentSHA256)
	}
	return tx.SendBatch(ctx, b).Close()
}

// TaxLatest is Tax.TaxLatest.
func (s *Postgres) TaxLatest(ctx context.Context, tenant, human string, year, n int) ([]TaxSnapshot, []int, error) {
	if n < 1 || n > 4 {
		return nil, nil, taxBad("n")
	}
	snaps, years := []TaxSnapshot{}, []int{}
	err := s.inTaxReader(ctx, tenant, human, func(tx pgx.Tx) error {
		if err := eachRow(ctx, tx, `SELECT DISTINCT tax_year FROM tax_snapshots WHERE tenant_id = $1 ORDER BY 1 DESC`,
			[]any{tenant}, func(r pgx.Rows) error {
				var y int
				if err := r.Scan(&y); err != nil {
					return err
				}
				years = append(years, y)
				return nil
			}); err != nil {
			return err
		}
		if year == 0 && len(years) > 0 {
			year = years[0]
		}
		if err := eachRow(ctx, tx, `SELECT snapshot_id::text, tax_year, taken_at FROM tax_snapshots
			WHERE tenant_id = $1 AND tax_year = $2 ORDER BY taken_at DESC, created_at DESC LIMIT $3`,
			[]any{tenant, year, n}, func(r pgx.Rows) error {
				sn := TaxSnapshot{Tenant: tenant}
				if err := r.Scan(&sn.SnapshotID, &sn.TaxYear, &sn.TakenAt); err != nil {
					return err
				}
				snaps = append(snaps, sn)
				return nil
			}); err != nil {
			return err
		}
		for i := range snaps {
			docs, err := taxReadDocuments(ctx, tx, snaps[i])
			if err != nil {
				return err
			}
			snaps[i].Documents = docs
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	return snaps, years, nil
}

func taxReadDocuments(ctx context.Context, tx pgx.Tx, snap TaxSnapshot) ([]TaxDocument, error) {
	out := []TaxDocument{}
	err := eachRow(ctx, tx, `SELECT row_no, arrival_date, kind, doc_type, tax_type, period, due_date, category, content_sha256
		FROM tax_documents WHERE tenant_id = $1 AND snapshot_id = $2::uuid ORDER BY row_no`,
		[]any{snap.Tenant, snap.SnapshotID}, func(r pgx.Rows) error {
			var d TaxDocument
			var due *time.Time
			if err := r.Scan(&d.RowNo, &d.ArrivalDate, &d.Kind, &d.DocType, &d.TaxType, &d.Period, &due, &d.Category,
				&d.ContentSHA256); err != nil {
				return err
			}
			if due != nil {
				d.DueDate = *due
			}
			out = append(out, d)
			return nil
		})
	return out, err
}
