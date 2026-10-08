package store

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The hours freeze sweep (spec 107 v1.0, T007; section 4.2), run on the hub's
// retention tick. For each workspace, at period end + grace in hours.tz:
//   - a `frozen` hours_periods row for every current human member, plus any
//     member with an entry or a minute in the period (a member removed
//     mid-period who logged time). A member with nothing gets a 0 row: the biz
//     owner signs off a zero, never a missing row. Agents never get a row;
//   - the row's minutes are the member's approved entries. Suggestions nobody
//     approved count zero (owner Q2, panel answer A): nothing is auto-approved;
//   - in the same transaction, the period's raw minutes are pruned.
//
// Then every minute older than HoursMinuteRetention is pruned, in any workspace.
//
// Periods follow hours.period from the day after the member's latest row (or,
// for a member with no row, the workspace's latest row), so a switch week ->
// month never pulls passed days into a new period. The freeze itself is exact
// without the sweep (HoursDayFrozen): the sweep only persists it. A re-run
// writes nothing new (the insert is ON CONFLICT DO NOTHING).

// HoursMinuteRetention: no raw minute outlives this, frozen or not (spec 1.7).
const HoursMinuteRetention = 45 * 24 * time.Hour

// HoursSweepBy is hours_periods.decided_by for a row the sweep wrote.
const HoursSweepBy = "sweep"

// hoursSweepLookback bounds, in days, how far back the sweep looks for rows
// and work: a month period plus the longest grace fits twice. Older days are
// frozen by the write path's check whatever the sweep did, and their minutes
// are gone.
const hoursSweepLookback = 70

// hoursSweepMaxPeriods bounds the periods one member is frozen in one run.
const hoursSweepMaxPeriods = 64

// HoursSweepResult counts one run.
type HoursSweepResult struct {
	Frozen int // hours_periods rows written
	Pruned int // minutes of frozen periods deleted
	Aged   int // minutes older than HoursMinuteRetention deleted
}

// HoursSweeper is implemented by Memory and Postgres.
type HoursSweeper interface {
	SweepHours(ctx context.Context, now time.Time) (HoursSweepResult, error)
}

var (
	_ HoursSweeper = (*Memory)(nil)
	_ HoursSweeper = (*Postgres)(nil)
)

// hoursSweepSource is what the shared run needs of a store.
type hoursSweepSource interface {
	GetTenant(ctx context.Context, tenantID string) (Tenant, error)
	ListMembers(ctx context.Context, tenant string) ([]Member, error)
	HoursPeriods(ctx context.Context, tenant, member, from, to string) ([]HoursPeriod, error)
	// hoursSweepTenants is every workspace.
	hoursSweepTenants(ctx context.Context) ([]string, error)
	// hoursActiveMembers is the humans (never an agent) with an entry or a
	// minute on a local day in from..to.
	hoursActiveMembers(ctx context.Context, tenant, from, to string) (map[string]bool, error)
	// freezeHoursPeriod writes p (state frozen, its minutes the member's
	// approved entries of p's days) unless the member has a row from p.Start,
	// and prunes the member's minutes of p's days; one transaction.
	freezeHoursPeriod(ctx context.Context, tenant string, p HoursPeriod) (created bool, pruned int, err error)
	// pruneAgedHoursMinutes deletes every minute before before, any workspace.
	pruneAgedHoursMinutes(ctx context.Context, before time.Time) (int, error)
}

// hoursNoRow: roles that are not a worker. A pure agent seat is an agent;
// a demo visitor (specs/077) is a stay, not a worker.
var hoursNoRow = map[string]bool{rbac.PureAgent: true, rbac.DemoUser: true}

func sweepHours(ctx context.Context, st hoursSweepSource, now time.Time) (HoursSweepResult, error) {
	tenants, err := st.hoursSweepTenants(ctx)
	if err != nil {
		return HoursSweepResult{}, err
	}
	r, firstErr := sweepHoursIn(ctx, st, tenants, now)
	n, err := st.pruneAgedHoursMinutes(ctx, now.Add(-HoursMinuteRetention))
	r.Aged = n
	if firstErr == nil {
		firstErr = err
	}
	return r, firstErr
}

