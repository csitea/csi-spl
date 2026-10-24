package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/119 T002 (spec 7.2, 11): the realm store through inPerson. The
// contract runs on Memory and, under hub-pg.tst.sh, on Postgres as the
// runtime login (never the owner); the RLS negatives T-N1, T-N3..T-N6 run on
// Postgres only. Receipts are written by the receipt copy (T004), so the
// tests seed them: on Postgres as the migrate login in the person scope
// (FORCE binds the owner too), on Memory into its map.

// realmFix is one driver of the contract: the store under test and how to
// seed a human and a receipt row.
type realmFix struct {
	st         Realm
	addHuman   func(t *testing.T, person string)
	addReceipt func(t *testing.T, person string, r RealmReceipt)
}

func memRealmFix() realmFix {
	m := NewMemory()
	return realmFix{
		st: m,
		addHuman: func(_ *testing.T, person string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hum.init()
			m.hum.humans[person] = &memHuman{}
		},
		addReceipt: func(_ *testing.T, person string, r RealmReceipt) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.realm.init()
			m.realm.receipts[person] = append(m.realm.receipts[person], r)
		},
	}
}

// pgRealmFix is the runtime login as the store, the migrate login seeding.
// Each human seeded is deleted at cleanup; its realm rows cascade.
func pgRealmFix(t *testing.T) (realmFix, *Postgres, *Postgres) {
	t.Helper()
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx := context.Background()
	return realmFix{
		st: rt,
		addHuman: func(t *testing.T, person string) {
			t.Helper()
			if _, err := pg.pool.Exec(ctx, `INSERT INTO humans (human_id, display_name) VALUES ($1, 'FirstName LastName')`, person); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { pg.pool.Exec(ctx, `DELETE FROM humans WHERE human_id = $1`, person) }) //nolint:errcheck
		},
		addReceipt: func(t *testing.T, person string, r RealmReceipt) {
			t.Helper()
			err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
				if _, err := tx.Exec(ctx, `SELECT set_config('app.person_id', $1, true)`, person); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `INSERT INTO personal.hours_receipts (person_id, workspace_id, workspace_name, day,
					minutes, label, kind, period_start, period_end, approval_state, approver_name, decided_at, rev)
					VALUES ($1, $2, $3, $4::date, $5, $6, $7, $8::date, $9::date, $10, NULLIF($11, ''), $12, $13)`,
					person, r.WorkspaceID, r.WorkspaceName, r.Day, r.Minutes, r.Label, r.Kind, r.PeriodStart,
					r.PeriodEnd, r.ApprovalState, r.ApproverName, r.DecidedAt, r.Rev)
				return err
			})
			if err != nil {
				t.Fatal(err)
			}
		},
	}, pg, rt
}

// realmPersons is two fresh HUM ids, digits only, unique per run.
func realmPersons() (p, q string) {
	n := time.Now().UnixNano() % 1_000_000_000
	return fmt.Sprintf("HUM-8%d1", n), fmt.Sprintf("HUM-8%d2", n)
}

// receipt is one seeded receipt row of the week from 2026-09-07.
func receipt(ws, label, kind string, minutes, rev int) RealmReceipt {
	return RealmReceipt{WorkspaceID: ws, WorkspaceName: "Workspace " + ws, Day: "2026-09-08", Minutes: minutes,
		Label: label, Kind: kind, PeriodStart: "2026-09-07", PeriodEnd: "2026-09-13", ApprovalState: "open", Rev: rev}
}

func intp(v int) *int { return &v }

func showLimit(p *int) string {
	if p == nil {
		return "off"
	}
	return fmt.Sprint(*p)
}

