package hub

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The team side of hours (spec 107 v1.0, T008; sections 4.3, 4.4, 6.1, 6.3):
//
//	GET /v1/hours?period=&member=&target=  hours.read: every member's approved
//	                                       entries and period states
//	PUT /v1/hours/periods                  hours.approve: approve or return
//	                                       frozen member periods, a batch
//
// Privacy (spec 1.7): the team side reads approved entries and period rows
// only (store.HoursTeam, store.Hours.HoursPeriods): never a raw minute, a
// rejected row or a suggestion.

// hoursTeamCaller is the caller of a team route.
type hoursTeamCaller struct {
	tenant store.Tenant
	hum    string
	st     store.Hours
	team   store.HoursTeam
	set    store.HoursSettings
}

// hoursTeamAuth is the signed-in member holding perm in this workspace.
func (s *Server) hoursTeamAuth(w http.ResponseWriter, r *http.Request, perm string) (hoursTeamCaller, bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return hoursTeamCaller{}, false
	}
	if hum == "" {
		writeForbidden(w, perm, "team hours need a signed-in member session")
		return hoursTeamCaller{}, false
	}
	if !s.permit(w, r, t.ID, hum, perm) {
		return hoursTeamCaller{}, false
	}
	hs, ok1 := s.o.Store.(store.Hours)
	team, ok2 := s.o.Store.(store.HoursTeam)
	if !ok1 || !ok2 {
		writeErr(w, http.StatusServiceUnavailable, "hours_unavailable", "hours are not kept by this hub")
		return hoursTeamCaller{}, false
	}
	return hoursTeamCaller{tenant: t, hum: hum, st: hs, team: team, set: store.HoursSettingsOf(t.Settings)}, true
}

// hoursTeamQuery is a team read: the workspace period holding day, narrowed
// to one member and one target (exact, or a type: t, ch, dm, cal, ws).
type hoursTeamQuery struct {
	day        time.Time // civil
	start, end time.Time // the workspace period, civil, inclusive
	member     string
	target     string
}

var hoursTargetTypes = map[string]bool{"t": true, "ch": true, "dm": true, "cal": true, "ws": true}

// parseHoursTeamQuery reads period (a day, default the workspace's today),
// member and target; the string is a 400's detail.
func parseHoursTeamQuery(r *http.Request, set store.HoursSettings, now time.Time) (hoursTeamQuery, string) {
	q := r.URL.Query()
	tq := hoursTeamQuery{day: civil(now, set.Location()), member: strings.TrimSpace(q.Get("member")),
		target: strings.TrimSpace(q.Get("target"))}
	if p := strings.TrimSpace(q.Get("period")); p != "" {
		d, err := time.Parse(hoursDayLayout, p)
		if err != nil {
			return tq, "period must be a day, YYYY-MM-DD"
		}
		tq.day = d
	}
	tq.start, tq.end = store.HoursPeriodBounds(set.Period, tq.day)
	return tq, ""
}

// keeps reports whether target passes the target filter.
func (q hoursTeamQuery) keeps(target string) bool {
	switch {
	case q.target == "":
		return true
	case hoursTargetTypes[q.target]:
		return target == q.target || strings.HasPrefix(target, q.target+":")
	}
	return target == q.target
}

// hoursTeamData is one team read: the members, their period rows covering
// the day, and the approved entries of the workspace period.
type hoursTeamData struct {
	q       hoursTeamQuery
	names   map[string]string            // member -> display name
	members []string                     // current members plus any with a row or an entry
	rows    map[string]store.HoursPeriod // member -> the row covering q.day
	entries []store.HoursTeamEntry
}

func (s *Server) loadHoursTeam(ctx context.Context, c hoursTeamCaller, q hoursTeamQuery) (*hoursTeamData, error) {
	from, to := q.start.Format(hoursDayLayout), q.end.Format(hoursDayLayout)
	d := &hoursTeamData{q: q, names: map[string]string{}, rows: map[string]store.HoursPeriod{}}
	es, err := c.team.HoursApprovedEntries(ctx, c.tenant.ID, q.member, from, to)
	if err != nil {
		return nil, err
	}
	for _, e := range es {
		if q.keeps(e.Target) {
			d.entries = append(d.entries, e)
		}
	}
	day := q.day.Format(hoursDayLayout)
	rows, err := c.st.HoursPeriods(ctx, c.tenant.ID, q.member, day, day)
	if err != nil {
		return nil, err
	}
	for _, p := range rows {
		d.rows[p.Member] = p
	}
	return d, s.hoursTeamMembers(ctx, c, d)
}

