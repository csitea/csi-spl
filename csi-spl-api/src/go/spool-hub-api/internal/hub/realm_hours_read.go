package hub

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hours"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The person's hours across every workspace (spec 118 v1.1 sections 5.2, 6,
// C2, C5, C6; tasks.md T003):
//
//	GET /v1/me/realm/hours?from=YYYY-MM-DD&to=YYYY-MM-DD  (at most 62 days)
//
// It reads, never writes. The person is the signed-in human alone: refused
// with 403 person_only under act-as (054), for a box token or an agent and
// for a person whose every seat is time_accountant (107 FR-21); 400 when the
// request names a workspace or a member (X-Spool-Tenant, member=,
// workspace=). The workspaces are the person's live memberships
// (Memberships, the one allow-listed operator read); at most 20, a 21st is
// 400 too_many_workspaces. Each one is read with the existing 107 store
// calls, each its own inTenant(W) transaction with member = the person (never
// "", the store's "every member"), at most 2 workspaces in flight. The realm
// reads (zone, limits, receipts) are inPerson transactions of their own,
// never nested with a workspace scope. hours.Across computes the days;
// nothing is stored. A workspace that cannot be read is "unavailable" and
// its days "incomplete", never a silent zero.
//
// Nothing here is served by a workspace route: no actual, overlap, limit or
// other workspace reaches GET /v1/me/hours, /v1/hours or an export (T-R2a).

const (
	realmHoursMaxDays       = 62
	realmHoursMaxWorkspaces = 20
	realmHoursInFlight      = 2
	realmHoursReadTimeout   = 10 * time.Second
	// realmTimeAccountant is 107 FR-21's seat with no own hours: a membership
	// whose role is this one is not read.
	realmTimeAccountant = "time_accountant"

	realmStateMember      = "member"
	realmStateLeft        = "left"
	realmStateUnavailable = "unavailable"
)

// realmPerson is the signed-in human of a realm route, or it writes the
// refusal. A realm route never takes a tenant: the person comes from the
// session alone (spec 119 C1, C2).
func (s *Server) realmPerson(w http.ResponseWriter, r *http.Request) (string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	q := r.URL.Query()
	if r.Header.Get(TenantHeader) != "" || q.Has("member") || q.Has("workspace") {
		writeErr(w, http.StatusBadRequest, "person_scope", "a personal route names no workspace and no member")
		return "", false
	}
	hum := ""
	if s.o.SessionID != nil { // test seam: the attributed human
		hum, _ = s.o.SessionID(r, "")
	} else if s.o.Auth != nil {
		sess, ok := s.o.Auth.SessionFromRequest(r)
		if ok && sess.Provider == auth.ProviderActAs {
			writeErr(w, http.StatusForbidden, "person_only", "personal hours are not shown under act-as")
			return "", false
		}
		hum = sess.HumanID
	}
	if hum == "" {
		if r.Header.Get("Authorization") != "" { // a box or agent credential, no person
			writeErr(w, http.StatusForbidden, "person_only", "personal hours need a signed-in person")
			return "", false
		}
		writeErr(w, http.StatusUnauthorized, "view_door", "sign in to see your hours")
		return "", false
	}
	return hum, true
}

// realmClone reports a live act-as clone among the memberships: store-based,
// so it holds however the session was formed (as readerIsActAsClone).
func (s *Server) realmClone(ctx context.Context, hum string, ms []store.Membership) bool {
	for _, m := range ms {
		if s.readerIsActAsClone(ctx, m.TenantID, hum) {
			return true
		}
	}
	return false
}

// realmWindow is the from..to of the request, civil days in zone; the
// default is the person's current ISO week.
func realmWindow(q map[string][]string, zone *time.Location, now time.Time) (time.Time, time.Time, string) {
	get := func(k string) string {
		if v := q[k]; len(v) > 0 {
			return strings.TrimSpace(v[0])
		}
		return ""
	}
	from, to := get("from"), get("to")
	if from == "" && to == "" {
		today := civil(now, zone)
		mon := today.AddDate(0, 0, -((int(today.Weekday()) + 6) % 7))
		return mon, mon.AddDate(0, 0, 6), ""
	}
	f, err1 := time.Parse(hoursDayLayout, from)
	t, err2 := time.Parse(hoursDayLayout, to)
	switch {
	case err1 != nil || err2 != nil:
		return f, t, "from and to must both be days, YYYY-MM-DD"
	case t.Before(f):
		return f, t, "to must not be before from"
	case int(t.Sub(f).Hours()/24)+1 > realmHoursMaxDays:
		return f, t, "a window holds at most 62 days"
	}
	return f, t, ""
}

