package store

import (
	"context"
	"slices"
	"sort"
	"strings"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// memCalendar is Memory's calendar_events (rdb 0125), guarded by Memory.mu:
// tenant -> event id -> row. official_days has no rows in Memory.
type memCalendar struct {
	events map[string]map[string]*CalendarEvent
	keys   map[string]map[string]string // tenant -> source_key -> event id (rdb 0156, calendar_sync.go)
}

// cloneCalendarEvent copies e; Props is copied deep (normalizeCalendarProps
// cannot fail on a map it built itself).
func cloneCalendarEvent(e *CalendarEvent) CalendarEvent {
	c := *e
	c.Mentions = slices.Clone(e.Mentions)
	c.Props, _ = normalizeCalendarProps(e.Props)
	c.Guests = slices.Clone(e.Guests)
	if c.Guests == nil {
		c.Guests = []CalendarGuest{}
	}
	return c
}

// calendarEventLocked is the tenant's live event id as the viewer may see it
// (a single event or a series row; an exception row has no id of its own).
func (s *Memory) calendarEventLocked(tenant, viewer, id string) (*CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	e, ok := s.cal.events[tenant][id]
	if !ok || !e.DeletedAt.IsZero() || e.RecurringEventID != "" || !calendarVisible(e, viewer) {
		return nil, ErrNotFound
	}
	return e, nil
}

func (s *Memory) CreateCalendarEvent(_ context.Context, tenant string, e CalendarEvent, now time.Time) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	if err := normalizeCalendarEvent(&e); err != nil {
		return CalendarEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return CalendarEvent{}, ErrNotFound
	}
	if s.cal.events == nil {
		s.cal.events = map[string]map[string]*CalendarEvent{}
	}
	if s.cal.events[tenant] == nil {
		s.cal.events[tenant] = map[string]*CalendarEvent{}
	}
	e.ID = uuid.New() // rdb 0125's gen_random_uuid() shape
	e.SourceKey = ""  // only a sync sets it (calendar_sync.go)
	e.CreatedAt, e.UpdatedAt = calendarNow(now), calendarNow(now)
	e.DeletedAt, e.DeletedBy = time.Time{}, ""
	e.RecurringEventID, e.OriginalStart, e.Status = "", time.Time{}, CalendarConfirmed
	s.cal.events[tenant][e.ID] = &e
	return cloneCalendarEvent(&e), nil
}

