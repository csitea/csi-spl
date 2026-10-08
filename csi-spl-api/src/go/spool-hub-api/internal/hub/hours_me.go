package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hours"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A member's own hours (spec 107 v1.0, T006; sections 2 and 6.3):
//
//	PUT /v1/me/hours/minutes  the WUI's tab-minute batch (<= 60, one tz)
//	GET /v1/me/hours?period=  the period holding that day: per day the
//	                          suggestions, the entries, the deltas; its state
//	PUT /v1/me/hours          approve / edit / reject / add / remove, and
//	                          resubmit a returned period; 409 period_frozen
//
// Privacy (spec 1.7): these are the only routes that serve raw minutes and
// unapproved suggestions, and every store call here takes the caller as the
// member: nothing reads another member's rows, and no call passes "" (the
// store's "every member").

const (
	hoursMinutesBatchMax = 60              // spec 6.3
	hoursMinuteSkew      = 2 * time.Minute // a tab clock slightly ahead
	hoursMinuteMaxAge    = 45 * 24 * time.Hour
	hoursZoneLookback    = 48 * time.Hour // the last tab batch's zone (1.6)
	hoursBodyMax         = 128 << 10
	hoursDayLayout       = "2006-01-02"
)

// hoursMeetingKinds is the calendar kinds suggested as meetings (spec 1.4):
// owner Q6, the panel's A, kind other only. Q6 = B (every timed, accepted
// event) is hoursMeetingKind answering true for any kind.
var hoursMeetingKinds = map[string]bool{"other": true}

func hoursMeetingKind(kind string) bool { return hoursMeetingKinds[kind] }

// hoursMe is the caller of a /v1/me/hours route.
type hoursMe struct {
	tenant store.Tenant
	hum    string
	st     store.Hours
	set    store.HoursSettings
}

// hoursCaller is the signed-in member of this workspace. A write is the
// member's own record: like their status, not for a demo visitor.
func (s *Server) hoursCaller(w http.ResponseWriter, r *http.Request) (hoursMe, bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return hoursMe{}, false
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "hours need a signed-in member session")
		return hoursMe{}, false
	}
	if r.Method != http.MethodGet && !s.permit(w, r, t.ID, hum, rbac.SelfKeys) {
		return hoursMe{}, false
	}
	hs, ok := s.o.Store.(store.Hours)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "hours_unavailable", "hours are not kept by this hub")
		return hoursMe{}, false
	}
	return hoursMe{tenant: t, hum: hum, st: hs, set: store.HoursSettingsOf(t.Settings)}, true
}

// hoursFail answers a store error.
func (s *Server) hoursFail(w http.ResponseWriter, tenant, op string, err error) {
	switch {
	case errors.Is(err, store.ErrHoursFrozen):
		writeErr(w, http.StatusConflict, "period_frozen", "the day's hours period is frozen")
	case errors.Is(err, store.ErrHoursDayCap):
		writeErr(w, http.StatusBadRequest, "day_cap", "a day holds at most 1440 minutes")
	case errors.Is(err, store.ErrHoursPeriodState):
		writeErr(w, http.StatusConflict, "period_state", "the period cannot be resubmitted in its state")
	case errors.Is(err, store.ErrHoursBad):
		writeErr(w, http.StatusBadRequest, "bad_hours", strings.TrimPrefix(err.Error(), "store: "))
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such hours row")
	default:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("op", op).Msg("hours")
		writeErrCause(w, http.StatusInternalServerError, "internal", "hours unavailable", err)
	}
}

// hoursZone is the member's zone (spec 1.6): their own time_zone in this
// workspace, else the zone of their last tab batch, else hours.tz.
func (s *Server) hoursZone(ctx context.Context, c hoursMe, now time.Time) (*time.Location, error) {
	if mr, ok := s.o.Store.(auth.MembershipSettingsReader); ok {
		ms, err := mr.MembershipSettings(ctx, c.hum, c.tenant.ID)
		if err != nil && !errors.Is(err, store.ErrNotFound) && !errors.Is(err, auth.ErrNoHuman) {
			return nil, err
		}
		if ms.TimeZone != nil {
			if loc, ok := hoursLoadZone(*ms.TimeZone); ok {
				return loc, nil
			}
		}
	}
	recent, err := c.st.HoursMinutes(ctx, c.tenant.ID, c.hum, now.Add(-hoursZoneLookback), now.Add(hoursMinuteSkew))
	if err != nil {
		return nil, err
	}
	for i := len(recent) - 1; i >= 0; i-- {
		if loc, ok := hoursLoadZone(recent[i].TZ); ok {
			return loc, nil
		}
	}
	return c.set.Location(), nil
}