// realmZone is the person's zone (118 C4): the realm profile's, else the
// browser's (tz=), else UTC.
func realmZone(p store.RealmProfile, browser string) (*time.Location, string) {
	if loc, ok := hoursLoadZone(p.TimeZone); ok {
		return loc, "profile"
	}
	if loc, ok := hoursLoadZone(browser); ok {
		return loc, "browser"
	}
	return time.UTC, "default"
}

// realmWorkspace is one workspace of the answer.
type realmWorkspace struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	State string `json:"state"` // member, left (a receipt) or unavailable
}

type realmLimitJSON struct {
	ValidFrom   string `json:"valid_from"`
	DayMinutes  *int   `json:"day_minutes"`
	WeekMinutes *int   `json:"week_minutes"`
}

// realmHoursRead is one GET being answered.
type realmHoursRead struct {
	hum      string
	zone     *time.Location
	from, to time.Time // civil, inclusive, the person's days
	now      time.Time
}

// wsFrom and wsTo widen the window by a day each side: a workspace's days
// are in its own zone, and a span near the edge may reach the person's day.
func (q realmHoursRead) wsFrom() string { return q.from.AddDate(0, 0, -1).Format(hoursDayLayout) }
func (q realmHoursRead) wsTo() string   { return q.to.AddDate(0, 0, 1).Format(hoursDayLayout) }

// GET /v1/me/realm/hours: answers {tz, tz_source, from, to, workspaces,
// days, totals, incomplete, limits}.
func (s *Server) handleGetRealmHours(w http.ResponseWriter, r *http.Request) {
	hum, ok := s.realmPerson(w, r)
	if !ok {
		return
	}
	ml, okM := s.o.Store.(store.MembershipLister)
	hs, okH := s.o.Store.(store.Hours)
	rs, okR := s.o.Store.(store.Realm)
	if !okM || !okH || !okR {
		writeErr(w, http.StatusServiceUnavailable, "hours_unavailable", "personal hours are not kept by this hub")
		return
	}
	ctx := r.Context()
	ms, err := ml.Memberships(ctx, hum)
	if err != nil {
		s.realmHoursFail(w, hum, "memberships", err)
		return
	}
	if s.realmClone(ctx, hum, ms) {
		writeErr(w, http.StatusForbidden, "person_only", "personal hours are not shown under act-as")
		return
	}
	seats := realmSeats(ms)
	if len(ms) > 0 && len(seats) == 0 {
		writeErr(w, http.StatusForbidden, "person_only", "a time accountant seat keeps no own hours")
		return
	}
	if len(seats) > realmHoursMaxWorkspaces {
		writeErr(w, http.StatusBadRequest, "too_many_workspaces", "personal hours read at most 20 workspaces")
		return
	}
	// The realm scope first, its own transactions (119 section 5).
	prof, limits, receipts, err := s.realmHoursRealm(ctx, rs, hum)
	if err != nil {
		s.realmHoursFail(w, hum, "realm", err)
		return
	}
	now := s.o.Now()
	zone, zoneSrc := realmZone(prof, r.URL.Query().Get("tz"))
	from, to, bad := realmWindow(r.URL.Query(), zone, now)
	if bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_window", bad)
		return
	}
	q := realmHoursRead{hum: hum, zone: zone, from: from, to: to, now: now}
	wsDays, wss := s.realmHoursWorkspaces(ctx, hs, q, seats)
	leftDays, left := realmReceiptDays(q, seats, receipts)
	wss = append(wss, left...)
	days, err := hours.Across(append(wsDays, leftDays...), zone, now)
	if err != nil {
		s.realmHoursFail(w, hum, "across", err)
		return
	}
	days = realmWindowDays(q, days)
	incomplete := false
	for _, d := range days {
		incomplete = incomplete || d.Incomplete
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"tz": zone.String(), "tz_source": zoneSrc,
		"from": from.Format(hoursDayLayout), "to": to.Format(hoursDayLayout),
		"workspaces": wss, "days": days, "totals": hours.Sum(days), "incomplete": incomplete,
		"limits": realmLimitsJSON(limits, q),
	})
}

