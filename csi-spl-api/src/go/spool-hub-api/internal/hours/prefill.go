// SPDX-License-Identifier: AGPL-3.0-only

package hours

// Prefill is the v2 prefill chain of spec 107 FR-17 (T023): per member and
// day, the plan, the resolved standard day, absences, holidays, foreman rows,
// clock times and the v1 activity rows of Suggest become the day's suggested
// rows, each with its kind, source and an evidence flag. It is pure like
// Suggest: no store, no clock of its own; every 098 key, the person's
// resolved standard day (FR-14) and the Standard Day switch (FR-15) are
// resolved by the caller. An entry always beats the chain (2.3): the caller
// replaces a suggestion by its entry, as v1 does.
//
// The chain, per day, first match wins (FR-17):
//
//  1. An absence or holiday (FR-29, FR-30). A whole-day one is the day, at
//     the standard day; on a day whose standard day is 0 (not a working
//     day) it adds nothing. A part-day one takes its minutes and the next
//     step fills the rest: the standard day minus those minutes caps steps
//     2, 3 and 5, and is the Standard Day's target in step 4. An absence
//     beats the plan; an explicit plan row on the day beats a holiday, an
//     inherited one does not (FR-16).
//  2. Foreman rows (FR-23): proposed, with evidence.
//  3. The plan (FR-16): each shift to its job, travel between two plan rows
//     of a day to the second job (FR-27, U3), the break deducted (FR-26).
//     A shift that ends after midnight splits at the member's local
//     midnight; a day holding only the tail of yesterday's shift is a plan
//     day too.
//  4. The Standard Day (FR-15), when on and the day's standard day is above
//     0: activity scaled to the standard day (largest remainder), an excess
//     kept; no activity is one row to the default target, marked no
//     activity and without evidence.
//  5. A clock in (and out) only (FR-24): end - start - break to the default
//     target.
//  6. The v1 activity rows, as Suggest made them: with the Standard Day
//     off, or on a day whose standard day is 0.
//
// Clock exceptions (FR-24) replace the start or the end of what steps 2..4
// produced; the day's minutes become end - start - break, the rows scaled to
// it. On a plan day Clock in moves the first row's start and Clock out the
// last row's end. A clock in without a clock out ends at the planned end,
// else at start + standard day + break, and the day is marked for the
// foreman (ForgottenClockOut, rows Proposed).
//
// The break rule (FR-26): a span (start..end, after clock exceptions) above
// BreakAfterMinutes loses BreakMinutes once, from the day's longest work
// row; never with No break on that day, and never from the prefill for a
// person whose standard day is above 0 and under the threshold (a half
// day). A Standard Day row is already net: its estimated span holds the
// break, its minutes do not lose it.
//
// Start and end (FR-32, Q19): a plan day's come from the plan or the clock;
// every other day's are estimated as DayStartMinutes + minutes + break, never
// taken from activity. A day of absences only has none.

import (
	"errors"
	"fmt"
	"sort"
	"time"
)

// Row kinds (FR-27): kind joins the entry's key.
const (
	KindWork    = "work"
	KindTravel  = "travel"
	KindWait    = "wait"
	KindAbsence = "absence"
)

// Row and day-record sources (FR-32's vocabulary). A Standard Day row scaled
// from activity is SourceStandard; an activity row kept as it is (an excess,
// or step 6) is SourceActivity.
const (
	SourcePlan     = "plan"
	SourceStandard = "standard"
	SourceActivity = "activity"
	SourceClock    = "clock"
	SourceForeman  = "foreman"
	SourceAbsence  = "absence"
	SourceHoliday  = "holiday"
)

// AbsenceHoliday is the absence type of a holiday row (FR-30).
const AbsenceHoliday = "holiday"

// Defaults of the 098 keys the caller resolves (FR-14, FR-26, FR-32).
const (
	DefaultStandardDayMinutes = 480
	DefaultDayStartMinutes    = 480
	DefaultBreakAfterMinutes  = 360
	DefaultBreakMinutes       = 30
	// MaxPlanRowsPerDay: a day holds up to two plan rows (FR-16, U3).
	MaxPlanRowsPerDay = 2
)

// PlanRow is one shift of the plan (FR-16), its day the local day of Start.
type PlanRow struct {
	Target   string // job:<id>
	Start    time.Time
	End      time.Time
	Explicit bool // written by the foreman; false = a read-time repeat
}

// Absence is one absence of a day (FR-30). Minutes 0 is the whole day.
type Absence struct {
	Date    string
	Type    string
	Minutes int
}

