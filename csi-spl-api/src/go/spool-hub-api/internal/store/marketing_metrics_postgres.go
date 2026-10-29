package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres side of marketing_metrics.go (rdb 0244). Every statement runs
// in the tenant's scope (inTenant), so RLS binds it.

const mktSampleCols = `sample_id, source, object_type, object_ref, COALESCE(post_id::text, ''), metric, value::text, unit,
	period_start, period_end, fetched_at, run_id`

const mktDefinitionCols = `metric, version, formula, attribution_rule, attribution_window_days, params,
	COALESCE(signed_off_by, ''), signed_off_at, created_by, created_at`

// AddMarketingMetricSample is MarketingMetrics.AddMarketingMetricSample.
func (s *Postgres) AddMarketingMetricSample(ctx context.Context, tenant string, m MarketingMetricSample, now time.Time) (MarketingMetricSample, error) {
	m, err := normMarketingSample(m, now)
	if err != nil {
		return MarketingMetricSample{}, err
	}
	m.Tenant = tenant
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `INSERT INTO marketing_metric_samples (tenant_id, source, object_type, object_ref, post_id,
			metric, value, unit, period_start, period_end, fetched_at, run_id)
			VALUES ($1, $2, $3, $4, NULLIF($5, '')::uuid, $6, $7::numeric, $8, $9, $10, $11, $12) RETURNING sample_id`,
			tenant, m.Source, m.ObjectType, m.ObjectRef, m.PostID, m.Metric, m.Value, m.Unit,
			m.PeriodStart, m.PeriodEnd, m.FetchedAt, m.RunID).Scan(&m.ID)
	})
	return m, mapFK(err) // no such workspace: the tenants FK, ErrNotFound
}

// AddMarketingMetricDefinition is MarketingMetrics.AddMarketingMetricDefinition.
// The next version is taken under the PRIMARY KEY: a racing writer of the
// same metric gets a unique violation, never a second row of one version.
func (s *Postgres) AddMarketingMetricDefinition(ctx context.Context, tenant string, d MarketingMetricDefinition, now time.Time) (MarketingMetricDefinition, error) {
	d, err := normMarketingDefinition(d)
	if err != nil {
		return MarketingMetricDefinition{}, err
	}
	params, err := json.Marshal(d.Params)
	if err != nil {
		return MarketingMetricDefinition{}, err
	}
	d.Tenant, d.CreatedAt = tenant, now
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `INSERT INTO marketing_metric_definitions (tenant_id, metric, version, formula,
			attribution_rule, attribution_window_days, params, signed_off_by, signed_off_at, created_by, created_at)
			SELECT $1, $2, COALESCE(max(version), 0) + 1, $3, $4, $5, $6::jsonb, NULLIF($7, ''), $8, $9, $10
			FROM marketing_metric_definitions WHERE tenant_id = $1 AND metric = $2
			RETURNING version`,
			tenant, d.Metric, d.Formula, d.AttributionRule, d.AttributionWindowDays, string(params),
			d.SignedOffBy, d.SignedOffAt, d.CreatedBy, now).Scan(&d.Version)
	})
	return d, mapFK(err)
}

// ReadMarketingMetrics is MarketingMetrics.ReadMarketingMetrics.
func (s *Postgres) ReadMarketingMetrics(ctx context.Context, tenant string) (MarketingMetricsRead, error) {
	out := MarketingMetricsRead{Samples: []MarketingMetricSample{}, Definitions: []MarketingMetricDefinition{}}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT DISTINCT ON (source, object_type, object_ref, metric, period_start, period_end) `+mktSampleCols+`
			FROM marketing_metric_samples WHERE tenant_id = $1
			ORDER BY source, object_type, object_ref, metric, period_start, period_end, fetched_at DESC, sample_id DESC`, tenant)
		if err != nil {
			return err
		}
		if out.Samples, err = scanMarketingSamples(rows, tenant); err != nil {
			return err
		}
		rows, err = tx.Query(ctx, `SELECT DISTINCT ON (metric) `+mktDefinitionCols+`
			FROM marketing_metric_definitions WHERE tenant_id = $1 ORDER BY metric, version DESC`, tenant)
		if err != nil {
			return err
		}
		out.Definitions, err = scanMarketingDefinitions(rows, tenant)
		return err
	})
	return out, err
}

func scanMarketingSamples(rows pgx.Rows, tenant string) ([]MarketingMetricSample, error) {
	out := []MarketingMetricSample{}
	err := scanRows(rows, func(r pgx.Rows) error {
		m := MarketingMetricSample{Tenant: tenant}
		if err := r.Scan(&m.ID, &m.Source, &m.ObjectType, &m.ObjectRef, &m.PostID, &m.Metric, &m.Value, &m.Unit,
			&m.PeriodStart, &m.PeriodEnd, &m.FetchedAt, &m.RunID); err != nil {
			return err
		}
		out = append(out, m)
		return nil
	})
	return out, err
}

func scanMarketingDefinitions(rows pgx.Rows, tenant string) ([]MarketingMetricDefinition, error) {
	out := []MarketingMetricDefinition{}
	err := scanRows(rows, func(r pgx.Rows) error {
		d := MarketingMetricDefinition{Tenant: tenant}
		var params []byte
		if err := r.Scan(&d.Metric, &d.Version, &d.Formula, &d.AttributionRule, &d.AttributionWindowDays, &params,
			&d.SignedOffBy, &d.SignedOffAt, &d.CreatedBy, &d.CreatedAt); err != nil {
			return err
		}
		if err := json.Unmarshal(params, &d.Params); err != nil {
			return err
		}
		out = append(out, d)
		return nil
	})
	return out, err
}
