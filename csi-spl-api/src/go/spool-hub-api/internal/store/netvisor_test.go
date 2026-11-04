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
	nvsOther = "HUM-9002" // invented: a human seated nowhere
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

// TestNetvisorStoreRLSControl is the red control the brief names: with
// rdb 0260's member_read policy dropped (in a rolled-back transaction)
// another human and the tenant alone read the owner's rows; with it, none.
func TestNetvisorStoreRLSControl(t *testing.T) {
	pg := rlsStore(t)
	a := newTenant(t, pg)
	nvsSeed(t, pg, a, nvsOwner)
	var drop strings.Builder
	for _, tb := range nvsTables {
		drop.WriteString(`DROP POLICY member_read ON ` + tb + `; `)
	}
	for name, args := range map[string][]any{"another human": {a, nvsOther}} {
		leaked := nvsCounts(t, pg, drop.String(), pgScopeNetvisorOwner, args...)
		held := nvsCounts(t, pg, "", pgScopeNetvisorOwner, args...)
		for _, tb := range nvsTables {
			if leaked[tb] == 0 {
				t.Errorf("control is void: %s: without member_read %s should read the owner's rows", tb, name)
			}
			if held[tb] != 0 {
				t.Errorf("%s: %s reads %d row(s) with member_read, want 0", tb, name, held[tb])
			}
		}
	}
	if leaked := nvsCounts(t, pg, drop.String(), pgScopeTenant, a); leaked["netvisor_forecast_items"] == 0 {
		t.Error("control is void: without member_read the tenant alone should read the forecast items")
	}
}