// Holiday is one public holiday on the member's calendar (FR-29). Minutes 0
// is the whole day.
type Holiday struct {
	Date    string
	Name    string
	Minutes int
}

// ForemanRow is one row a foreman entered for the member (FR-23).
type ForemanRow struct {
	Date    string
	Target  string
	Kind    string // "" is KindWork
	Minutes int
}

// Clock is a day's clock exception (FR-24); a zero time is not clocked.
type Clock struct {
	Date string
	In   time.Time
	Out  time.Time
}

// PrefillInput is everything one member's prefill is made of.
type PrefillInput struct {
	Days              []string       // the days asked for, YYYY-MM-DD in Loc
	Loc               *time.Location // the member's zone (1.6)
	StandardDay       map[string]int // the resolved standard day per date (FR-14); missing = 0
	StandardDayOn     bool           // the member's Standard Day switch (FR-15)
	DefaultTarget     string         // the last planned job, else "" = ws (FR-15)
	DayStartMinutes   int            // hours.day_start, minutes after local midnight
	BreakAfterMinutes int            // hours.break_after_minutes
	BreakMinutes      int            // hours.break_minutes
	NoBreak           map[string]bool
	Plan              []PlanRow // the day before the first asked day too: its shift may end after midnight
	Absences          []Absence
	Holidays          []Holiday
	Foreman           []ForemanRow
	Clocks            []Clock
	Activity          []Day // Suggest's output
}

// PrefillRow is one suggested row of a day.
type PrefillRow struct {
	Target      string
	Kind        string
	Source      string
	Minutes     int
	Evidence    bool   // activity, a plan row, a clock time, a foreman row, an absence or holiday
	AbsenceType string // for KindAbsence
	NoActivity  bool   // the Standard Day's row of a day without activity
	Proposed    bool   // a foreman row, or a day with a forgotten clock out
}

// PrefillDay is one day's prefill, rows sorted by minutes, most first.
type PrefillDay struct {
	Date              string
	Minutes           int
	Rows              []PrefillRow
	Start, End        time.Time // zero on a day of absences only, or with no rows
	StartSource       string
	EndSource         string
	BreakMinutes      int
	ForgottenClockOut bool // marked for the foreman (FR-24)
}

// piece is a plan interval on one local day.
type piece struct {
	target, kind         string
	start, end           time.Time
	startClock, endClock bool
	forgotten            bool
	brk                  int
}

func (p piece) minutes() int { return int(p.end.Sub(p.start)/time.Minute) - p.brk }

type prefiller struct {
	in       PrefillInput
	days     []string
	absences map[string][]Absence
	holidays map[string][]Holiday
	foreman  map[string][]ForemanRow
	clocks   map[string]Clock
	activity map[string]Day
	groups   map[string][]PlanRow
	explicit map[string]bool
	pieces   map[string][]piece
}

// Prefill runs the chain for each asked day, oldest first. It returns an
// error for input the store could never hold.
func Prefill(in PrefillInput) ([]PrefillDay, error) {
	p, err := newPrefiller(in)
	if err != nil {
		return nil, err
	}
	out := make([]PrefillDay, 0, len(p.days))
	for _, d := range p.days {
		out = append(out, p.day(d))
	}
	return out, nil
}

func newPrefiller(in PrefillInput) (*prefiller, error) {
	if in.Loc == nil {
		return nil, errors.New("hours: no time zone")
	}
	if in.DayStartMinutes < 0 || in.DayStartMinutes >= 1440 {
		return nil, fmt.Errorf("hours: day start %d outside 0..1439", in.DayStartMinutes)
	}
	if in.BreakAfterMinutes < 0 || in.BreakMinutes < 0 {
		return nil, errors.New("hours: negative break setting")
	}
	p := &prefiller{
		in: in, absences: map[string][]Absence{}, holidays: map[string][]Holiday{},
		foreman: map[string][]ForemanRow{}, clocks: map[string]Clock{}, activity: map[string]Day{},
		groups: map[string][]PlanRow{}, explicit: map[string]bool{}, pieces: map[string][]piece{},
	}
	for _, step := range []func() error{p.indexDays, p.indexLeave, p.indexForeman, p.indexClocks, p.indexActivity, p.indexPlan} {
		if err := step(); err != nil {
			return nil, err
		}
	}
	return p, nil
}