func hoursLoadZone(name string) (*time.Location, bool) {
	if name == "" || name == "Local" || !auth.IsTimeZone(name) {
		return nil, false
	}
	loc, err := time.LoadLocation(name)
	return loc, err == nil
}

// civil is the day of t in loc as a civil date (00:00 UTC).
func civil(t time.Time, loc *time.Location) time.Time {
	y, m, d := t.In(loc).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// ---- one period ---------------------------------------------------------------

// hoursPeriod is everything the page shows of one of the member's periods.
type hoursPeriod struct {
	loc        *time.Location
	today      string
	start, end time.Time // civil, inclusive
	row        *store.HoursPeriod
	frozen     map[string]bool
	suggest    map[string]map[string]hours.Row // day -> target -> row
	entries    []store.HoursEntry
}

func (p *hoursPeriod) days() []string {
	var out []string
	for d := p.start; !d.After(p.end); d = d.AddDate(0, 0, 1) {
		out = append(out, d.Format(hoursDayLayout))
	}
	return out
}

func (p *hoursPeriod) returned() bool { return p.row != nil && p.row.State == store.HoursReturned }

// loadHoursPeriod reads the member's period holding day (civil, in loc).
func (s *Server) loadHoursPeriod(ctx context.Context, c hoursMe, loc *time.Location, day, now time.Time) (*hoursPeriod, error) {
	rows, err := c.st.HoursPeriods(ctx, c.tenant.ID, c.hum,
		day.AddDate(0, 0, -62).Format(hoursDayLayout), day.Format(hoursDayLayout))
	if err != nil {
		return nil, err
	}
	p := &hoursPeriod{loc: loc, today: civil(now, loc).Format(hoursDayLayout)}
	p.start, p.end, p.row = store.HoursPeriodFor(day, rows, c.set)
	days := p.days()
	if p.frozen, err = c.st.HoursFrozenDays(ctx, c.tenant.ID, c.hum, days, now); err != nil {
		return nil, err
	}
	if p.entries, err = c.st.HoursEntries(ctx, c.tenant.ID, c.hum, days[0], days[len(days)-1]); err != nil {
		return nil, err
	}
	// No suggestion for a frozen day nor in a returned period (spec 2.2).
	open := false
	for _, d := range days {
		open = open || !p.frozen[d]
	}
	p.suggest = map[string]map[string]hours.Row{}
	if !open || p.returned() {
		return p, nil
	}
	return p, s.suggestHours(ctx, c, p)
}

// suggestHours fills p.suggest from the member's minutes and meetings (spec 2.1).
func (s *Server) suggestHours(ctx context.Context, c hoursMe, p *hoursPeriod) error {
	// A day either side: a block near the edge may start on the day before.
	from := time.Date(p.start.Year(), p.start.Month(), p.start.Day()-1, 0, 0, 0, 0, p.loc)
	to := time.Date(p.end.Year(), p.end.Month(), p.end.Day()+2, 0, 0, 0, 0, p.loc)
	ms, err := c.st.HoursMinutes(ctx, c.tenant.ID, c.hum, from, to)
	if err != nil {
		return err
	}
	meetings, err := s.hoursMeetings(ctx, c, from, to)
	if err != nil {
		return err
	}
	idle, err := c.st.HoursIdleMinutes(ctx, c.tenant.ID, c.hum)
	if err != nil {
		return err
	}
	in := hours.Input{Meetings: meetings, IdleMinutes: idle, Loc: p.loc}
	for _, m := range ms {
		in.Minutes = append(in.Minutes, hours.Minute{At: m.At, Target: m.Target, Src: m.Src})
	}
	out, err := hours.Suggest(in)
	if err != nil {
		return err
	}
	first, last := p.start.Format(hoursDayLayout), p.end.Format(hoursDayLayout)
	for _, d := range out {
		if d.Date < first || d.Date > last || p.frozen[d.Date] {
			continue
		}
		rows := map[string]hours.Row{}
		for _, r := range d.Rows {
			r.Minutes = min(r.Minutes, store.HoursDayCap) // a 25-hour day
			rows[r.Target] = r
		}
		p.suggest[d.Date] = rows
	}
	return nil
}

// hoursMeetings is the member's meetings in [from, to) (spec 1.4): timed,
// confirmed, of a counted kind, created by the member or answered yes.
func (s *Server) hoursMeetings(ctx context.Context, c hoursMe, from, to time.Time) ([]hours.Meeting, error) {
	cal := s.calendarStore()
	if cal == nil {
		return nil, nil
	}
	evs, err := cal.ListCalendarEvents(ctx, c.tenant.ID, c.hum, store.CalendarRange{Start: from, End: to})
	if errors.Is(err, store.ErrCalendarUnavailable) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []hours.Meeting
	for _, e := range evs {
		if !hoursCountedMeeting(e, c.hum) {
			continue
		}
		out = append(out, hours.Meeting{EventID: e.ID, TopicID: e.TopicID, Start: e.StartsAt, End: e.EndsAt})
	}
	return out, nil
}

func hoursCountedMeeting(e store.CalendarEvent, hum string) bool {
	if e.AllDay || !hoursMeetingKind(e.Kind) || !e.DeletedAt.IsZero() ||
		(e.Status != "" && e.Status != store.CalendarConfirmed) {
		return false
	}
	if e.CreatorType == "human" && e.CreatorID == hum {
		return true
	}
	for _, g := range e.Guests {
		if g.Type == "human" && g.ID == hum {
			return g.Response == store.CalendarYes
		}
	}
	return false
}

// ---- the answer ---------------------------------------------------------------

type hoursSpanJSON struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

// hoursRowJSON is one (day, target) row: an open suggestion (state
// "suggested") or an entry, with its delta when the suggestion grew since.
type hoursRowJSON struct {
	Target           string          `json:"target"`
	State            string          `json:"state"`
	Minutes          int             `json:"minutes"`
	SuggestedMinutes int             `json:"suggested_minutes"`
	Delta            int             `json:"delta,omitempty"`
	Note             string          `json:"note,omitempty"`
	Blocks           []hoursSpanJSON `json:"blocks"`
}

type hoursDayJSON struct {
	Date             string         `json:"date"`
	Today            bool           `json:"today"`
	Closed           bool           `json:"closed"` // before the member's today
	Frozen           bool           `json:"frozen"`
	SuggestedMinutes int            `json:"suggested_minutes"` // of the open suggestions
	ApprovedMinutes  int            `json:"approved_minutes"`
	Open             int            `json:"open"` // open suggestions + deltas
	Rows             []hoursRowJSON `json:"rows"`
}

type hoursPeriodJSON struct {
	Start     string `json:"start"`
	End       string `json:"end"`
	State     string `json:"state"` // open, frozen, returned or approved
	Minutes   int    `json:"minutes"`
	Note      string `json:"note,omitempty"`
	FreezesAt string `json:"freezes_at"`
}

const hoursSuggested = "suggested"

func (p *hoursPeriod) json(set store.HoursSettings) map[string]any {
	byDay := map[string][]store.HoursEntry{}
	for _, e := range p.entries {
		byDay[e.Day] = append(byDay[e.Day], e)
	}
	days := []hoursDayJSON{}
	for _, d := range p.days() {
		days = append(days, p.dayJSON(d, byDay[d]))
	}
	per := hoursPeriodJSON{Start: p.start.Format(hoursDayLayout), End: p.end.Format(hoursDayLayout), State: "open",
		FreezesAt: store.HoursFreezeAt(p.end, set.GraceDays, set.Location()).UTC().Format(time.RFC3339)}
	switch {
	case p.row != nil:
		per.State, per.Minutes, per.Note = p.row.State, p.row.Minutes, p.row.Note
	case p.frozen[per.End]:
		per.State = store.HoursFrozen // frozen by the clock; the sweep has not run
	}
	return map[string]any{"tz": p.loc.String(), "today": p.today, "period": per, "days": days}
}

func (p *hoursPeriod) dayJSON(d string, es []store.HoursEntry) hoursDayJSON {
	day := hoursDayJSON{Date: d, Today: d == p.today, Closed: d < p.today, Frozen: p.frozen[d], Rows: []hoursRowJSON{}}
	sug := p.suggest[d]
	seen := map[string]bool{}
	for _, e := range es {
		seen[e.Target] = true
		row := hoursRowJSON{Target: e.Target, State: e.State, Minutes: e.Minutes,
			SuggestedMinutes: e.SuggestedMinutes, Note: e.Note, Blocks: []hoursSpanJSON{}}
		if s, ok := sug[e.Target]; ok {
			row.Blocks = spansJSON(s.Blocks)
			if s.Minutes > e.SuggestedMinutes {
				row.Delta = s.Minutes - e.SuggestedMinutes
				day.Open++
			}
		}
		if e.State == store.HoursApproved {
			day.ApprovedMinutes += e.Minutes
		}
		day.Rows = append(day.Rows, row)
	}
	for t, s := range sug {
		if seen[t] {
			continue
		}
		day.Rows = append(day.Rows, hoursRowJSON{Target: t, State: hoursSuggested, Minutes: s.Minutes,
			SuggestedMinutes: s.Minutes, Blocks: spansJSON(s.Blocks)})
		day.SuggestedMinutes += s.Minutes
		day.Open++
	}
	sort.SliceStable(day.Rows, func(i, j int) bool {
		if day.Rows[i].Minutes != day.Rows[j].Minutes {
			return day.Rows[i].Minutes > day.Rows[j].Minutes
		}
		return day.Rows[i].Target < day.Rows[j].Target
	})
	return day
}

func spansJSON(ss []hours.Span) []hoursSpanJSON {
	out := make([]hoursSpanJSON, 0, len(ss))
	for _, s := range ss {
		out = append(out, hoursSpanJSON{Start: s.Start.UTC().Format(time.RFC3339), End: s.End.UTC().Format(time.RFC3339)})
	}
	return out
}

// ---- GET /v1/me/hours ------------------------------------------------------------

// GET /v1/me/hours?period=YYYY-MM-DD: the period holding that day (default
// the member's today).
func (s *Server) handleGetMyHours(w http.ResponseWriter, r *http.Request) {
	c, ok := s.hoursCaller(w, r)
	if !ok {
		return
	}
	ctx, now := r.Context(), s.o.Now()
	loc, err := s.hoursZone(ctx, c, now)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "zone", err)
		return
	}
	day := civil(now, loc)
	if q := strings.TrimSpace(r.URL.Query().Get("period")); q != "" {
		if day, err = time.Parse(hoursDayLayout, q); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_period", "period must be a day, YYYY-MM-DD")
			return
		}
	}
	p, err := s.loadHoursPeriod(ctx, c, loc, day, now)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "read", err)
		return
	}
	writeJSON(w, http.StatusOK, p.json(c.set))
}

