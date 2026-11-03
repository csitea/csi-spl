package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 125 B4 (SPL-4721, rdb 0255), case C-NVS-4. Postgres only, run by
// hub-pg.tst.sh as the plain owner role. Every figure, account number and
// human id here is invented (C2).

// nvsTables are rdb 0255's tables; the data tables follow the settings.
var nvsTables = []string{"netvisor_settings", "netvisor_snapshots", "netvisor_forecast_items", "netvisor_card_cost_lines"}

const (
	nvsOwner = "HUM-9001" // invented
	nvsOther = "HUM-9002" // invented: another member, an admin, anyone
)

// nvsSnap is one invented snapshot with two items and one card line.
func nvsSnap(now time.Time) NetvisorSnapshot {
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	month := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	yes := true
	return NetvisorSnapshot{
		SnapshotID: uuid4(), AsOf: day, MonthEnd: month.AddDate(0, 1, -1), NewestBankVoucherDate: day.AddDate(0, 0, -1),
		FetchedAt: now.Truncate(time.Microsecond),
		Items: []NetvisorForecastItem{
			{ItemNo: 0, Category: "bank_balance", Sign: 1, Amount: "1234.50", Label: "bank"},
			{ItemNo: 1, Category: "payable", Sign: -1, Amount: "99.99", DueDate: day.AddDate(0, 0, 3), Approved: &yes, Label: "bill"},
		},
		CardLines: []NetvisorCardCostLine{
			{LineNo: 0, Month: month, Route: "debit_ledger", Vendor: "vendor-x", AccountNumber: "4000", Amount: "12.30", VATCode: "v1"},
		},
	}
}

// nvsSeed gives tenant an owner and one snapshot of that owner; it returns
// the snapshot as filed.
func nvsSeed(t *testing.T, pg *Postgres, tenant, owner string) NetvisorSnapshot {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC()
	if err := pg.NetvisorSetOwner(ctx, tenant, owner, "operator", now); err != nil {
		t.Fatal(err)
	}
	snap, err := pg.NetvisorIngest(ctx, tenant, nvsSnap(now))
	if err != nil {
		t.Fatal(err)
	}
	return snap
}

// nvsCounts counts each rdb 0255 table's rows under scope (a set_config
// statement and its args), in one transaction that is rolled back after
// setup ran in it (the control drops a policy there).
func nvsCounts(t *testing.T, pg *Postgres, setup, scope string, args ...any) map[string]int {
	t.Helper()
	ctx := context.Background()
	out := map[string]int{}
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if setup != "" {
		if _, err := tx.Exec(ctx, setup); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec(ctx, scope, args...); err != nil {
		t.Fatal(err)
	}
	for _, tb := range nvsTables {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{tb}.Sanitize()).Scan(&n); err != nil {
			t.Fatal(err)
		}
		out[tb] = n
	}
	return out
}

// TestNetvisorStoreRLS: the owner reads its snapshot; the tenant alone,
// another human, the operator scope, the ingest scope (data tables) and the
// owner's id in another workspace read 0 rows of any rdb 0255 table.
func TestNetvisorStoreRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	want := nvsSeed(t, pg, a, nvsOwner)
	nvsSeed(t, pg, b, nvsOwner) // the same human id owning another workspace

	got, err := pg.NetvisorLatest(ctx, a, nvsOwner, "test")
	if err != nil {
		t.Fatal(err)
	}
	if got.SnapshotID != want.SnapshotID || len(got.Items) != 2 || len(got.CardLines) != 1 ||
		got.Items[0].Amount != "1234.50" || got.Items[1].Approved == nil || !*got.Items[1].Approved ||
		got.CardLines[0].Amount != "12.30" || !got.NewestBankVoucherDate.Equal(want.NewestBankVoucherDate) {
		t.Fatalf("owner's latest = %+v, want %+v", got, want)
	}
	own := nvsCounts(t, pg, "", pgScopeNetvisorOwner, a, nvsOwner)
	for _, tb := range nvsTables {
		if own[tb] == 0 {
			t.Errorf("control: %s: the owner reads none of its rows", tb)
		}
	}
	none := map[string]struct {
		scope string
		args  []any
	}{
		"tenant alone":          {pgScopeTenant, []any{a}},
		"another human":         {pgScopeNetvisorOwner, []any{a, nvsOther}},
		"human id empty":        {pgScopeNetvisorOwner, []any{a, ""}},
		"operator":              {pgScopeOperator, nil},
		"owner, other tenant":   {pgScopeNetvisorOwner, []any{newTenant(t, pg), nvsOwner}},
		"no scope":              {`SELECT 1`, nil},
		"ingest (data tables)":  {pgScopeNetvisorIngest, []any{a}},
		"operator + human only": {`SELECT set_config('app.rls_scope', 'operator', true), set_config('app.human_id', $1, true)`, []any{nvsOwner}},
	}
	for name, c := range none {
		n := nvsCounts(t, pg, "", c.scope, c.args...)
		for _, tb := range nvsTables {
			if name == "ingest (data tables)" && tb == "netvisor_settings" {
				if n[tb] != 1 {
					t.Errorf("ingest scope reads %d settings row(s), want its 1", n[tb])
				}
				continue
			}
			if n[tb] != 0 {
				t.Errorf("%s: %s reads %d row(s), want 0", name, tb, n[tb])
			}
		}
	}
	if _, err := pg.NetvisorLatest(ctx, a, nvsOther, "test"); !errors.Is(err, ErrNotFound) {
		t.Errorf("NetvisorLatest(another human) = %v, want ErrNotFound", err)
	}
	if _, err := pg.NetvisorSettings(ctx, a, nvsOther); !errors.Is(err, ErrNotFound) {
		t.Errorf("NetvisorSettings(another human) = %v, want ErrNotFound", err)
	}
	for _, h := range []string{"", "CLE-01", "c-376", "HUM-"} {
		if _, err := pg.NetvisorLatest(ctx, a, h, "test"); !errors.Is(err, ErrNoHuman) {
			t.Errorf("NetvisorLatest(human %q) = %v, want ErrNoHuman", h, err)
		}
	}
}

