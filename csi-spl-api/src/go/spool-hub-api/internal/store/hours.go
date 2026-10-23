package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// Hours tracking (spec 107 v1.0, T004; sections 3.2 and 4.2) over rdb 0151's
// hours_minutes, hours_entries and hours_periods. The store owns:
//   - the minute record: an upsert where a post overrides a tab and a tab
//     never overrides a post (spec 1.3), and a member's minutes for a range;
//   - the worker's entries, with the 1440-minute day cap: a day's approved
//     minutes above 1440 are refused, never clamped. The suggestion engine
//     (internal/hours) can propose up to 1500 on a 25-hour DST day; the route
//     that turns suggestions into entries (T006) clamps, this store refuses;
//   - the period rows (the freeze, the return, the biz owner's approval) and
//     the effective-freeze check: a day is frozen when a row covers it in
//     state frozen or approved, or when no row covers it and its period's
//     end + grace has passed in hours.tz. A returned period is editable;
//   - the four registered workspace keys (spec 098) and N, the idle cutoff,
//     with the member's own override (owner Q3 = B).
//
//   - the spans of an entry (spec 107 3.4, rdb 0176 hours_entry_spans): its
//     start and end times, written with the entry. An entry without spans
//     stays valid (spec 118 Q2 A).
//   - the v2 widening (spec 107 v2 T020, rdb 0215): an entry's kind joins
//     its key (work, travel, wait, absence; FR-27), the job: target (FR-18),
//     the proposed and disputed states (FR-23), the absence type (FR-30),
//     who entered it for the member, a reason, and the category split
//     (FR-28). No money field (FR-19).
//
// Privacy (spec 1.7): only this file's Postgres side names hours_minutes, and
// every read takes the member it is for. Every per-member call runs in the
// member scope (inMember, rdb 0176's member_scope): a statement that forgot
// its member_id still reads and writes 0 rows of another member.

// The four workspace settings (spec 4.2), registered keys of tenants.settings.
const (
	HoursKeyPeriod      = "hours.period"
	HoursKeyGraceDays   = "hours.freeze_grace_days"
	HoursKeyIdleMinutes = "hours.idle_minutes"
	HoursKeyTZ          = "hours.tz"
)

// Period kinds (hours.period).
const (
	HoursPeriodWeek     = "week"      // Mon..Sun
	HoursPeriodTwoWeeks = "two_weeks" // two weeks from a fixed Monday
	HoursPeriodMonth    = "month"
)

// The ranges of the idle cutoff N, workspace and member alike.
const (
	HoursIdleMin = 5
	HoursIdleMax = 30
)

// HoursMemberIdleKey is the membership settings key of a member's own N
// (rdb 0078 jsonb, owner Q3 = B); absent or out of range = the workspace's.
const HoursMemberIdleKey = "hours_idle_minutes"

func init() {
	RegisterTenantSetting(TenantSettingDef{Key: HoursKeyPeriod, Kind: SettingString, Default: HoursPeriodWeek,
		OneOf: []string{HoursPeriodWeek, HoursPeriodTwoWeeks, HoursPeriodMonth}})
	RegisterTenantSetting(TenantSettingDef{Key: HoursKeyGraceDays, Kind: SettingInt, Default: 2, Min: 0, Max: 7})
	RegisterTenantSetting(TenantSettingDef{Key: HoursKeyIdleMinutes, Kind: SettingInt, Default: 10,
		Min: HoursIdleMin, Max: HoursIdleMax})
	RegisterTenantSetting(TenantSettingDef{Key: HoursKeyTZ, Kind: SettingString, Default: "UTC",
		MaxLen: auth.TimeZoneMaxLen, Valid: auth.IsTimeZone, ValidHint: "an IANA zone name (e.g. Europe/Helsinki)"})
}

// Minute sources and entry / period states (rdb 0151 CHECKs).
const (
	HoursSrcPost = "post"
	HoursSrcTab  = "tab"

	HoursApproved = "approved" // an entry, or a period the biz owner signed off
	HoursRejected = "rejected" // an entry; counts 0

	// v2 entry states (FR-23): a foreman's row before the worker approves
	// it, and one the worker disputed. Neither counts toward the day cap.
	HoursProposed = "proposed"
	HoursDisputed = "disputed"

	HoursFrozen   = "frozen"
	HoursReturned = "returned"
)