// ---- PUT /v1/me/hours/minutes ------------------------------------------------------

type hoursMinuteBody struct {
	TZ      string `json:"tz"`
	Minutes []struct {
		At     string `json:"at"`
		Target string `json:"target"`
	} `json:"minutes"`
}

// parseHoursMinutes checks a tab batch at now; the string is the 400's detail.
func parseHoursMinutes(b hoursMinuteBody, now time.Time) ([]store.HoursMinute, *time.Location, string) {
	loc, ok := hoursLoadZone(b.TZ)
	if !ok {
		return nil, nil, "tz must be an IANA zone name"
	}
	if len(b.Minutes) == 0 || len(b.Minutes) > hoursMinutesBatchMax {
		return nil, nil, "minutes must hold 1..60 rows"
	}
	out := make([]store.HoursMinute, 0, len(b.Minutes))
	for _, m := range b.Minutes {
		at, err := time.Parse(time.RFC3339, m.At)
		if err != nil {
			return nil, nil, "at must be an RFC 3339 time"
		}
		if at.After(now.Add(hoursMinuteSkew)) || at.Before(now.Add(-hoursMinuteMaxAge)) {
			return nil, nil, "at must be within the last 45 days and not in the future"
		}
		out = append(out, store.HoursMinute{At: at.UTC().Truncate(time.Minute), Target: m.Target,
			Src: store.HoursSrcTab, TZ: b.TZ})
	}
	return out, loc, ""
}

