package hub

import (
	"context"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Hours of use per person and workspace (SPL-5709, rdb 0289, spec 143
// usage-hours.md; owner HUM-10, t1 2798773d, msgs 1f0b86e4 and 944839c2).
//
//   POST /v1/me/use-minute   the WUI's heartbeat, once a minute while a
//                            workspace tab is visible and the person active.
//                            The person and the workspace come from the
//                            session, the minute from the hub clock; the
//                            body is ignored. Counted once per minute.
//   GET  /v1/reporting/use   per member of the session's workspace: minutes
//                            here and across the hub, in a day range. The
//                            workspace's biz_owner and admins read every
//                            member; anyone else only ?human_id=<self>.
//   GET  /v1/operator/use    the hub total, for the operator workspace's
//                            admins.

// useReaders are the workspace roles that read every member's hours.
var useReaders = []string{rbac.BizOwner, rbac.Admin}

// permUseRead names the refusal of a member reading others' hours.
const permUseRead = "reporting.use"

// UseRetentionDays is how long the daily rows are kept (spec: 400 days, a
// year back plus a month to compare with).
const UseRetentionDays = 400

// useMaxDays bounds one report's range.
const useMaxDays = 400

func (s *Server) routeUseMinutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/me/use-minute", s.handleUseMinute)
	mux.HandleFunc("OPTIONS /v1/me/use-minute", s.hoursTimerPreflight)
	mux.HandleFunc("GET /v1/reporting/use", s.handleUseReport)
	mux.HandleFunc("OPTIONS /v1/reporting/use", s.preflight)
	mux.HandleFunc("GET /v1/operator/use", s.handleUseTotal)
	mux.HandleFunc("OPTIONS /v1/operator/use", s.preflight)
}

// useStore is the store half, or answered 501.
func (s *Server) useStore(w http.ResponseWriter) (store.UseMinutes, bool) {
	us, ok := s.o.Store.(store.UseMinutes)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no hours of use")
	}
	return us, ok
}

// handleUseMinute counts the current minute for the session's person in
// the session's workspace. An act-as clone is not the person: not counted.
func (s *Server) handleUseMinute(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeErr(w, http.StatusUnauthorized, "view_door", "a member session is required")
		return
	}
	// self.keys, the hours writes' gate: a demo_user or a channel guest is
	// not counted (403).
	if !s.permit(w, r, t.ID, hum, rbac.SelfKeys) {
		return
	}
	us, ok := s.useStore(w)
	if !ok {
		return
	}
	now := s.o.Now().UTC()
	if s.readerIsActAsClone(r.Context(), t.ID, hum) {
		writeJSON(w, http.StatusOK, map[string]any{"counted": false, "minute": now.Truncate(time.Minute).Format(time.RFC3339)})
		return
	}
	c, err := us.RecordUseMinute(r.Context(), t.ID, hum, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("use minute")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the minute was not counted")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"counted": c.Workspace, "minute": now.Truncate(time.Minute).Format(time.RFC3339)})
}

// useRange reads ?from=&to= (YYYY-MM-DD, UTC, inclusive); default the 30
// days to today. why != "" = a 400.
func useRange(r *http.Request, now time.Time) (from, to, why string) {
	q := r.URL.Query()
	toT := now.UTC().Truncate(24 * time.Hour)
	if v := q.Get("to"); v != "" {
		t, err := time.Parse(store.UseDayLayout, v)
		if err != nil {
			return "", "", "to must be YYYY-MM-DD"
		}
		toT = t
	}
	fromT := toT.AddDate(0, 0, -29)
	if v := q.Get("from"); v != "" {
		t, err := time.Parse(store.UseDayLayout, v)
		if err != nil {
			return "", "", "from must be YYYY-MM-DD"
		}
		fromT = t
	}
	switch {
	case fromT.After(toT):
		return "", "", "from is after to"
	case toT.Sub(fromT) >= useMaxDays*24*time.Hour:
		return "", "", "the range is at most 400 days"
	}
	return fromT.Format(store.UseDayLayout), toT.Format(store.UseDayLayout), ""
}

// useMemberOut is one row of GET /v1/reporting/use.
type useMemberOut struct {
	HumanID     string `json:"human_id"`
	Name        string `json:"name"`
	MinutesHere int64  `json:"minutes_here"`
	MinutesHub  int64  `json:"minutes_hub"`
}