// Entry kinds (rdb 0215 CHECK, FR-27). The kind joins the entry's key: travel
// to a job and work on it are two rows. "" means work (every v1 caller).
const (
	HoursKindWork    = "work"
	HoursKindTravel  = "travel"
	HoursKindWait    = "wait"
	HoursKindAbsence = "absence"
)

// Absence types (rdb 0215 CHECK, FR-30): set exactly on an absence row.
const (
	HoursAbsenceSick     = "sick"
	HoursAbsenceVacation = "vacation"
	HoursAbsenceUnpaid   = "unpaid"
	HoursAbsenceTraining = "training"
	HoursAbsenceHoliday  = "holiday"
)

// Rate categories (FR-28), the keys of HoursEntry.CategoryMinutes. A label
// on hours, never money (FR-19).
const (
	HoursCategoryNormal  = "normal"
	HoursCategoryEvening = "evening"
	HoursCategoryNight   = "night"
	HoursCategoryWeekend = "weekend"
	HoursCategoryHoliday = "holiday"
)

// Span sources (rdb 0176 CHECK). An activity span is an approved
// suggestion's block: it REPLACES the entry's earlier activity spans (a
// suggestion is recomputed whole). Every other source ADDS to what the
// entry holds (a stopped timer adds its interval).
const (
	HoursSpanActivity = "activity"
	HoursSpanTimer    = "timer"
	HoursSpanPlan     = "plan"
	HoursSpanClock    = "clock"
	HoursSpanManual   = "manual"
)

// MaxHoursSpansPerEntry bounds one entry's spans in one write.
const MaxHoursSpansPerEntry = 96

// HoursDayCap is the most minutes a member's approved entries hold in a day.
const HoursDayCap = 1440

// Bounds of one call; the routes take fewer (spec 6.3: <= 60 minutes).
const (
	MaxHoursMinutesBatch = 1440
	MaxHoursEntriesBatch = 400
	MaxHoursNote         = 500
)

var (
	// ErrHoursBad: a row outside the rdb 0151 checks.
	ErrHoursBad = errors.New("store: bad hours row")
	// ErrHoursDayCap: the write would put a day above HoursDayCap.
	ErrHoursDayCap = errors.New("store: a day holds at most 1440 minutes")
	// ErrHoursFrozen: the day is in a frozen or approved period (409 period_frozen).
	ErrHoursFrozen = errors.New("store: the day's hours period is frozen")
	// ErrHoursPeriodState: the period row is not in a state that allows the change.
	ErrHoursPeriodState = errors.New("store: hours period state does not allow the change")
	// ErrHoursOverlap: a span would overlap another span of the member in the
	// workspace, on any target (spec 118 REQ-1; 409 overlap_in_workspace).
	ErrHoursOverlap = errors.New("store: hours span overlaps another span of the member in this workspace")
)

// HoursMinute is one hours_minutes row.
type HoursMinute struct {
	At     time.Time // the minute, truncated, UTC
	Target string    // t:<task_id>, ch:<name>, dm:<peer> or ws
	Src    string    // HoursSrcPost or HoursSrcTab
	TZ     string    // the IANA zone of the minute's day (spec 1.6)
}

// HoursEntry is one hours_entries row: the worker's decision for (day,
// target, kind).
type HoursEntry struct {
	Day              string // YYYY-MM-DD, the member's local day
	Target           string // as HoursMinute, plus cal:<event_id> and job:<job_id>
	Kind             string // HoursKindWork ("" on a write), HoursKindTravel, ...
	Minutes          int
	SuggestedMinutes int
	State            string // HoursApproved, HoursRejected, HoursProposed or HoursDisputed
	Note             string
	AbsenceType      string // HoursAbsenceSick, ...; set exactly when Kind is absence
	EnteredBy        string // who entered it for the member (FR-23); "" = the member
	Reason           string // a travel or wait row's reason (FR-27), <= 500
	// CategoryMinutes is the approved minutes by rate category (FR-28),
	// stored at approval; nil until then.
	CategoryMinutes map[string]int
	UpdatedAt       time.Time
	UpdatedBy       string
	// Spans are written with the entry (spec 107 3.4): activity spans replace
	// the entry's activity spans, other sources add. Never read back here:
	// HoursEntrySpans reads them.
	Spans []HoursSpan
}