// realmContract is the realm store's behaviour, the same on every driver.
// Each gap names what went wrong.
func realmContract(t *testing.T, f realmFix) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	p, q := realmPersons()
	f.addHuman(t, p)
	f.addHuman(t, q)
	st := f.st

	// Profile: the zero profile until put; put whole; Q untouched.
	if got, err := st.RealmProfileOf(ctx, p); err != nil || got.TimeZone != "" || string(got.CommPrefs) != "{}" {
		t.Errorf("profile before any put: %+v %v, want the zero profile with {}", got, err)
	}
	if err := st.PutRealmProfile(ctx, p, RealmProfile{TimeZone: "Europe/Helsinki", Locale: "fi",
		CommPrefs: json.RawMessage(`{"digest":"weekly"}`)}, now); err != nil {
		t.Fatalf("put profile: %v", err)
	}
	got, err := st.RealmProfileOf(ctx, p)
	var prefs map[string]string
	if err == nil {
		err = json.Unmarshal(got.CommPrefs, &prefs)
	}
	if err != nil || got.TimeZone != "Europe/Helsinki" || got.Locale != "fi" || prefs["digest"] != "weekly" || !got.UpdatedAt.Equal(now) {
		t.Errorf("profile after put: %+v %v", got, err)
	}
	if err := st.PutRealmProfile(ctx, p, RealmProfile{}, now); err != nil {
		t.Fatalf("put empty profile: %v", err)
	}
	if got, err := st.RealmProfileOf(ctx, p); err != nil || got.TimeZone != "" || got.Locale != "" || string(got.CommPrefs) != "{}" {
		t.Errorf("profile put whole with nothing set: %+v %v, want zone and locale NULL, {}", got, err)
	}
	if got, err := st.RealmProfileOf(ctx, q); err != nil || got.TimeZone != "" {
		t.Errorf("T-N1: Q's profile after P's put: %+v %v, want the zero profile", got, err)
	}
	for name, bad := range map[string]RealmProfile{
		"zone":   {TimeZone: "not a zone"},
		"locale": {Locale: "xx-nope"},
		"prefs":  {CommPrefs: json.RawMessage(`[1]`)},
		"big":    {CommPrefs: json.RawMessage(fmt.Sprintf(`{"a":"%0*d"}`, RealmCommPrefsMax, 0))},
	} {
		if err := st.PutRealmProfile(ctx, p, bad, now); !errors.Is(err, ErrRealmBad) {
			t.Errorf("put profile with a bad %s: %v, want ErrRealmBad", name, err)
		}
	}
	if err := st.PutRealmProfile(ctx, "HUM-77777777777", RealmProfile{}, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("put profile of no human: %v, want ErrNotFound", err)
	}

	// Limits: a change appends a row from its day; a past day keeps its limit.
	if _, ok, err := st.RealmLimitsOn(ctx, p, "2026-09-01"); ok || err != nil {
		t.Errorf("limits before any: found %v %v", ok, err)
	}
	for _, l := range []RealmLimits{
		{ValidFrom: "2026-09-01", DayLimitMinutes: intp(480)},
		{ValidFrom: "2026-09-15", WeekLimitMinutes: intp(2400)},
		{ValidFrom: "2026-09-15", DayLimitMinutes: intp(300)}, // the same day again: replaces it
	} {
		if err := st.AppendRealmLimits(ctx, p, l, now); err != nil {
			t.Fatalf("append %+v: %v", l, err)
		}
	}
	for _, c := range []struct {
		day       string
		found     bool
		from      string
		day1, wk1 string
	}{
		{"2026-08-31", false, "", "", ""},
		{"2026-09-01", true, "2026-09-01", "480", "off"},
		{"2026-09-14", true, "2026-09-01", "480", "off"},
		{"2026-09-15", true, "2026-09-15", "300", "off"},
		{"2027-01-01", true, "2026-09-15", "300", "off"},
	} {
		l, ok, err := st.RealmLimitsOn(ctx, p, c.day)
		if err != nil || ok != c.found || (ok && (l.ValidFrom != c.from || showLimit(l.DayLimitMinutes) != c.day1 || showLimit(l.WeekLimitMinutes) != c.wk1)) {
			t.Errorf("limits on %s: %+v found %v %v, want from %s day %s week %s", c.day, l, ok, err, c.from, c.day1, c.wk1)
		}
	}
	if h, err := st.RealmLimitsHistory(ctx, p); err != nil || len(h) != 2 || h[0].ValidFrom != "2026-09-01" || h[1].ValidFrom != "2026-09-15" {
		t.Errorf("limits history: %+v %v, want 2026-09-01, 2026-09-15", h, err)
	}
	if h, err := st.RealmLimitsHistory(ctx, q); err != nil || len(h) != 0 {
		t.Errorf("T-N1: Q's limits history: %+v %v, want none", h, err)
	}
	for _, bad := range []RealmLimits{
		{ValidFrom: "2026-13-01"}, {ValidFrom: "2026-09-01", DayLimitMinutes: intp(59)},
		{ValidFrom: "2026-09-01", DayLimitMinutes: intp(1441)}, {ValidFrom: "2026-09-01", WeekLimitMinutes: intp(10081)},
	} {
		if err := st.AppendRealmLimits(ctx, p, bad, now); !errors.Is(err, ErrRealmBad) {
			t.Errorf("append bad limits %+v: %v, want ErrRealmBad", bad, err)
		}
	}
	if _, _, err := st.RealmLimitsOn(ctx, p, "yesterday"); !errors.Is(err, ErrRealmBad) {
		t.Errorf("limits on a bad day: %v, want ErrRealmBad", err)
	}

	// Receipts: max(rev) per (workspace, day, label, kind); erasure per workspace.
	w1, w2 := "ws-a-"+uuid4(), "ws-b-"+uuid4()
	for _, r := range []RealmReceipt{
		receipt(w1, "topic", "work", 60, 0), receipt(w1, "topic", "work", 90, 1),
		receipt(w1, "topic", "travel", 30, 0), receipt(w2, "workspace", "work", 15, 0),
	} {
		f.addReceipt(t, p, r)
	}
	f.addReceipt(t, q, receipt(w1, "topic", "work", 45, 0))
	rs, err := st.RealmReceipts(ctx, p)
	want := []string{w1 + " topic travel 30 rev 0", w1 + " topic work 90 rev 1", w2 + " workspace work 15 rev 0"}
	var have []string
	for _, r := range rs {
		have = append(have, fmt.Sprintf("%s %s %s %d rev %d", r.WorkspaceID, r.Label, r.Kind, r.Minutes, r.Rev))
	}
	if err != nil || fmt.Sprint(have) != fmt.Sprint(want) {
		t.Errorf("P's receipts: %v %v, want %v", have, err, want)
	}
	if len(rs) > 0 && (rs[0].Day != "2026-09-08" || rs[0].PeriodStart != "2026-09-07" || rs[0].PeriodEnd != "2026-09-13" ||
		rs[0].ApprovalState != "open" || rs[0].WorkspaceName != "Workspace "+w1 || rs[0].ApproverName != "" || rs[0].DecidedAt != nil) {
		t.Errorf("receipt columns: %+v", rs[0])
	}
	if rq, err := st.RealmReceipts(ctx, q); err != nil || len(rq) != 1 || rq[0].Minutes != 45 {
		t.Errorf("T-N1: Q's receipts: %+v %v, want its one row", rq, err)
	}
	if n, err := st.DeleteRealmReceipts(ctx, p, w1); err != nil || n != 3 {
		t.Errorf("P erases W1: %d %v, want 3 (every rev)", n, err)
	}
	if rs, err := st.RealmReceipts(ctx, p); err != nil || len(rs) != 1 || rs[0].WorkspaceID != w2 {
		t.Errorf("P's receipts after erasing W1: %+v %v, want W2's one row", rs, err)
	}
	if rq, err := st.RealmReceipts(ctx, q); err != nil || len(rq) != 1 {
		t.Errorf("Q's receipts after P erased W1: %+v %v, want its one row", rq, err)
	}
	if n, err := st.DeleteRealmReceipts(ctx, p, w1); err != nil || n != 0 {
		t.Errorf("P erases W1 again: %d %v, want 0", n, err)
	}
	if _, err := st.DeleteRealmReceipts(ctx, p, ""); !errors.Is(err, ErrRealmBad) {
		t.Errorf("erase with no workspace: %v, want ErrRealmBad", err)
	}
}

