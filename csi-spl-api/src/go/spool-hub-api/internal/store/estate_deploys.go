package store

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// The deploy record (spec 143 section 2.3, tasks T025 + T027, SPL-2788):
// rdb 0202 estate_deploys, one row per hub or WUI deploy to an env. Two
// writers (owner HUM-10 poll 3, msg a8bfcdd0):
//
//	ci         the deploy workflow's report, POST /v1/operator/deploys
//	reconcile  the hub's 2-minute check, which found a served version no
//	           row named (deployed_by 'hub-reconcile', run id 'reconcile')
//
// Estate rows, no tenant: every scope reads, the operator scope writes.

// EstateDeploy is one estate_deploys row.
type EstateDeploy struct {
	DeployID      string    `json:"deploy_id"`
	Env           string    `json:"env"`
	Component     string    `json:"component"`
	Version       string    `json:"version"`
	CommitSHA     string    `json:"commit_sha"`
	DeployedAt    time.Time `json:"deployed_at"`
	Status        string    `json:"status"`
	Source        string    `json:"source"`
	WorkflowRunID string    `json:"workflow_run_id"`
	DeployedBy    string    `json:"deployed_by"`
}

// The values rdb 0202's CHECKs allow.
var (
	EstateDeployEnvs       = []string{"dev", "prd"}
	EstateDeployComponents = []string{"hub", "wui", "inf"}
	EstateDeployStatuses   = []string{"success", "failed"}
	estateDeployVersionRe  = regexp.MustCompile(`^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$`)
	estateDeploySHARe      = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

// The reconcile check's marks (spec 143 section 2.3.2).
const (
	EstateDeployReconcileBy  = "hub-reconcile"
	EstateDeployReconcileRun = "reconcile"
)

// EstateDeploys is the deploy record. Postgres only; the hub answers 503
// on a store without it and runs no reconcile check.
type EstateDeploys interface {
	// PutEstateDeploy writes the workflow's report (source ci) and returns
	// the row. Idempotent per run: a re-post of the same env, component,
	// sha, status and non-empty workflow_run_id returns the first row and
	// stored=false, so a re-run step never doubles a deploy.
	PutEstateDeploy(ctx context.Context, d EstateDeploy) (row EstateDeploy, stored bool, err error)
	// LatestEstateDeploy is the newest successful row of (env, component);
	// ok=false when there is none.
	LatestEstateDeploy(ctx context.Context, env, component string) (row EstateDeploy, ok bool, err error)
	// FillEstateDeploy writes a reconcile row for what (env, component)
	// serves, only while the newest successful row names another sha (or
	// none): under a per-(env, component) lock, so hub instances checking
	// at once write it once. stored=false when a row already names it.
	FillEstateDeploy(ctx context.Context, env, component, version, sha string) (stored bool, err error)
}

// CheckEstateDeploy names the first value rdb 0202 would refuse ("" = fine),
// so the route answers 400 before the statement.
func CheckEstateDeploy(d EstateDeploy) string {
	switch {
	case !slices.Contains(EstateDeployEnvs, d.Env):
		return "env must be dev or prd"
	case !slices.Contains(EstateDeployComponents, d.Component):
		return "component must be hub, wui or inf"
	case !estateDeployVersionRe.MatchString(d.Version):
		return "version must look like v1.7.1 or v1.7.1-c3"
	case !estateDeploySHARe.MatchString(d.CommitSHA):
		return "commit_sha must be a full 40-character lowercase sha"
	case !slices.Contains(EstateDeployStatuses, d.Status):
		return "status must be success or failed"
	case len(d.WorkflowRunID) > 64 || hasControl(d.WorkflowRunID):
		return "workflow_run_id must be one line of up to 64 bytes"
	case len(d.DeployedBy) > 128 || hasControl(d.DeployedBy):
		return "deployed_by must be one line of up to 128 bytes"
	}
	return ""
}

var _ EstateDeploys = (*Postgres)(nil)

const estateDeployCols = `deploy_id, env, component, version, commit_sha, deployed_at, status, source, workflow_run_id, deployed_by`

// estateDeployPut inserts the ci row unless the same run already reported
// it; the second SELECT returns the earlier row then.
const estateDeployPut = `WITH hit AS (
	SELECT ` + estateDeployCols + `, false AS stored FROM estate_deploys
	WHERE $7 <> '' AND source = 'ci' AND env = $2 AND component = $3 AND commit_sha = $5
		AND status = $6 AND workflow_run_id = $7
	ORDER BY deployed_at LIMIT 1
), ins AS (
	INSERT INTO estate_deploys (deploy_id, env, component, version, commit_sha, status, source, workflow_run_id, deployed_by)
	SELECT $1, $2, $3, $4, $5, $6, 'ci', $7, $8 WHERE NOT EXISTS (SELECT 1 FROM hit)
	RETURNING ` + estateDeployCols + `, true AS stored
)
SELECT ` + estateDeployCols + `, stored FROM ins UNION ALL SELECT ` + estateDeployCols + `, stored FROM hit`

// estateDeployFill is the reconcile insert; the caller holds the lock.
const estateDeployFill = `INSERT INTO estate_deploys (deploy_id, env, component, version, commit_sha, status, source, workflow_run_id, deployed_by)
SELECT $1, $2, $3, $4, $5, 'success', 'reconcile', $6, $7
WHERE (SELECT commit_sha FROM estate_deploys WHERE env = $2 AND component = $3 AND status = 'success'
	ORDER BY deployed_at DESC LIMIT 1) IS DISTINCT FROM $5`

func scanEstateDeploy(row pgx.Row, extra ...any) (EstateDeploy, error) {
	var d EstateDeploy
	err := row.Scan(append([]any{&d.DeployID, &d.Env, &d.Component, &d.Version, &d.CommitSHA, &d.DeployedAt,
		&d.Status, &d.Source, &d.WorkflowRunID, &d.DeployedBy}, extra...)...)
	return d, err
}

// PutEstateDeploy is EstateDeploys on Postgres (see the interface).
func (s *Postgres) PutEstateDeploy(ctx context.Context, d EstateDeploy) (EstateDeploy, bool, error) {
	if why := CheckEstateDeploy(d); why != "" {
		return EstateDeploy{}, false, errors.New("estate deploy: " + why)
	}
	var row EstateDeploy
	var stored bool
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		row, err = scanEstateDeploy(tx.QueryRow(ctx, estateDeployPut, uuid.NewString(), d.Env, d.Component,
			d.Version, d.CommitSHA, d.Status, d.WorkflowRunID, d.DeployedBy), &stored)
		return err
	})
	if err != nil {
		return EstateDeploy{}, false, err
	}
	return row, stored, nil
}

