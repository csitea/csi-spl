package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hours"
)

// Spec 107 T004 (sections 3.2, 4.2): the hours store on Memory and Postgres
// (SPOOL_TEST_PG_DSN; every Postgres call runs in the tenant's RLS scope).
// Post-over-tab precedence, the 1440-minute day cap (also for a 25-hour DST
// day the suggestion engine fills with 1500), the effective freeze with and
// without a period row, a returned period editable, the period moves, the
// four 098 keys and the member's own idle cutoff.

const hoursMember = "33333333-3333-4333-8333-333333333333"

var hoursT0 = time.Date(2026, 10, 7, 9, 0, 0, 0, time.UTC) // a Wednesday

func hoursStore(t *testing.T, st Store) Hours {
	t.Helper()
	h, ok := st.(Hours)
	if !ok {
		t.Fatal("store does not implement Hours")
	}
	return h
}

func TestHoursMinutesPostOverTab(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid, other := hoursStore(t, st), newTenant(t, st), newTenant(t, st)
			m0, m1, m2 := hoursT0, hoursT0.Add(time.Minute), hoursT0.Add(2*time.Minute)
			put := func(ms ...HoursMinute) {
				t.Helper()
				if err := h.UpsertHoursMinutes(ctx, tid, hoursMember, ms); err != nil {
					t.Fatal(err)
				}
			}
			// m0: tab, then a post takes it. m1: post, then a tab leaves it.
			// m2: tab, then a later tab replaces it. The seconds are truncated.
			put(HoursMinute{At: m0.Add(17 * time.Second), Target: "ch:lobby", Src: HoursSrcTab, TZ: "UTC"},
				HoursMinute{At: m1, Target: "t:a", Src: HoursSrcPost, TZ: "UTC"},
				HoursMinute{At: m2, Target: "ws", Src: HoursSrcTab, TZ: "UTC"})
			put(HoursMinute{At: m0, Target: "t:b", Src: HoursSrcPost, TZ: "Europe/Helsinki"},
				HoursMinute{At: m1, Target: "ch:lobby", Src: HoursSrcTab, TZ: "UTC"},
				HoursMinute{At: m2, Target: "dm:HUM-2", Src: HoursSrcTab, TZ: "UTC"})
			// One batch naming a minute twice: the post wins, as the upsert would.
			put(HoursMinute{At: m2.Add(time.Minute), Target: "t:c", Src: HoursSrcPost, TZ: "UTC"},
				HoursMinute{At: m2.Add(time.Minute), Target: "ws", Src: HoursSrcTab, TZ: "UTC"})

			got, err := h.HoursMinutes(ctx, tid, hoursMember, m0, m0.Add(time.Hour))
			if err != nil {
				t.Fatal(err)
			}
			want := []HoursMinute{
				{At: m0, Target: "t:b", Src: HoursSrcPost, TZ: "Europe/Helsinki"},
				{At: m1, Target: "t:a", Src: HoursSrcPost, TZ: "UTC"},
				{At: m2, Target: "dm:HUM-2", Src: HoursSrcTab, TZ: "UTC"},
				{At: m2.Add(time.Minute), Target: "t:c", Src: HoursSrcPost, TZ: "UTC"},
			}
			if len(got) != len(want) {
				t.Fatalf("minutes: %+v", got)
			}
			for i := range want {
				if !got[i].At.Equal(want[i].At) || got[i].Target != want[i].Target || got[i].Src != want[i].Src || got[i].TZ != want[i].TZ {
					t.Errorf("minute %d: got %+v want %+v", i, got[i], want[i])
				}
			}
			// The range is half-open, per member, per workspace.
			if got, _ := h.HoursMinutes(ctx, tid, hoursMember, m1, m2); len(got) != 1 || got[0].Target != "t:a" {
				t.Errorf("[m1, m2): %+v", got)
			}
			if got, _ := h.HoursMinutes(ctx, tid, "44444444-4444-4444-8444-444444444444", m0, m0.Add(time.Hour)); len(got) != 0 {
				t.Errorf("another member reads %+v", got)
			}
			if got, _ := h.HoursMinutes(ctx, other, hoursMember, m0, m0.Add(time.Hour)); len(got) != 0 {
				t.Errorf("another workspace reads %+v", got)
			}
			for _, bad := range []HoursMinute{
				{At: m0, Target: "x:1", Src: HoursSrcTab, TZ: "UTC"},
				{At: m0, Target: "ws", Src: "typing", TZ: "UTC"},
				{At: m0, Target: "ws", Src: HoursSrcTab, TZ: "not a zone"},
			} {
				if err := h.UpsertHoursMinutes(ctx, tid, hoursMember, []HoursMinute{bad}); !errors.Is(err, ErrHoursBad) {
					t.Errorf("%+v: %v", bad, err)
				}
			}
		})
	}
}