func (s *Memory) GetCalendarEvent(_ context.Context, tenant, viewer, id string) (CalendarEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if series, orig := calendarRef(id); !orig.IsZero() {
		b, err := s.calendarBundleLocked(tenant, viewer, series)
		if err != nil {
			return CalendarEvent{}, err
		}
		occ, _, err := b.occurrence(orig)
		return occ, err
	}
	e, err := s.calendarEventLocked(tenant, viewer, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	return cloneCalendarEvent(e), nil
}

// calendarBundleLocked is the live series id the viewer can read, with its
// exception rows.
func (s *Memory) calendarBundleLocked(tenant, viewer, id string) (*calendarBundle, error) {
	e, err := s.calendarEventLocked(tenant, viewer, id)
	if err != nil {
		return nil, err
	}
	if e.RRule == "" {
		return nil, ErrNotFound
	}
	b := &calendarBundle{series: cloneCalendarEvent(e)}
	for _, x := range s.cal.events[tenant] {
		if x.RecurringEventID == id {
			b.excs = append(b.excs, cloneCalendarEvent(x))
		}
	}
	sort.Slice(b.excs, func(i, j int) bool { return b.excs[i].OriginalStart.Before(b.excs[j].OriginalStart) })
	return b, nil
}

// applyCalendarPlanLocked writes a plan's rows into the series' workspace.
func (s *Memory) applyCalendarPlanLocked(tenant string, plan calendarPlan) CalendarEvent {
	for i := range plan.writes {
		row := cloneCalendarEvent(&plan.writes[i])
		s.cal.events[tenant][row.ID] = &row
	}
	return plan.out
}

// calendarSeriesWriteLocked runs plan on the series of id (a series id or an
// occurrence id); ok is false when id names a single event.
func (s *Memory) calendarSeriesWriteLocked(tenant, viewer, id string,
	plan func(*calendarBundle, time.Time) (calendarPlan, error)) (CalendarEvent, bool, error) {
	series, orig := calendarRef(id)
	if orig.IsZero() {
		e, err := s.calendarEventLocked(tenant, viewer, id)
		if err != nil || e.RRule == "" {
			return CalendarEvent{}, false, err
		}
	}
	b, err := s.calendarBundleLocked(tenant, viewer, series)
	if err != nil {
		return CalendarEvent{}, true, err
	}
	pl, err := plan(b, orig)
	if err != nil {
		return pl.out, true, err
	}
	return s.applyCalendarPlanLocked(tenant, pl), true, nil
}

func (s *Memory) UpdateCalendarEvent(_ context.Context, tenant, viewer, id string, p CalendarPatch, now time.Time) (CalendarEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out, series, err := s.calendarSeriesWriteLocked(tenant, viewer, id, func(b *calendarBundle, orig time.Time) (calendarPlan, error) {
		return planCalendarEdit(b, orig, p, now)
	})
	if series || err != nil {
		return out, err
	}
	e, err := s.calendarEventLocked(tenant, viewer, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	if err := calendarPrecondition(e, p.IfUpdatedAt); err != nil {
		return cloneCalendarEvent(e), err
	}
	next := cloneCalendarEvent(e)
	applyCalendarPatch(&next, p)
	if err := normalizeCalendarEvent(&next); err != nil {
		return CalendarEvent{}, err
	}
	next.UpdatedAt = calendarNow(now)
	*e = next
	return cloneCalendarEvent(e), nil
}

func (s *Memory) DeleteCalendarEvent(ctx context.Context, tenant, viewer, id string) error {
	_, err := s.TrashCalendarEvent(ctx, tenant, viewer, id, time.Time{}, s.now())
	return err
}

// TrashCalendarEvent marks the event deleted; updated_at stays, so an Undo
// gives back the very version the caller last read.
func (s *Memory) TrashCalendarEvent(ctx context.Context, tenant, viewer, id string, ifUpdated, now time.Time) (CalendarEvent, error) {
	return s.TrashCalendarScope(ctx, tenant, viewer, id, "", ifUpdated, now)
}

func (s *Memory) TrashCalendarScope(_ context.Context, tenant, viewer, id, scope string, ifUpdated, now time.Time) (CalendarEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out, series, err := s.calendarSeriesWriteLocked(tenant, viewer, id, func(b *calendarBundle, orig time.Time) (calendarPlan, error) {
		return planCalendarDelete(b, orig, scope, viewer, ifUpdated, now)
	})
	if series || err != nil {
		return out, err
	}
	e, err := s.calendarEventLocked(tenant, viewer, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	if err := calendarPrecondition(e, ifUpdated); err != nil {
		return cloneCalendarEvent(e), err
	}
	e.DeletedAt, e.DeletedBy = calendarNow(now), viewer
	return cloneCalendarEvent(e), nil
}

// RestoreCalendarEvent: only the viewer who deleted the event brings it back.
func (s *Memory) RestoreCalendarEvent(_ context.Context, tenant, viewer, id string) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if series, orig := calendarRef(id); !orig.IsZero() {
		b, err := s.calendarBundleLocked(tenant, viewer, series)
		if err != nil {
			return CalendarEvent{}, err
		}
		pl, err := planCalendarRestore(b, orig, viewer, s.now())
		if err != nil {
			return CalendarEvent{}, err
		}
		return s.applyCalendarPlanLocked(tenant, pl), nil
	}
	e, ok := s.cal.events[tenant][id]
	if !ok || e.RecurringEventID != "" || !calendarDeletedBy(e, viewer) {
		return CalendarEvent{}, ErrNotFound
	}
	e.DeletedAt, e.DeletedBy = time.Time{}, ""
	return cloneCalendarEvent(e), nil
}

func (s *Memory) CalendarTrash(_ context.Context, tenant, viewer string, since time.Time) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool {
		return e.RecurringEventID == "" && calendarDeletedBy(e, viewer) && !e.DeletedAt.Before(since)
	}, func(a, b *CalendarEvent) bool {
		if !a.DeletedAt.Equal(b.DeletedAt) {
			return a.DeletedAt.After(b.DeletedAt)
		}
		return a.ID < b.ID
	}), nil
}

