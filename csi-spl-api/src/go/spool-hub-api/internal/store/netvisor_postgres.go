package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres side of netvisor.go (rdb 0255). Only the two scopes below
// open these tables; inTenant alone, asOperator and the Reporting SQL tab
// read 0 of their rows.

// pgScopeNetvisorOwner is the tenant scope plus rdb 0255's owner scope, in
// one statement, so no moment of the transaction holds one without the
// other. Only inNetvisorOwner and NetvisorIngest set app.human_id
// (TestNetvisorHumanScopeCallers).
const pgScopeNetvisorOwner = `SELECT set_config('app.tenant_id', $1, true), set_config('app.human_id', $2, true)`

// pgScopeNetvisorIngest is the tenant scope plus rdb 0255's ingest scope,
// which reaches netvisor_settings alone.
const pgScopeNetvisorIngest = `SELECT set_config('app.tenant_id', $1, true), set_config('app.rls_scope', 'netvisor_ingest', true)`

// pgNetvisorIngestAsOwner leaves the ingest scope for the owner's, inside
// the ingest transaction.
const pgNetvisorIngestAsOwner = `SELECT set_config('app.rls_scope', '', true), set_config('app.human_id', $1, true)`

// inNetvisorOwner runs fn in one transaction scoped to tenant AND its
// Netvisor owner human. A statement in fn reads and writes only the rows
// filed under human: for anyone but the owner, none.
func (s *Postgres) inNetvisorOwner(ctx context.Context, tenant, human string, fn func(pgx.Tx) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if err := checkHuman(human); err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, budgeted(ctx, pgScopeNetvisorOwner), tenant, human); err != nil {
			return err
		}
		return fn(tx)
	})
}

// inNetvisorIngest runs fn in one transaction in tenant's ingest scope:
// netvisor_settings only.
func (s *Postgres) inNetvisorIngest(ctx context.Context, tenant string, fn func(pgx.Tx) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, budgeted(ctx, pgScopeNetvisorIngest), tenant); err != nil {
			return err
		}
		return fn(tx)
	})
}

const nvsSettingsCols = `owner_human_id, env, COALESCE(bank_account, ''), vat_accounts, tax_accounts, vendor_exclusions,
	updated_by, updated_at, refresh_requested_at`

func scanNetvisorSettings(row pgx.Row, tenant string) (NetvisorSettings, error) {
	st := NetvisorSettings{Tenant: tenant}
	err := row.Scan(&st.OwnerHumanID, &st.Env, &st.BankAccount, &st.VATAccounts, &st.TaxAccounts,
		&st.VendorExclusions, &st.UpdatedBy, &st.UpdatedAt, &st.RefreshRequestedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, ErrNotFound
	}
	return st, err
}