func (p *prefiller) checkDate(s string) error {
	if _, err := time.ParseInLocation("2006-01-02", s, p.in.Loc); err != nil {
		return fmt.Errorf("hours: date %q is not YYYY-MM-DD", s)
	}
	return nil
}

func checkMinutes(what string, m int) error {
	if m < 0 || m > 1440 {
		return fmt.Errorf("hours: %s minutes %d outside 0..1440", what, m)
	}
	return nil
}

func (p *prefiller) indexDays() error {
	seen := map[string]bool{}
	for _, d := range p.in.Days {
		if err := p.checkDate(d); err != nil {
			return err
		}
		if !seen[d] {
			seen[d] = true
			p.days = append(p.days, d)
		}
	}
	sort.Strings(p.days)
	for d, m := range p.in.StandardDay {
		if err := checkMinutes("standard day "+d, m); err != nil {
			return err
		}
	}
	return nil
}

func (p *prefiller) indexLeave() error {
	for _, a := range p.in.Absences {
		if err := p.checkDate(a.Date); err != nil {
			return err
		}
		if a.Type == "" {
			return errors.New("hours: absence without a type")
		}
		if err := checkMinutes("absence", a.Minutes); err != nil {
			return err
		}
		p.absences[a.Date] = append(p.absences[a.Date], a)
	}
	for _, h := range p.in.Holidays {
		if err := p.checkDate(h.Date); err != nil {
			return err
		}
		if err := checkMinutes("holiday", h.Minutes); err != nil {
			return err
		}
		p.holidays[h.Date] = append(p.holidays[h.Date], h)
	}
	return nil
}

func (p *prefiller) indexForeman() error {
	for _, f := range p.in.Foreman {
		if err := p.checkDate(f.Date); err != nil {
			return err
		}
		if f.Target == "" {
			return errors.New("hours: foreman row without a target")
		}
		switch f.Kind {
		case "", KindWork, KindTravel, KindWait, KindAbsence:
		default:
			return fmt.Errorf("hours: foreman row kind %q", f.Kind)
		}
		if err := checkMinutes("foreman row", f.Minutes); err != nil {
			return err
		}
		p.foreman[f.Date] = append(p.foreman[f.Date], f)
	}
	return nil
}

func (p *prefiller) indexClocks() error {
	for _, c := range p.in.Clocks {
		if err := p.checkDate(c.Date); err != nil {
			return err
		}
		if _, dup := p.clocks[c.Date]; dup {
			return fmt.Errorf("hours: two clock rows on %s", c.Date)
		}
		if !c.In.IsZero() && !c.Out.IsZero() && !c.Out.After(c.In) {
			return fmt.Errorf("hours: clock out before clock in on %s", c.Date)
		}
		p.clocks[c.Date] = c
	}
	return nil
}

func (p *prefiller) indexActivity() error {
	for _, d := range p.in.Activity {
		if err := p.checkDate(d.Date); err != nil {
			return err
		}
		p.activity[d.Date] = d
	}
	return nil
}

// indexPlan checks the plan, groups it per day and lays the shifts of every
// day the plan applies to onto local days.
func (p *prefiller) indexPlan() error {
	for _, r := range p.in.Plan {
		if r.Target == "" {
			return errors.New("hours: plan row without a target")
		}
		if !r.End.After(r.Start) {
			return errors.New("hours: plan row ends before it starts")
		}
		if r.End.Sub(r.Start) > 24*time.Hour {
			return errors.New("hours: plan row over 24 h")
		}
		d := p.dateOf(r.Start)
		p.groups[d] = append(p.groups[d], r)
		if r.Explicit {
			p.explicit[d] = true
		}
	}
	for d, rows := range p.groups {
		if len(rows) > MaxPlanRowsPerDay {
			return fmt.Errorf("hours: %d plan rows on %s, at most %d", len(rows), d, MaxPlanRowsPerDay)
		}
		sort.Slice(rows, func(i, j int) bool { return rows[i].Start.Before(rows[j].Start) })
		for i := 1; i < len(rows); i++ {
			if rows[i].Start.Before(rows[i-1].End) {
				return fmt.Errorf("hours: plan rows overlap on %s", d)
			}
		}
		if _, _, done := p.leave(d); done || len(p.foreman[d]) > 0 {
			continue
		}
		for _, pc := range p.shift(d, rows) {
			day := p.dateOf(pc.start)
			p.pieces[day] = append(p.pieces[day], pc)
		}
	}
	return nil
}

func (p *prefiller) dateOf(t time.Time) string { return t.In(p.in.Loc).Format("2006-01-02") }