// HoursSpan is one interval of an entry: [Start, End), whole minutes, UTC.
type HoursSpan struct {
	Start time.Time
	End   time.Time
	Src   string // HoursSpanActivity, HoursSpanTimer, ...
}

// HoursEntrySpan is one hours_entry_spans row: a span with its entry's key.
type HoursEntrySpan struct {
	Day    string
	Target string
	Kind   string
	HoursSpan
}

// HoursPeriod is one hours_periods row.
type HoursPeriod struct {
	Member    string
	Start     string // YYYY-MM-DD
	End       string // YYYY-MM-DD, inclusive
	State     string // HoursFrozen, HoursReturned or HoursApproved
	Minutes   int
	Note      string
	DecidedBy string
	DecidedAt time.Time
}

// HoursPeriodChange moves a period row: frozen -> approved or returned (Note
// required), returned -> frozen (the worker's Resubmit). Minutes, when set,
// replaces the row's total.
type HoursPeriodChange struct {
	State   string
	Note    string
	Minutes *int
	By      string
	At      time.Time
}

// hoursTransitions: by the state a row moves to, the states it may be in.
var hoursTransitions = map[string][]string{
	HoursApproved: {HoursFrozen},
	HoursReturned: {HoursFrozen},
	HoursFrozen:   {HoursReturned},
}

// Hours is implemented by Memory and Postgres. Every call is for one tenant;
// member is the HUM-* the rows belong to.
type Hours interface {
	// UpsertHoursMinutes writes minutes: a new minute is inserted; an existing
	// tab minute takes the new target, source and zone; a post minute stays.
	UpsertHoursMinutes(ctx context.Context, tenant, member string, ms []HoursMinute) error
	// HoursMinutes is the member's minutes in [from, to), oldest first.
	HoursMinutes(ctx context.Context, tenant, member string, from, to time.Time) ([]HoursMinute, error)
	// HoursEntries is the member's entries of days from..to (inclusive), by
	// day, target, then kind.
	HoursEntries(ctx context.Context, tenant, member, from, to string) ([]HoursEntry, error)
	// PutHoursEntries upserts entries of one member as by, all or none:
	// ErrHoursFrozen for a frozen day, ErrHoursDayCap above the cap.
	PutHoursEntries(ctx context.Context, tenant, member string, es []HoursEntry, by string, now time.Time) error
	// HoursEntrySpans is the spans of the member's entries of days from..to
	// (inclusive), by start.
	HoursEntrySpans(ctx context.Context, tenant, member, from, to string) ([]HoursEntrySpan, error)
	// DeleteHoursEntry removes the work entry of (day, target) (an added
	// row taken back); ErrNotFound when none, ErrHoursFrozen for a frozen day.
	DeleteHoursEntry(ctx context.Context, tenant, member, day, target string, now time.Time) error
	// CreateHoursPeriod inserts a period row; false when the member already has
	// a row from that start (the sweep's idempotent re-run).
	CreateHoursPeriod(ctx context.Context, tenant string, p HoursPeriod) (bool, error)
	// SetHoursPeriodState applies ch to the member's row from start.
	// ErrNotFound: no row. ErrHoursPeriodState: a move hoursTransitions refuses.
	SetHoursPeriodState(ctx context.Context, tenant, member, start string, ch HoursPeriodChange) (HoursPeriod, error)
	// HoursPeriods is the rows overlapping days from..to; member "" = every
	// member (the team view). By start, then member.
	HoursPeriods(ctx context.Context, tenant, member, from, to string) ([]HoursPeriod, error)
	// HoursFrozenDays answers, per day, whether the member's day is frozen now.
	HoursFrozenDays(ctx context.Context, tenant, member string, days []string, now time.Time) (map[string]bool, error)
	// HoursIdleMinutes is N for the member: their own override, else the
	// workspace's hours.idle_minutes.
	HoursIdleMinutes(ctx context.Context, tenant, member string) (int, error)
}

var (
	_ Hours = (*Memory)(nil)
	_ Hours = (*Postgres)(nil)
)

// ---- settings ---------------------------------------------------------------

// HoursSettings are the four keys in force.
type HoursSettings struct {
	Period      string
	GraceDays   int
	IdleMinutes int
	TZ          string
}