// PUT /v1/me/hours/minutes {tz, minutes: [{at, target}]}: the WUI's active-tab
// minutes (spec 1.2); refused whole when one falls on a frozen day.
func (s *Server) handlePutMyHoursMinutes(w http.ResponseWriter, r *http.Request) {
	c, ok := s.hoursCaller(w, r)
	if !ok {
		return
	}
	var body hoursMinuteBody
	if !decodeHoursBody(w, r, &body, "body must be {tz, minutes: [{at, target}]}") {
		return
	}
	now := s.o.Now()
	ms, loc, bad := parseHoursMinutes(body, now)
	if bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_minutes", bad)
		return
	}
	dayset := map[string]bool{}
	var days []string
	for _, m := range ms {
		if d := m.At.In(loc).Format(hoursDayLayout); !dayset[d] {
			dayset[d] = true
			days = append(days, d)
		}
	}
	frozen, err := c.st.HoursFrozenDays(r.Context(), c.tenant.ID, c.hum, days, now)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "minutes freeze", err)
		return
	}
	for _, d := range days {
		if frozen[d] {
			s.hoursFail(w, c.tenant.ID, "minutes", store.ErrHoursFrozen)
			return
		}
	}
	if err := c.st.UpsertHoursMinutes(r.Context(), c.tenant.ID, c.hum, ms); err != nil {
		s.hoursFail(w, c.tenant.ID, "minutes", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"stored": len(ms)})
}

