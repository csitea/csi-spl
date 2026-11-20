package store

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 123 13.8 row P04: tenant isolation and estate scope of the project's
// cost (P01) on Postgres. The month read already names its tenant
// (c.tenant_id = $3), so each forced read here names A and admits the estate
// while it holds another scope: what keeps those rows out is RLS, not the
// WHERE (as in TestCostMonthReadRLS).

// costProjectRLSLift reads every tenant scope with RLS off on cost_lines: a
// package var so the red control can run the whole test lifted.
var costProjectRLSLift = false

// costProjectRLSRead is the project's cost of q read under tenant's scope
// ("" = the operator's), folded as P01 folds it (Estate: four parts, else two).
func costProjectRLSRead(t *testing.T, pg *Postgres, tenant string, q CostMonthQuery) (CostMonth, CostProject) {
	t.Helper()
	ctx := context.Background()
	var cm CostMonth
	read := func(tx pgx.Tx) (err error) { cm, err = costMonthIn(ctx, tx, q); return err }
	var err error
	switch {
	case tenant == "":
		err = pg.asOperator(ctx, read)
	case costProjectRLSLift:
		err = costProjectRLSLifted(ctx, pg, tenant, read)
	default:
		err = pg.inTenant(ctx, tenant, read)
	}
	if err != nil {
		t.Fatal(err)
	}
	return cm, CostProjectParts(CostProjectInput{Estate: q.Estate, AIRead: true, Parts: cm.Parts, Coverage: cm.Coverage})
}

// costProjectRLSLifted runs read under tenant's scope with RLS off on
// cost_lines (the policy dropped), in a transaction that is rolled back.
func costProjectRLSLifted(ctx context.Context, pg *Postgres, tenant string, read func(pgx.Tx) error) error {
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `ALTER TABLE cost_lines DISABLE ROW LEVEL SECURITY`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, pgScopeTenant, tenant); err != nil {
			return err
		}
		if err := read(tx); err != nil {
			return err
		}
		return errRollback
	})
	if errors.Is(err, errRollback) {
		return nil
	}
	return err
}

// TestCostProjectRLS: workspace B reads 0 of A's parts, even when its
// statement names A and admits the estate; a non-operator workspace (A)
// asking for the estate reads no estate part, no cloud and no owned
// hardware, only its own AI share; each workspace's own project is the two
// parts of Q-8 A with its own money only.
// CONTROL: the operator scope reads the estate cloud, the owned hardware and
// A's AI share, so the zeros are the policy's, not an empty month; and with
// RLS off on cost_lines (the policy dropped) B's forced read gets A's rows.
func TestCostProjectRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	from, to, day := costTestMonthClean(t, pg)
	a, b := newTenant(t, pg), newTenant(t, pg)
	cloud, asset := uid("csi-spl-"), uid("laptop-")
	costSeed(t, pg, "", day(3), "gcp", cloud, "cloud_run", "billing_export", 0, 1_000_000, 900_000)
	costSeed(t, pg, "", day(3), CostSourceHandAsset, asset, "asset", "hand", 0, 2_000_000, 1_800_000)
	costSeed(t, pg, a, day(4), CostSourceAIShare, "a-claude", "share", "metered", 0, 4_000_000, 3_600_000)
	costSeed(t, pg, b, day(5), CostSourceAIShare, "b-claude", "share", "metered", 0, 500_000, 450_000)
	forceA := CostMonthQuery{Tenant: a, Estate: true, From: from, To: to}

	_, bp := costProjectRLSRead(t, pg, b, CostMonthQuery{Tenant: b, From: from, To: to})
	if len(bp.Parts) != 2 || *bp.Total.Priced.USDMicros != 500_000 || len(bp.LeftOut) != 0 {
		t.Errorf("B's own project %+v left out %+v: want ai_tokens 0.50 USD and human, nothing of A's", bp.Parts, bp.LeftOut)
	}
	cm, cp := costProjectRLSRead(t, pg, b, forceA)
	if len(cm.Parts) != 0 || *cp.Total.Priced.USDMicros != 0 {
		t.Errorf("B naming A and the estate reads %+v (total %d USD micros), want 0 of A's parts", cm.Parts, *cp.Total.Priced.USDMicros)
	}

	cm, ap := costProjectRLSRead(t, pg, a, forceA)
	for _, p := range cm.Parts {
		if p.Estate {
			t.Errorf("A (a non-operator) asking for the estate reads %s/%s", p.Source, p.ProjectOrVendor)
		}
	}
	if c, h := projectPart(t, ap, CostProjectCloud), projectPart(t, ap, CostProjectHardware); c.Lines != 0 || h.Lines != 0 ||
		*ap.Total.Priced.USDMicros != 4_000_000 {
		t.Errorf("A asking for the estate: cloud %+v owned hardware %+v total %d, want no estate line, its own AI 4.00 only",
			c, h, *ap.Total.Priced.USDMicros)
	}
	_, ws := costProjectRLSRead(t, pg, a, CostMonthQuery{Tenant: a, From: from, To: to})
	if len(ws.Parts) != 2 || ws.Parts[0].Part != CostProjectAI || *ws.Total.Priced.USDMicros != 4_000_000 || len(ws.LeftOut) != 0 {
		t.Errorf("A's own project %+v left out %+v: want ai_tokens 4.00 and human, no estate part", ws.Parts, ws.LeftOut)
	}

	_, op := costProjectRLSRead(t, pg, "", forceA)
	if pv(projectPart(t, op, CostProjectCloud).USDMicros) != int64(1_000_000) ||
		pv(projectPart(t, op, CostProjectHardware).USDMicros) != int64(2_000_000) ||
		pv(projectPart(t, op, CostProjectAI).USDMicros) != int64(4_000_000) {
		t.Errorf("CONTROL: the operator scope reads %+v, want cloud 1.00, owned hardware 2.00, A's AI 4.00", op.Parts)
	}
	var lifted CostMonth
	if err := costProjectRLSLifted(ctx, pg, b, func(tx pgx.Tx) (err error) { lifted, err = costMonthIn(ctx, tx, forceA); return err }); err != nil {
		t.Fatal(err)
	}
	if p, ok := partsBy(lifted.Parts)["false/"+CostSourceAIShare+"/a-claude/share"]; !ok || p.USDMicros != 4_000_000 {
		t.Errorf("CONTROL: with the policy dropped B's forced read gets %+v, want A's 4.00 share: the test cannot see a leak", lifted.Parts)
	}
}