func hoursEntry(day, target string, minutes int) HoursEntry {
	return HoursEntry{Day: day, Target: target, Minutes: minutes, SuggestedMinutes: minutes, State: HoursApproved}
}

func TestHoursEntriesDayCap(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid := hoursStore(t, st), newTenant(t, st)
			const day = "2026-10-07"
			if err := h.PutHoursEntries(ctx, tid, hoursMember, []HoursEntry{
				hoursEntry(day, "t:a", 1000), hoursEntry(day, "cal:ev1", 440)}, hoursMember, hoursT0); err != nil {
				t.Fatalf("1440 exactly: %v", err)
			}
			// One more minute is refused, and the whole write with it.
			err := h.PutHoursEntries(ctx, tid, hoursMember, []HoursEntry{
				hoursEntry(day, "t:a", 999), hoursEntry(day, "ws", 2)}, hoursMember, hoursT0)
			if !errors.Is(err, ErrHoursDayCap) {
				t.Fatalf("1441: %v", err)
			}
			es, _ := h.HoursEntries(ctx, tid, hoursMember, day, day)
			if len(es) != 2 || es[0].Target != "cal:ev1" || es[1].Minutes != 1000 {
				t.Fatalf("a refused write left %+v", es)
			}
			// A rejected row counts 0: rejecting t:a frees room for ws.
			rej := hoursEntry(day, "t:a", 1000)
			rej.State, rej.Note = HoursRejected, "  not work  "
			if err := h.PutHoursEntries(ctx, tid, hoursMember, []HoursEntry{rej, hoursEntry(day, "ws", 900)}, hoursMember, hoursT0); err != nil {
				t.Fatalf("rejected counts 0: %v", err)
			}
			es, _ = h.HoursEntries(ctx, tid, hoursMember, day, day)
			if len(es) != 3 || es[1].State != HoursRejected || es[1].Note != "not work" || es[1].UpdatedBy != hoursMember {
				t.Fatalf("entries: %+v", es)
			}
			// Delete an added row; a second delete is not found.
			if err := h.DeleteHoursEntry(ctx, tid, hoursMember, day, "ws", hoursT0); err != nil {
				t.Fatal(err)
			}
			if err := h.DeleteHoursEntry(ctx, tid, hoursMember, day, "ws", hoursT0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second delete: %v", err)
			}
			for _, bad := range [][]HoursEntry{
				{hoursEntry(day, "t:a", 1441)},
				{hoursEntry("2026-13-01", "t:a", 1)},
				{hoursEntry(day, "x:1", 1)},
				{hoursEntry(day, "t:a", 1), hoursEntry(day, "t:a", 2)},
				{{Day: day, Target: "t:a", Minutes: 1, State: "maybe"}},
			} {
				if err := h.PutHoursEntries(ctx, tid, hoursMember, bad, hoursMember, hoursT0); !errors.Is(err, ErrHoursBad) {
					t.Errorf("%+v: %v", bad, err)
				}
			}
		})
	}
}

// TestHoursDSTDayCap: the 25-hour day Europe/Helsinki has on 2026-10-25. The
// suggestion engine fills it with 1500 minutes; the store refuses them, one
// row (ErrHoursBad) or split (ErrHoursDayCap). T006 clamps before it writes.
func TestHoursDSTDayCap(t *testing.T) {
	ctx := context.Background()
	loc, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		t.Skip("no tzdata:", err)
	}
	from := time.Date(2026, 10, 25, 0, 0, 0, 0, loc)
	to := time.Date(2026, 10, 26, 0, 0, 0, 0, loc)
	var ms []hours.Minute
	for at := from; at.Before(to); at = at.Add(time.Minute) {
		target := "t:a"
		if at.Sub(from) >= 750*time.Minute {
			target = "t:b"
		}
		ms = append(ms, hours.Minute{At: at, Target: target, Src: hours.SrcPost})
	}
	days, err := hours.Suggest(hours.Input{Minutes: ms, IdleMinutes: 10, Loc: loc})
	if err != nil || len(days) != 1 || days[0].Date != "2026-10-25" || days[0].Minutes != 1500 {
		t.Fatalf("suggested %+v %v", days, err)
	}
	var es []HoursEntry
	for _, r := range days[0].Rows {
		es = append(es, hoursEntry(days[0].Date, r.Target, r.Minutes))
	}
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid := hoursStore(t, st), newTenant(t, st)
			if err := h.PutHoursEntries(ctx, tid, hoursMember, es, hoursMember, hoursT0); !errors.Is(err, ErrHoursDayCap) {
				t.Fatalf("1500 in two rows: %v", err)
			}
			one := []HoursEntry{hoursEntry("2026-10-25", "t:a", 1500)}
			if err := h.PutHoursEntries(ctx, tid, hoursMember, one, hoursMember, hoursT0); !errors.Is(err, ErrHoursBad) {
				t.Fatalf("1500 in one row: %v", err)
			}
			if got, _ := h.HoursEntries(ctx, tid, hoursMember, "2026-10-25", "2026-10-25"); len(got) != 0 {
				t.Fatalf("stored %+v", got)
			}
		})
	}
}