// TestRealmStore is the realm contract on Memory and, under hub-pg.tst.sh,
// on Postgres as the runtime login.
func TestRealmStore(t *testing.T) {
	t.Run("memory", func(t *testing.T) { realmContract(t, memRealmFix()) })
	if os.Getenv("SPOOL_TEST_PG_DSN") == "" || os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN") == "" {
		return
	}
	t.Run("postgres", func(t *testing.T) {
		f, _, _ := pgRealmFix(t)
		realmContract(t, f)
	})
}

// personRows counts person's rows in every personal table under the
// transaction's settings, by table.
func personRows(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, person string) (map[string]int, error) {
	out := map[string]int{}
	for _, tb := range personalTables {
		var c int
		if err := q.QueryRow(ctx, `SELECT count(*) FROM personal.`+tb+` WHERE person_id = $1`, person).Scan(&c); err != nil {
			return nil, fmt.Errorf("%s: %w", tb, err)
		}
		out[tb] = c
	}
	return out, nil
}

// realmSeedPG seeds P and Q with a row in every personal table: profile and
// limits through the runtime store, a receipt, a receipt_due row and a
// contact as the migrate login in the person's own scope.
func realmSeedPG(t *testing.T) (pg, rt *Postgres, p, q string) {
	t.Helper()
	f, pg, rt := pgRealmFix(t)
	ctx := context.Background()
	p, q = realmPersons()
	for _, who := range []string{p, q} {
		f.addHuman(t, who)
		if err := rt.PutRealmProfile(ctx, who, RealmProfile{TimeZone: "UTC"}, time.Now()); err != nil {
			t.Fatal(err)
		}
		if err := rt.AppendRealmLimits(ctx, who, RealmLimits{ValidFrom: "2026-09-01", DayLimitMinutes: intp(480)}, time.Now()); err != nil {
			t.Fatal(err)
		}
		f.addReceipt(t, who, receipt("ws-n-"+uuid4(), "topic", "work", 60, 0))
		err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.person_id', $1, true)`, who); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO personal.receipt_due (person_id, workspace_id, reason) VALUES ($1, $2, 'removed')`, who, "ws-d-"+uuid4()); err != nil {
				return err
			}
			// spec 154 B1 (rdb 0225): one contact, raw, until B2's store.
			_, err := tx.Exec(ctx, `INSERT INTO personal.contacts (person_id, first_name, last_name) VALUES ($1, 'FirstName', 'LastName')`, who)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return pg, rt, p, q
}