// TestNetvisorStoreRLSControl is the red control the brief names: with the
// owner_scope policy dropped (in a rolled-back transaction) another human
// and the tenant alone read the owner's rows; with it, none.
func TestNetvisorStoreRLSControl(t *testing.T) {
	pg := rlsStore(t)
	a := newTenant(t, pg)
	nvsSeed(t, pg, a, nvsOwner)
	var drop strings.Builder
	for _, tb := range nvsTables {
		drop.WriteString(`DROP POLICY owner_scope ON ` + tb + `; `)
	}
	for name, args := range map[string][]any{"another human": {a, nvsOther}} {
		leaked := nvsCounts(t, pg, drop.String(), pgScopeNetvisorOwner, args...)
		held := nvsCounts(t, pg, "", pgScopeNetvisorOwner, args...)
		for _, tb := range nvsTables {
			if leaked[tb] == 0 {
				t.Errorf("control is void: %s: without owner_scope %s should read the owner's rows", tb, name)
			}
			if held[tb] != 0 {
				t.Errorf("%s: %s reads %d row(s) with owner_scope, want 0", tb, name, held[tb])
			}
		}
	}
	if leaked := nvsCounts(t, pg, drop.String(), pgScopeTenant, a); leaked["netvisor_forecast_items"] == 0 {
		t.Error("control is void: without owner_scope the tenant alone should read the forecast items")
	}
}