// HoursSettingsOf reads the keys from a tenant's settings (defaults applied).
func HoursSettingsOf(v TenantSettingValues) HoursSettings {
	return HoursSettings{Period: v.String(HoursKeyPeriod), GraceDays: v.Int(HoursKeyGraceDays),
		IdleMinutes: v.Int(HoursKeyIdleMinutes), TZ: v.String(HoursKeyTZ)}
}

// Location is hours.tz; UTC when the zone is unknown to this binary.
func (h HoursSettings) Location() *time.Location {
	if loc, err := time.LoadLocation(h.TZ); err == nil && h.TZ != "Local" && h.TZ != "" {
		return loc
	}
	return time.UTC
}

// memberIdleMinutes is the member's own N when it is set and in range.
func memberIdleMinutes(ms auth.MembershipSettings) (int, bool) {
	if ms.HoursIdleMinutes == nil {
		return 0, false
	}
	n := *ms.HoursIdleMinutes
	return n, n >= HoursIdleMin && n <= HoursIdleMax
}

// hoursSettingsSource is what the shared reads need of a store.
type hoursSettingsSource interface {
	GetTenant(ctx context.Context, tenantID string) (Tenant, error)
	MembershipSettings(ctx context.Context, humanID, tenant string) (auth.MembershipSettings, error)
	HoursPeriods(ctx context.Context, tenant, member, from, to string) ([]HoursPeriod, error)
}

func hoursIdleMinutes(ctx context.Context, st hoursSettingsSource, tenant, member string) (int, error) {
	t, err := st.GetTenant(ctx, tenant)
	if err != nil {
		return 0, err
	}
	ms, err := st.MembershipSettings(ctx, member, tenant)
	if err != nil {
		return 0, err
	}
	if n, ok := memberIdleMinutes(ms); ok {
		return n, nil
	}
	return HoursSettingsOf(t.Settings).IdleMinutes, nil
}

// ---- periods and the freeze -------------------------------------------------

const hoursDay = "2006-01-02"

// hoursTwoWeeksAnchor is the Monday every two_weeks period counts from.
var hoursTwoWeeksAnchor = time.Date(1970, 1, 5, 0, 0, 0, 0, time.UTC)

// ParseHoursDay reads YYYY-MM-DD as a civil date (00:00 UTC).
func ParseHoursDay(s string) (time.Time, error) {
	d, err := time.Parse(hoursDay, s)
	if err != nil {
		return time.Time{}, fmt.Errorf("%w: day %q is not YYYY-MM-DD", ErrHoursBad, s)
	}
	return d, nil
}

func addDays(d time.Time, n int) time.Time { return d.AddDate(0, 0, n) }

// HoursPeriodBounds is the period of kind that holds day (civil dates).
func HoursPeriodBounds(kind string, day time.Time) (start, end time.Time) {
	switch kind {
	case HoursPeriodMonth:
		start = time.Date(day.Year(), day.Month(), 1, 0, 0, 0, 0, time.UTC)
		return start, addDays(start.AddDate(0, 1, 0), -1)
	case HoursPeriodTwoWeeks:
		n := int(day.Sub(hoursTwoWeeksAnchor).Hours()) / 24
		k := n / 14
		if n < 0 && n%14 != 0 {
			k--
		}
		start = addDays(hoursTwoWeeksAnchor, 14*k)
		return start, addDays(start, 13)
	default:
		start = addDays(day, -((int(day.Weekday()) + 6) % 7))
		return start, addDays(start, 6)
	}
}

// HoursFreezeAt is when a period ending on end freezes: 00:00 of the day
// after end + grace, in loc (a week with grace 2 freezes Wednesday 00:00).
func HoursFreezeAt(end time.Time, grace int, loc *time.Location) time.Time {
	return time.Date(end.Year(), end.Month(), end.Day()+grace+1, 0, 0, 0, 0, loc)
}