// realmSeats is the memberships the person keeps own hours in (not a
// time_accountant seat), in the drop box order.
func realmSeats(ms []store.Membership) []store.Membership {
	var out []store.Membership
	for _, m := range ms {
		if !seatAccountant(m) {
			out = append(out, m)
		}
	}
	return out
}

// realmHoursRealm reads the person's realm rows, each an inPerson
// transaction of its own.
func (s *Server) realmHoursRealm(ctx context.Context, rs store.Realm, hum string) (store.RealmProfile, []store.RealmLimits, []store.RealmReceipt, error) {
	prof, err := rs.RealmProfileOf(ctx, hum)
	if err != nil {
		return prof, nil, nil, err
	}
	limits, err := rs.RealmLimitsHistory(ctx, hum)
	if err != nil {
		return prof, nil, nil, err
	}
	receipts, err := rs.RealmReceipts(ctx, hum)
	return prof, limits, receipts, err
}

func (s *Server) realmHoursFail(w http.ResponseWriter, hum, op string, err error) {
	if errors.Is(err, store.ErrNoPerson) {
		writeErr(w, http.StatusForbidden, "person_only", "personal hours need a signed-in person")
		return
	}
	s.o.Log.Error().Err(err).Str("human_id", hum).Str("op", op).Msg("realm hours")
	writeErrCause(w, http.StatusInternalServerError, "internal", "personal hours unavailable", err)
}

// realmHoursWorkspaces reads every seat, at most realmHoursInFlight at once;
// a failed one comes back unavailable on every day of the window.
func (s *Server) realmHoursWorkspaces(ctx context.Context, hs store.Hours, q realmHoursRead, seats []store.Membership) ([]hours.WorkspaceDay, []realmWorkspace) {
	got := make([][]hours.WorkspaceDay, len(seats))
	errs := make([]error, len(seats))
	sem := make(chan struct{}, realmHoursInFlight)
	var wg sync.WaitGroup
	for i, m := range seats {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int, m store.Membership) {
			defer func() { <-sem; wg.Done() }()
			wctx, cancel := context.WithTimeout(ctx, realmHoursReadTimeout)
			defer cancel()
			got[i], errs[i] = s.realmHoursOne(wctx, hs, q, m)
		}(i, m)
	}
	wg.Wait()
	var days []hours.WorkspaceDay
	wss := make([]realmWorkspace, 0, len(seats))
	for i, m := range seats {
		ws := realmWorkspace{ID: m.TenantID, Name: m.DisplayName, State: realmStateMember}
		if errs[i] != nil {
			s.o.Log.Warn().Err(errs[i]).Str("tenant", m.TenantID).Str("human_id", q.hum).Msg("realm hours: workspace unavailable")
			ws.State = realmStateUnavailable
			for d := q.from; !d.After(q.to); d = d.AddDate(0, 0, 1) {
				days = append(days, hours.WorkspaceDay{Workspace: m.TenantID, Day: d.Format(hoursDayLayout), Unavailable: true})
			}
		} else {
			days = append(days, got[i]...)
		}
		wss = append(wss, ws)
	}
	return days, wss
}

// realmHoursOne reads one workspace as the person: its entries with their
// spans, its period marks, and today's open suggestions, all through the
// 107 store calls with member = the person.
func (s *Server) realmHoursOne(ctx context.Context, hs store.Hours, q realmHoursRead, m store.Membership) ([]hours.WorkspaceDay, error) {
	t, err := s.o.Store.GetTenant(ctx, m.TenantID)
	if err != nil {
		return nil, err
	}
	c := hoursMe{tenant: t, hum: q.hum, st: hs, set: store.HoursSettingsOf(t.Settings)}
	from, to := q.wsFrom(), q.wsTo()
	entries, err := hs.HoursEntries(ctx, t.ID, q.hum, from, to)
	if err != nil {
		return nil, err
	}
	spans, err := hs.HoursEntrySpans(ctx, t.ID, q.hum, from, to)
	if err != nil {
		return nil, err
	}
	periods, err := hs.HoursPeriods(ctx, t.ID, q.hum, from, to)
	if err != nil {
		return nil, err
	}
	open, err := s.realmOpenToday(ctx, c, q, entries, periods)
	if err != nil {
		return nil, err
	}
	return realmWorkspaceDays(t.ID, entries, spans, periods, open), nil
}