// TestNetvisorStoreWrites: only the owner writes; the owner moves only by
// NetvisorSetOwner, and then the old owner reads nothing.
func TestNetvisorStoreWrites(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a := newTenant(t, pg)
	if _, err := pg.NetvisorIngest(ctx, a, nvsSnap(now)); !errors.Is(err, ErrNetvisorNoOwner) {
		t.Fatalf("ingest without an owner = %v, want ErrNetvisorNoOwner", err)
	}
	old := nvsSeed(t, pg, a, nvsOwner)
	in := NetvisorSettings{Env: "test", BankAccount: "1910", VATAccounts: []string{"2939"}, VendorExclusions: []string{"vendor-y"}}
	if _, err := pg.NetvisorPutSettings(ctx, a, nvsOther, in, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("PutSettings(another human) = %v, want ErrNotFound", err)
	}
	st, err := pg.NetvisorPutSettings(ctx, a, nvsOwner, in, now)
	if err != nil || st.OwnerHumanID != nvsOwner || st.BankAccount != "1910" || len(st.VATAccounts) != 1 || len(st.TaxAccounts) != 0 {
		t.Fatalf("PutSettings(owner) = %+v %v", st, err)
	}
	if _, err := pg.NetvisorPutSettings(ctx, a, nvsOwner, NetvisorSettings{Env: "test", BankAccount: "FI00"}, now); !errors.Is(err, ErrBadNetvisor) {
		t.Errorf("PutSettings(bad account) = %v, want ErrBadNetvisor", err)
	}
	snap := nvsSnap(now)
	snap.Env = "prd"
	if _, err := pg.NetvisorIngest(ctx, a, snap); !errors.Is(err, ErrNetvisorEnv) {
		t.Errorf("ingest of prd into a test workspace = %v, want ErrNetvisorEnv", err)
	}
	// Another human cannot file a row, not even under its own id (42501).
	var pe *pgconn.PgError
	err = pg.inNetvisorOwner(ctx, a, nvsOther, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO netvisor_snapshots (tenant_id, snapshot_id, owner_human_id, env, as_of, month_end, fetched_at)
			VALUES ($1, $2::uuid, $3, 'test', current_date, current_date, now())`, a, uuid4(), nvsOther)
		return err
	})
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Errorf("another human's own-id snapshot insert = %v, want 42501", err)
	}
	if err := pg.NetvisorSetOwner(ctx, a, nvsOther, "operator", now); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.NetvisorLatest(ctx, a, nvsOwner, "test"); !errors.Is(err, ErrNotFound) {
		t.Errorf("old owner after the move = %v, want ErrNotFound", err)
	}
	if _, err := pg.NetvisorLatest(ctx, a, nvsOther, "test"); !errors.Is(err, ErrNotFound) {
		t.Errorf("new owner reads the old owner's snapshot %s: %v", old.SnapshotID, err)
	}
	if got, err := pg.NetvisorIngest(ctx, a, nvsSnap(now)); err != nil || got.OwnerHumanID != nvsOther {
		t.Errorf("ingest after the move = %q %v, want filed under the new owner", got.OwnerHumanID, err)
	}
}

// TestNetvisorHumanScopeCallers: app.human_id is set in netvisor_postgres.go
// alone, so no other store path can open a Netvisor owner's rows.
func TestNetvisorHumanScopeCallers(t *testing.T) {
	ents, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	seen := false
	for _, e := range ents {
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		has := strings.Contains(string(b), "app.human_id")
		seen = seen || (has && name == "netvisor_postgres.go")
		if has && name != "netvisor_postgres.go" {
			t.Errorf("%s names app.human_id: only netvisor_postgres.go sets the Netvisor owner scope", name)
		}
	}
	if !seen {
		t.Fatal("control: netvisor_postgres.go does not name app.human_id - the scan reads the wrong files")
	}
}

// TestNetvisorStoreRefresh (rdb 0257, B5): only the owner opens a "Refresh
// now"; a second press keeps the first time; the ingest scope reads it; a
// snapshot fetched before the request leaves it open, one fetched at or
// after it clears it. Another human, and a workspace with no owner, are
// refused.
func TestNetvisorStoreRefresh(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, none := newTenant(t, pg), newTenant(t, pg)
	nvsSeed(t, pg, a, nvsOwner)
	if at, err := pg.NetvisorRefreshRequested(ctx, a); err != nil || at != nil {
		t.Fatalf("before any press: %v %v, want none", at, err)
	}
	if _, err := pg.NetvisorRefreshRequested(ctx, none); !errors.Is(err, ErrNetvisorNoOwner) {
		t.Fatalf("no owner: %v, want ErrNetvisorNoOwner", err)
	}
	if _, err := pg.NetvisorRequestRefresh(ctx, a, nvsOther, time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("another human pressed: %v, want ErrNotFound", err)
	}
	press := time.Now().UTC().Truncate(time.Microsecond)
	got, err := pg.NetvisorRequestRefresh(ctx, a, nvsOwner, press)
	if err != nil || !got.Equal(press) {
		t.Fatalf("owner's press: %v %v", got, err)
	}
	if again, err := pg.NetvisorRequestRefresh(ctx, a, nvsOwner, press.Add(time.Minute)); err != nil || !again.Equal(press) {
		t.Fatalf("second press moved the request: %v %v, want %v", again, err, press)
	}
	if st, err := pg.NetvisorSettings(ctx, a, nvsOwner); err != nil || st.RefreshRequestedAt == nil || !st.RefreshRequestedAt.Equal(press) {
		t.Fatalf("settings read: %+v %v", st, err)
	}
	early := nvsSnap(press.Add(-time.Hour))
	if _, err := pg.NetvisorIngest(ctx, a, early); err != nil {
		t.Fatal(err)
	}
	if at, err := pg.NetvisorRefreshRequested(ctx, a); err != nil || at == nil || !at.Equal(press) {
		t.Fatalf("an older fetch cleared the request: %v %v", at, err)
	}
	if _, err := pg.NetvisorIngest(ctx, a, nvsSnap(press.Add(time.Second))); err != nil {
		t.Fatal(err)
	}
	if at, err := pg.NetvisorRefreshRequested(ctx, a); err != nil || at != nil {
		t.Fatalf("the answering fetch left the request open: %v %v", at, err)
	}
}