// LatestEstateDeploy is EstateDeploys on Postgres (see the interface).
func (s *Postgres) LatestEstateDeploy(ctx context.Context, env, component string) (EstateDeploy, bool, error) {
	var row EstateDeploy
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		row, err = scanEstateDeploy(tx.QueryRow(ctx, `SELECT `+estateDeployCols+` FROM estate_deploys
			WHERE env = $1 AND component = $2 AND status = 'success' ORDER BY deployed_at DESC LIMIT 1`, env, component))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return EstateDeploy{}, false, nil
	}
	if err != nil {
		return EstateDeploy{}, false, err
	}
	return row, true, nil
}

// FillEstateDeploy is EstateDeploys on Postgres (see the interface).
func (s *Postgres) FillEstateDeploy(ctx context.Context, env, component, version, sha string) (bool, error) {
	d := EstateDeploy{Env: env, Component: component, Version: version, CommitSHA: sha, Status: "success",
		WorkflowRunID: EstateDeployReconcileRun, DeployedBy: EstateDeployReconcileBy}
	if why := CheckEstateDeploy(d); why != "" {
		return false, errors.New("estate deploy: " + why)
	}
	var stored bool
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('estate_deploys:' || $1 || ':' || $2))`, env, component); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, estateDeployFill, uuid.NewString(), env, component, version, sha, d.WorkflowRunID, d.DeployedBy)
		stored = err == nil && tag.RowsAffected() == 1
		return err
	})
	return stored, err
}
