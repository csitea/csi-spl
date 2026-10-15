package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The personal realm routes (spec 119 v1.1 section 9 C2, tasks.md T003): a
// person's own layer ABOVE the workspaces.
//
//	GET    /v1/me/realm/settings                the hours limits (118 C3)
//	PUT    /v1/me/realm/settings                a new limits row from valid_from
//	GET    /v1/me/realm/profile                 time zone, locale, comm prefs
//	PUT    /v1/me/realm/profile                 the whole profile
//	GET    /v1/me/realm/receipts                the receipts, newest rev (8.2)
//	DELETE /v1/me/realm/receipts/{workspace_id} the person's own erasure (8.3)
//
// Who: a human session only. The person is the session's HUM-*, never a path,
// query, header or body value: a body field the route does not know is 400,
// a member= parameter or an X-Spool-Tenant header is 400, and no route takes
// a person id, so another person (a foreman, an admin, a workspace owner)
// has no way to name P's realm. 403 person_only under act-as (spec 054), for
// an agent, a box token and a seat that is only an agent or a
// time-accountant. The realm has no workspace: nothing here reads or sets a
// tenant scope, and the store runs every statement in inPerson.
//
// Privacy (C3, 118 T-K2): the hours limit warning is the WUI's, computed on
// read from actual hours and the limit; this file never stores, sends or logs
// it, and no log line here carries a realm value (limit, zone, locale,
// receipt row): an error is logged with the op and the error alone.

const (
	realmBodyMax  = 8 << 10 // the profile's comm_prefs is capped at 4 KiB
	realmPersonly = "person_only"
)

// realmPersonRe is rdb 0168's person_id CHECK: an agent id never matches.
var realmPersonRe = regexp.MustCompile(`^HUM-[0-9]+$`)

// realmNotPerson is the roles whose seat is not a person (realmTimeAccountant,
// spec 107 FR-20, is realm_hours_read.go's: not in rbac yet): a human whose
// seats are all of these has no realm.
var realmNotPerson = map[string]bool{rbac.PureAgent: true, realmTimeAccountant: true}

// realmMe is the caller of a realm route.
type realmMe struct {
	person string
	st     store.Realm
}

// realmCaller resolves the person of a realm request, or answers.
func (s *Server) realmCaller(w http.ResponseWriter, r *http.Request) (realmMe, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if r.Header.Get(TenantHeader) != "" {
		writeErr(w, http.StatusBadRequest, "tenant_named", "the realm has no workspace: send no "+TenantHeader)
		return realmMe{}, false
	}
	if r.URL.Query().Has("member") {
		writeErr(w, http.StatusBadRequest, "member_named", "the realm is the session's own: send no member")
		return realmMe{}, false
	}
	if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		writeErr(w, http.StatusForbidden, realmPersonly, "the realm is a person's: a box token has none")
		return realmMe{}, false
	}
	var sess auth.Session
	ok := false
	if s.o.Auth != nil {
		sess, ok = s.o.Auth.SessionFromRequest(r)
	}
	if !ok {
		writeErr(w, http.StatusUnauthorized, "door", "a signed-in person is required")
		return realmMe{}, false
	}
	refuse, err := s.realmRefuses(r.Context(), sess)
	if err != nil {
		s.o.Log.Error().Err(err).Str("op", "realm_caller").Msg("realm")
		writeErr(w, http.StatusServiceUnavailable, "realm_unavailable", "the personal realm is unavailable")
		return realmMe{}, false
	}
	if refuse {
		writeErr(w, http.StatusForbidden, realmPersonly, "the personal realm is for the signed-in person only")
		return realmMe{}, false
	}
	rs, ok := s.o.Store.(store.Realm)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "realm_unavailable", "the personal realm is not kept by this hub")
		return realmMe{}, false
	}
	return realmMe{person: sess.HumanID, st: rs}, true
}

