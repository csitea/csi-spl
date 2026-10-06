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
}

// cloneCalendarEvent copies e; Props is copied deep (normalizeCalendarProps
// cannot fail on a map it built itself).
func cloneCalendarEvent(e *CalendarEvent) CalendarEvent {
	c := *e
	c.Mentions = slices.Clone(e.Mentions)
	c.Props, _ = normalizeCalendarProps(e.Props)
	return c
}

// calendarEventLocked is the tenant's live event id as the viewer may see it.
func (s *Memory) calendarEventLocked(tenant, viewer, id string) (*CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	e, ok := s.cal.events[tenant][id]
	if !ok || !e.DeletedAt.IsZero() || !calendarVisible(e, viewer) {
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
	e.CreatedAt, e.UpdatedAt = calendarNow(now), calendarNow(now)
	e.DeletedAt, e.DeletedBy = time.Time{}, ""
	s.cal.events[tenant][e.ID] = &e
	return cloneCalendarEvent(&e), nil
}

func (s *Memory) GetCalendarEvent(_ context.Context, tenant, viewer, id string) (CalendarEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, err := s.calendarEventLocked(tenant, viewer, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	return cloneCalendarEvent(e), nil
}

func (s *Memory) UpdateCalendarEvent(_ context.Context, tenant, viewer, id string, p CalendarPatch, now time.Time) (CalendarEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
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
func (s *Memory) TrashCalendarEvent(_ context.Context, tenant, viewer, id string, ifUpdated, now time.Time) (CalendarEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
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
	e, ok := s.cal.events[tenant][id]
	if !ok || !calendarDeletedBy(e, viewer) {
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
		return calendarDeletedBy(e, viewer) && !e.DeletedAt.Before(since)
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
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool {
		return e.DeletedAt.IsZero() && calendarVisible(e, viewer) && calendarOverlaps(e, r)
	}, byCalendarStart), nil
}

func (s *Memory) CalendarMarks(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarMark, error) {
	evs, err := s.ListCalendarEvents(ctx, tenant, viewer, r)
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
		return e.DeletedAt.IsZero() && !e.RemindAt.IsZero() && !e.RemindAt.Before(r.Start) && e.RemindAt.Before(r.End) &&
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