func (p *prefiller) midnight(date string) time.Time {
	t, _ := time.ParseInLocation("2006-01-02", date, p.in.Loc)
	return t
}

func (p *prefiller) nextMidnight(t time.Time) time.Time {
	l := t.In(p.in.Loc)
	return time.Date(l.Year(), l.Month(), l.Day()+1, 0, 0, 0, 0, p.in.Loc)
}

func (p *prefiller) std(date string) int { return p.in.StandardDay[date] }

// breakFor is the break a span loses on date (FR-26), 0 when none.
func (p *prefiller) breakFor(span, std int, date string) int {
	if p.in.BreakMinutes <= 0 || p.in.NoBreak[date] || span <= p.in.BreakAfterMinutes {
		return 0
	}
	if std > 0 && std < p.in.BreakAfterMinutes {
		return 0
	}
	return p.in.BreakMinutes
}

// shift turns one day's plan rows into pieces split at local midnight: the
// clock exceptions moved in, travel between the rows, the break deducted
// once from the longest work piece.
func (p *prefiller) shift(date string, rows []PlanRow) []piece {
	work := make([]piece, len(rows))
	for i, r := range rows {
		work[i] = piece{target: r.Target, kind: KindWork, start: r.Start, end: r.End}
	}
	c, clocked := p.clocks[date]
	if clocked && !c.In.IsZero() {
		work[0].start, work[0].startClock = c.In, true
	}
	if clocked && !c.Out.IsZero() {
		last := len(work) - 1
		work[last].end, work[last].endClock = c.Out, true
	}
	forgotten := clocked && !c.In.IsZero() && c.Out.IsZero()
	for i := range work {
		if work[i].end.Before(work[i].start) {
			work[i].end = work[i].start
		}
	}
	all := append([]piece(nil), work...)
	for i := 0; i+1 < len(work); i++ {
		if work[i+1].start.After(work[i].end) {
			all = append(all, piece{target: work[i+1].target, kind: KindTravel, start: work[i].end, end: work[i+1].start})
		}
	}
	var out []piece
	for _, pc := range all {
		pc.forgotten = forgotten
		for cut := p.nextMidnight(pc.start); pc.end.After(cut); cut = p.nextMidnight(pc.start) {
			head := pc
			head.end, head.endClock = cut, false
			out = append(out, head)
			pc.start, pc.startClock = cut, false
		}
		out = append(out, pc)
	}
	span := spanOf(work[0].start, work[len(work)-1].end)
	if brk := p.breakFor(span, p.std(date), date); brk > 0 {
		longest := -1
		for i, pc := range out {
			if pc.kind == KindWork && (longest < 0 || pc.minutes() > out[longest].minutes()) {
				longest = i
			}
		}
		if longest >= 0 {
			out[longest].brk = min(brk, out[longest].minutes())
		}
	}
	return out
}

// leave is step 1: the day's absence and holiday rows, the minutes left for
// the next step (-1 = no cap) and whether they are the whole day.
func (p *prefiller) leave(date string) (rows []PrefillRow, rest int, done bool) {
	std := p.std(date)
	var hols []Holiday
	if !p.explicit[date] {
		hols = p.holidays[date]
	}
	if std > 0 {
		for _, a := range p.absences[date] {
			if a.Minutes == 0 {
				return []PrefillRow{absenceRow(a.Type, SourceAbsence, std)}, 0, true
			}
		}
		for _, h := range hols {
			if h.Minutes == 0 {
				return []PrefillRow{absenceRow(AbsenceHoliday, SourceHoliday, std)}, 0, true
			}
		}
	}
	sum := 0
	for _, a := range p.absences[date] {
		if a.Minutes > 0 {
			rows = append(rows, absenceRow(a.Type, SourceAbsence, a.Minutes))
			sum += a.Minutes
		}
	}
	for _, h := range hols {
		if h.Minutes > 0 {
			rows = append(rows, absenceRow(AbsenceHoliday, SourceHoliday, h.Minutes))
			sum += h.Minutes
		}
	}
	if len(rows) == 0 {
		return nil, -1, false
	}
	if sum >= std {
		return rows, 0, true
	}
	return rows, std - sum, false
}

func absenceRow(typ, src string, minutes int) PrefillRow {
	return PrefillRow{Target: TargetWS, Kind: KindAbsence, Source: src, Minutes: minutes, Evidence: true, AbsenceType: typ}
}

func (p *prefiller) defaultTarget() string {
	if p.in.DefaultTarget == "" {
		return TargetWS
	}
	return p.in.DefaultTarget
}