// realmRefuses reports a session that is not a person: an act-as clone (the
// session's provider, or a live clone row however the session was formed),
// no HUM-* (an agent), or seats that are all agent or time-accountant. A
// person with no seat at all (every workspace left) keeps their realm.
func (s *Server) realmRefuses(ctx context.Context, sess auth.Session) (bool, error) {
	if sess.Provider == auth.ProviderActAs || !realmPersonRe.MatchString(sess.HumanID) {
		return true, nil
	}
	if sess.Tenant != "" && s.readerIsActAsClone(ctx, sess.Tenant, sess.HumanID) {
		return true, nil
	}
	ml, ok := s.o.Store.(store.MembershipLister)
	if !ok {
		return false, errors.New("realm: the store lists no memberships")
	}
	seats, err := ml.Memberships(ctx, sess.HumanID)
	if err != nil {
		return false, err
	}
	return realmSeatsNotPerson(seats), nil
}

// realmSeatsNotPerson: at least one seat, and every seat an agent's or a
// time-accountant's.
func realmSeatsNotPerson(seats []store.Membership) bool {
	for _, m := range seats {
		if !realmNotPerson[m.Role] {
			return false
		}
	}
	return len(seats) > 0
}

// realmFail answers a store error; the log line carries the op and the error
// only, never a realm value.
func (s *Server) realmFail(w http.ResponseWriter, op string, err error) {
	switch {
	case errors.Is(err, store.ErrNoPerson):
		writeErr(w, http.StatusForbidden, realmPersonly, "the personal realm is for the signed-in person only")
	case errors.Is(err, store.ErrRealmBad):
		writeErr(w, http.StatusBadRequest, "bad_realm", strings.TrimPrefix(err.Error(), "store: "))
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such person")
	default:
		s.o.Log.Error().Err(err).Str("op", op).Msg("realm")
		writeErrCause(w, http.StatusInternalServerError, "internal", "the personal realm is unavailable", err)
	}
}

// readRealmJSON: a capped body, no unknown field (a person_id in a body is
// 400, never read).
func readRealmJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	return readJSONStrict(w, r, v, realmBodyMax, "invalid JSON body for this realm route")
}

// realmToday is today in the person's own zone (the profile's), UTC when none.
func (s *Server) realmToday(ctx context.Context, c realmMe) (string, error) {
	p, err := c.st.RealmProfileOf(ctx, c.person)
	if err != nil {
		return "", err
	}
	loc := time.UTC
	if l, ok := hoursLoadZone(p.TimeZone); ok {
		loc = l
	}
	return s.o.Now().In(loc).Format(time.DateOnly), nil
}

// ---- settings ----------------------------------------------------------------

type realmLimitsRow struct {
	ValidFrom        string `json:"valid_from"`
	DayLimitMinutes  *int   `json:"day_limit_minutes"`
	WeekLimitMinutes *int   `json:"week_limit_minutes"`
	UpdatedAt        string `json:"updated_at,omitempty"`
}

func realmLimitsOut(l store.RealmLimits) realmLimitsRow {
	out := realmLimitsRow{ValidFrom: l.ValidFrom, DayLimitMinutes: l.DayLimitMinutes, WeekLimitMinutes: l.WeekLimitMinutes}
	if !l.UpdatedAt.IsZero() {
		out.UpdatedAt = l.UpdatedAt.UTC().Format(time.RFC3339)
	}
	return out
}

// realmSettingsOut is the settings answer: the limits in force today (null =
// none) and every row, oldest first. No warning: that is the WUI's (C3).
func (s *Server) realmSettingsOut(ctx context.Context, c realmMe) (map[string]any, error) {
	today, err := s.realmToday(ctx, c)
	if err != nil {
		return nil, err
	}
	hist, err := c.st.RealmLimitsHistory(ctx, c.person)
	if err != nil {
		return nil, err
	}
	rows := make([]realmLimitsRow, 0, len(hist))
	inForce := -1
	for i, l := range hist {
		rows = append(rows, realmLimitsOut(l))
		if l.ValidFrom <= today {
			inForce = i
		}
	}
	var now *realmLimitsRow
	if inForce >= 0 {
		now = &rows[inForce]
	}
	return map[string]any{"today": today, "limits": now, "history": rows}, nil
}

