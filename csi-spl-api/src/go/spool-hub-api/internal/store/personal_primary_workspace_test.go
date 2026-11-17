package store

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 119 primary-workspace.md v0.3.1, T-PW4 (the profile column part,
// tasks.md T019): rdb 0292's personal.profile.primary_workspace_id is read
// only in its person's own scope. Under a tenant scope, the operator scope,
// no scope or another person's scope, a read of the column returns 0 rows.
// Its CHECK holds 1..200, and the store puts, reads and clears it. Postgres
// only, as the runtime login (hub-pg.tst.sh); names start TestRLS so its
// RLS control counts them, no t.Run.

// primaryWorkspaceColumnGaps reads P's primary_workspace_id under each scope;
// P's own scope must read W1 (seedRealm's value), every other none.
func primaryWorkspaceColumnGaps(ctx context.Context, tx pgx.Tx, s realmSeed) []string {
	var gaps []string
	for _, c := range []struct {
		name, person, tenant, rls string
		want                      bool
	}{
		{"P reads P's (control)", s.p, "", "", true},
		{"Q reads P's", s.q, "", "", false},
		{"P with a tenant set", s.p, s.w1, "", false},
		{"P under the operator scope", s.p, "", "operator", false},
		{"operator scope alone", "", "", "operator", false},
		{"tenant scope alone", "", s.w1, "", false},
		{"no scope", "", "", "", false},
	} {
		var got []string
		err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, c.person, c.tenant, c.rls); err != nil {
				return err
			}
			rows, err := sp.Query(ctx, `SELECT primary_workspace_id FROM personal.profile
				WHERE person_id = $1 AND primary_workspace_id IS NOT NULL`, s.p)
			if err != nil {
				return err
			}
			got, err = pgx.CollectRows(rows, pgx.RowTo[string])
			return err
		})
		switch {
		case err != nil:
			gaps = append(gaps, fmt.Sprintf("T-PW4 %s: %v", c.name, err))
		case c.want && (len(got) != 1 || got[0] != s.w1):
			gaps = append(gaps, fmt.Sprintf("T-PW4 %s: %v, want [%s]", c.name, got, s.w1))
		case !c.want && len(got) != 0:
			gaps = append(gaps, fmt.Sprintf("T-PW4 %s: %d row(s) %v, want 0", c.name, len(got), got))
		}
	}
	return gaps
}

// primaryWorkspaceCheckGaps is rdb 0292's CHECK in P's own scope: "" and 201
// characters are refused (23514), 200 and NULL pass.
func primaryWorkspaceCheckGaps(ctx context.Context, tx pgx.Tx, s realmSeed) []string {
	var gaps []string
	for _, c := range []struct {
		name string
		v    any
		ok   bool
	}{
		{"''", "", false}, {"201 characters", strings.Repeat("w", 201), false},
		{"200 characters", strings.Repeat("w", 200), true}, {"NULL", nil, true},
	} {
		err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, s.p, "", ""); err != nil {
				return err
			}
			_, err := sp.Exec(ctx, `UPDATE personal.profile SET primary_workspace_id = $2 WHERE person_id = $1`, s.p, c.v)
			return err
		})
		switch {
		case c.ok && err != nil:
			gaps = append(gaps, fmt.Sprintf("CHECK %s: %v, want ok", c.name, err))
		case !c.ok && sqlState(err) != "23514":
			gaps = append(gaps, fmt.Sprintf("CHECK %s: err %v, want 23514", c.name, err))
		}
	}
	return gaps
}

// TestRLSPrimaryWorkspaceColumn is T-PW4's profile column part. CONTROL: an
// operator_scope policy on personal.profile turns exactly the two operator
// cases red.
func TestRLSPrimaryWorkspaceColumn(t *testing.T) {
	pg := rlsStore(t)
	_, rt := runtimeSession(t)
	ctx := context.Background()
	tx, s := seedRealm(t, pg, rt)
	for _, g := range append(primaryWorkspaceColumnGaps(ctx, tx, s), primaryWorkspaceCheckGaps(ctx, tx, s)...) {
		t.Error(g)
	}
	tx.Rollback(ctx) //nolint:errcheck // the control's CREATE POLICY waits on this tx's locks

	ctl, cs := seedRealm(t, pg, rt, `CREATE POLICY operator_scope ON personal.profile
		USING (current_setting('app.rls_scope', true) = 'operator')`)
	red := primaryWorkspaceColumnGaps(ctx, ctl, cs)
	ctl.Rollback(ctx) //nolint:errcheck
	want := []string{"T-PW4 P under the operator scope:", "T-PW4 operator scope alone:"}
	joined := strings.Join(red, "\n")
	if len(red) != len(want) {
		t.Errorf("control operator_scope: want %d red, got %d: %v", len(want), len(red), red)
	}
	for _, w := range want {
		if !strings.Contains(joined, w) {
			t.Errorf("control operator_scope: %q stayed green:\n%s", w, joined)
		}
	}
}