// HoursPeriodFor is the member's period holding day: the row covering it, else
// the bounds of hours.period, starting no earlier than the day after the
// member's latest row before day (a period switch never pulls passed days in,
// spec 4.2). row is nil when no row covers day.
func HoursPeriodFor(day time.Time, rows []HoursPeriod, hs HoursSettings) (start, end time.Time, row *HoursPeriod) {
	ds := day.Format(hoursDay)
	var after time.Time
	for i := range rows {
		r := &rows[i]
		if r.Start <= ds && ds <= r.End {
			s, _ := ParseHoursDay(r.Start)
			e, _ := ParseHoursDay(r.End)
			return s, e, r
		}
		if e, err := ParseHoursDay(r.End); err == nil && r.End < ds && e.After(after) {
			after = e
		}
	}
	start, end = HoursPeriodBounds(hs.Period, day)
	if !after.IsZero() && !start.After(after) {
		start = addDays(after, 1)
	}
	return start, end, nil
}

// HoursDayFrozen is the effective-freeze check of spec 4.2 for one day.
func HoursDayFrozen(day time.Time, rows []HoursPeriod, hs HoursSettings, now time.Time) bool {
	_, end, row := HoursPeriodFor(day, rows, hs)
	if row != nil {
		return row.State != HoursReturned
	}
	return !now.Before(HoursFreezeAt(end, hs.GraceDays, hs.Location()))
}

func hoursFrozenDays(ctx context.Context, st hoursSettingsSource, tenant, member string, days []string, now time.Time) (map[string]bool, error) {
	out := make(map[string]bool, len(days))
	if len(days) == 0 {
		return out, nil
	}
	parsed := make([]time.Time, len(days))
	for i, d := range days {
		p, err := ParseHoursDay(d)
		if err != nil {
			return nil, err
		}
		parsed[i] = p
	}
	t, err := st.GetTenant(ctx, tenant)
	if err != nil {
		return nil, err
	}
	sorted := append([]string(nil), days...)
	sort.Strings(sorted)
	// Rows from the earliest asked day's possible period start: a month back
	// covers every kind; the latest earlier row only clamps a start.
	first, _ := ParseHoursDay(sorted[0])
	from := addDays(first, -62).Format(hoursDay)
	rows, err := st.HoursPeriods(ctx, tenant, member, from, sorted[len(sorted)-1])
	if err != nil {
		return nil, err
	}
	hs := HoursSettingsOf(t.Settings)
	for i, d := range days {
		out[d] = HoursDayFrozen(parsed[i], rows, hs, now)
	}
	return out, nil
}

// refuseFrozen is ErrHoursFrozen when any of days is frozen.
func refuseFrozen(ctx context.Context, st hoursSettingsSource, tenant, member string, days []string, now time.Time) error {
	frozen, err := hoursFrozenDays(ctx, st, tenant, member, days, now)
	if err != nil {
		return err
	}
	for _, d := range days {
		if frozen[d] {
			return fmt.Errorf("%w: %s", ErrHoursFrozen, d)
		}
	}
	return nil
}

// ---- row checks -------------------------------------------------------------

var (
	hoursMinuteTargetRE = regexp.MustCompile(`(?s)^((t|ch|dm):.{1,200}|ws)$`)
	hoursEntryTargetRE  = regexp.MustCompile(`(?s)^((t|ch|dm|cal|job):.{1,200}|ws)$`)
)

func hoursBad(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrHoursBad, fmt.Sprintf(format, a...))
}

