package hub

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Outlook import (spec 180 FR-2, FR-3, FR-4, FR-11): one member's
// Outlook export (csi-spl-orc/src/powershell/outlook-calendar-export.ps1)
// into their calendar in one workspace (do_spl_calendar_import_outlook).
//
//	PUT /v1/operator/calendar/import/outlook?tenant=<slug>&owner=<HUM-n>  body: one export
//
//   - Switch: hub env SPOOL_HUB_CALENDAR_OUTLOOK_IMPORT_ENABLED (cnf, off by
//     default); off, the route answers 404 not_found and writes nothing.
//   - Who: the operator (operatorAuth), as the other /v1/operator routes.
//     The owner is a HUM-* member of the workspace, else 403 not_a_member.
//   - The whole batch is checked before any write (FR-3): the format, from
//     <= to, at most 2000 events, RFC 3339 times with ends_at > starts_at
//     (all-day: day <= end_day as YYYY-MM-DD), a source_id. One bad event is
//     400 bad_event naming its index and why; nothing is written. A title is
//     cut to 200 characters; the answer and the log never carry one.
//   - Each event is written by key outlook:<owner>:<24 hex of SHA-256 of
//     source_id> (store.ImportCalendarBySourceKey): kind other, private,
//     owner and mention the member, creator system outlook-import. A row of
//     that owner that starts in [from, to) and is not in the batch is
//     soft-deleted (a moved or cancelled meeting); one outside is untouched.
//   - The answer: {created, updated, unchanged, deleted}.

const (
	outlookExportFormat  = "spool-hub-outlook-export/1"
	outlookImporter      = "outlook-import"
	outlookImportMaxBody = 4 << 20
	outlookTitleMax      = 200
)

// outlookExport is FR-1's file.
type outlookExport struct {
	Format     string         `json:"format"`
	ExportedAt string         `json:"exported_at"`
	TimeZone   string         `json:"time_zone"`
	From       string         `json:"from"`
	To         string         `json:"to"`
	Count      int            `json:"count"`
	Events     []outlookEvent `json:"events"`
}

// outlookEvent is one exported occurrence.
type outlookEvent struct {
	SourceID   string `json:"source_id"`
	Title      string `json:"title"`
	StartsAt   string `json:"starts_at"`
	EndsAt     string `json:"ends_at"`
	AllDay     bool   `json:"all_day"`
	Day        string `json:"day"`
	EndDay     string `json:"end_day"`
	Location   string `json:"location"`
	BusyStatus string `json:"busy_status"`
	Private    bool   `json:"private"`
	Recurring  bool   `json:"recurring"`
}

// outlookSourceKey is FR-4's key of one occurrence.
func outlookSourceKey(owner, sourceID string) string {
	sum := sha256.Sum256([]byte(sourceID))
	return "outlook:" + owner + ":" + hex.EncodeToString(sum[:])[:24]
}

// outlookWindow checks the export's header and answers its window.
func (x outlookExport) window(owner string) (store.CalendarImportWindow, *issueErr) {
	win := store.CalendarImportWindow{Prefix: "outlook:" + owner + ":", By: outlookImporter}
	var err1, err2 error
	win.From, err1 = time.Parse(time.RFC3339, x.From)
	win.To, err2 = time.Parse(time.RFC3339, x.To)
	switch {
	case x.Format != outlookExportFormat:
		return win, badCalendar("format must be " + outlookExportFormat)
	case err1 != nil || err2 != nil || win.To.Before(win.From):
		return win, badCalendar("from and to must be RFC 3339 times, from <= to")
	case len(x.Events) > store.CalendarSyncMaxEvents:
		return win, badCalendar(fmt.Sprintf("an import holds at most %d events", store.CalendarSyncMaxEvents))
	}
	win.From, win.To = win.From.UTC(), win.To.UTC()
	return win, nil
}

// outlookTimes answers an event's start and end (FR-3). An all-day event
// covers day .. end_day (inclusive) as whole UTC days, the member create's
// shape.
func (v outlookEvent) times() (time.Time, time.Time, string) {
	if v.AllDay {
		d, err1 := time.Parse(time.DateOnly, v.Day)
		e, err2 := time.Parse(time.DateOnly, v.EndDay)
		if err1 != nil || err2 != nil || e.Before(d) {
			return d, e, "an all-day event has day <= end_day, each YYYY-MM-DD"
		}
		return d, e.AddDate(0, 0, 1), ""
	}
	s, err1 := time.Parse(time.RFC3339, v.StartsAt)
	e, err2 := time.Parse(time.RFC3339, v.EndsAt)
	switch {
	case err1 != nil:
		return s, e, "starts_at is not an RFC 3339 time"
	case err2 != nil:
		return s, e, "ends_at is not an RFC 3339 time"
	case !e.After(s):
		return s, e, "ends_at must be after starts_at"
	}
	return s, e, ""
}