func decodeHoursBody(w http.ResponseWriter, r *http.Request, v any, shape string) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, hoursBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", shape)
		return false
	}
	return true
}

// ---- PUT /v1/me/hours ----------------------------------------------------------------

type hoursEntryBody struct {
	Day     string `json:"day"`
	Target  string `json:"target"`
	Minutes int    `json:"minutes"`
	State   string `json:"state"`
	Note    string `json:"note"`
}

type hoursKeyBody struct {
	Day    string `json:"day"`
	Target string `json:"target"`
}

// hoursPutBody is one batch: entries to upsert (approve, edit, add: state
// approved; reject: rejected), added rows to take back, and a day of a
// returned period to resubmit after the writes.
type hoursPutBody struct {
	Entries  []hoursEntryBody `json:"entries"`
	Remove   []hoursKeyBody   `json:"remove"`
	Resubmit string           `json:"resubmit"`
}

// hoursBatch is a PUT /v1/me/hours being applied: the periods it touches,
// read once each.
type hoursBatch struct {
	s       *Server
	c       hoursMe
	loc     *time.Location
	now     time.Time
	periods map[string]*hoursPeriod // by any day asked
}

// period is the member's period holding day (YYYY-MM-DD), refused after the
// member's today.
func (b *hoursBatch) period(ctx context.Context, day string) (*hoursPeriod, string, error) {
	if p, ok := b.periods[day]; ok {
		return p, "", nil
	}
	d, err := time.Parse(hoursDayLayout, day)
	if err != nil {
		return nil, "day must be YYYY-MM-DD", nil
	}
	if d.After(civil(b.now, b.loc)) {
		return nil, "a day after today has no hours yet", nil
	}
	for _, p := range b.periods {
		if !d.Before(p.start) && !d.After(p.end) {
			b.periods[day] = p
			return p, "", nil
		}
	}
	p, err := b.s.loadHoursPeriod(ctx, b.c, b.loc, d, b.now)
	if err == nil {
		b.periods[day] = p
	}
	return p, "", err
}

// entries turns the body's rows into store entries. SuggestedMinutes is the
// hub's own number, never the caller's: the current suggestion, else what the
// entry already held (a returned period has no suggestions), else 0 (an
// added row).
func (b *hoursBatch) entries(ctx context.Context, in []hoursEntryBody) ([]store.HoursEntry, string, error) {
	out := make([]store.HoursEntry, 0, len(in))
	for _, e := range in {
		p, bad, err := b.period(ctx, e.Day)
		if bad != "" || err != nil {
			return nil, bad, err
		}
		se := store.HoursEntry{Day: e.Day, Target: e.Target, Minutes: e.Minutes, State: e.State, Note: e.Note}
		if s, ok := p.suggest[e.Day][e.Target]; ok {
			se.SuggestedMinutes = s.Minutes
		} else {
			for _, old := range p.entries {
				if old.Day == e.Day && old.Target == e.Target {
					se.SuggestedMinutes = old.SuggestedMinutes
				}
			}
		}
		out = append(out, se)
	}
	return out, "", nil
}

// PUT /v1/me/hours {entries?, remove?, resubmit?}: answers the period of the
// first day named, as GET reads it after the writes.
func (s *Server) handlePutMyHours(w http.ResponseWriter, r *http.Request) {
	c, ok := s.hoursCaller(w, r)
	if !ok {
		return
	}
	var body hoursPutBody
	if !decodeHoursBody(w, r, &body, "body must be {entries?: [{day, target, minutes, state, note?}], remove?: [{day, target}], resubmit?}") {
		return
	}
	if len(body.Entries) == 0 && len(body.Remove) == 0 && body.Resubmit == "" {
		writeErr(w, http.StatusBadRequest, "bad_hours", "nothing to write")
		return
	}
	ctx, now := r.Context(), s.o.Now()
	loc, err := s.hoursZone(ctx, c, now)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "zone", err)
		return
	}
	b := &hoursBatch{s: s, c: c, loc: loc, now: now, periods: map[string]*hoursPeriod{}}
	first, done := s.applyHoursBatch(w, r, b, body)
	if !done {
		return
	}
	p, err := s.loadHoursPeriod(ctx, c, loc, first, now)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "read back", err)
		return
	}
	writeJSON(w, http.StatusOK, p.json(c.set))
}