// NetvisorSetOwner is Netvisor.NetvisorSetOwner: it creates the settings
// row (env test) or moves an existing one to human. Snapshots already
// filed stay under the human they were filed under.
func (s *Postgres) NetvisorSetOwner(ctx context.Context, tenant, human, by string, now time.Time) error {
	if err := checkHuman(human); err != nil {
		return err
	}
	if by == "" || len(by) > 200 {
		return nvsBad("updated_by")
	}
	err := s.inNetvisorIngest(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO netvisor_settings (tenant_id, owner_human_id, updated_by, updated_at)
			VALUES ($1, $2, $3, $4)
			ON CONFLICT (tenant_id) DO UPDATE SET owner_human_id = EXCLUDED.owner_human_id,
				updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at`, tenant, human, by, now)
		return err
	})
	return mapFK(err) // no such workspace: the tenants FK, ErrNotFound
}

// NetvisorSettings is Netvisor.NetvisorSettings.
func (s *Postgres) NetvisorSettings(ctx context.Context, tenant, human string) (NetvisorSettings, error) {
	var st NetvisorSettings
	err := s.inNetvisorOwner(ctx, tenant, human, func(tx pgx.Tx) (err error) {
		st, err = scanNetvisorSettings(tx.QueryRow(ctx, `SELECT `+nvsSettingsCols+` FROM netvisor_settings WHERE tenant_id = $1`, tenant), tenant)
		return err
	})
	return st, err
}

// NetvisorPutSettings is Netvisor.NetvisorPutSettings. The owner is not a
// column it writes: only NetvisorSetOwner moves it.
func (s *Postgres) NetvisorPutSettings(ctx context.Context, tenant, human string, in NetvisorSettings, now time.Time) (NetvisorSettings, error) {
	in, err := normNetvisorSettings(in)
	if err != nil {
		return NetvisorSettings{}, err
	}
	var st NetvisorSettings
	err = s.inNetvisorOwner(ctx, tenant, human, func(tx pgx.Tx) (err error) {
		st, err = scanNetvisorSettings(tx.QueryRow(ctx, `UPDATE netvisor_settings SET env = $2, bank_account = NULLIF($3, ''),
			vat_accounts = $4, tax_accounts = $5, vendor_exclusions = $6, updated_by = $7, updated_at = $8
			WHERE tenant_id = $1 RETURNING `+nvsSettingsCols,
			tenant, in.Env, in.BankAccount, in.VATAccounts, in.TaxAccounts, in.VendorExclusions, human, now), tenant)
		return err
	})
	return st, err
}

// NetvisorIngest is Netvisor.NetvisorIngest: in the ingest scope it reads
// the owner and env from netvisor_settings, then files the snapshot, its
// items and its lines in that owner's scope, in one transaction.
func (s *Postgres) NetvisorIngest(ctx context.Context, tenant string, snap NetvisorSnapshot) (NetvisorSnapshot, error) {
	snap, err := normNetvisorSnapshot(snap)
	if err != nil {
		return NetvisorSnapshot{}, err
	}
	snap.Tenant = tenant
	err = s.inNetvisorIngest(ctx, tenant, func(tx pgx.Tx) error {
		var env string
		err := tx.QueryRow(ctx, `SELECT owner_human_id, env FROM netvisor_settings WHERE tenant_id = $1`, tenant).Scan(&snap.OwnerHumanID, &env)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNetvisorNoOwner
		}
		if err != nil {
			return err
		}
		if snap.Env == "" {
			snap.Env = env
		}
		if snap.Env != env {
			return ErrNetvisorEnv
		}
		// The snapshot answers an open "Refresh now" made before it was
		// fetched (rdb 0257); a later request stays open.
		if _, err := tx.Exec(ctx, `UPDATE netvisor_settings SET refresh_requested_at = NULL
			WHERE tenant_id = $1 AND refresh_requested_at <= $2`, tenant, snap.FetchedAt); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, pgNetvisorIngestAsOwner, snap.OwnerHumanID); err != nil {
			return err
		}
		return nvsInsertSnapshot(ctx, tx, snap)
	})
	if err != nil {
		return NetvisorSnapshot{}, err
	}
	return snap, nil
}

// NetvisorRequestRefresh is Netvisor.NetvisorRequestRefresh: an open
// request keeps its first time, so a second press does not push it back.
func (s *Postgres) NetvisorRequestRefresh(ctx context.Context, tenant, human string, now time.Time) (time.Time, error) {
	var at time.Time
	err := s.inNetvisorOwner(ctx, tenant, human, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `UPDATE netvisor_settings SET refresh_requested_at = COALESCE(refresh_requested_at, $2)
			WHERE tenant_id = $1 RETURNING refresh_requested_at`, tenant, now).Scan(&at)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return at, err
}

// NetvisorRefreshRequested is Netvisor.NetvisorRefreshRequested.
func (s *Postgres) NetvisorRefreshRequested(ctx context.Context, tenant string) (*time.Time, error) {
	var at *time.Time
	err := s.inNetvisorIngest(ctx, tenant, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT refresh_requested_at FROM netvisor_settings WHERE tenant_id = $1`, tenant).Scan(&at)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNetvisorNoOwner
		}
		return err
	})
	return at, err
}