func TestHoursEffectiveFreeze(t *testing.T) {
	ctx := context.Background()
	if _, err := time.LoadLocation("Europe/Helsinki"); err != nil {
		t.Skip("no tzdata:", err)
	}
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid, zone := hoursStore(t, st), newTenant(t, st), "Europe/Helsinki"
			if _, err := st.(TenantKV).SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{
				HoursKeyTZ: zone}}); err != nil {
				t.Fatal(err)
			}
			// Week Mon 2026-10-05 .. Sun 10-11, grace 2: frozen from Wed 10-14
			// 00:00 Helsinki (EEST) = 10-13 21:00 UTC, with no row at all.
			freeze := time.Date(2026, 10, 13, 21, 0, 0, 0, time.UTC)
			days := []string{"2026-10-05", "2026-10-11", "2026-10-12"}
			got, err := h.HoursFrozenDays(ctx, tid, hoursMember, days, freeze.Add(-time.Second))
			if err != nil || got["2026-10-05"] || got["2026-10-11"] || got["2026-10-12"] {
				t.Fatalf("before the freeze: %v %v", got, err)
			}
			got, _ = h.HoursFrozenDays(ctx, tid, hoursMember, days, freeze)
			if !got["2026-10-05"] || !got["2026-10-11"] || got["2026-10-12"] {
				t.Fatalf("at the freeze, no row: %v", got)
			}
			if err := h.PutHoursEntries(ctx, tid, hoursMember, []HoursEntry{hoursEntry("2026-10-09", "ws", 30)},
				hoursMember, freeze); !errors.Is(err, ErrHoursFrozen) {
				t.Fatalf("write after the freeze, no row: %v", err)
			}

			// A frozen row freezes its days before the clock does.
			next := HoursPeriod{Member: hoursMember, Start: "2026-10-12", End: "2026-10-18", State: HoursFrozen, DecidedBy: "sweep"}
			if ok, err := h.CreateHoursPeriod(ctx, tid, next); err != nil || !ok {
				t.Fatalf("create: %v %v", ok, err)
			}
			if got, _ := h.HoursFrozenDays(ctx, tid, hoursMember, []string{"2026-10-12"}, freeze); !got["2026-10-12"] {
				t.Fatalf("frozen row: %v", got)
			}
			// Returned: editable again although its end + grace has passed.
			if _, err := h.SetHoursPeriodState(ctx, tid, hoursMember, "2026-10-12", HoursPeriodChange{
				State: HoursReturned, Note: "fix Tuesday", By: "biz"}); err != nil {
				t.Fatal(err)
			}
			late := freeze.Add(30 * 24 * time.Hour)
			if got, _ := h.HoursFrozenDays(ctx, tid, hoursMember, []string{"2026-10-13"}, late); got["2026-10-13"] {
				t.Fatalf("returned is editable: %v", got)
			}
			if err := h.PutHoursEntries(ctx, tid, hoursMember, []HoursEntry{hoursEntry("2026-10-13", "ws", 30)},
				hoursMember, late); err != nil {
				t.Fatalf("write in a returned period: %v", err)
			}
			// Resubmit, then the biz owner approves: frozen for good.
			for _, s := range []string{HoursFrozen, HoursApproved} {
				if _, err := h.SetHoursPeriodState(ctx, tid, hoursMember, "2026-10-12", HoursPeriodChange{State: s, By: "x"}); err != nil {
					t.Fatal(s, err)
				}
				if err := h.DeleteHoursEntry(ctx, tid, hoursMember, "2026-10-13", "ws", late); !errors.Is(err, ErrHoursFrozen) {
					t.Fatalf("%s: delete %v", s, err)
				}
			}
		})
	}
}