// realmOpenToday is the open suggestions of the person's today in this
// workspace (its zone), the way GET /v1/me/hours makes them (suggestHours):
// none on a frozen day, in a returned period or for a target already
// entered. It reuses the rows already read; no second entries read.
func (s *Server) realmOpenToday(ctx context.Context, c hoursMe, q realmHoursRead, entries []store.HoursEntry, periods []store.HoursPeriod) ([]store.HoursEntry, error) {
	loc, err := s.hoursZone(ctx, c, q.now)
	if err != nil {
		return nil, err
	}
	today := civil(q.now, loc)
	day := today.Format(hoursDayLayout)
	if day < q.wsFrom() || day > q.wsTo() || realmPeriodMark(day, periods) == store.HoursReturned {
		return nil, nil
	}
	p := &hoursPeriod{loc: loc, today: day, start: today, end: today, suggest: map[string]map[string]hours.Row{}}
	if p.frozen, err = c.st.HoursFrozenDays(ctx, c.tenant.ID, c.hum, []string{day}, q.now); err != nil || p.frozen[day] {
		return nil, err
	}
	if err := s.suggestHours(ctx, c, p); err != nil {
		return nil, err
	}
	entered := map[string]bool{}
	for _, e := range entries {
		if e.Day == day {
			entered[e.Target] = true
		}
	}
	var out []store.HoursEntry
	for target, row := range p.suggest[day] {
		if entered[target] {
			continue
		}
		e := store.HoursEntry{Day: day, Target: target, Minutes: row.Minutes, State: hoursSuggested}
		for _, b := range row.Blocks {
			e.Spans = append(e.Spans, store.HoursSpan{Start: b.Start, End: b.End})
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Target < out[j].Target })
	return out, nil
}

// realmWorkspaceDays turns one workspace's rows into Across's input, one
// WorkspaceDay per day that holds an entry or an open suggestion.
func realmWorkspaceDays(ws string, entries []store.HoursEntry, spans []store.HoursEntrySpan, periods []store.HoursPeriod, open []store.HoursEntry) []hours.WorkspaceDay {
	bySpan := map[[2]string][]hours.TimeSpan{}
	for _, sp := range spans {
		k := [2]string{sp.Day, sp.Target}
		bySpan[k] = append(bySpan[k], hours.TimeSpan{Start: sp.Start.UTC(), End: sp.End.UTC()})
	}
	byDay := map[string]*hours.WorkspaceDay{}
	var order []string
	add := func(day string, e hours.AcrossEntry) {
		if byDay[day] == nil {
			byDay[day] = &hours.WorkspaceDay{Workspace: ws, Day: day, State: realmPeriodMark(day, periods)}
			order = append(order, day)
		}
		byDay[day].Entries = append(byDay[day].Entries, e)
	}
	for _, e := range entries {
		state := hours.EntryApproved
		if e.State == store.HoursRejected {
			state = hours.EntryRejected
		}
		add(e.Day, hours.AcrossEntry{Target: e.Target, Minutes: e.Minutes, State: state, Spans: bySpan[[2]string{e.Day, e.Target}]})
	}
	for _, e := range open {
		var ss []hours.TimeSpan
		for _, b := range e.Spans {
			ss = append(ss, hours.TimeSpan{Start: b.Start.UTC(), End: b.End.UTC()})
		}
		add(e.Day, hours.AcrossEntry{Target: e.Target, Minutes: e.Minutes, State: hours.EntryOpen, Spans: ss})
	}
	sort.Strings(order)
	out := make([]hours.WorkspaceDay, 0, len(order))
	for _, d := range order {
		out = append(out, *byDay[d])
	}
	return out
}

// realmPeriodMark is 107's mark of day: the state of the period row holding
// it (frozen, returned, approved), else open.
func realmPeriodMark(day string, periods []store.HoursPeriod) string {
	for _, p := range periods {
		if p.Start <= day && day <= p.End {
			return p.State
		}
	}
	return "open"
}

