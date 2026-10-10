package store

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// The box feed of cost tracking (spec 123 sections 4.3 and 4.6, build lane
// 4): one source's rows of one UTC day, as a box's cost-source factory read
// them (csi-spl-orc spl-cost-source.func.sh), written into rdb 0166's
// cost_lines and cost_coverage. The rows are ESTATE rows (tenant_id NULL,
// operator scope): fleet tokens (origin transcript) and agent-seconds
// (origin agent_run). They are counts, never prices: a subscription's cost is
// its invoice (Q-4), so amount, usd and eur are 0 and units carry the count.
// Cost data is the owner's only (HUM-10, msg 02803231): nothing here returns
// a row, only how many were written.

// CostIngestOrigins are the origins the box feed may write. billing_export is
// the GCP reader's own path, invoice and hand the hand-entry API's.
var CostIngestOrigins = []string{"transcript", "agent_run"}

// CostCoverageStates is rdb 0166's cost_coverage.state CHECK.
var CostCoverageStates = []string{"ok", "missing", "partial"}

// CostIngestLinesMax is the rows one day of one source may carry.
const CostIngestLinesMax = 5000

// The shapes rdb 0166's CHECKs enforce, so a refusal is a 400, not a 500.
var (
	costNameRe = regexp.MustCompile(`^[a-z][a-z0-9_.-]{0,63}$`)
	costDayRe  = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)
)

// CostLine is one box-fed row of a day: the natural key's columns (day and
// source come from its CostDay, tenant_id is NULL) and the count. AgentID and
// Model "" are NULL.
type CostLine struct {
	ProjectOrVendor string  `json:"project_or_vendor"`
	AgentID         string  `json:"agent_id,omitempty"`
	Model           string  `json:"model,omitempty"`
	Kind            string  `json:"kind"`
	Units           float64 `json:"units"`
	Origin          string  `json:"origin"`
}

// CostDay is what one source read for one day: its rows and its one
// cost_coverage row (State, Reason). RunID names the read.
type CostDay struct {
	Day    string
	Source string
	RunID  string
	State  string
	Reason string
	Lines  []CostLine
}

// CostIngestResult is what PutCostDay did: rows written (inserted or
// updated) and live rows of an earlier read of the same day and source that
// this read no longer has (removed).
type CostIngestResult struct {
	Written int `json:"written"`
	Removed int `json:"removed"`
}

// CostIngest is the store half of the box feed. Optional: the hub's ingest
// route answers as off on a store without it.
type CostIngest interface {
	// PutCostDay writes one checked CostDay (CheckCostDay) in one operator
	// transaction: every line UPSERTed on the 0166 natural key (a re-read
	// updates, never duplicates), the live box-fed rows of (day, source) the
	// read did not return removed (a re-read may lose a line), and the
	// (day, source) coverage row UPSERTed. A `missing` day carries no line
	// and removes nothing: a failed read never erases a good one.
	PutCostDay(ctx context.Context, d CostDay) (CostIngestResult, error)
}

// CheckCostDay names the first thing the day may not carry ("" = fine): the
// Go side of rdb 0166's CHECKs plus the feed's own rules, so the ingest
// refuses before the transaction.
func CheckCostDay(d CostDay) string {
	day, err := time.Parse(time.DateOnly, d.Day)
	switch {
	case !costDayRe.MatchString(d.Day) || err != nil || day.Format(time.DateOnly) != d.Day:
		return "day must be a UTC day YYYY-MM-DD"
	case !costNameRe.MatchString(d.Source):
		return "source must match ^[a-z][a-z0-9_.-]{0,63}$"
	case d.RunID == "" || len(d.RunID) > 200 || hasControl(d.RunID):
		return "run_id must be one line of 1..200 bytes"
	case !slices.Contains(CostCoverageStates, d.State):
		return "state must be ok, missing or partial"
	case len(d.Reason) > 480 || hasControl(d.Reason):
		return "reason must be one line of up to 480 bytes"
	case d.State != "ok" && d.Reason == "":
		return "a day that is not ok names its reason"
	case d.State == "missing" && len(d.Lines) > 0:
		return "a missing day carries no line"
	case len(d.Lines) > CostIngestLinesMax:
		return fmt.Sprintf("at most %d lines per day and source", CostIngestLinesMax)
	}
	seen := make(map[[4]string]bool, len(d.Lines))
	for i, l := range d.Lines {
		if why := checkCostLine(l); why != "" {
			return fmt.Sprintf("line %d: %s", i, why)
		}
		k := [4]string{l.ProjectOrVendor, l.AgentID, l.Model, l.Kind}
		if seen[k] {
			return fmt.Sprintf("line %d: a second line with the same project_or_vendor, agent_id, model and kind", i)
		}
		seen[k] = true
	}
	return ""
}

