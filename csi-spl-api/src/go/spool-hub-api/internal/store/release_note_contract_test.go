package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 143 releases-projects.md row B-3 (SPL-5475), spec 171 Step C: the
// contract migration on release_notes and estate_deploys. Postgres only.

// contractBefore undoes the contract migration in a rolled-back transaction:
// the state a live database is in when it applies (rdb 0270 on 0267). That
// state keys on sha alone, so it holds no sha in two repos: the rows other
// tests committed that way go first.
const contractBefore = `SELECT set_config('app.rls_scope', 'operator', true);
DROP POLICY release_notes_tenant_read ON release_notes;
DROP POLICY operator_scope ON release_notes;
ALTER TABLE release_notes NO FORCE ROW LEVEL SECURITY;
ALTER TABLE release_notes DISABLE ROW LEVEL SECURITY;
ALTER TABLE release_notes DROP CONSTRAINT release_notes_tenant_fk;
ALTER TABLE estate_deploys DROP CONSTRAINT estate_deploys_tenant_fk;
DROP POLICY estate_deploys_tenant_read ON estate_deploys;
CREATE POLICY estate_deploys_read ON estate_deploys FOR SELECT TO PUBLIC USING (true);
ALTER TABLE release_notes ALTER COLUMN tenant_id SET DEFAULT 't1', ALTER COLUMN repo_slug SET DEFAULT 'csitea/csi-spl';
ALTER TABLE estate_deploys ALTER COLUMN tenant_id SET DEFAULT 't1', ALTER COLUMN repo_slug SET DEFAULT 'csitea/csi-spl';
DELETE FROM release_notes WHERE sha IN (SELECT sha FROM release_notes GROUP BY sha HAVING count(*) > 1);
ALTER TABLE release_notes DROP CONSTRAINT release_notes_pkey, ADD CONSTRAINT release_notes_pkey PRIMARY KEY (sha);
CREATE UNIQUE INDEX release_notes_tenant_repo_sha ON release_notes (tenant_id, repo_slug, sha)`

// contractCatalogue is what the contract decides on both tables: their
// constraints, policies, row security, column defaults and indexes.
const contractCatalogue = `SELECT string_agg(x, E'\n' ORDER BY x) FROM (
	SELECT conrelid::regclass || ' ' || conname || ' ' || pg_get_constraintdef(oid) AS x FROM pg_constraint
		WHERE conrelid IN ('release_notes'::regclass, 'estate_deploys'::regclass)
	UNION ALL SELECT tablename || ' ' || policyname || ' ' || cmd || ' ' || coalesce(qual, '') || ' ' || coalesce(with_check, '')
		FROM pg_policies WHERE schemaname = current_schema() AND tablename IN ('release_notes', 'estate_deploys')
	UNION ALL SELECT relname || ' rls ' || relrowsecurity || ' ' || relforcerowsecurity FROM pg_class
		WHERE oid IN ('release_notes'::regclass, 'estate_deploys'::regclass)
	UNION ALL SELECT table_name || '.' || column_name || ' default ' || coalesce(column_default, '-')
		FROM information_schema.columns WHERE table_schema = current_schema()
		AND table_name IN ('release_notes', 'estate_deploys') AND column_name IN ('tenant_id', 'repo_slug')
	UNION ALL SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename IN ('release_notes', 'estate_deploys')
) s`

