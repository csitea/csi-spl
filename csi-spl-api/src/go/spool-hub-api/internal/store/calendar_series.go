package store

import (
	"errors"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/calrecur"
	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Recurrence in the store (specs/097 T006, spec 4.4), shared by Memory and
// Postgres so the rules are one rule:
//
//   - a series row has rrule; its occurrences are computed (calrecur), never
//     stored. A changed occurrence is an exception row with its own fields;
//     a deleted one is an exception row with status cancelled.
//   - an occurrence's id is <series id>_<YYYYMMDDTHHMMSSZ> of its unchanged
//     start; an exception row is never addressed by its own uuid.
//   - a write to a series is a plan: the full rows to write (calendarPlan),
//     which each store applies in one transaction under the series' lock.
//     Every row of a plan is in the series' workspace: an occurrence id of
//     another workspace finds no series (ErrNotFound) and writes nothing.

// calendarSeriesOf is the calrecur series of a series row; a rule calrecur
// refuses is ErrInvalidCalendarEvent.
func calendarSeriesOf(e *CalendarEvent) (calrecur.Series, error) {
	s, err := calrecur.NewSeries(e.ID, e.RRule, e.StartsAt, e.EndsAt, e.TimeZone)
	if err != nil {
		return s, fmt.Errorf("%w: rrule: %s", ErrInvalidCalendarEvent,
			strings.TrimPrefix(err.Error(), calrecur.ErrBadRule.Error()+": "))
	}
	return s, nil
}

// normalizeCalendarRecurrence checks the series and exception columns and
// sets recur_until from the rule (spec 4.4: on every write).
func normalizeCalendarRecurrence(e *CalendarEvent) error {
	bad := func(what string) error { return fmt.Errorf("%w: %s", ErrInvalidCalendarEvent, what) }
	switch {
	case e.Status != CalendarConfirmed && e.Status != CalendarCancelled:
		return bad("status must be confirmed or cancelled")
	case (e.RecurringEventID == "") != e.OriginalStart.IsZero():
		return bad("an exception has both recurring_event_id and original_start")
	case e.RRule != "" && e.RecurringEventID != "":
		return bad("one occurrence has no rrule of its own")
	}
	e.RecurUntil = time.Time{}
	if !e.OriginalStart.IsZero() {
		e.OriginalStart = e.OriginalStart.UTC()
	}
	if e.RRule == "" {
		return nil
	}
	s, err := calendarSeriesOf(e)
	if err != nil {
		return err
	}
	if until, ok := s.RecurUntil(); ok {
		e.RecurUntil = until
	}
	return nil
}

// calendarRef splits an id: an occurrence id answers its series id and the
// occurrence's unchanged start, any other id itself and a zero start.
func calendarRef(id string) (string, time.Time) {
	if series, orig, err := calrecur.ParseOccurrenceID(id); err == nil {
		return series, orig.UTC()
	}
	return id, time.Time{}
}

// calendarSingle: a row that is neither a series nor an exception.
func calendarSingle(e *CalendarEvent) bool {
	return e.RRule == "" && e.RecurringEventID == ""
}

// calendarOccurrence is the occurrence of series at orig: the exception row
// ex when there is one, else the series moved to orig. Its UpdatedAt is the
// row it comes from, the If-Match a write to it carries.
func calendarOccurrence(series, ex *CalendarEvent, orig time.Time) CalendarEvent {
	var o CalendarEvent
	if ex != nil {
		o = cloneCalendarEvent(ex)
	} else {
		o = cloneCalendarEvent(series)
		shift := orig.Sub(series.StartsAt)
		o.StartsAt, o.EndsAt = orig, series.EndsAt.Add(shift)
		if !o.RemindAt.IsZero() {
			o.RemindAt = o.RemindAt.Add(shift)
		}
	}
	o.ID = calrecur.OccurrenceID(series.ID, orig)
	o.RecurringEventID, o.OriginalStart, o.RRule, o.RecurUntil = series.ID, orig.UTC(), series.RRule, time.Time{}
	return o
}

// calendarExpand lists series' occurrences in r with its exceptions applied,
// at most limit (else ErrCalendarTooMany). A stored rule this build cannot
// read shows nothing rather than failing the whole read.
func calendarExpand(series *CalendarEvent, excs []CalendarEvent, r CalendarRange, limit int) ([]CalendarEvent, error) {
	s, err := calendarSeriesOf(series)
	if err != nil {
		return nil, nil
	}
	cx := make([]calrecur.Exception, 0, len(excs))
	byOrig := make(map[int64]*CalendarEvent, len(excs))
	for i := range excs {
		x := &excs[i]
		cx = append(cx, calrecur.Exception{EventID: x.ID, OriginalStart: x.OriginalStart, Start: x.StartsAt,
			End: x.EndsAt, Cancelled: x.Status == CalendarCancelled})
		byOrig[x.OriginalStart.Unix()] = x
	}
	occs, err := s.Expand(cx, r.Start, r.End, max(limit, 0))
	if errors.Is(err, calrecur.ErrTooMany) {
		return nil, ErrCalendarTooMany
	} else if err != nil {
		return nil, err
	}
	out := make([]CalendarEvent, 0, len(occs))
	for _, oc := range occs {
		var ex *CalendarEvent
		if oc.ExceptionID != "" {
			ex = byOrig[oc.OriginalStart.Unix()]
		}
		out = append(out, calendarOccurrence(series, ex, oc.OriginalStart))
	}
	return out, nil
}

// calendarWithSeries is a range read's answer: the single events, then each
// series' occurrences the viewer can read, by start then id, at most limit
// in all (ErrCalendarTooMany past it).
func calendarWithSeries(singles, series, excs []CalendarEvent, viewer string, r CalendarRange, limit int) ([]CalendarEvent, error) {
	bySeries := map[string][]CalendarEvent{}
	for _, x := range excs {
		bySeries[x.RecurringEventID] = append(bySeries[x.RecurringEventID], x)
	}
	out := slices.Clone(singles)
	for i := range series {
		occs, err := calendarExpand(&series[i], bySeries[series[i].ID], r, limit-len(out))
		if err != nil {
			return nil, err
		}
		for j := range occs {
			if calendarVisible(&occs[j], viewer) {
				out = append(out, occs[j])
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return byCalendarStart(&out[i], &out[j]) })
	return out, nil
}

// calendarBundle is a series row and its exception rows, read under the
// series' lock.
type calendarBundle struct {
	series CalendarEvent
	excs   []CalendarEvent
}

// calendarPlan is a write to a series: the full rows to write, in order (a
// new series before the exceptions that move to it), and the answer.
type calendarPlan struct {
	writes []CalendarEvent
	out    CalendarEvent
}

func (b *calendarBundle) exceptionAt(orig time.Time) *CalendarEvent {
	for i := range b.excs {
		if b.excs[i].OriginalStart.Equal(orig) {
			return &b.excs[i]
		}
	}
	return nil
}

// occurrence is the live occurrence at orig, and its exception row if any;
// a start the rule does not make, or a cancelled one, is ErrNotFound.
func (b *calendarBundle) occurrence(orig time.Time) (CalendarEvent, *CalendarEvent, error) {
	s, err := calendarSeriesOf(&b.series)
	if err != nil {
		return CalendarEvent{}, nil, err
	}
	ex := b.exceptionAt(orig)
	if !s.Has(orig) || (ex != nil && ex.Status == CalendarCancelled) {
		return CalendarEvent{}, nil, ErrNotFound
	}
	return calendarOccurrence(&b.series, ex, orig), ex, nil
}

// errCalendarScope is a scope the id cannot take.
func errCalendarScope(what string) error {
	return fmt.Errorf("%w: %s", ErrInvalidCalendarEvent, what)
}

// planCalendarEdit is a PATCH on series b: at the occurrence orig, or on the
// series itself when orig is zero (spec 4.4's table).
func planCalendarEdit(b *calendarBundle, orig time.Time, p CalendarPatch, now time.Time) (calendarPlan, error) {
	if orig.IsZero() {
		if p.Scope != "" && p.Scope != CalendarScopeAll {
			return calendarPlan{}, errCalendarScope("scope this or following needs an occurrence id")
		}
		return planCalendarAll(b, p, now)
	}
	occ, ex, err := b.occurrence(orig)
	if err != nil {
		return calendarPlan{}, err
	}
	if err := calendarPrecondition(&occ, p.IfUpdatedAt); err != nil {
		return calendarPlan{out: occ}, err
	}
	p.IfUpdatedAt = time.Time{}
	switch {
	case p.Scope == "" || p.Scope == CalendarScopeThis:
		return planCalendarThis(b, occ, ex, p, now)
	case p.Scope == CalendarScopeAll || (p.Scope == CalendarScopeFollowing && orig.Equal(b.series.StartsAt)):
		return planCalendarAll(b, calendarPatchToSeries(p, &occ, &b.series), now)
	case p.Scope == CalendarScopeFollowing:
		return planCalendarFollowing(b, occ, p, now)
	}
	return calendarPlan{}, errCalendarScope("scope must be this, following or all")
}

// planCalendarDelete is a DELETE on series b, as planCalendarEdit.
func planCalendarDelete(b *calendarBundle, orig time.Time, scope, viewer string, ifUpdated, now time.Time) (calendarPlan, error) {
	if scope != "" && scope != CalendarScopeThis && scope != CalendarScopeFollowing && scope != CalendarScopeAll {
		return calendarPlan{}, errCalendarScope("scope must be this, following or all")
	}
	if orig.IsZero() {
		if scope != "" && scope != CalendarScopeAll {
			return calendarPlan{}, errCalendarScope("scope this or following needs an occurrence id")
		}
		return planCalendarTrashSeries(b, viewer, ifUpdated, now)
	}
	occ, ex, err := b.occurrence(orig)
	if err != nil {
		return calendarPlan{}, err
	}
	if err := calendarPrecondition(&occ, ifUpdated); err != nil {
		return calendarPlan{out: occ}, err
	}
	switch {
	case scope == "" || scope == CalendarScopeThis:
		return planCalendarCancel(b, occ, ex, viewer, now)
	case scope == CalendarScopeAll || orig.Equal(b.series.StartsAt):
		return planCalendarTrashSeries(b, viewer, time.Time{}, now)
	}
	old, err := calendarEndedBefore(&b.series, orig, now)
	return calendarPlan{writes: []CalendarEvent{old}, out: old}, err
}

// calendarExceptionRow is the exception row for occurrence occ: ex itself
// when there is one, else a new row of the series' workspace.
func calendarExceptionRow(occ CalendarEvent, ex *CalendarEvent, now time.Time) CalendarEvent {
	row := cloneCalendarEvent(&occ)
	row.ID, row.CreatedAt = uuid.New(), calendarNow(now)
	if ex != nil {
		row.ID, row.CreatedAt = ex.ID, ex.CreatedAt
	}
	row.RRule, row.RecurUntil, row.Status = "", time.Time{}, CalendarConfirmed
	row.DeletedAt, row.DeletedBy = time.Time{}, ""
	return row
}

// planCalendarThis writes or updates the exception row of one occurrence.
func planCalendarThis(b *calendarBundle, occ CalendarEvent, ex *CalendarEvent, p CalendarPatch, now time.Time) (calendarPlan, error) {
	if p.RRule != nil {
		return calendarPlan{}, errCalendarScope("one occurrence has no rrule: use scope following or all")
	}
	row := calendarExceptionRow(occ, ex, now)
	applyCalendarPatch(&row, p)
	if err := normalizeCalendarEvent(&row); err != nil {
		return calendarPlan{}, err
	}
	row.UpdatedAt = calendarNow(now)
	return calendarPlan{writes: []CalendarEvent{row}, out: calendarOccurrence(&b.series, &row, occ.OriginalStart)}, nil
}

// planCalendarCancel writes a cancelled exception row (DELETE scope this).
// The answer is the occurrence with deleted_at set; deleted_by on the row
// lets the same viewer restore it.
func planCalendarCancel(b *calendarBundle, occ CalendarEvent, ex *CalendarEvent, viewer string, now time.Time) (calendarPlan, error) {
	row := calendarExceptionRow(occ, ex, now)
	row.Status, row.DeletedBy, row.UpdatedAt = CalendarCancelled, viewer, calendarNow(now)
	out := calendarOccurrence(&b.series, &row, occ.OriginalStart)
	out.DeletedAt = calendarNow(now)
	return calendarPlan{writes: []CalendarEvent{row}, out: out}, nil
}

// planCalendarTrashSeries soft-deletes the series (spec 4.8); its exceptions
// are read only through a live series, so they go and come back with it.
func planCalendarTrashSeries(b *calendarBundle, viewer string, ifUpdated, now time.Time) (calendarPlan, error) {
	if err := calendarPrecondition(&b.series, ifUpdated); err != nil {
		return calendarPlan{out: cloneCalendarEvent(&b.series)}, err
	}
	s := cloneCalendarEvent(&b.series)
	s.DeletedAt, s.DeletedBy = calendarNow(now), viewer
	return calendarPlan{writes: []CalendarEvent{s}, out: s}, nil
}

// planCalendarRestore brings back an occurrence the viewer cancelled.
func planCalendarRestore(b *calendarBundle, orig time.Time, viewer string, now time.Time) (calendarPlan, error) {
	ex := b.exceptionAt(orig)
	if ex == nil || ex.Status != CalendarCancelled || viewer == "" || ex.DeletedBy != viewer {
		return calendarPlan{}, ErrNotFound
	}
	row := cloneCalendarEvent(ex)
	row.Status, row.DeletedBy = CalendarConfirmed, ""
	return calendarPlan{writes: []CalendarEvent{row}, out: calendarOccurrence(&b.series, &row, orig)}, nil
}

// planCalendarAll updates the series (p is relative to the series row). A
// time shift moves every exception's original_start by the same amount; a
// changed field reaches each exception that kept the series' old value.
func planCalendarAll(b *calendarBundle, p CalendarPatch, now time.Time) (calendarPlan, error) {
	if err := calendarPrecondition(&b.series, p.IfUpdatedAt); err != nil {
		return calendarPlan{out: cloneCalendarEvent(&b.series)}, err
	}
	nu := cloneCalendarEvent(&b.series)
	applyCalendarPatch(&nu, p)
	if err := normalizeCalendarEvent(&nu); err != nil {
		return calendarPlan{}, err
	}
	nu.UpdatedAt = calendarNow(now)
	plan := calendarPlan{writes: []CalendarEvent{nu}, out: nu}
	plan.writes = append(plan.writes, calendarFollowAll(b.excs, &b.series, &nu, nu.StartsAt.Sub(b.series.StartsAt), now)...)
	return plan, nil
}

// planCalendarFollowing ends the series before occ and starts a new series
// at occ with p applied; the later exceptions move to the new series. The
// answer is the new series' first occurrence.
func planCalendarFollowing(b *calendarBundle, occ CalendarEvent, p CalendarPatch, now time.Time) (calendarPlan, error) {
	orig := occ.OriginalStart
	old, err := calendarEndedBefore(&b.series, orig, now)
	if err != nil {
		return calendarPlan{}, err
	}
	nu := cloneCalendarEvent(&occ)
	nu.ID, nu.RecurringEventID, nu.OriginalStart, nu.Status = uuid.New(), "", time.Time{}, CalendarConfirmed
	nu.CreatedAt, nu.UpdatedAt, nu.DeletedAt, nu.DeletedBy = calendarNow(now), calendarNow(now), time.Time{}, ""
	if nu.RRule, err = calendarRuleRest(&b.series, orig); err != nil {
		return calendarPlan{}, err
	}
	applyCalendarPatch(&nu, p)
	if err := normalizeCalendarEvent(&nu); err != nil {
		return calendarPlan{}, err
	}
	later := slices.DeleteFunc(slices.Clone(b.excs), func(x CalendarEvent) bool { return !x.OriginalStart.After(orig) })
	for i := range later {
		later[i].RecurringEventID = nu.ID
	}
	plan := calendarPlan{writes: []CalendarEvent{old, nu}, out: calendarOccurrence(&nu, nil, nu.StartsAt)}
	plan.writes = append(plan.writes, calendarFollowAll(later, &b.series, &nu, nu.StartsAt.Sub(orig), now)...)
	return plan, nil
}

// calendarEndedBefore is series s ended just before the occurrence orig:
// its COUNT or UNTIL replaced by UNTIL = orig - 1 s.
func calendarEndedBefore(s *CalendarEvent, orig, now time.Time) (CalendarEvent, error) {
	old := cloneCalendarEvent(s)
	old.RRule = calendarRuleWith(s.RRule, "UNTIL="+orig.Add(-time.Second).UTC().Format("20060102T150405Z"))
	if err := normalizeCalendarEvent(&old); err != nil {
		return CalendarEvent{}, err
	}
	old.UpdatedAt = calendarNow(now)
	return old, nil
}

// calendarRuleRest is the rule of the series that continues s from orig: the
// same rule, a COUNT lowered by the occurrences before orig.
func calendarRuleRest(s *CalendarEvent, orig time.Time) (string, error) {
	count := 0
	for _, part := range strings.Split(s.RRule, ";") {
		if v, ok := strings.CutPrefix(part, "COUNT="); ok {
			count, _ = strconv.Atoi(v)
		}
	}
	if count == 0 {
		return s.RRule, nil
	}
	rule, err := calendarSeriesOf(s)
	if err != nil {
		return "", err
	}
	before, err := rule.Expand(nil, s.StartsAt, orig, calrecur.MaxCount)
	if err != nil {
		return "", err
	}
	return calendarRuleWith(s.RRule, "COUNT="+strconv.Itoa(count-len(before))), nil
}

// calendarRuleWith is rule without its COUNT and UNTIL, plus end.
func calendarRuleWith(rule, end string) string {
	parts := slices.DeleteFunc(strings.Split(rule, ";"), func(p string) bool {
		return strings.HasPrefix(p, "COUNT=") || strings.HasPrefix(p, "UNTIL=")
	})
	return strings.Join(append(parts, end), ";")
}

// calendarPatchToSeries moves a patch written against occurrence occ onto the
// series row: a time moves the series by as much as it moves occ.
func calendarPatchToSeries(p CalendarPatch, occ, series *CalendarEvent) CalendarPatch {
	if p.StartsAt != nil {
		t := series.StartsAt.Add(p.StartsAt.Sub(occ.StartsAt))
		p.StartsAt = &t
	}
	if p.EndsAt != nil {
		t := series.EndsAt.Add(p.EndsAt.Sub(occ.EndsAt))
		p.EndsAt = &t
	}
	if p.RemindAt != nil && !p.RemindAt.IsZero() {
		t := p.RemindAt.Add(series.StartsAt.Sub(occ.StartsAt))
		p.RemindAt = &t
	}
	return p
}

// calendarFollowAll applies calendarFollow to excs and answers the rows that
// changed, ordered so that no two share an original_start mid-way (the
// calendar_events_exception_once index is not deferrable).
func calendarFollowAll(excs []CalendarEvent, old, nu *CalendarEvent, delta time.Duration, now time.Time) []CalendarEvent {
	excs = slices.Clone(excs)
	sort.Slice(excs, func(i, j int) bool {
		if delta > 0 {
			return excs[i].OriginalStart.After(excs[j].OriginalStart)
		}
		return excs[i].OriginalStart.Before(excs[j].OriginalStart)
	})
	var out []CalendarEvent
	for i := range excs {
		was := cloneCalendarEvent(&excs[i])
		calendarFollow(&excs[i], old, nu, delta)
		if !reflect.DeepEqual(was, excs[i]) {
			excs[i].UpdatedAt = calendarNow(now)
			out = append(out, excs[i])
		}
	}
	return out
}

// calendarFollow moves exception ex of series old to series nu: its
// original_start by delta, and each field it did not change itself (it still
// holds old's value) to nu's. A moved occurrence keeps its own times.
func calendarFollow(ex *CalendarEvent, old, nu *CalendarEvent, delta time.Duration) {
	was := ex.OriginalStart
	ex.OriginalStart = was.Add(delta)
	if ex.StartsAt.Equal(was) && ex.EndsAt.Equal(was.Add(old.EndsAt.Sub(old.StartsAt))) {
		ex.StartsAt, ex.EndsAt = ex.OriginalStart, ex.OriginalStart.Add(nu.EndsAt.Sub(nu.StartsAt))
	}
	for _, f := range []struct{ dst, o, n *string }{{&ex.Title, &old.Title, &nu.Title},
		{&ex.Description, &old.Description, &nu.Description}, {&ex.Kind, &old.Kind, &nu.Kind},
		{&ex.Audience, &old.Audience, &nu.Audience}, {&ex.TopicID, &old.TopicID, &nu.TopicID},
		{&ex.ReleaseVersion, &old.ReleaseVersion, &nu.ReleaseVersion}, {&ex.TimeZone, &old.TimeZone, &nu.TimeZone}} {
		if *f.dst == *f.o {
			*f.dst = *f.n
		}
	}
	if ex.AllDay == old.AllDay {
		ex.AllDay = nu.AllDay
	}
	if slices.Equal(ex.Mentions, old.Mentions) {
		ex.Mentions = slices.Clone(nu.Mentions)
	}
	if calendarLead(ex) == calendarLead(old) {
		ex.RemindAt = time.Time{}
		if lead := calendarLead(nu); lead >= 0 {
			ex.RemindAt = ex.StartsAt.Add(-lead)
		}
	}
	calendarFollowProps(ex, old, nu)
	calendarFollowGuests(ex, old, nu)
}

// calendarLead is how long before its start an event's remind_at is, -1
// for none.
func calendarLead(e *CalendarEvent) time.Duration {
	if e.RemindAt.IsZero() {
		return -1
	}
	return e.StartsAt.Sub(e.RemindAt)
}

// calendarFollowProps: each props key ex holds at old's value takes nu's.
func calendarFollowProps(ex *CalendarEvent, old, nu *CalendarEvent) {
	if ex.Props == nil {
		ex.Props = map[string]any{}
	}
	keys := map[string]bool{}
	for k := range old.Props {
		keys[k] = true
	}
	for k := range nu.Props {
		keys[k] = true
	}
	for k := range keys {
		if !reflect.DeepEqual(ex.Props[k], old.Props[k]) {
			continue
		}
		if v, ok := nu.Props[k]; ok {
			ex.Props[k] = v
		} else {
			delete(ex.Props, k)
		}
	}
}
