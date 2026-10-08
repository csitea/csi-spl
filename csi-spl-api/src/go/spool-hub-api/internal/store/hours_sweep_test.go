package store

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 107 T007 (section 4.2): the freeze sweep on Memory and Postgres. A
// removed member with minutes gets a row, a member with nothing a 0 row, an
// agent none; the period's minutes are pruned, a minute of the next local day
// is not; a re-run writes nothing; a week -> month switch never pulls passed
// days in; minutes older than 45 days go. Unapproved suggestions count zero
// (owner Q2, panel A): the row's total is the approved entries only.
//
// Postgres runs the sweep for the test's own workspace only (sweepHoursIn):
// the database is shared with the other packages' tests.

// The week before A (09-21..09-27) is due at sweepBeforeA: owner and empty
// get a 0 row for it. Week A is Mon 2026-09-28 .. Sun 10-04; with grace 2 it freezes Wed 10-07
// 00:00 UTC (hours.tz defaults to UTC).
var (
	sweepWeekA   = [2]string{"2026-09-28", "2026-10-04"}
	sweepAfterA  = time.Date(2026, 10, 7, 0, 30, 0, 0, time.UTC)
	sweepBeforeA = time.Date(2026, 10, 6, 23, 30, 0, 0, time.UTC)
)

func sweepRun(t *testing.T, name string, st Store, tid string, now time.Time) HoursSweepResult {
	t.Helper()
	var r HoursSweepResult
	var err error
	if name == "memory" { // its own store: the public, every-workspace entry
		r, err = st.(HoursSweeper).SweepHours(context.Background(), now)
	} else {
		r, err = sweepHoursIn(context.Background(), st.(hoursSweepSource), []string{tid}, now)
	}
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func sweepMember(t *testing.T, st Store, tid, email, role string) string {
	t.Helper()
	id, _, err := st.(MemberProvisioner).ProvisionMember(context.Background(),
		ProvisionInput{Tenant: tid, Email: email, DisplayName: "FirstName LastName", Role: role}, sweepBeforeA)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func sweepMinute(t *testing.T, h Hours, tid, member string, at time.Time, tz string) {
	t.Helper()
	if err := h.UpsertHoursMinutes(context.Background(), tid, member,
		[]HoursMinute{{At: at, Target: "t:a", Src: HoursSrcTab, TZ: tz}}); err != nil {
		t.Fatal(err)
	}
}

func sweepRows(t *testing.T, h Hours, tid string) map[string]HoursPeriod {
	t.Helper()
	rows, err := h.HoursPeriods(context.Background(), tid, "", "2000-01-01", "9999-12-31")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]HoursPeriod{}
	for _, p := range rows {
		out[p.Member+" "+p.Start] = p
	}
	return out
}

func TestHoursSweepFreezesEveryMember(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid := hoursStore(t, st), newTenant(t, st)
			sfx := uid("")
			owner := sweepMember(t, st, tid, "owner-"+sfx+"@example.com", RoleTenantOwner)
			empty := sweepMember(t, st, tid, "empty-"+sfx+"@example.com", rbac.Developer)
			gone := sweepMember(t, st, tid, "gone-"+sfx+"@example.com", rbac.Developer)
			idle := sweepMember(t, st, tid, "idle-"+sfx+"@example.com", rbac.Developer)
			agent := sweepMember(t, st, tid, "agent-"+sfx+"@example.com", rbac.PureAgent)

			// owner: 90 approved + 30 rejected in week A; two minutes in A, one
			// on Sunday 22:30 UTC that is Monday in Helsinki (week B, kept).
			if err := h.PutHoursEntries(ctx, tid, owner, []HoursEntry{hoursEntry("2026-09-29", "t:a", 90),
				{Day: "2026-09-30", Target: "t:b", Minutes: 30, SuggestedMinutes: 30, State: HoursRejected}},
				owner, sweepBeforeA); err != nil {
				t.Fatal(err)
			}
			sweepMinute(t, h, tid, owner, time.Date(2026, 9, 29, 10, 0, 0, 0, time.UTC), "UTC")
			sweepMinute(t, h, tid, owner, time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC), "UTC")
			sweepMinute(t, h, tid, owner, time.Date(2026, 10, 4, 22, 30, 0, 0, time.UTC), "Europe/Helsinki")
			// gone logged a minute in week A, then was removed; idle was removed
			// with nothing logged; an agent id writes a minute (never a row).
			sweepMinute(t, h, tid, gone, time.Date(2026, 9, 30, 11, 0, 0, 0, time.UTC), "UTC")
			sweepMinute(t, h, tid, "c-001", time.Date(2026, 9, 30, 11, 0, 0, 0, time.UTC), "UTC")
			rm := st.(interface {
				RemoveMember(ctx context.Context, tenant, humanID string) error
			})
			for _, id := range []string{gone, idle} {
				if err := rm.RemoveMember(ctx, tid, id); err != nil {
					t.Fatal(err)
				}
			}

			// Before week A's end + grace only the week before it is due.
			sweepRun(t, name, st, tid, sweepBeforeA)
			for k := range sweepRows(t, h, tid) {
				if k[len(k)-10:] != "2026-09-21" {
					t.Fatalf("before week A's end + grace: row %s", k)
				}
			}
			r := sweepRun(t, name, st, tid, sweepAfterA)
			if r.Frozen != 3 || r.Pruned != 3 {
				t.Fatalf("sweep = %+v, want 3 rows (owner, empty, gone) and 3 minutes pruned", r)
			}
			rows := map[string]HoursPeriod{}
			for k, p := range sweepRows(t, h, tid) {
				if p.Start == sweepWeekA[0] {
					rows[k] = p
				}
			}
			want := map[string]int{owner: 90, empty: 0, gone: 0}
			if len(rows) != len(want) {
				t.Fatalf("rows = %v, want one for each of %v", rows, want)
			}
			for id, minutes := range want {
				p, ok := rows[id+" "+sweepWeekA[0]]
				if !ok || p.End != sweepWeekA[1] || p.State != HoursFrozen || p.Minutes != minutes || p.DecidedBy != HoursSweepBy {
					t.Fatalf("row of %s = %+v (found %v), want frozen %s..%s with %d minutes", id, p, ok, sweepWeekA[0], sweepWeekA[1], minutes)
				}
			}
			for _, id := range []string{idle, agent, "c-001"} {
				for k := range rows {
					if k[:len(id)] == id {
						t.Fatalf("%s got a row %s", id, k)
					}
				}
			}
			left, err := h.HoursMinutes(ctx, tid, owner, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC), sweepAfterA)
			if err != nil || len(left) != 1 || left[0].TZ != "Europe/Helsinki" {
				t.Fatalf("owner's minutes after the sweep = %v %v, want only the Helsinki Monday one", left, err)
			}
			if frozen, err := h.HoursFrozenDays(ctx, tid, owner, []string{"2026-10-01", "2026-10-05"}, sweepAfterA); err != nil ||
				!frozen["2026-10-01"] || frozen["2026-10-05"] {
				t.Fatalf("frozen days = %v %v", frozen, err)
			}

			// Idempotent: a re-run writes nothing and changes no row.
			if r := sweepRun(t, name, st, tid, sweepAfterA.Add(time.Hour)); r.Frozen != 0 || r.Pruned != 0 {
				t.Fatalf("re-run = %+v, want nothing", r)
			}
			if again := sweepRows(t, h, tid); len(again) != len(rows)+2 {
				t.Fatalf("re-run rows = %v, want %v", again, rows)
			}
		})
	}
}