// GET /v1/me/realm/settings
func (s *Server) handleGetRealmSettings(w http.ResponseWriter, r *http.Request) {
	c, ok := s.realmCaller(w, r)
	if !ok {
		return
	}
	out, err := s.realmSettingsOut(r.Context(), c)
	if err != nil {
		s.realmFail(w, "settings_get", err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// PUT /v1/me/realm/settings {day_limit_minutes, week_limit_minutes, valid_from?}:
// the limits in force from valid_from (today in the person's zone when
// omitted). A past day is 400: a past week keeps the limit it had (118 C3).
func (s *Server) handlePutRealmSettings(w http.ResponseWriter, r *http.Request) {
	c, ok := s.realmCaller(w, r)
	if !ok {
		return
	}
	var body realmLimitsRow
	if !readRealmJSON(w, r, &body) {
		return
	}
	ctx := r.Context()
	today, err := s.realmToday(ctx, c)
	if err != nil {
		s.realmFail(w, "settings_put", err)
		return
	}
	if body.ValidFrom == "" {
		body.ValidFrom = today
	}
	if body.ValidFrom < today {
		writeErr(w, http.StatusBadRequest, "bad_realm", "valid_from must be today or later")
		return
	}
	l := store.RealmLimits{ValidFrom: body.ValidFrom, DayLimitMinutes: body.DayLimitMinutes, WeekLimitMinutes: body.WeekLimitMinutes}
	if err := c.st.AppendRealmLimits(ctx, c.person, l, s.o.Now()); err != nil {
		s.realmFail(w, "settings_put", err)
		return
	}
	out, err := s.realmSettingsOut(ctx, c)
	if err != nil {
		s.realmFail(w, "settings_get", err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// ---- profile -----------------------------------------------------------------

type realmProfileJSON struct {
	TimeZone  string          `json:"time_zone"`
	Locale    string          `json:"locale"`
	CommPrefs json.RawMessage `json:"comm_prefs"`
	UpdatedAt string          `json:"updated_at,omitempty"`
}

func realmProfileOut(p store.RealmProfile) realmProfileJSON {
	out := realmProfileJSON{TimeZone: p.TimeZone, Locale: p.Locale, CommPrefs: p.CommPrefs}
	if len(out.CommPrefs) == 0 {
		out.CommPrefs = json.RawMessage(`{}`)
	}
	if !p.UpdatedAt.IsZero() {
		out.UpdatedAt = p.UpdatedAt.UTC().Format(time.RFC3339)
	}
	return out
}

// GET /v1/me/realm/profile: "" = none. The name shown is humans.display_name
// (OQ-10 A): the realm keeps no second one.
func (s *Server) handleGetRealmProfile(w http.ResponseWriter, r *http.Request) {
	c, ok := s.realmCaller(w, r)
	if !ok {
		return
	}
	p, err := c.st.RealmProfileOf(r.Context(), c.person)
	if err != nil {
		s.realmFail(w, "profile_get", err)
		return
	}
	writeJSON(w, http.StatusOK, realmProfileOut(p))
}

// PUT /v1/me/realm/profile {time_zone, locale, comm_prefs}: the whole profile.
func (s *Server) handlePutRealmProfile(w http.ResponseWriter, r *http.Request) {
	c, ok := s.realmCaller(w, r)
	if !ok {
		return
	}
	var body realmProfileJSON
	if !readRealmJSON(w, r, &body) {
		return
	}
	if _, ok := hoursLoadZone(body.TimeZone); body.TimeZone != "" && !ok {
		writeErr(w, http.StatusBadRequest, "bad_realm", "time_zone must be a known IANA zone name")
		return
	}
	ctx := r.Context()
	p := store.RealmProfile{TimeZone: body.TimeZone, Locale: body.Locale, CommPrefs: body.CommPrefs}
	if err := c.st.PutRealmProfile(ctx, c.person, p, s.o.Now()); err != nil {
		s.realmFail(w, "profile_put", err)
		return
	}
	got, err := c.st.RealmProfileOf(ctx, c.person)
	if err != nil {
		s.realmFail(w, "profile_get", err)
		return
	}
	writeJSON(w, http.StatusOK, realmProfileOut(got))
}

// ---- receipts ----------------------------------------------------------------

type realmReceiptJSON struct {
	WorkspaceID   string  `json:"workspace_id"`
	WorkspaceName string  `json:"workspace_name"`
	Day           string  `json:"day"`
	Minutes       int     `json:"minutes"`
	Label         string  `json:"label"`
	Kind          string  `json:"kind"`
	PeriodStart   string  `json:"period_start"`
	PeriodEnd     string  `json:"period_end"`
	ApprovalState string  `json:"approval_state"`
	ApproverName  string  `json:"approver_name,omitempty"`
	DecidedAt     *string `json:"decided_at,omitempty"`
	Rev           int     `json:"rev"`
	CopiedAt      string  `json:"copied_at"`
}

func realmReceiptOut(rc store.RealmReceipt) realmReceiptJSON {
	out := realmReceiptJSON{WorkspaceID: rc.WorkspaceID, WorkspaceName: rc.WorkspaceName, Day: rc.Day,
		Minutes: rc.Minutes, Label: rc.Label, Kind: rc.Kind, PeriodStart: rc.PeriodStart, PeriodEnd: rc.PeriodEnd,
		ApprovalState: rc.ApprovalState, ApproverName: rc.ApproverName, Rev: rc.Rev,
		CopiedAt: rc.CopiedAt.UTC().Format(time.RFC3339)}
	if rc.DecidedAt != nil {
		d := rc.DecidedAt.UTC().Format(time.RFC3339)
		out.DecidedAt = &d
	}
	return out
}

// GET /v1/me/realm/receipts: read-only, the newest rev per (workspace, day,
// label, kind), by workspace, day, label, kind.
func (s *Server) handleGetRealmReceipts(w http.ResponseWriter, r *http.Request) {
	c, ok := s.realmCaller(w, r)
	if !ok {
		return
	}
	rcs, err := c.st.RealmReceipts(r.Context(), c.person)
	if err != nil {
		s.realmFail(w, "receipts_get", err)
		return
	}
	out := make([]realmReceiptJSON, 0, len(rcs))
	for _, rc := range rcs {
		out = append(out, realmReceiptOut(rc))
	}
	writeJSON(w, http.StatusOK, map[string]any{"receipts": out})
}

// DELETE /v1/me/realm/receipts/{workspace_id}: erases every rev of the
// person's own receipts of that workspace (OQ-4 A: delete, never edit) and
// closes its receipt_due row; {deleted: n}, 0 when there were none.
func (s *Server) handleDeleteRealmReceipts(w http.ResponseWriter, r *http.Request) {
	c, ok := s.realmCaller(w, r)
	if !ok {
		return
	}
	n, err := c.st.DeleteRealmReceipts(r.Context(), c.person, r.PathValue("workspace_id"))
	if err != nil {
		s.realmFail(w, "receipts_delete", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": n})
}

// ---- routes ------------------------------------------------------------------

// realmPreflight: methods with the headers every browser route allows (no new
// request header: a new header is a new preflight, see 032).
func (s *Server) realmPreflight(methods string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.allowOrigin(w, r) {
			h := w.Header()
			h.Set("Access-Control-Allow-Methods", methods)
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
			h.Set("Access-Control-Max-Age", corsMaxAge)
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// routeRealm registers 119's realm routes (C2). 118's /v1/me/realm/hours and
// /v1/me/realm/targets are registered by their own files.
func (s *Server) routeRealm(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/me/realm/settings", s.handleGetRealmSettings)
	mux.HandleFunc("PUT /v1/me/realm/settings", s.handlePutRealmSettings)
	mux.HandleFunc("OPTIONS /v1/me/realm/settings", s.realmPreflight("GET, PUT"))
	mux.HandleFunc("GET /v1/me/realm/profile", s.handleGetRealmProfile)
	mux.HandleFunc("PUT /v1/me/realm/profile", s.handlePutRealmProfile)
	mux.HandleFunc("OPTIONS /v1/me/realm/profile", s.realmPreflight("GET, PUT"))
	mux.HandleFunc("GET /v1/me/realm/receipts", s.handleGetRealmReceipts)
	mux.HandleFunc("DELETE /v1/me/realm/receipts/{workspace_id}", s.handleDeleteRealmReceipts)
	mux.HandleFunc("OPTIONS /v1/me/realm/receipts/{workspace_id}", s.realmPreflight("DELETE"))
}