// nvsSeatTechnical seats a fresh technical human (the act-as clone's
// shape, rdb 0088) in tenant with role.
func nvsSeatTechnical(t *testing.T, pg *Postgres, tenant, role string) string {
	t.Helper()
	ctx := context.Background()
	var hum string
	if err := pg.pool.QueryRow(ctx, `INSERT INTO humans (display_name, technical) VALUES ('clone', true) RETURNING human_id`).Scan(&hum); err != nil {
		t.Fatal(err)
	}
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
			VALUES ($1, $2, $3, 'operator')`, tenant, hum, role)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return hum
}

// TestNetvisorStoreMemberRead (rdb 0260, C7 as rewritten, SPL-4792): a
// person seated in the workspace reads the owner's settings and newest
// snapshot but writes nothing; an agent seat, a time accountant, a
// technical (act-as clone) human, a suspended seat and a person of another
// workspace read 0 rows. After an owner move the former owner, still
// seated, reads the new owner's figures only. CONTROL: the red control
// TestNetvisorStoreRLSControl drops member_read; reverting 0260 to 0255's
// owner_scope turns the member's reads here to ErrNotFound.
func TestNetvisorStoreMemberRead(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a, b := newTenant(t, pg), newTenant(t, pg)
	owner := seatMember(t, pg, a, "developer")
	want := nvsSeed(t, pg, a, owner)
	member := seatMember(t, pg, a, "developer")

	got, err := pg.NetvisorLatest(ctx, a, member, "test")
	if err != nil || got.SnapshotID != want.SnapshotID || len(got.Items) != 2 || len(got.CardLines) != 1 {
		t.Fatalf("member's latest = %+v %v, want the owner's %s", got, err, want.SnapshotID)
	}
	if st, err := pg.NetvisorSettings(ctx, a, member); err != nil || st.OwnerHumanID != owner {
		t.Fatalf("member's settings = %+v %v, want owner %s", st, err, owner)
	}
	if n := nvsCounts(t, pg, "", pgScopeNetvisorOwner, a, member); n["netvisor_forecast_items"] != 2 || n["netvisor_card_cost_lines"] != 1 {
		t.Errorf("member counts = %v, want the owner's rows", n)
	}
	if _, err := pg.NetvisorPutSettings(ctx, a, member, NetvisorSettings{Env: "test"}, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("PutSettings(member) = %v, want ErrNotFound", err)
	}
	if _, err := pg.NetvisorRequestRefresh(ctx, a, member, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("RequestRefresh(member) = %v, want ErrNotFound", err)
	}
	var pe *pgconn.PgError
	err = pg.inNetvisorOwner(ctx, a, member, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO netvisor_snapshots (tenant_id, snapshot_id, owner_human_id, env, as_of, month_end, fetched_at)
			VALUES ($1, $2::uuid, $3, 'test', current_date, current_date, now())`, a, uuid4(), owner)
		return err
	})
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Errorf("member's snapshot insert under the owner's id = %v, want 42501", err)
	}

	suspended := seatMember(t, pg, a, "developer")
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE tenant_memberships SET disabled_at = now() WHERE tenant_id = $1 AND human_id = $2`, a, suspended)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	blind := map[string]string{
		"agent seat":                     seatMember(t, pg, a, "pure_agent"),
		"time accountant":                seatMember(t, pg, a, "time_accountant"),
		"technical human (act-as clone)": nvsSeatTechnical(t, pg, a, "developer"),
		"suspended seat":                 suspended,
		"person of another workspace":    seatMember(t, pg, b, "admin"),
	}
	for name, hum := range blind {
		if n := nvsCounts(t, pg, "", pgScopeNetvisorOwner, a, hum); n["netvisor_settings"]+n["netvisor_snapshots"]+n["netvisor_forecast_items"]+n["netvisor_card_cost_lines"] != 0 {
			t.Errorf("%s reads %v, want 0 rows", name, n)
		}
		if _, err := pg.NetvisorLatest(ctx, a, hum, "test"); !errors.Is(err, ErrNotFound) {
			t.Errorf("NetvisorLatest(%s) = %v, want ErrNotFound", name, err)
		}
	}

	if err := pg.NetvisorSetOwner(ctx, a, member, "operator", now); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.NetvisorLatest(ctx, a, owner, "test"); !errors.Is(err, ErrNotFound) {
		t.Errorf("former owner before the new owner's first snapshot = %v, want ErrNotFound (never a former owner's rows)", err)
	}
	next, err := pg.NetvisorIngest(ctx, a, nvsSnap(now))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := pg.NetvisorLatest(ctx, a, owner, "test"); err != nil || got.SnapshotID != next.SnapshotID {
		t.Errorf("former owner, still seated = %+v %v, want the new owner's %s", got, err, next.SnapshotID)
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

// TestNetvisorStoreCardLineNoAccount (B5 fix, SPL-4742, rdb 0258): a card
// line with no bookkeeping account (a credit-card e-invoice line) is filed
// and read back with account_number ""; a value given is still 1-12 digits,
// in the store and in the table's CHECK.
func TestNetvisorStoreCardLineNoAccount(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a := newTenant(t, pg)
	nvsSeed(t, pg, a, nvsOwner)
	snap := nvsSnap(now.Add(time.Second))
	snap.CardLines = append(snap.CardLines, NetvisorCardCostLine{LineNo: 1, Month: snap.CardLines[0].Month,
		Route: "credit_einvoice", Vendor: "vendor-z", Amount: "7.00"})
	filed, err := pg.NetvisorIngest(ctx, a, snap)
	if err != nil {
		t.Fatalf("ingest of a line without an account = %v", err)
	}
	got, err := pg.NetvisorLatest(ctx, a, nvsOwner, "test")
	if err != nil || got.SnapshotID != filed.SnapshotID || len(got.CardLines) != 2 {
		t.Fatalf("latest = %+v %v, want the two lines of %s", got, err, filed.SnapshotID)
	}
	if l := got.CardLines[1]; l.AccountNumber != "" || l.Route != "credit_einvoice" || l.Amount != "7.00" {
		t.Errorf("the line without an account read back as %+v", l)
	}
	if got.CardLines[0].AccountNumber != "4000" {
		t.Errorf("the line with an account read back as %+v", got.CardLines[0])
	}
	bad := nvsSnap(now.Add(2 * time.Second))
	bad.CardLines[0].AccountNumber = "40x0"
	if _, err := pg.NetvisorIngest(ctx, a, bad); !errors.Is(err, ErrBadNetvisor) {
		t.Errorf("ingest of account 40x0 = %v, want ErrBadNetvisor", err)
	}
	var def string
	if err := pg.pool.QueryRow(ctx, `SELECT pg_get_constraintdef(oid) FROM pg_constraint
		WHERE conname = 'netvisor_card_cost_lines_account_number_check'`).Scan(&def); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(def, `^([0-9]{1,12})?$`) {
		t.Errorf("account_number CHECK = %s, want rdb 0258's", def)
	}
}