// sweepHoursIn freezes the due periods of tenants; one workspace's failure
// does not stop the others, the first is returned.
func sweepHoursIn(ctx context.Context, st hoursSweepSource, tenants []string, now time.Time) (HoursSweepResult, error) {
	var r HoursSweepResult
	var firstErr error
	for _, tenant := range tenants {
		if err := sweepHoursTenant(ctx, st, tenant, now, &r); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return r, firstErr
}

func sweepHoursTenant(ctx context.Context, st hoursSweepSource, tenant string, now time.Time, r *HoursSweepResult) error {
	t, err := st.GetTenant(ctx, tenant)
	if err != nil {
		return err
	}
	hs := HoursSettingsOf(t.Settings)
	ln := now.In(hs.Location())
	today := time.Date(ln.Year(), ln.Month(), ln.Day(), 0, 0, 0, 0, time.UTC)
	floor := addDays(today, -hoursSweepLookback)
	from, to := floor.Format(hoursDay), today.Format(hoursDay)

	rows, err := st.HoursPeriods(ctx, tenant, "", from, "9999-12-31")
	if err != nil {
		return err
	}
	latest := map[string]time.Time{}
	var wsLatest time.Time
	for _, p := range rows {
		e, err := ParseHoursDay(p.End)
		if err != nil {
			continue
		}
		if e.After(latest[p.Member]) {
			latest[p.Member] = e
		}
		if e.After(wsLatest) {
			wsLatest = e
		}
	}
	members, err := st.ListMembers(ctx, tenant)
	if err != nil {
		return err
	}
	listed, current := map[string]bool{}, map[string]bool{}
	for _, m := range members {
		listed[m.HumanID] = true
		current[m.HumanID] = !hoursNoRow[m.Role]
	}
	active, err := st.hoursActiveMembers(ctx, tenant, from, to)
	if err != nil {
		return err
	}
	candidates := map[string]bool{}
	for id, ok := range current {
		if ok {
			candidates[id] = true
		}
	}
	for id := range active {
		if !listed[id] {
			candidates[id] = true // removed mid-period, logged time
		}
	}
	first := hoursFirstDue(hs, today, now)
	run := hoursSweepRun{st: st, tenant: tenant, hs: hs, now: now, r: r}
	for id := range candidates {
		c := first
		switch {
		case !latest[id].IsZero():
			c = addDays(latest[id], 1)
		case !wsLatest.IsZero():
			c = addDays(wsLatest, 1)
		}
		if c.Before(floor) {
			c = floor
		}
		if err := run.member(ctx, id, current[id], c); err != nil {
			return err
		}
	}
	return nil
}

// hoursFirstDue is the start of the latest period already due at now: where
// a workspace with no row at all starts, so its first sweep freezes one
// period, not the history before hours tracking existed.
func hoursFirstDue(hs HoursSettings, today, now time.Time) time.Time {
	s, e := HoursPeriodBounds(hs.Period, today)
	for i := 0; i < 3 && now.Before(HoursFreezeAt(e, hs.GraceDays, hs.Location())); i++ {
		s, e = HoursPeriodBounds(hs.Period, addDays(s, -1))
	}
	return s
}

// hoursSweepRun is one workspace's sweep: its store, settings and clock, and
// the counts it adds to.
type hoursSweepRun struct {
	st     hoursSweepSource
	tenant string
	hs     HoursSettings
	now    time.Time
	r      *HoursSweepResult
}

// member freezes the member's due periods from day c on. A member who is no
// longer current gets a row only for a period they logged in.
func (w hoursSweepRun) member(ctx context.Context, id string, current bool, c time.Time) error {
	st, tenant, hs, now, r := w.st, w.tenant, w.hs, w.now, w.r
	for i := 0; i < hoursSweepMaxPeriods; i++ {
		start, end := HoursPeriodBounds(hs.Period, c)
		if start.Before(c) {
			start = c // never pull passed days into a new period (spec 4.2)
		}
		if now.Before(HoursFreezeAt(end, hs.GraceDays, hs.Location())) {
			return nil
		}
		s, e := start.Format(hoursDay), end.Format(hoursDay)
		write := current
		if !write {
			act, err := st.hoursActiveMembers(ctx, tenant, s, e)
			if err != nil {
				return err
			}
			write = act[id]
		}
		if write {
			created, pruned, err := st.freezeHoursPeriod(ctx, tenant, HoursPeriod{Member: id, Start: s, End: e,
				State: HoursFrozen, DecidedBy: HoursSweepBy, DecidedAt: now})
			if err != nil {
				return err
			}
			if created {
				r.Frozen++
			}
			r.Pruned += pruned
		}
		c = addDays(end, 1)
	}
	return nil
}

// hoursMinuteDay is the member's local day of a minute, in the zone it was
// written with (spec 1.6); UTC when this binary does not know the zone.
func hoursMinuteDay(m HoursMinute) string {
	loc, err := time.LoadLocation(m.TZ)
	if err != nil {
		loc = time.UTC
	}
	return m.At.In(loc).Format(hoursDay)
}