// hoursTeamMembers fills names and members: every current human member, plus
// any member with a row or an entry (one removed mid-period).
func (s *Server) hoursTeamMembers(ctx context.Context, c hoursTeamCaller, d *hoursTeamData) error {
	seen := map[string]bool{}
	add := func(id string) {
		if !seen[id] && (d.q.member == "" || id == d.q.member) {
			seen[id] = true
			d.members = append(d.members, id)
		}
	}
	if dir, ok := s.o.Store.(store.MemberDirectory); ok {
		ms, err := dir.ListMembers(ctx, c.tenant.ID)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return err
		}
		for _, m := range ms {
			d.names[m.HumanID] = m.DisplayName
			add(m.HumanID)
		}
	}
	for id := range d.rows {
		add(id)
	}
	for _, e := range d.entries {
		add(e.Member)
	}
	sort.Strings(d.members)
	return nil
}

// state is the member's period state: the row's, else open or frozen by the
// clock (the sweep has not run yet).
func (d *hoursTeamData) state(member string, set store.HoursSettings, now time.Time) string {
	if p, ok := d.rows[member]; ok {
		return p.State
	}
	if !now.Before(store.HoursFreezeAt(d.q.end, set.GraceDays, set.Location())) {
		return store.HoursFrozen
	}
	return "open"
}

type hoursTeamMemberJSON struct {
	Member      string `json:"member_id"`
	Name        string `json:"name"`
	State       string `json:"state"` // open, frozen, returned or approved
	Minutes     int    `json:"minutes"`
	PeriodStart string `json:"period_start,omitempty"`
	PeriodEnd   string `json:"period_end,omitempty"`
	RowMinutes  int    `json:"period_minutes"`
	Note        string `json:"note,omitempty"`
	DecidedBy   string `json:"decided_by,omitempty"`
	DecidedAt   string `json:"decided_at,omitempty"`
}

type hoursTeamEntryJSON struct {
	Member           string `json:"member_id"`
	Day              string `json:"day"`
	Target           string `json:"target"`
	Minutes          int    `json:"minutes"`
	SuggestedMinutes int    `json:"suggested_minutes"`
	Note             string `json:"note,omitempty"`
}

func (d *hoursTeamData) json(set store.HoursSettings, now time.Time) map[string]any {
	total := map[string]int{}
	entries := make([]hoursTeamEntryJSON, 0, len(d.entries))
	for _, e := range d.entries {
		total[e.Member] += e.Minutes
		entries = append(entries, hoursTeamEntryJSON{Member: e.Member, Day: e.Day, Target: e.Target,
			Minutes: e.Minutes, SuggestedMinutes: e.SuggestedMinutes, Note: e.Note})
	}
	members := make([]hoursTeamMemberJSON, 0, len(d.members))
	for _, id := range d.members {
		m := hoursTeamMemberJSON{Member: id, Name: d.names[id], State: d.state(id, set, now), Minutes: total[id]}
		if p, ok := d.rows[id]; ok {
			m.PeriodStart, m.PeriodEnd, m.RowMinutes, m.Note = p.Start, p.End, p.Minutes, p.Note
			m.DecidedBy, m.DecidedAt = p.DecidedBy, p.DecidedAt.UTC().Format(time.RFC3339)
		}
		members = append(members, m)
	}
	per := map[string]any{"start": d.q.start.Format(hoursDayLayout), "end": d.q.end.Format(hoursDayLayout),
		"freezes_at": store.HoursFreezeAt(d.q.end, set.GraceDays, set.Location()).UTC().Format(time.RFC3339)}
	return map[string]any{"period": per, "members": members, "entries": entries}
}

// GET /v1/hours?period=YYYY-MM-DD&member=&target=: the workspace period
// holding that day (default today in hours.tz).
func (s *Server) handleGetTeamHours(w http.ResponseWriter, r *http.Request) {
	c, ok := s.hoursTeamAuth(w, r, rbac.HoursRead)
	if !ok {
		return
	}
	now := s.o.Now()
	q, bad := parseHoursTeamQuery(r, c.set, now)
	if bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_period", bad)
		return
	}
	d, err := s.loadHoursTeam(r.Context(), c, q)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "team read", err)
		return
	}
	writeJSON(w, http.StatusOK, d.json(c.set, now))
}