// day runs the chain for one date.
func (p *prefiller) day(date string) PrefillDay {
	out := PrefillDay{Date: date}
	rows, rest, done := p.leave(date)
	if !done {
		rows = append(rows, p.rest(&out, date, rest)...)
	}
	out.Rows = tidy(rows)
	for i := range out.Rows {
		out.Minutes += out.Rows[i].Minutes
		if out.ForgottenClockOut {
			out.Rows[i].Proposed = true
		}
	}
	return out
}

// rest is steps 2..6 for the minutes step 1 left (rest -1 = no cap).
func (p *prefiller) rest(out *PrefillDay, date string, rest int) []PrefillRow {
	std := p.std(date)
	if fr := p.foreman[date]; len(fr) > 0 {
		rows := make([]PrefillRow, 0, len(fr))
		for _, f := range fr {
			kind := f.Kind
			if kind == "" {
				kind = KindWork
			}
			rows = append(rows, PrefillRow{Target: f.Target, Kind: kind, Source: SourceForeman, Minutes: f.Minutes, Evidence: true, Proposed: true})
		}
		p.estimate(out, date, rows, std, SourceForeman)
		return capRows(p.clockIn(out, date, rows, std), rest)
	}
	if ps := p.pieces[date]; len(ps) > 0 {
		return capRows(p.planRows(out, ps), rest)
	}
	target := std
	if rest >= 0 {
		target = rest
	}
	if p.in.StandardDayOn && target > 0 {
		rows := p.standardRows(date, target)
		p.estimate(out, date, rows, std, SourceStandard)
		return p.clockIn(out, date, rows, std)
	}
	if c, ok := p.clocks[date]; ok && !c.In.IsZero() {
		return capRows(p.clockOnly(out, date, c, std), rest)
	}
	act := p.activity[date]
	rows := make([]PrefillRow, 0, len(act.Rows))
	for _, r := range act.Rows {
		rows = append(rows, PrefillRow{Target: r.Target, Kind: KindWork, Source: SourceActivity, Minutes: r.Minutes, Evidence: true})
	}
	p.estimate(out, date, rows, std, SourceStandard)
	return rows
}

// planRows is step 3: one row per piece of the plan on the day.
func (p *prefiller) planRows(out *PrefillDay, ps []piece) []PrefillRow {
	sort.Slice(ps, func(i, j int) bool { return ps[i].start.Before(ps[j].start) })
	out.Start, out.StartSource = ps[0].start, SourcePlan
	if ps[0].startClock {
		out.StartSource = SourceClock
	}
	rows := make([]PrefillRow, 0, len(ps))
	for _, pc := range ps {
		if !pc.end.Before(out.End) {
			out.End, out.EndSource = pc.end, SourcePlan
			if pc.endClock {
				out.EndSource = SourceClock
			}
		}
		out.BreakMinutes += pc.brk
		out.ForgottenClockOut = out.ForgottenClockOut || pc.forgotten
		rows = append(rows, PrefillRow{Target: pc.target, Kind: pc.kind, Source: SourcePlan, Minutes: pc.minutes(), Evidence: true})
	}
	return rows
}

// standardRows is step 4: the day's activity scaled to target, an excess
// kept, or one no-activity row.
func (p *prefiller) standardRows(date string, target int) []PrefillRow {
	act := p.activity[date]
	rows := make([]PrefillRow, 0, len(act.Rows))
	for _, r := range act.Rows {
		rows = append(rows, PrefillRow{Target: r.Target, Kind: KindWork, Source: SourceActivity, Minutes: r.Minutes, Evidence: true})
	}
	sum := sumMinutes(rows)
	if sum == 0 {
		return []PrefillRow{{Target: p.defaultTarget(), Kind: KindWork, Source: SourceStandard, Minutes: target, NoActivity: true}}
	}
	if sum >= target {
		return rows
	}
	rows = scaleTo(rows, target)
	for i := range rows {
		rows[i].Source = SourceStandard
	}
	return rows
}

// estimate sets a day's start and end where neither plan nor clock gives
// them (FR-32, Q19): day start (wall clock, so a DST night does not move
// it) + minutes + the break the span would lose.
func (p *prefiller) estimate(out *PrefillDay, date string, rows []PrefillRow, std int, src string) {
	total := sumMinutes(rows)
	if total == 0 {
		return
	}
	brk := p.breakFor(total+p.in.BreakMinutes, std, date)
	m := p.midnight(date)
	out.Start = time.Date(m.Year(), m.Month(), m.Day(), p.in.DayStartMinutes/60, p.in.DayStartMinutes%60, 0, 0, p.in.Loc)
	out.End = out.Start.Add(time.Duration(total+brk) * time.Minute)
	out.StartSource, out.EndSource, out.BreakMinutes = src, src, brk
}

