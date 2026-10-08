package hub

import (
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The header timer (spec 107 section 13 Q7 = B, task T019): time worked
// outside the app, started and stopped in the WUI header.
//
//	POST /v1/me/hours/timer {target, start, end}
//
// The WUI keeps the running timer (start + target) on the device; on stop it
// posts the interval once and the hub turns it into entries. PUT /v1/me/hours
// does not fit: it sets a row's minutes, so the client would have to read
// the row, add, and split the interval at midnight in a zone only the hub
// resolves (spec 1.6). Here the hub does all three:
//
//   - the interval is split at the member's local midnight, one entry per day;
//   - each day's entry for target ADDS the day's piece to what the row holds:
//     an entry's minutes (a rejected one counts 0), else the open suggestion's
//     (stopping a timer on a target says "this is my time on it", so the
//     row is approved), else 0;
//   - the whole interval is written or nothing: a frozen day is 409
//     period_frozen, a day above 1440 minutes is 400 day_cap.
//
// Same caller and privacy line as hours_me.go: only the caller's rows.

const hoursTimerMax = 24 * time.Hour // a longer run is a forgotten timer

type hoursTimerBody struct {
	Target string `json:"target"`
	Start  string `json:"start"`
	End    string `json:"end"`
}

// hoursTimerPiece is the part of the interval on one local day.
type hoursTimerPiece struct {
	Day     string `json:"day"`
	Minutes int    `json:"minutes"`
}

// splitHoursTimer cuts [start, end) at local midnights in loc; a piece is
// rounded to the nearest minute and a piece of 0 minutes is dropped.
func splitHoursTimer(start, end time.Time, loc *time.Location) []hoursTimerPiece {
	var out []hoursTimerPiece
	for at := start; at.Before(end); {
		l := at.In(loc)
		next := time.Date(l.Year(), l.Month(), l.Day()+1, 0, 0, 0, 0, loc)
		if next.After(end) {
			next = end
		}
		if m := int(next.Sub(at).Round(time.Minute) / time.Minute); m > 0 {
			out = append(out, hoursTimerPiece{Day: l.Format(hoursDayLayout), Minutes: m})
		}
		at = next
	}
	return out
}

// parseHoursTimer checks the body at now; the string is the 400's detail.
func parseHoursTimer(b hoursTimerBody, now time.Time) (time.Time, time.Time, string) {
	start, err1 := time.Parse(time.RFC3339, b.Start)
	end, err2 := time.Parse(time.RFC3339, b.End)
	switch {
	case err1 != nil || err2 != nil:
		return start, end, "start and end must be RFC 3339 times"
	case b.Target == "":
		return start, end, "target is required"
	case !end.After(start):
		return start, end, "end must be after start"
	case end.After(now.Add(hoursMinuteSkew)):
		return start, end, "end must not be in the future"
	case end.Sub(start) > hoursTimerMax:
		return start, end, "a timer runs at most 24 hours; add longer time on the Hours page"
	case end.Sub(start) < 30*time.Second:
		return start, end, "the timer ran under a minute; nothing to write"
	}
	return start, end, ""
}

// timerEntries is the batch's entries: each day's row plus its piece. Every
// piece's period is already in b.periods.
func (b *hoursBatch) timerEntries(target string, pieces []hoursTimerPiece) []hoursEntryBody {
	out := make([]hoursEntryBody, 0, len(pieces))
	for _, pc := range pieces {
		p := b.periods[pc.Day]
		base, note, found := 0, "", false
		for _, e := range p.entries {
			if e.Day == pc.Day && e.Target == target {
				found, note = true, e.Note
				if e.State == store.HoursApproved {
					base = e.Minutes
				}
			}
		}
		if s, ok := p.suggest[pc.Day][target]; ok && !found {
			base = s.Minutes
		}
		out = append(out, hoursEntryBody{Day: pc.Day, Target: target, Minutes: base + pc.Minutes,
			State: store.HoursApproved, Note: note})
	}
	return out
}

// POST /v1/me/hours/timer: answers {written: [{day, minutes}], hours: the
// period of the stop day, as GET reads it after the write}.
func (s *Server) handlePostMyHoursTimer(w http.ResponseWriter, r *http.Request) {
	c, ok := s.hoursCaller(w, r)
	if !ok {
		return
	}
	var body hoursTimerBody
	if !decodeHoursBody(w, r, &body, "body must be {target, start, end}") {
		return
	}
	ctx, now := r.Context(), s.o.Now()
	start, end, bad := parseHoursTimer(body, now)
	if bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_timer", bad)
		return
	}
	loc, err := s.hoursZone(ctx, c, now)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "zone", err)
		return
	}
	pieces := splitHoursTimer(start, end, loc)
	b := &hoursBatch{s: s, c: c, loc: loc, now: now, periods: map[string]*hoursPeriod{}}
	for _, pc := range pieces {
		if _, bad, err := b.period(ctx, pc.Day); bad != "" || err != nil {
			s.hoursRefuse(w, c.tenant.ID, bad, err)
			return
		}
	}
	es, bad, err := b.entries(ctx, b.timerEntries(body.Target, pieces))
	if bad == "" && err == nil {
		err = c.st.PutHoursEntries(ctx, c.tenant.ID, c.hum, es, c.hum, now)
	}
	if bad != "" || err != nil {
		s.hoursRefuse(w, c.tenant.ID, bad, err)
		return
	}
	last, _ := time.Parse(hoursDayLayout, pieces[len(pieces)-1].Day)
	p, err := s.loadHoursPeriod(ctx, c, loc, last, now)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "read back", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"written": pieces, "hours": p.json(c.set)})
}

func (s *Server) hoursTimerPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeMyHoursTimer(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/me/hours/timer", s.handlePostMyHoursTimer)
	mux.HandleFunc("OPTIONS /v1/me/hours/timer", s.hoursTimerPreflight)
}