// useReportCaller is the read gate: (tenant, only) where only is the one
// human the caller may read, "" = every member.
func (s *Server) useReportCaller(w http.ResponseWriter, r *http.Request) (store.Tenant, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return t, "", false
	}
	if hum == "" {
		writeErr(w, http.StatusUnauthorized, "view_door", "a member session is required")
		return t, "", false
	}
	want := r.URL.Query().Get("human_id")
	if want == hum {
		return t, hum, true
	}
	a, err := s.access(r.Context(), hum, t.ID)
	if err != nil || !a.HasAny(useReaders...) || s.readerIsActAsClone(r.Context(), t.ID, hum) {
		writeForbidden(w, permUseRead, "only the workspace's owner or an admin reads other members' hours")
		return t, "", false
	}
	return t, want, true
}

// handleUseReport: GET /v1/reporting/use.
func (s *Server) handleUseReport(w http.ResponseWriter, r *http.Request) {
	t, only, ok := s.useReportCaller(w, r)
	if !ok {
		return
	}
	from, to, why := useRange(r, s.o.Now())
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_range", why)
		return
	}
	us, ok := s.useStore(w)
	if !ok {
		return
	}
	rows, err := s.useMembers(r.Context(), us, t.ID, only, from, to)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("use report")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "hours of use unavailable")
		return
	}
	var here int64
	for _, m := range rows {
		here += m.MinutesHere
	}
	writeJSON(w, http.StatusOK, map[string]any{"from": from, "to": to, "minutes_here": here, "members": rows})
}

// useMembers is a row per current member (only = that one), joined with
// the minutes here and across the hub.
func (s *Server) useMembers(ctx context.Context, us store.UseMinutes, tenant, only, from, to string) ([]useMemberOut, error) {
	md, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		return []useMemberOut{}, nil
	}
	ms, err := md.ListMembers(ctx, tenant)
	if err != nil {
		return nil, err
	}
	out, hums := []useMemberOut{}, []string{}
	for _, m := range ms {
		if only == "" || m.HumanID == only {
			out = append(out, useMemberOut{HumanID: m.HumanID, Name: m.DisplayName})
			hums = append(hums, m.HumanID)
		}
	}
	here, err := us.WorkspaceUseMinutes(ctx, tenant, from, to)
	if err != nil {
		return nil, err
	}
	hub, err := us.HubUseMinutesOf(ctx, hums, from, to)
	if err != nil {
		return nil, err
	}
	for i := range out {
		out[i].MinutesHere, out[i].MinutesHub = here[out[i].HumanID], hub[out[i].HumanID]
	}
	return out, nil
}

// handleUseTotal: GET /v1/operator/use, the operator workspace's admins.
func (s *Server) handleUseTotal(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := s.estateReadCaller(w, r, []string{rbac.Admin}, "only an admin of the operator workspace reads the hub's hours of use"); !ok {
		return
	}
	from, to, why := useRange(r, s.o.Now())
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_range", why)
		return
	}
	us, ok := s.useStore(w)
	if !ok {
		return
	}
	tot, err := us.HubUseTotal(r.Context(), from, to)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("use total")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "hours of use unavailable")
		return
	}
	days := make([]map[string]any, 0, len(tot.Days))
	for _, d := range tot.Days {
		days = append(days, map[string]any{"day": d.Day, "minutes": d.Minutes, "people": d.People})
	}
	ws := make([]map[string]any, 0, len(tot.Workspaces))
	for _, x := range tot.Workspaces {
		ws = append(ws, map[string]any{"id": x.TenantID, "minutes": x.Minutes, "people": x.People})
	}
	writeJSON(w, http.StatusOK, map[string]any{"from": from, "to": to, "minutes": tot.Minutes, "people": tot.People,
		"days": days, "workspaces": ws})
}

// sweepUseMinutes prunes the rows past the retention, on the sweep tick.
func (s *Server) sweepUseMinutes(ctx context.Context) {
	us, ok := s.o.Store.(store.UseMinutes)
	if !ok {
		return
	}
	before := s.o.Now().UTC().AddDate(0, 0, -UseRetentionDays).Format(store.UseDayLayout)
	n, err := us.SweepUseMinutes(ctx, before)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("use minutes retention sweep")
		return
	}
	if n > 0 {
		s.o.Log.Info().Int("pruned", n).Msg("use minutes retention sweep")
	}
}