func TestHoursPeriodRows(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid, other := hoursStore(t, st), newTenant(t, st), newTenant(t, st)
			p := HoursPeriod{Member: hoursMember, Start: "2026-09-28", End: "2026-10-04", State: HoursFrozen,
				Minutes: 600, DecidedBy: "sweep", DecidedAt: hoursT0}
			if ok, err := h.CreateHoursPeriod(ctx, tid, p); err != nil || !ok {
				t.Fatalf("create: %v %v", ok, err)
			}
			if ok, err := h.CreateHoursPeriod(ctx, tid, p); err != nil || ok {
				t.Fatalf("re-run: %v %v", ok, err)
			}
			b := p
			b.Member = "44444444-4444-4444-8444-444444444444"
			if _, err := h.CreateHoursPeriod(ctx, tid, b); err != nil {
				t.Fatal(err)
			}
			ret := func(ch HoursPeriodChange) (HoursPeriod, error) {
				return h.SetHoursPeriodState(ctx, tid, hoursMember, p.Start, ch)
			}
			if _, err := ret(HoursPeriodChange{State: HoursReturned, By: "biz"}); !errors.Is(err, ErrHoursBad) {
				t.Fatalf("return without a note: %v", err)
			}
			if _, err := ret(HoursPeriodChange{State: HoursFrozen, By: "w"}); !errors.Is(err, ErrHoursPeriodState) {
				t.Fatalf("resubmit a frozen row: %v", err)
			}
			got, err := ret(HoursPeriodChange{State: HoursReturned, Note: "Tuesday?", By: "biz", At: hoursT0})
			if err != nil || got.State != HoursReturned || got.Note != "Tuesday?" || got.Minutes != 600 || got.DecidedBy != "biz" {
				t.Fatalf("return: %+v %v", got, err)
			}
			if _, err := ret(HoursPeriodChange{State: HoursApproved, By: "biz"}); !errors.Is(err, ErrHoursPeriodState) {
				t.Fatalf("approve a returned row: %v", err)
			}
			n := 540
			if got, err = ret(HoursPeriodChange{State: HoursFrozen, Minutes: &n, By: hoursMember}); err != nil || got.Minutes != 540 || got.Note != "Tuesday?" {
				t.Fatalf("resubmit: %+v %v", got, err)
			}
			if got, err = ret(HoursPeriodChange{State: HoursApproved, By: "biz"}); err != nil || got.State != HoursApproved {
				t.Fatalf("approve: %+v %v", got, err)
			}
			if _, err := ret(HoursPeriodChange{State: HoursReturned, Note: "x", By: "biz"}); !errors.Is(err, ErrHoursPeriodState) {
				t.Fatalf("approved is final: %v", err)
			}
			if _, err := h.SetHoursPeriodState(ctx, other, hoursMember, p.Start, HoursPeriodChange{State: HoursApproved, By: "biz"}); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another workspace: %v", err)
			}
			all, _ := h.HoursPeriods(ctx, tid, "", "2026-10-04", "2026-10-04")
			mine, _ := h.HoursPeriods(ctx, tid, hoursMember, "2026-09-01", "2026-12-31")
			none, _ := h.HoursPeriods(ctx, tid, "", "2026-10-05", "2026-10-31")
			theirs, _ := h.HoursPeriods(ctx, other, "", "2026-09-01", "2026-12-31")
			if len(all) != 2 || all[0].Member != hoursMember || len(mine) != 1 || mine[0].End != "2026-10-04" || len(none) != 0 || len(theirs) != 0 {
				t.Fatalf("periods all=%+v mine=%+v none=%+v theirs=%+v", all, mine, none, theirs)
			}
		})
	}
}