// calendarDeletedBy: e is in the trash, deleted by viewer, who can read it.
func calendarDeletedBy(e *CalendarEvent, viewer string) bool {
	return !e.DeletedAt.IsZero() && viewer != "" && e.DeletedBy == viewer && calendarVisible(e, viewer)
}

// calendarSelectLocked is the tenant's events keep accepts, sorted by less.
func (s *Memory) calendarSelectLocked(tenant string, keep func(*CalendarEvent) bool, less func(a, b *CalendarEvent) bool) []CalendarEvent {
	var hit []*CalendarEvent
	for _, e := range s.cal.events[tenant] {
		if keep(e) {
			hit = append(hit, e)
		}
	}
	sort.Slice(hit, func(i, j int) bool { return less(hit[i], hit[j]) })
	if len(hit) > calendarMaxEvents {
		hit = hit[:calendarMaxEvents]
	}
	out := make([]CalendarEvent, 0, len(hit))
	for _, e := range hit {
		out = append(out, cloneCalendarEvent(e))
	}
	return out
}

func byCalendarStart(a, b *CalendarEvent) bool {
	if !a.StartsAt.Equal(b.StartsAt) {
		return a.StartsAt.Before(b.StartsAt)
	}
	return a.ID < b.ID
}

func (s *Memory) ListCalendarEvents(_ context.Context, tenant, viewer string, r CalendarRange) ([]CalendarEvent, error) {
	return s.listCalendar(tenant, viewer, r, calendarMaxEvents)
}

// listCalendar is the range read: the single events, and the series that may
// reach r expanded with their exceptions (calendarWithSeries).
func (s *Memory) listCalendar(tenant, viewer string, r CalendarRange, limit int) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	singles := s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool {
		return calendarSingle(e) && e.DeletedAt.IsZero() && calendarVisible(e, viewer) && calendarOverlaps(e, r)
	}, byCalendarStart)
	series := s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool {
		return e.RRule != "" && e.DeletedAt.IsZero() && calendarVisible(e, viewer) && e.StartsAt.Before(r.End) &&
			(e.RecurUntil.IsZero() || !e.RecurUntil.Before(r.Start))
	}, byCalendarStart)
	ids := map[string]bool{}
	for _, e := range series {
		ids[e.ID] = true
	}
	excs := s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool { return ids[e.RecurringEventID] }, byCalendarStart)
	return calendarWithSeries(singles, series, excs, viewer, r, limit)
}

func (s *Memory) CalendarMarks(_ context.Context, tenant, viewer string, r CalendarRange) ([]CalendarMark, error) {
	evs, err := s.listCalendar(tenant, viewer, r, calendarMaxMarkOccurrences)
	if err != nil {
		return nil, err
	}
	return calendarMarksOf(evs, r), nil
}

func (s *Memory) CalendarReminders(_ context.Context, tenant, viewer string, r CalendarRange) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool {
		return calendarSingle(e) && e.DeletedAt.IsZero() && !e.RemindAt.IsZero() && !e.RemindAt.Before(r.Start) && e.RemindAt.Before(r.End) &&
			calendarOwnsOrNamed(e, viewer)
	}, func(a, b *CalendarEvent) bool {
		if !a.RemindAt.Equal(b.RemindAt) {
			return a.RemindAt.Before(b.RemindAt)
		}
		return a.ID < b.ID
	}), nil
}

// OfficialDays: Memory holds no official_days rows.
func (s *Memory) OfficialDays(context.Context, string, CalendarRange) ([]OfficialDay, error) {
	return nil, nil
}

// calendarMarksOf folds events into the year strip's days, oldest first.
// Both stores use it, so the day rule (calendarDays) is one rule.
func calendarMarksOf(evs []CalendarEvent, r CalendarRange) []CalendarMark {
	by := map[string]*CalendarMark{}
	for i := range evs {
		for _, d := range calendarDays(&evs[i], r) {
			m := by[d]
			if m == nil {
				m = &CalendarMark{Day: d}
				by[d] = m
			}
			m.Count++
			if !slices.Contains(m.Kinds, evs[i].Kind) {
				m.Kinds = append(m.Kinds, evs[i].Kind)
			}
		}
	}
	out := make([]CalendarMark, 0, len(by))
	for _, m := range by {
		slices.Sort(m.Kinds)
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return strings.Compare(out[i].Day, out[j].Day) < 0 })
	return out
}