// ---- PUT /v1/hours/periods ------------------------------------------------------

// hoursDecisionBody: approve or return the frozen rows covering period (a
// day) of members; no members = every frozen row (Approve all / Return all).
type hoursDecisionBody struct {
	Period  string   `json:"period"`
	Action  string   `json:"action"` // approve or return
	Members []string `json:"members"`
	Note    string   `json:"note"`
}

// hoursDecisionRows checks body and answers the rows it moves, all frozen;
// the string is a 400's detail, a non-nil error a store or state error.
func hoursDecisionRows(ctx context.Context, c hoursTeamCaller, body hoursDecisionBody) ([]store.HoursPeriod, string, error) {
	if body.Action != "approve" && body.Action != "return" {
		return nil, "action must be approve or return", nil
	}
	if body.Action == "return" && strings.TrimSpace(body.Note) == "" {
		return nil, "a return needs a note", nil
	}
	if _, err := time.Parse(hoursDayLayout, body.Period); err != nil {
		return nil, "period must be a day, YYYY-MM-DD", nil
	}
	rows, err := c.st.HoursPeriods(ctx, c.tenant.ID, "", body.Period, body.Period)
	if err != nil {
		return nil, "", err
	}
	byMember := map[string]store.HoursPeriod{}
	for _, p := range rows {
		byMember[p.Member] = p
	}
	if len(body.Members) == 0 {
		var out []store.HoursPeriod
		for _, p := range rows {
			if p.State == store.HoursFrozen {
				out = append(out, p)
			}
		}
		return out, "", nil
	}
	out := make([]store.HoursPeriod, 0, len(body.Members))
	for _, m := range body.Members {
		p, ok := byMember[m]
		if !ok || p.State != store.HoursFrozen {
			return nil, "", store.ErrHoursPeriodState // only a frozen row moves
		}
		out = append(out, p)
	}
	return out, "", nil
}

// PUT /v1/hours/periods {period, action, members?, note?}: all or none of
// the named rows move; answers the team view of that period.
func (s *Server) handlePutTeamHoursPeriods(w http.ResponseWriter, r *http.Request) {
	c, ok := s.hoursTeamAuth(w, r, rbac.HoursApprove)
	if !ok {
		return
	}
	var body hoursDecisionBody
	if !decodeHoursBody(w, r, &body, "body must be {period, action: approve|return, members?: [HUM-*], note?}") {
		return
	}
	ctx, now := r.Context(), s.o.Now()
	rows, bad, err := hoursDecisionRows(ctx, c, body)
	if bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_hours", bad)
		return
	}
	if errors.Is(err, store.ErrHoursPeriodState) {
		writeErr(w, http.StatusConflict, "period_state", "only a frozen period can be approved or returned")
		return
	}
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "decide read", err)
		return
	}
	state := store.HoursApproved
	if body.Action == "return" {
		state = store.HoursReturned
	}
	for _, p := range rows {
		ch := store.HoursPeriodChange{State: state, Note: body.Note, By: c.hum, At: now}
		if _, err := c.st.SetHoursPeriodState(ctx, c.tenant.ID, p.Member, p.Start, ch); err != nil {
			s.hoursFail(w, c.tenant.ID, "decide", err)
			return
		}
		if state == store.HoursReturned {
			s.recordMemberActivity(ctx, store.MemberActivity{TenantID: c.tenant.ID, SubjectHum: p.Member,
				ActorHum: c.hum, Kind: "hours_returned", Detail: p.Start + ".." + p.End})
		}
	}
	day, _ := time.Parse(hoursDayLayout, body.Period)
	q := hoursTeamQuery{day: day}
	q.start, q.end = store.HoursPeriodBounds(c.set.Period, day)
	d, err := s.loadHoursTeam(ctx, c, q)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "decide read back", err)
		return
	}
	out := d.json(c.set, now)
	out["changed"] = len(rows)
	writeJSON(w, http.StatusOK, out)
}

// ---- routes ------------------------------------------------------------------------

func (s *Server) routeTeamHours(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/hours", s.handleGetTeamHours)
	mux.HandleFunc("OPTIONS /v1/hours", s.hoursPreflight)
	mux.HandleFunc("PUT /v1/hours/periods", s.handlePutTeamHoursPeriods)
	mux.HandleFunc("OPTIONS /v1/hours/periods", s.hoursPreflight)
}