func TestHoursSettingsKeys(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			kv := st.(TenantKV)
			tn, _ := st.GetTenant(ctx, tid)
			if hs := HoursSettingsOf(tn.Settings); hs != (HoursSettings{Period: "week", GraceDays: 2, IdleMinutes: 10, TZ: "UTC"}) {
				t.Fatalf("defaults: %+v", hs)
			}
			for k, v := range map[string]any{HoursKeyPeriod: "day", HoursKeyGraceDays: 8, HoursKeyIdleMinutes: 4,
				HoursKeyTZ: "not a zone"} {
				if _, err := kv.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{k: v}}); !errors.Is(err, ErrBadTenantSetting) {
					t.Errorf("%s=%v: %v", k, v, err)
				}
			}
			if _, err := kv.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{HoursKeyPeriod: "month",
				HoursKeyGraceDays: 0, HoursKeyIdleMinutes: 30, HoursKeyTZ: "America/Argentina/Buenos_Aires"}}); err != nil {
				t.Fatal(err)
			}
			tn, _ = st.GetTenant(ctx, tid)
			if hs := HoursSettingsOf(tn.Settings); hs != (HoursSettings{Period: "month", GraceDays: 0, IdleMinutes: 30, TZ: "America/Argentina/Buenos_Aires"}) {
				t.Fatalf("set: %+v", hs)
			}
		})
	}
}

// TestHoursMemberIdleMinutes: owner Q3 = B, a member's own N wins over the
// workspace's; out of 5..30 it is ignored.
func TestHoursMemberIdleMinutes(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			h, tid := hoursStore(t, st), newTenant(t, st)
			hum := st.(Humans)
			email := uid("h") + "@example.com"
			if err := hum.PutInvite(ctx, Invite{TenantID: tid, Email: email, Role: "developer", InvitedBy: AdmittedOperator,
				ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			member, err := hum.Admit(ctx, Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			ms := st.(membershipSettingsStore)
			for _, c := range []struct {
				workspace, own any
				want           int
			}{{nil, nil, 10}, {15, nil, 15}, {15, 20, 20}, {15, 40, 15}, {nil, 5, 5}} {
				p := TenantSettingsPatch{Unset: []string{HoursKeyIdleMinutes}}
				if c.workspace != nil {
					p = TenantSettingsPatch{Set: map[string]any{HoursKeyIdleMinutes: c.workspace}}
				}
				if _, err := st.(TenantKV).SetTenantSettings(ctx, tid, p); err != nil {
					t.Fatal(err)
				}
				if err := ms.SetMembershipSettings(ctx, member, tid, map[string]any{HoursMemberIdleKey: c.own}); err != nil {
					t.Fatal(err)
				}
				if got, err := h.HoursIdleMinutes(ctx, tid, member); err != nil || got != c.want {
					t.Errorf("workspace %v own %v: %d %v, want %d", c.workspace, c.own, got, err, c.want)
				}
			}
		})
	}
}

func TestHoursPeriodBounds(t *testing.T) {
	d := func(s string) time.Time { x, _ := ParseHoursDay(s); return x }
	for _, c := range []struct{ kind, day, start, end string }{
		{"week", "2026-10-07", "2026-10-05", "2026-10-11"},
		{"week", "2026-10-11", "2026-10-05", "2026-10-11"},
		{"week", "2026-10-05", "2026-10-05", "2026-10-11"},
		{"two_weeks", "1970-01-05", "1970-01-05", "1970-01-18"},
		{"two_weeks", "1970-01-04", "1969-12-22", "1970-01-04"},
		{"two_weeks", "2026-10-07", "2026-09-28", "2026-10-11"},
		{"two_weeks", "2026-10-12", "2026-10-12", "2026-10-25"},
		{"month", "2026-02-14", "2026-02-01", "2026-02-28"},
		{"month", "2028-02-29", "2028-02-01", "2028-02-29"},
	} {
		s, e := HoursPeriodBounds(c.kind, d(c.day))
		if s.Format(hoursDay) != c.start || e.Format(hoursDay) != c.end {
			t.Errorf("%s %s: %s..%s, want %s..%s", c.kind, c.day, s.Format(hoursDay), e.Format(hoursDay), c.start, c.end)
		}
	}
	// week -> month: the open month starts after the member's last frozen week.
	rows := []HoursPeriod{{Start: "2026-10-05", End: "2026-10-11", State: HoursFrozen}}
	s, e, row := HoursPeriodFor(d("2026-10-20"), rows, HoursSettings{Period: "month"})
	if row != nil || s.Format(hoursDay) != "2026-10-12" || e.Format(hoursDay) != "2026-10-31" {
		t.Errorf("after a switch: %s..%s %v", s.Format(hoursDay), e.Format(hoursDay), row)
	}
	if _, _, row = HoursPeriodFor(d("2026-10-08"), rows, HoursSettings{Period: "month"}); row == nil {
		t.Error("a covered day has its row")
	}
}