// hoursNamedDays is every day body names, entries first.
func hoursNamedDays(body hoursPutBody) []string {
	var named []string
	for _, e := range body.Entries {
		named = append(named, e.Day)
	}
	for _, k := range body.Remove {
		named = append(named, k.Day)
	}
	if body.Resubmit != "" {
		named = append(named, body.Resubmit)
	}
	return named
}

// applyHoursBatch writes body; false once it has answered with a refusal.
// It returns the first day named, the period the answer shows.
func (s *Server) applyHoursBatch(w http.ResponseWriter, r *http.Request, b *hoursBatch, body hoursPutBody) (time.Time, bool) {
	ctx, c := r.Context(), b.c
	named := hoursNamedDays(body)
	// Check every day first: a refusal writes nothing of the batch.
	for _, d := range named {
		if _, bad, err := b.period(ctx, d); bad != "" || err != nil {
			s.hoursRefuse(w, c.tenant.ID, bad, err)
			return time.Time{}, false
		}
	}
	var resubmit *hoursPeriod
	if body.Resubmit != "" {
		if resubmit = b.periods[body.Resubmit]; !resubmit.returned() {
			s.hoursFail(w, c.tenant.ID, "resubmit", store.ErrHoursPeriodState)
			return time.Time{}, false
		}
	}
	if len(body.Entries) > 0 {
		es, bad, err := b.entries(ctx, body.Entries)
		if bad == "" && err == nil {
			err = c.st.PutHoursEntries(ctx, c.tenant.ID, c.hum, es, c.hum, b.now)
		}
		if bad != "" || err != nil {
			s.hoursRefuse(w, c.tenant.ID, bad, err)
			return time.Time{}, false
		}
	}
	for _, k := range body.Remove {
		if err := c.st.DeleteHoursEntry(ctx, c.tenant.ID, c.hum, k.Day, k.Target, b.now); err != nil {
			s.hoursFail(w, c.tenant.ID, "remove", err)
			return time.Time{}, false
		}
	}
	if resubmit != nil && !s.resubmitHours(w, r, b, resubmit) {
		return time.Time{}, false
	}
	first, _ := time.Parse(hoursDayLayout, named[0])
	return first, true
}

func (s *Server) hoursRefuse(w http.ResponseWriter, tenant, bad string, err error) {
	if bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_day", bad)
		return
	}
	s.hoursFail(w, tenant, "write", err)
}

// resubmitHours moves a returned period back to frozen (spec 4.3) with the
// approved total of its entries as they read after the batch.
func (s *Server) resubmitHours(w http.ResponseWriter, r *http.Request, b *hoursBatch, p *hoursPeriod) bool {
	ctx, c := r.Context(), b.c
	start, end := p.start.Format(hoursDayLayout), p.end.Format(hoursDayLayout)
	es, err := c.st.HoursEntries(ctx, c.tenant.ID, c.hum, start, end)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "resubmit read", err)
		return false
	}
	total := 0
	for _, e := range es {
		if e.State == store.HoursApproved {
			total += e.Minutes
		}
	}
	_, err = c.st.SetHoursPeriodState(ctx, c.tenant.ID, c.hum, p.row.Start,
		store.HoursPeriodChange{State: store.HoursFrozen, Minutes: &total, By: c.hum, At: b.now})
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "resubmit", err)
		return false
	}
	return true
}

// ---- routes ------------------------------------------------------------------------

// hoursPreflight: the headers every browser route allows (no new request
// header: a new header is a new preflight, see 032).
func (s *Server) hoursPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeMyHours(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/me/hours", s.handleGetMyHours)
	mux.HandleFunc("PUT /v1/me/hours", s.handlePutMyHours)
	mux.HandleFunc("OPTIONS /v1/me/hours", s.hoursPreflight)
	mux.HandleFunc("PUT /v1/me/hours/minutes", s.handlePutMyHoursMinutes)
	mux.HandleFunc("OPTIONS /v1/me/hours/minutes", s.hoursPreflight)
}