func checkCostLine(l CostLine) string {
	switch {
	case l.ProjectOrVendor == "" || len(l.ProjectOrVendor) > 200 || hasControl(l.ProjectOrVendor):
		return "project_or_vendor must be one line of 1..200 bytes"
	case len(l.AgentID) > 100 || hasControl(l.AgentID):
		return "agent_id must be one line of up to 100 bytes"
	case len(l.Model) > 200 || hasControl(l.Model):
		return "model must be one line of up to 200 bytes"
	case !costNameRe.MatchString(l.Kind):
		return "kind must match ^[a-z][a-z0-9_.-]{0,63}$"
	case math.IsNaN(l.Units) || math.IsInf(l.Units, 0) || l.Units < 0 || l.Units > 1e15:
		return "units must be a count 0..1e15"
	case !slices.Contains(CostIngestOrigins, l.Origin):
		return "origin must be transcript or agent_run (the box feed)"
	}
	return ""
}

var _ CostIngest = (*Postgres)(nil)

// costLineUpsert writes the day's lines from parallel arrays in one
// statement: counts only, so the money columns are 0 in USD at the usage day.
// A package var so the idempotency test's control can drop the ON CONFLICT.
var costLineUpsert = `INSERT INTO cost_lines (day, source, project_or_vendor, tenant_id, agent_id, model, kind, units,
	amount_micros, currency, usd_micros, eur_micros, fx_rate_day, origin, run_id)
SELECT $1::date, $2, l.pov, NULL, NULLIF(l.agent, ''), NULLIF(l.model, ''), l.kind, l.units,
	0, 'USD', 0, 0, $1::date, l.origin, $3
FROM unnest($4::text[], $5::text[], $6::text[], $7::text[], $8::numeric[], $9::text[])
	AS l(pov, agent, model, kind, units, origin)
ON CONFLICT (day, source, project_or_vendor, tenant_id, agent_id, model, kind) WHERE superseded_by IS NULL
DO UPDATE SET units = EXCLUDED.units, origin = EXCLUDED.origin, run_id = EXCLUDED.run_id, read_at = now()`

// costLineStale removes the live box-fed rows of (day, source) whose key the
// read did not return: a re-read that lost a line must not keep its old count.
const costLineStale = `DELETE FROM cost_lines c WHERE c.day = $1::date AND c.source = $2 AND c.tenant_id IS NULL
	AND c.superseded_by IS NULL AND c.origin = ANY($3)
	AND NOT EXISTS (SELECT 1 FROM unnest($4::text[], $5::text[], $6::text[], $7::text[]) AS l(pov, agent, model, kind)
		WHERE l.pov = c.project_or_vendor AND l.agent = coalesce(c.agent_id, '')
			AND l.model = coalesce(c.model, '') AND l.kind = c.kind)`

// PutCostDay is CostIngest on Postgres (see the interface).
func (s *Postgres) PutCostDay(ctx context.Context, d CostDay) (CostIngestResult, error) {
	var res CostIngestResult
	if why := CheckCostDay(d); why != "" {
		return res, fmt.Errorf("cost day: %s", why)
	}
	n := len(d.Lines)
	pov, agent, model, kind, origin := make([]string, n), make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	units := make([]float64, n)
	for i, l := range d.Lines {
		pov[i], agent[i], model[i], kind[i], units[i], origin[i] = l.ProjectOrVendor, l.AgentID, l.Model, l.Kind, l.Units, l.Origin
	}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if n > 0 {
			tag, err := tx.Exec(ctx, costLineUpsert, d.Day, d.Source, d.RunID, pov, agent, model, kind, units, origin)
			if err != nil {
				return err
			}
			res.Written = int(tag.RowsAffected())
		}
		if d.State != "missing" {
			tag, err := tx.Exec(ctx, costLineStale, d.Day, d.Source, CostIngestOrigins, pov, agent, model, kind)
			if err != nil {
				return err
			}
			res.Removed = int(tag.RowsAffected())
		}
		_, err := tx.Exec(ctx, `INSERT INTO cost_coverage (day, source, state, reason, run_id)
			VALUES ($1::date, $2, $3, NULLIF($4, ''), $5)
			ON CONFLICT (day, source) DO UPDATE SET state = EXCLUDED.state, reason = EXCLUDED.reason,
				run_id = EXCLUDED.run_id, read_at = now()`, d.Day, d.Source, d.State, d.Reason, d.RunID)
		return err
	})
	if err != nil {
		return CostIngestResult{}, err
	}
	return res, nil
}