// clockIn applies a day's clock exception to the rows of steps 2 and 4: the
// start or end replaced, the minutes end - start - break, the rows scaled.
func (p *prefiller) clockIn(out *PrefillDay, date string, rows []PrefillRow, std int) []PrefillRow {
	c, ok := p.clocks[date]
	if !ok || (c.In.IsZero() && c.Out.IsZero()) {
		return rows
	}
	if !c.In.IsZero() {
		out.Start, out.StartSource = c.In, SourceClock
	}
	if c.Out.IsZero() {
		base := std
		if base == 0 {
			base = sumMinutes(rows)
		}
		out.End = out.Start.Add(time.Duration(base+p.breakFor(base+p.in.BreakMinutes, std, date)) * time.Minute)
		out.ForgottenClockOut = true
	} else {
		out.End, out.EndSource = c.Out, SourceClock
	}
	span := spanOf(out.Start, out.End)
	out.BreakMinutes = p.breakFor(span, std, date)
	rows = scaleTo(rows, max(0, span-out.BreakMinutes))
	for i := range rows {
		rows[i].Evidence = true
	}
	return rows
}

// clockOnly is step 5: a clock in (and out) and nothing else.
func (p *prefiller) clockOnly(out *PrefillDay, date string, c Clock, std int) []PrefillRow {
	out.Start, out.StartSource = c.In, SourceClock
	if c.Out.IsZero() {
		out.End = c.In.Add(time.Duration(std+p.breakFor(std+p.in.BreakMinutes, std, date)) * time.Minute)
		out.EndSource = SourceStandard
		out.ForgottenClockOut = true
	} else {
		out.End, out.EndSource = c.Out, SourceClock
	}
	span := spanOf(out.Start, out.End)
	out.BreakMinutes = p.breakFor(span, std, date)
	return []PrefillRow{{Target: p.defaultTarget(), Kind: KindWork, Source: SourceClock, Minutes: span - out.BreakMinutes, Evidence: true}}
}

func spanOf(start, end time.Time) int { return max(0, int(end.Sub(start)/time.Minute)) }

func sumMinutes(rows []PrefillRow) int {
	n := 0
	for _, r := range rows {
		n += r.Minutes
	}
	return n
}

// capRows scales rows down to rest when they exceed it (a part-day absence).
func capRows(rows []PrefillRow, rest int) []PrefillRow {
	if rest < 0 || sumMinutes(rows) <= rest {
		return rows
	}
	return scaleTo(rows, rest)
}

// scaleTo scales rows proportionally to total whole minutes, the remainder
// to the largest fractions (ties: the earlier row).
func scaleTo(rows []PrefillRow, total int) []PrefillRow {
	w := sumMinutes(rows)
	if w == 0 || w == total {
		return rows
	}
	out := append([]PrefillRow(nil), rows...)
	rem := make([]int, len(out))
	order := make([]int, len(out))
	given := 0
	for i, r := range rows {
		num := r.Minutes * total
		out[i].Minutes, rem[i], order[i] = num/w, num%w, i
		given += out[i].Minutes
	}
	sort.SliceStable(order, func(a, b int) bool { return rem[order[a]] > rem[order[b]] })
	for k := 0; given < total; k++ {
		out[order[k]].Minutes++
		given++
	}
	return out
}

// tidy drops empty rows, merges rows of one key (two plan pieces of one job
// on a day) and sorts by minutes, most first.
func tidy(rows []PrefillRow) []PrefillRow {
	type key struct{ target, kind, source, absence string }
	at := map[key]int{}
	var out []PrefillRow
	for _, r := range rows {
		if r.Minutes <= 0 {
			continue
		}
		k := key{r.Target, r.Kind, r.Source, r.AbsenceType}
		if i, ok := at[k]; ok {
			out[i].Minutes += r.Minutes
			continue
		}
		at[k] = len(out)
		out = append(out, r)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Minutes != out[j].Minutes {
			return out[i].Minutes > out[j].Minutes
		}
		if out[i].Target != out[j].Target {
			return out[i].Target < out[j].Target
		}
		return out[i].Kind < out[j].Kind
	})
	return out
}