// outlookTitle cuts a title to outlookTitleMax characters; none is "Busy".
func outlookTitle(t string) string {
	t = strings.TrimSpace(t)
	if t == "" {
		return "Busy"
	}
	if utf8.RuneCountInString(t) > outlookTitleMax {
		t = string([]rune(t)[:outlookTitleMax])
	}
	return t
}

// outlookBatch turns the export's events into the store batch (FR-3, FR-4).
func (x outlookExport) batch(owner, tz string) ([]store.CalendarSyncEvent, *issueErr) {
	out := make([]store.CalendarSyncEvent, 0, len(x.Events))
	for i, v := range x.Events {
		if strings.TrimSpace(v.SourceID) == "" {
			return nil, badCalendar(fmt.Sprintf("event %d: source_id is empty", i))
		}
		start, end, why := v.times()
		if why != "" {
			return nil, badCalendar(fmt.Sprintf("event %d: %s", i, why))
		}
		desc := "Imported from Outlook"
		if b := strings.TrimSpace(v.BusyStatus); b != "" {
			desc += "\nShow as: " + b
		}
		props := map[string]any{}
		if loc := strings.TrimSpace(v.Location); loc != "" {
			props[calPropLocation] = string([]rune(loc)[:min(utf8.RuneCountInString(loc), calendarLocationMax)])
		}
		out = append(out, store.CalendarSyncEvent{SourceKey: outlookSourceKey(owner, v.SourceID), Event: store.CalendarEvent{
			Title: outlookTitle(v.Title), Description: desc, Kind: "other", StartsAt: start.UTC(), EndsAt: end.UTC(),
			AllDay: v.AllDay, Audience: store.CalendarPrivate, Mentions: []string{owner}, OwnerID: owner,
			CreatorType: "system", CreatorID: outlookImporter, Props: props, TimeZone: tz}})
	}
	return out, nil
}

// outlookZone answers the export's IANA zone, or "" (UTC) for none or a
// Windows name.
func outlookZone(tz string) string {
	tz = strings.TrimSpace(tz)
	if tz == "" || strings.Contains(tz, " ") {
		return ""
	}
	if _, err := time.LoadLocation(tz); err != nil {
		return ""
	}
	return tz
}

// outlookOwnerMember: owner is a HUM-* member of tenant; it writes the refusal.
func (s *Server) outlookOwnerMember(w http.ResponseWriter, r *http.Request, tenant, owner string) bool {
	if !humanIDRe.MatchString(owner) {
		writeErr(w, http.StatusBadRequest, "bad_owner", "owner must be a HUM-* id")
		return false
	}
	md, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		writeErr(w, http.StatusForbidden, "not_a_member", "owner is not a member of this workspace")
		return false
	}
	ms, err := md.ListMembers(r.Context(), tenant)
	if err != nil {
		s.writeCalendarErr(w, tenant, "outlook import owner", err)
		return false
	}
	for _, m := range ms {
		if m.HumanID == owner {
			return true
		}
	}
	writeErr(w, http.StatusForbidden, "not_a_member", "owner is not a member of this workspace")
	return false
}

// handleOperatorCalendarImportOutlook is PUT /v1/operator/calendar/import/outlook.
func (s *Server) handleOperatorCalendarImportOutlook(w http.ResponseWriter, r *http.Request) {
	if !s.o.CalendarOutlookImportEnabled {
		writeErr(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	qs := r.URL.Query()
	owner := strings.TrimSpace(qs.Get("owner"))
	t, c, ok := s.operatorCalendarTarget(w, r, qs.Get("tenant"))
	if !ok || !s.outlookOwnerMember(w, r, t.ID, owner) {
		return
	}
	imp, ok := c.(store.CalendarImport)
	switch {
	case !ok:
		writeIssueErr(w, calendarUnavailable())
		return
	case !billing.AllowsWrite(t.BillingStatus):
		writeUnpaid(w)
		return
	}
	var x outlookExport
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, outlookImportMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&x); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be one "+outlookExportFormat+" file")
		return
	}
	win, ie := x.window(owner)
	var batch []store.CalendarSyncEvent
	if ie == nil {
		batch, ie = x.batch(owner, outlookZone(x.TimeZone))
	}
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	res, err := imp.ImportCalendarBySourceKey(r.Context(), t.ID, win, batch, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, t.ID, "outlook import", err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("owner", owner).Str("operator", op).Int("events", len(batch)).
		Int("created", res.Created).Int("updated", res.Updated).Int("unchanged", res.Unchanged).
		Int("deleted", res.Deleted).Msg("operator.calendar_outlook_imported")
	writeJSON(w, http.StatusOK, map[string]any{"created": res.Created, "updated": res.Updated,
		"unchanged": res.Unchanged, "deleted": res.Deleted})
}