func TestHoursSweepPeriodSwitch(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid := hoursStore(t, st), newTenant(t, st)
			m := sweepMember(t, st, tid, "m-"+uid("")+"@example.com", RoleTenantOwner)
			sweepRun(t, name, st, tid, sweepAfterA) // week A frozen
			if _, err := st.(TenantKV).SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{
				HoursKeyPeriod: HoursPeriodMonth}}); err != nil {
				t.Fatal(err)
			}
			// October ends on a Saturday; with grace 2 it freezes Tue 11-03.
			if r := sweepRun(t, name, st, tid, time.Date(2026, 11, 2, 23, 0, 0, 0, time.UTC)); r.Frozen != 0 {
				t.Fatalf("before October's end + grace: froze %d", r.Frozen)
			}
			if r := sweepRun(t, name, st, tid, time.Date(2026, 11, 3, 0, 30, 0, 0, time.UTC)); r.Frozen != 1 {
				t.Fatalf("froze %d, want October's row", r.Frozen)
			}
			rows := sweepRows(t, h, tid)
			oct, ok := rows[m+" 2026-10-05"]
			if len(rows) != 2 || !ok || oct.End != "2026-10-31" {
				t.Fatalf("rows = %v, want week A and 10-05..10-31 (never from 10-01)", rows)
			}
		})
	}
}

func TestHoursSweepAgedMinutes(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid := hoursStore(t, st), newTenant(t, st)
			old, kept := time.Date(2001, 1, 1, 9, 0, 0, 0, time.UTC), time.Date(2001, 2, 20, 9, 0, 0, 0, time.UTC)
			sweepMinute(t, h, tid, hoursMember, old, "UTC")
			sweepMinute(t, h, tid, hoursMember, kept, "UTC")
			now := old.Add(HoursMinuteRetention + time.Hour)
			n, err := st.(hoursSweepSource).pruneAgedHoursMinutes(ctx, now.Add(-HoursMinuteRetention))
			if err != nil || n != 1 {
				t.Fatalf("aged prune = %d %v, want 1", n, err)
			}
			left, err := h.HoursMinutes(ctx, tid, hoursMember, old, kept.Add(time.Minute))
			if err != nil || len(left) != 1 || !left[0].At.Equal(kept) {
				t.Fatalf("left = %v %v, want only %v", left, err, kept)
			}
		})
	}
}