// nvsInsertSnapshot writes snap and its rows; the caller holds the owner's
// scope.
func nvsInsertSnapshot(ctx context.Context, tx pgx.Tx, snap NetvisorSnapshot) error {
	if _, err := tx.Exec(ctx, `INSERT INTO netvisor_snapshots (tenant_id, snapshot_id, owner_human_id, env, as_of,
		month_end, newest_bank_voucher_date, fetched_at) VALUES ($1, $2::uuid, $3, $4, $5, $6, $7, $8)`,
		snap.Tenant, snap.SnapshotID, snap.OwnerHumanID, snap.Env, snap.AsOf, snap.MonthEnd,
		nvsDate(snap.NewestBankVoucherDate), snap.FetchedAt); err != nil {
		return err
	}
	if err := nvsInsertItems(ctx, tx, snap); err != nil {
		return err
	}
	return nvsInsertCardLines(ctx, tx, snap)
}

// nvsDate is a nullable date: nil for the zero time.
func nvsDate(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func nvsInsertItems(ctx context.Context, tx pgx.Tx, snap NetvisorSnapshot) error {
	if len(snap.Items) == 0 {
		return nil
	}
	n := len(snap.Items)
	no, sign := make([]int, n), make([]int, n)
	cat, amt, cur, label := make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	due, overdue, approved := make([]*time.Time, n), make([]bool, n), make([]*bool, n)
	for i, it := range snap.Items {
		no[i], cat[i], sign[i], amt[i], cur[i] = it.ItemNo, it.Category, it.Sign, it.Amount, it.Currency
		due[i], overdue[i], approved[i], label[i] = nvsDate(it.DueDate), it.Overdue, it.Approved, it.Label
	}
	_, err := tx.Exec(ctx, `INSERT INTO netvisor_forecast_items (tenant_id, snapshot_id, owner_human_id, item_no, category,
		sign, amount, currency, due_date, overdue, approved, label)
		SELECT $1, $2::uuid, $3, u.no::integer, u.cat, u.sign::smallint, u.amt::numeric, u.cur, u.due, u.overdue, u.approved, u.label
		FROM unnest($4::bigint[], $5::text[], $6::bigint[], $7::text[], $8::text[], $9::date[], $10::bool[], $11::bool[], $12::text[])
			AS u (no, cat, sign, amt, cur, due, overdue, approved, label)`,
		snap.Tenant, snap.SnapshotID, snap.OwnerHumanID, no, cat, sign, amt, cur, due, overdue, approved, label)
	return err
}

func nvsInsertCardLines(ctx context.Context, tx pgx.Tx, snap NetvisorSnapshot) error {
	if len(snap.CardLines) == 0 {
		return nil
	}
	n := len(snap.CardLines)
	no, month, excluded := make([]int, n), make([]time.Time, n), make([]bool, n)
	cols := make([][]string, 9) // route, vendor, account, account name, dimension, item, amount, currency, vat code
	for c := range cols {
		cols[c] = make([]string, n)
	}
	for i, l := range snap.CardLines {
		no[i], month[i], excluded[i] = l.LineNo, l.Month, l.Excluded
		for c, v := range []string{l.Route, l.Vendor, l.AccountNumber, l.AccountName, l.Dimension, l.DimensionItem, l.Amount, l.Currency, l.VATCode} {
			cols[c][i] = v
		}
	}
	_, err := tx.Exec(ctx, `INSERT INTO netvisor_card_cost_lines (tenant_id, snapshot_id, owner_human_id, line_no, month,
		route, vendor, account_number, account_name, dimension, dimension_item, amount, currency, vat_code, excluded)
		SELECT $1, $2::uuid, $3, u.no::integer, u.month, u.route, u.vendor, u.acct, u.acct_name, u.dim, u.dim_item, u.amt::numeric,
			u.cur, u.vat, u.excluded
		FROM unnest($4::bigint[], $5::date[], $6::text[], $7::text[], $8::text[], $9::text[], $10::text[], $11::text[],
			$12::text[], $13::text[], $14::text[], $15::bool[])
			AS u (no, month, route, vendor, acct, acct_name, dim, dim_item, amt, cur, vat, excluded)`,
		snap.Tenant, snap.SnapshotID, snap.OwnerHumanID, no, month, cols[0], cols[1], cols[2], cols[3], cols[4], cols[5],
		cols[6], cols[7], cols[8], excluded)
	return err
}

// NetvisorLatest is Netvisor.NetvisorLatest.
func (s *Postgres) NetvisorLatest(ctx context.Context, tenant, human, env string) (NetvisorSnapshot, error) {
	if !nvsOneOf(env, NetvisorEnvs) {
		return NetvisorSnapshot{}, nvsBad("env")
	}
	var snap NetvisorSnapshot
	err := s.inNetvisorOwner(ctx, tenant, human, func(tx pgx.Tx) error {
		var voucher *time.Time
		err := tx.QueryRow(ctx, `SELECT snapshot_id::text, owner_human_id, env, as_of, month_end, newest_bank_voucher_date, fetched_at
			FROM netvisor_snapshots WHERE tenant_id = $1 AND owner_human_id = $2 AND env = $3
			ORDER BY fetched_at DESC, created_at DESC LIMIT 1`, tenant, human, env).Scan(
			&snap.SnapshotID, &snap.OwnerHumanID, &snap.Env, &snap.AsOf, &snap.MonthEnd, &voucher, &snap.FetchedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if voucher != nil {
			snap.NewestBankVoucherDate = *voucher
		}
		snap.Tenant = tenant
		if snap.Items, err = nvsReadItems(ctx, tx, snap); err != nil {
			return err
		}
		snap.CardLines, err = nvsReadCardLines(ctx, tx, snap)
		return err
	})
	if err != nil {
		return NetvisorSnapshot{}, err
	}
	return snap, nil
}

func nvsReadItems(ctx context.Context, tx pgx.Tx, snap NetvisorSnapshot) ([]NetvisorForecastItem, error) {
	out := []NetvisorForecastItem{}
	err := eachRow(ctx, tx, `SELECT item_no, category, sign, amount::text, currency, due_date, overdue, approved, label
		FROM netvisor_forecast_items WHERE tenant_id = $1 AND snapshot_id = $2::uuid ORDER BY item_no`,
		[]any{snap.Tenant, snap.SnapshotID}, func(r pgx.Rows) error {
			var it NetvisorForecastItem
			var sign int16
			var due *time.Time
			if err := r.Scan(&it.ItemNo, &it.Category, &sign, &it.Amount, &it.Currency, &due, &it.Overdue, &it.Approved, &it.Label); err != nil {
				return err
			}
			it.Sign = int(sign)
			if due != nil {
				it.DueDate = *due
			}
			out = append(out, it)
			return nil
		})
	return out, err
}

func nvsReadCardLines(ctx context.Context, tx pgx.Tx, snap NetvisorSnapshot) ([]NetvisorCardCostLine, error) {
	out := []NetvisorCardCostLine{}
	err := eachRow(ctx, tx, `SELECT line_no, month, route, vendor, account_number, account_name, dimension, dimension_item,
		amount::text, currency, vat_code, excluded
		FROM netvisor_card_cost_lines WHERE tenant_id = $1 AND snapshot_id = $2::uuid ORDER BY line_no`,
		[]any{snap.Tenant, snap.SnapshotID}, func(r pgx.Rows) error {
			var l NetvisorCardCostLine
			if err := r.Scan(&l.LineNo, &l.Month, &l.Route, &l.Vendor, &l.AccountNumber, &l.AccountName, &l.Dimension,
				&l.DimensionItem, &l.Amount, &l.Currency, &l.VATCode, &l.Excluded); err != nil {
				return err
			}
			out = append(out, l)
			return nil
		})
	return out, err
}