// GATE, one transaction that rolls back: from the state before it, the file
// builds the live catalogue, the old rows survive the key swap, one sha then
// stores in a second repo of the workspace, and a re-apply changes nothing
// and keeps both rows. RED CONTROLS: a row of a tenant that is not in tenants
// stops the file; a second row with the same workspace, repo and sha fails on
// the primary key.
func TestReleaseNotesDeploysContract(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	raw := sqlFileGlob(t, "release_notes_deploys_rls_contract.sql")
	tn := newTenant(t, pg)
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	exec := func(what, q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	// tryThen runs q, then the statements of then, under a savepoint that
	// always rolls back.
	tryThen := func(q string, args []any, then string) error {
		t.Helper()
		sp, err := tx.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer sp.Rollback(ctx) //nolint:errcheck
		if _, err := sp.Exec(ctx, q, args...); err != nil || then == "" {
			return err
		}
		_, err = sp.Exec(ctx, then)
		return err
	}
	// try runs under a savepoint that always rolls back, so a refusal leaves
	// the transaction usable and a success leaves nothing behind.
	try := func(q string, args ...any) error {
		t.Helper()
		return tryThen(q, args, "")
	}
	catalogue := func() string {
		t.Helper()
		var s string
		if err := tx.QueryRow(ctx, contractCatalogue).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	count := func(sha string) int {
		t.Helper()
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM release_notes WHERE sha = $1`, sha).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	const note = `INSERT INTO release_notes (tenant_id, repo_slug, sha, committed_at, subject, state) VALUES ($1, $2, $3, now(), 's', 'ok')`
	const deploy = `INSERT INTO estate_deploys (tenant_id, repo_slug, deploy_id, env, component, version, commit_sha, status)
		VALUES ($1, 'csitea/csi-spl', $2, 'prd', 'hub', 'v1.7.1', $3, 'success')`

	live := catalogue()
	exec("before", contractBefore)
	old := randSHA()
	exec("old note", note, tn, relRepo, old)
	exec("old deploy", deploy, tn, uuid4(), old)

	for _, q := range []string{note, deploy} {
		args := []any{"t-not-a-tenant", relRepo, randSHA()}
		if q == deploy {
			args = []any{"t-not-a-tenant", uuid4(), randSHA()}
		}
		err := tryThen(q, args, raw)
		if err == nil || !strings.Contains(err.Error(), "name a tenant not in tenants") {
			t.Errorf("RED CONTROL: an orphan row: %v, want the orphan guard", err)
		}
	}

	exec("contract", raw)
	if got := catalogue(); got != live {
		t.Errorf("the file builds another catalogue than the live one:\n%s\nwant\n%s", got, live)
	}
	if n := count(old); n != 1 {
		t.Fatalf("the old note after the key swap: %d rows, want 1", n)
	}
	exec("the same sha in a second repo", note, tn, otherRepo, old)
	var pe *pgconn.PgError
	if err := try(note, tn, relRepo, old); !errors.As(err, &pe) || pe.ConstraintName != "release_notes_pkey" {
		t.Errorf("RED CONTROL: the same workspace, repo and sha again: %v, want release_notes_pkey", err)
	}

	exec("re-apply", raw)
	if got := catalogue(); got != live {
		t.Errorf("a re-apply changed the catalogue:\n%s\nwant\n%s", got, live)
	}
	if n := count(old); n != 2 {
		t.Errorf("the shared-sha rows after a re-apply: %d, want 2", n)
	}
}

// GATE on the live table: one sha in two repos of a workspace keeps two rows
// through the store, each workspace's Reporting SQL tab reads its own two of
// the four rows of that sha, and a workspace delete takes its notes and
// deploys.
// RED CONTROLS: the same workspace, repo and sha again fails on the primary
// key; a row naming no workspace fails (no t1 default); the other
// workspace's rows stay after the delete.
func TestReleaseNotesLiveKey(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	gone, kept := newTenant(t, pg), newTenant(t, pg)
	sha := randSHA()
	var pkey string
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT pg_get_constraintdef(oid) FROM pg_constraint
			WHERE conrelid = 'release_notes'::regclass AND conname = 'release_notes_pkey'`).Scan(&pkey)
	}); err != nil || pkey != "PRIMARY KEY (tenant_id, repo_slug, sha)" {
		t.Fatalf("release_notes_pkey: %q %v", pkey, err)
	}
	for _, tn := range []string{gone, kept} {
		for _, repo := range []string{relRepo, otherRepo} {
			if err := pg.PutReleaseNotes(ctx, tn, repo, []ReleaseNote{noteOK(sha, "", now)}, now); err != nil {
				t.Fatal(err)
			}
		}
		if _, _, err := pg.PutEstateDeploy(ctx, EstateDeploy{TenantID: tn, RepoSlug: relRepo, Env: "dev", Component: "hub",
			Version: "v1.0.0", CommitSHA: sha, Status: "success"}); err != nil {
			t.Fatal(err)
		}
	}
	if n := countOf(t, pg, "release_notes", gone); n != 2 {
		t.Fatalf("one sha in two repos: %d rows, want 2", n)
	}
	var pe *pgconn.PgError
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO release_notes (tenant_id, repo_slug, sha, committed_at, subject, state)
			VALUES ($1, $2, $3, now(), 's', 'ok')`, gone, relRepo, sha)
		return err
	})
	if !errors.As(err, &pe) || pe.ConstraintName != "release_notes_pkey" {
		t.Errorf("RED CONTROL: the same workspace, repo and sha again: %v, want release_notes_pkey", err)
	}
	err = pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO release_notes (sha, committed_at, subject, state) VALUES ($1, now(), 's', 'ok')`, randSHA())
		return err
	})
	if !errors.As(err, &pe) || pe.Code != "23502" {
		t.Errorf("RED CONTROL: a note naming no workspace: %v, want the not-null refusal", err)
	}
	q := `SELECT count(*) FROM release_notes WHERE sha = '` + sha + `'`
	for tn, want := range map[string]string{gone: "2", kept: "2"} {
		r, err := runSQL(t, pg, tn, q)
		if err != nil {
			t.Fatalf("the SQL tab on release_notes: %v", err)
		}
		if got := one(t, r); got != want {
			t.Errorf("the SQL tab of %s reads %s rows of the sha, want %s (its own)", tn, got, want)
		}
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, gone)
		return err
	}); err != nil {
		t.Fatalf("delete a workspace with notes and a deploy: %v", err)
	}
	for tn, want := range map[string][2]int{gone: {0, 0}, kept: {2, 1}} {
		if n, d := countOf(t, pg, "release_notes", tn), countOf(t, pg, "estate_deploys", tn); n != want[0] || d != want[1] {
			t.Errorf("%s after the delete: %d notes, %d deploys, want %v", tn, n, d, want)
		}
	}
}