// normalizeHoursMinutes checks ms and merges repeats of one minute the way
// the upsert would (a post wins; a later tab replaces an earlier tab), so one
// statement never touches a row twice.
func normalizeHoursMinutes(member string, ms []HoursMinute) ([]HoursMinute, error) {
	if strings.TrimSpace(member) == "" {
		return nil, hoursBad("no member")
	}
	if len(ms) > MaxHoursMinutesBatch {
		return nil, hoursBad("at most %d minutes per write", MaxHoursMinutesBatch)
	}
	at := make(map[int64]int, len(ms))
	out := make([]HoursMinute, 0, len(ms))
	for _, m := range ms {
		m.At = m.At.UTC().Truncate(time.Minute)
		if m.At.IsZero() || !hoursMinuteTargetRE.MatchString(m.Target) || !auth.IsTimeZone(m.TZ) ||
			(m.Src != HoursSrcPost && m.Src != HoursSrcTab) {
			return nil, hoursBad("minute %s %q %q %q", m.At.Format(time.RFC3339), m.Target, m.Src, m.TZ)
		}
		k := m.At.Unix()
		if i, dup := at[k]; dup {
			if out[i].Src == HoursSrcTab {
				out[i] = m
			}
			continue
		}
		at[k] = len(out)
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, nil
}

// normalizeHoursEntries checks es (one row per (day, target, kind)) and
// returns the distinct days they touch.
func normalizeHoursEntries(member, by string, es []HoursEntry) (days []string, err error) {
	if strings.TrimSpace(member) == "" || strings.TrimSpace(by) == "" {
		return nil, hoursBad("no member or author")
	}
	if len(es) == 0 || len(es) > MaxHoursEntriesBatch {
		return nil, hoursBad("1..%d entries per write", MaxHoursEntriesBatch)
	}
	seen := map[hoursEntryKey]bool{}
	dayset := map[string]bool{}
	for i := range es {
		e := &es[i]
		if err := checkHoursEntry(e); err != nil {
			return nil, err
		}
		k := e.key()
		if seen[k] {
			return nil, hoursBad("entry %s %s %s twice", e.Day, e.Target, e.Kind)
		}
		seen[k] = true
		if !dayset[e.Day] {
			dayset[e.Day] = true
			days = append(days, e.Day)
		}
	}
	sort.Strings(days)
	return days, nil
}

// hoursEntryKey is an entry's key within its member (rdb 0216's PK).
type hoursEntryKey struct{ Day, Target, Kind string }

func (e HoursEntry) key() hoursEntryKey { return hoursEntryKey{e.Day, e.Target, e.Kind} }

var (
	hoursEntryStates = map[string]bool{HoursApproved: true, HoursRejected: true, HoursProposed: true, HoursDisputed: true}
	hoursKinds       = map[string]bool{HoursKindWork: true, HoursKindTravel: true, HoursKindWait: true, HoursKindAbsence: true}
	hoursAbsences    = map[string]bool{HoursAbsenceSick: true, HoursAbsenceVacation: true, HoursAbsenceUnpaid: true,
		HoursAbsenceTraining: true, HoursAbsenceHoliday: true}
	hoursCategories = map[string]bool{HoursCategoryNormal: true, HoursCategoryEvening: true, HoursCategoryNight: true,
		HoursCategoryWeekend: true, HoursCategoryHoliday: true}
)

// maxHoursEnteredBy is rdb 0215's bound of entered_by.
const maxHoursEnteredBy = 200

func checkHoursEntry(e *HoursEntry) error {
	if _, err := ParseHoursDay(e.Day); err != nil {
		return err
	}
	e.Note, e.Reason, e.EnteredBy = strings.TrimSpace(e.Note), strings.TrimSpace(e.Reason), strings.TrimSpace(e.EnteredBy)
	if e.Kind == "" {
		e.Kind = HoursKindWork
	}
	switch {
	case !hoursEntryTargetRE.MatchString(e.Target):
		return hoursBad("target %q", e.Target)
	case !hoursKinds[e.Kind]:
		return hoursBad("entry kind %q", e.Kind)
	case e.Minutes < 0 || e.Minutes > HoursDayCap || e.SuggestedMinutes < 0 || e.SuggestedMinutes > HoursDayCap:
		return hoursBad("minutes of %s %s are 0..%d", e.Day, e.Target, HoursDayCap)
	case !hoursEntryStates[e.State]:
		return hoursBad("entry state %q", e.State)
	case (e.Kind == HoursKindAbsence) != (e.AbsenceType != ""):
		return hoursBad("an absence type is set exactly on an absence row (%s %s %q)", e.Kind, e.Target, e.AbsenceType)
	case e.AbsenceType != "" && !hoursAbsences[e.AbsenceType]:
		return hoursBad("absence type %q", e.AbsenceType)
	case len([]rune(e.Note)) > MaxHoursNote || len([]rune(e.Reason)) > MaxHoursNote:
		return hoursBad("a note or a reason is at most %d characters", MaxHoursNote)
	case len([]rune(e.EnteredBy)) > maxHoursEnteredBy:
		return hoursBad("entered by is at most %d characters", maxHoursEnteredBy)
	}
	for c, m := range e.CategoryMinutes {
		if !hoursCategories[c] || m < 0 || m > HoursDayCap {
			return hoursBad("category minutes %q: %d", c, m)
		}
	}
	return checkHoursSpans(e)
}

// checkHoursSpans checks e's spans against rdb 0176's CHECKs and returns
// them in UTC, by start.
func checkHoursSpans(e *HoursEntry) error {
	if len(e.Spans) > MaxHoursSpansPerEntry {
		return hoursBad("at most %d spans per entry", MaxHoursSpansPerEntry)
	}
	if e.Spans == nil {
		return nil
	}
	ss := make([]HoursSpan, len(e.Spans))
	for i, sp := range e.Spans {
		sp.Start, sp.End = sp.Start.UTC(), sp.End.UTC()
		switch {
		case !sp.Start.Equal(sp.Start.Truncate(time.Minute)) || !sp.End.Equal(sp.End.Truncate(time.Minute)):
			return hoursBad("a span of %s %s is not on whole minutes", e.Day, e.Target)
		case !sp.End.After(sp.Start) || sp.End.Sub(sp.Start) > HoursDayCap*time.Minute:
			return hoursBad("a span of %s %s ends before it starts or runs over 1440 minutes", e.Day, e.Target)
		case !hoursSpanSrc[sp.Src]:
			return hoursBad("span source %q", sp.Src)
		}
		ss[i] = sp
	}
	sort.Slice(ss, func(i, j int) bool { return ss[i].Start.Before(ss[j].Start) })
	e.Spans = ss
	return nil
}

var hoursSpanSrc = map[string]bool{HoursSpanActivity: true, HoursSpanTimer: true, HoursSpanPlan: true,
	HoursSpanClock: true, HoursSpanManual: true}

// hoursReplacesActivity says whether e's write replaces its activity spans.
func hoursReplacesActivity(e HoursEntry) bool {
	for _, sp := range e.Spans {
		if sp.Src == HoursSpanActivity {
			return true
		}
	}
	return false
}

// hoursEntryCounts is what an entry adds to its day's total: a rejected row
// counts 0 (spec 4.1).
func hoursEntryCounts(e HoursEntry) int {
	if e.State == HoursApproved {
		return e.Minutes
	}
	return 0
}

func checkHoursPeriod(p *HoursPeriod) error {
	s, err := ParseHoursDay(p.Start)
	if err != nil {
		return err
	}
	e, err := ParseHoursDay(p.End)
	if err != nil {
		return err
	}
	p.Note = strings.TrimSpace(p.Note)
	switch {
	case strings.TrimSpace(p.Member) == "" || strings.TrimSpace(p.DecidedBy) == "":
		return hoursBad("a period needs a member and who decided")
	case e.Before(s):
		return hoursBad("period %s..%s ends before it starts", p.Start, p.End)
	case p.State != HoursFrozen && p.State != HoursReturned && p.State != HoursApproved:
		return hoursBad("period state %q", p.State)
	case p.State == HoursReturned && p.Note == "":
		return hoursBad("a returned period needs a note")
	case p.Minutes < 0 || len([]rune(p.Note)) > MaxHoursNote:
		return hoursBad("period minutes or note")
	}
	return nil
}

// checkHoursPeriodChange checks ch and returns the states the row may be in.
func checkHoursPeriodChange(ch *HoursPeriodChange) (from []string, err error) {
	from = hoursTransitions[ch.State]
	ch.Note = strings.TrimSpace(ch.Note)
	switch {
	case len(from) == 0:
		return nil, hoursBad("period state %q", ch.State)
	case strings.TrimSpace(ch.By) == "":
		return nil, hoursBad("who decided")
	case ch.State == HoursReturned && ch.Note == "":
		return nil, hoursBad("a returned period needs a note")
	case len([]rune(ch.Note)) > MaxHoursNote || (ch.Minutes != nil && *ch.Minutes < 0):
		return nil, hoursBad("period minutes or note")
	}
	if ch.At.IsZero() {
		ch.At = time.Now()
	}
	ch.At = ch.At.UTC()
	return from, nil
}

// applyHoursPeriodChange is the row after ch: a return sets the note, any
// other move keeps it.
func applyHoursPeriodChange(p HoursPeriod, ch HoursPeriodChange) HoursPeriod {
	p.State, p.DecidedBy, p.DecidedAt = ch.State, ch.By, ch.At
	if ch.State == HoursReturned {
		p.Note = ch.Note
	}
	if ch.Minutes != nil {
		p.Minutes = *ch.Minutes
	}
	return p
}