// TestRLSPersonStore is T-N1, T-N3, T-N4, T-N5 and T-N6 through the store's
// own scopes, as the runtime login. CONTROL: in P's own scope P's rows are
// > 0 in every table, so each 0 below is the policy, not an empty table.
func TestRLSPersonStore(t *testing.T) {
	pg, rt, p, q := realmSeedPG(t)
	ctx := context.Background()
	expect := func(what string, got map[string]int, err error, wantRows bool) {
		t.Helper()
		if err != nil {
			t.Errorf("%s: %v", what, err)
			return
		}
		for _, tb := range personalTables {
			if wantRows && got[tb] == 0 {
				t.Errorf("%s: 0 rows of personal.%s, want > 0", what, tb)
			}
			if !wantRows && got[tb] != 0 {
				t.Errorf("%s: %d row(s) of personal.%s, want 0", what, got[tb], tb)
			}
		}
	}
	// T-N1: inPerson(P) reads P's rows (control) and none of Q's; a row
	// stamped Q is refused by WITH CHECK.
	var mine, theirs map[string]int
	err := rt.inPerson(ctx, p, func(tx pgx.Tx) (err error) {
		if mine, err = personRows(ctx, tx, p); err != nil {
			return err
		}
		theirs, err = personRows(ctx, tx, q)
		return err
	})
	expect("control: P's own rows under inPerson(P)", mine, err, true)
	expect("T-N1: Q's rows under inPerson(P)", theirs, err, false)
	err = rt.inPerson(ctx, p, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO personal.settings (person_id, valid_from) VALUES ($1, '2030-01-01')`, q)
		return err
	})
	if sqlState(err) != "42501" {
		t.Errorf("T-N1: inPerson(P) inserting a row stamped Q: %v, want the policy's 42501", err)
	}
	// T-N3: both settings in one crafted transaction.
	err = rt.inPerson(ctx, p, func(tx pgx.Tx) (err error) {
		if _, err = tx.Exec(ctx, `SELECT set_config('app.tenant_id', 'ws-crafted', true)`); err != nil {
			return err
		}
		mine, err = personRows(ctx, tx, p)
		return err
	})
	expect("T-N3: inPerson(P) with app.tenant_id set too", mine, err, false)
	// T-N4: the operator scope, alone and on top of the person scope.
	err = rt.asOperator(ctx, func(tx pgx.Tx) (err error) {
		mine, err = personRows(ctx, tx, p)
		return err
	})
	expect("T-N4: asOperator", mine, err, false)
	err = rt.inPerson(ctx, p, func(tx pgx.Tx) (err error) {
		if _, err = tx.Exec(ctx, pgScopeOperator); err != nil {
			return err
		}
		mine, err = personRows(ctx, tx, p)
		return err
	})
	expect("T-N4: inPerson(P) under the operator scope", mine, err, false)
	// T-N5: no setting, and app.person_id = ''.
	mine, err = personRows(ctx, rt.pool, p)
	expect("T-N5: the runtime with no setting", mine, err, false)
	err = pgx.BeginFunc(ctx, rt.pool, func(tx pgx.Tx) (err error) {
		if _, err = tx.Exec(ctx, `SELECT set_config('app.person_id', '', true)`); err != nil {
			return err
		}
		mine, err = personRows(ctx, tx, p)
		return err
	})
	expect("T-N5: the runtime with app.person_id ''", mine, err, false)
	// T-N6: the schema owner without the setting (FORCE).
	mine, err = personRows(ctx, pg.pool, p)
	expect("T-N6: the migrate login with no setting", mine, err, false)
	// The store's erasure works only through the person scope.
	if rs, err := rt.RealmReceipts(ctx, p); err != nil || len(rs) != 1 {
		t.Errorf("P's receipts through the store: %+v %v, want 1", rs, err)
	} else if n, err := rt.DeleteRealmReceipts(ctx, p, rs[0].WorkspaceID); err != nil || n != 1 {
		t.Errorf("P erases its workspace through the store: %d %v, want 1", n, err)
	}
}