// realmReceiptDays is the left workspaces (C5, C6): a receipt whose
// workspace is no live seat. Its minutes are reported and, with no times
// (Q5 A), unplaced in actual. A rejoin does not merge a receipt back.
func realmReceiptDays(q realmHoursRead, seats []store.Membership, receipts []store.RealmReceipt) ([]hours.WorkspaceDay, []realmWorkspace) {
	live := map[string]bool{}
	for _, m := range seats {
		live[m.TenantID] = true
	}
	from, to := q.wsFrom(), q.wsTo()
	byKey := map[[2]string]*hours.WorkspaceDay{}
	var keys [][2]string
	names := map[string]string{}
	var left []string
	for _, rc := range receipts {
		if live[rc.WorkspaceID] {
			continue
		}
		if _, seen := names[rc.WorkspaceID]; !seen {
			left = append(left, rc.WorkspaceID)
		}
		names[rc.WorkspaceID] = rc.WorkspaceName
		if rc.Day < from || rc.Day > to {
			continue
		}
		k := [2]string{rc.WorkspaceID, rc.Day}
		if byKey[k] == nil {
			byKey[k] = &hours.WorkspaceDay{Workspace: rc.WorkspaceID, Day: rc.Day, State: rc.ApprovalState}
			keys = append(keys, k)
		}
		state := hours.EntryApproved
		if rc.ApprovalState == store.HoursRejected {
			state = hours.EntryRejected
		}
		byKey[k].Entries = append(byKey[k].Entries, hours.AcrossEntry{Target: rc.Label, Minutes: rc.Minutes, State: state})
	}
	days := make([]hours.WorkspaceDay, 0, len(keys))
	for _, k := range keys {
		days = append(days, *byKey[k])
	}
	sort.Strings(left)
	wss := make([]realmWorkspace, 0, len(left))
	for _, id := range left {
		wss = append(wss, realmWorkspace{ID: id, Name: names[id], State: realmStateLeft})
	}
	return days, wss
}

// realmWindowDays keeps the person's days of the window, one per day: a
// day with nothing is a zero day, so the view draws a whole grid.
func realmWindowDays(q realmHoursRead, days []hours.PersonalDay) []hours.PersonalDay {
	byDay := map[string]hours.PersonalDay{}
	for _, d := range days {
		byDay[d.Day] = d
	}
	out := []hours.PersonalDay{}
	for d := q.from; !d.After(q.to); d = d.AddDate(0, 0, 1) {
		key := d.Format(hoursDayLayout)
		pd, ok := byDay[key]
		if !ok {
			pd = hours.PersonalDay{Day: key, Unavailable: []string{}, OverlapIntervals: []hours.OverlapInterval{},
				Workspaces: map[string]hours.WorkspaceShare{}}
		}
		out = append(out, pd)
	}
	return out
}

// realmLimitsJSON is the limits rows that judge the window: the one in force
// on from, and every later change up to to. The warning is the WUI's (8.1):
// no number here is compared, sent on or stored.
func realmLimitsJSON(rows []store.RealmLimits, q realmHoursRead) []realmLimitJSON {
	from, to := q.from.Format(hoursDayLayout), q.to.Format(hoursDayLayout)
	out := []realmLimitJSON{}
	for i, l := range rows {
		if l.ValidFrom > to {
			break
		}
		if l.ValidFrom <= from && i+1 < len(rows) && rows[i+1].ValidFrom <= from {
			continue // a later row is already in force on from
		}
		out = append(out, realmLimitJSON{ValidFrom: l.ValidFrom, DayMinutes: l.DayLimitMinutes, WeekMinutes: l.WeekLimitMinutes})
	}
	return out
}

// realmHoursPreflight: GET (this file) and PUT (the multi-workspace save,
// realm_hours_write.go, 118 T004, which registers no OPTIONS of its own on
// this path) with the headers every browser route allows.
func (s *Server) realmHoursPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeRealmHoursRead(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/me/realm/hours", s.handleGetRealmHours)
	mux.HandleFunc("OPTIONS /v1/me/realm/hours", s.realmHoursPreflight)
}
