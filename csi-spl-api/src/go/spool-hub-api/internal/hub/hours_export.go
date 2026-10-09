package hub

import (
	"bytes"
	"context"
	"encoding/csv"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/xlsx"
)

// The hours download (spec 107 v1.0, T009; section 6.2):
//
//	GET /v1/hours/export?period=&format=csv|xlsx&final=&group=  hours.read
//
// One line per approved entry of the workspace period holding period (a
// day): rejected rows and open suggestions never appear (the read is
// store.HoursTeam's). final (default true) keeps only the members whose
// period the biz owner approved; final=false adds frozen, returned and open
// periods. group orders the lines: member (default), target or day.
//
// approved_by / approved_at are the biz owner's decision for a final period,
// else the worker's own approval of the entry.

// hoursExportColumns are the spec's columns, CSV and XLSX alike.
var hoursExportColumns = []string{"date", "member_id", "member_name", "target_type", "target_id", "target_name",
	"issue_key", "minutes", "hours_decimal", "suggested_minutes", "note", "period_state", "approved_by", "approved_at"}

// hoursExportLine is one approved entry as the download shows it.
type hoursExportLine struct {
	Date, Member, MemberName         string
	TargetType, TargetID, TargetName string
	IssueKey                         string
	Minutes, SuggestedMinutes        int
	Note, PeriodState, By, At        string
}

// hours is the minutes as decimal hours, two places.
func (l hoursExportLine) hours() float64 { return math.Round(float64(l.Minutes)*100/60) / 100 }

// hoursExportGroups orders lines: by member, target or day, then the rest.
var hoursExportGroups = map[string]func(a, b hoursExportLine) bool{
	"member": func(a, b hoursExportLine) bool {
		return lessKeys([]string{a.Member, a.Date, a.TargetType, a.TargetID}, []string{b.Member, b.Date, b.TargetType, b.TargetID})
	},
	"target": func(a, b hoursExportLine) bool {
		return lessKeys([]string{a.TargetType, a.TargetID, a.Member, a.Date}, []string{b.TargetType, b.TargetID, b.Member, b.Date})
	},
	"day": func(a, b hoursExportLine) bool {
		return lessKeys([]string{a.Date, a.Member, a.TargetType, a.TargetID}, []string{b.Date, b.Member, b.TargetType, b.TargetID})
	},
}

func lessKeys(a, b []string) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// hoursTargetParts splits a target into the download's type and id.
func hoursTargetParts(target string) (typ, id string) {
	kind, rest, _ := strings.Cut(target, ":")
	switch kind {
	case "t":
		return "topic", rest
	case "ch":
		return "channel", rest
	case "dm":
		return "dm", rest
	case "cal":
		return "meeting", rest
	}
	return "other", ""
}

// hoursNames resolves the names a line shows: members, issues by task, and
// meetings, read once per download.
type hoursNames struct {
	members  map[string]string
	issues   map[string]store.Issue // task_id -> issue
	meetings map[string]string      // event id -> title
}

func (s *Server) hoursExportNames(ctx context.Context, c hoursTeamCaller, d *hoursTeamData) hoursNames {
	n := hoursNames{members: d.names, issues: map[string]store.Issue{}, meetings: map[string]string{}}
	if is, ok := s.o.Store.(store.Issues); ok {
		all, err := is.ListIssues(ctx, c.tenant.ID)
		if err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", c.tenant.ID).Msg("hours export: issues")
		}
		for _, i := range all {
			if i.TaskID != "" {
				n.issues[i.TaskID] = i
			}
		}
	}
	cal := s.calendarStore()
	for _, e := range d.entries {
		id, ok := strings.CutPrefix(e.Target, "cal:")
		if _, seen := n.meetings[id]; !ok || seen || cal == nil {
			continue
		}
		// The meeting as its member sees it; a deleted or hidden one has no name.
		ev, err := cal.GetCalendarEvent(ctx, c.tenant.ID, e.Member, id)
		if err == nil {
			n.meetings[id] = ev.Title
		} else {
			n.meetings[id] = ""
		}
	}
	return n
}

// line is the download line of e.
func (n hoursNames) line(e store.HoursTeamEntry, row *store.HoursPeriod, state string) hoursExportLine {
	l := hoursExportLine{Date: e.Day, Member: e.Member, MemberName: n.members[e.Member], Minutes: e.Minutes,
		SuggestedMinutes: e.SuggestedMinutes, Note: e.Note, PeriodState: state,
		By: e.UpdatedBy, At: e.UpdatedAt.UTC().Format(time.RFC3339)}
	l.TargetType, l.TargetID = hoursTargetParts(e.Target)
	switch l.TargetType {
	case "topic":
		if i, ok := n.issues[l.TargetID]; ok {
			l.TargetType, l.TargetName, l.IssueKey = "issue", i.Title, i.Key()
		}
	case "channel":
		l.TargetName = l.TargetID
	case "dm":
		l.TargetName = n.members[l.TargetID]
	case "meeting":
		l.TargetName = n.meetings[l.TargetID]
	}
	if row != nil && row.State == store.HoursApproved {
		l.By, l.At = row.DecidedBy, row.DecidedAt.UTC().Format(time.RFC3339)
	}
	return l
}

// hoursExportLines is the download's lines of d, ordered by group.
func hoursExportLines(d *hoursTeamData, n hoursNames, set store.HoursSettings, now time.Time, final bool, group string) []hoursExportLine {
	out := []hoursExportLine{}
	for _, e := range d.entries {
		state := d.state(e.Member, set, now)
		if final && state != store.HoursApproved {
			continue
		}
		var row *store.HoursPeriod
		if p, ok := d.rows[e.Member]; ok {
			row = &p
		}
		out = append(out, n.line(e, row, state))
	}
	sort.SliceStable(out, func(i, j int) bool { return hoursExportGroups[group](out[i], out[j]) })
	return out
}

// csvSafe keeps a spreadsheet from reading a cell as a formula.
func csvSafe(s string) string {
	if s != "" && strings.ContainsRune("=+-@\t\r", rune(s[0])) {
		return "'" + s
	}
	return s
}

func (l hoursExportLine) texts() []string {
	return []string{l.Date, l.Member, csvSafe(l.MemberName), l.TargetType, csvSafe(l.TargetID), csvSafe(l.TargetName),
		l.IssueKey, strconv.Itoa(l.Minutes), strconv.FormatFloat(l.hours(), 'f', 2, 64),
		strconv.Itoa(l.SuggestedMinutes), csvSafe(l.Note), l.PeriodState, l.By, l.At}
}

// hoursCSV is the lines as CSV with the header.
func hoursCSV(lines []hoursExportLine) ([]byte, error) {
	var b bytes.Buffer
	w := csv.NewWriter(&b)
	if err := w.Write(hoursExportColumns); err != nil {
		return nil, err
	}
	for _, l := range lines {
		if err := w.Write(l.texts()); err != nil {
			return nil, err
		}
	}
	w.Flush()
	return b.Bytes(), w.Error()
}

// hoursXLSX is the lines as one sheet; minutes and hours are numbers.
func hoursXLSX(lines []hoursExportLine) ([]byte, error) {
	rows := make([][]xlsx.Cell, 0, len(lines)+1)
	head := make([]xlsx.Cell, len(hoursExportColumns))
	for i, c := range hoursExportColumns {
		head[i] = xlsx.Str(c)
	}
	rows = append(rows, head)
	for _, l := range lines {
		t := l.texts()
		row := make([]xlsx.Cell, len(t))
		for i, v := range t {
			row[i] = xlsx.Str(v)
		}
		row[7], row[8], row[9] = xlsx.Num(float64(l.Minutes)), xlsx.Num(l.hours()), xlsx.Num(float64(l.SuggestedMinutes))
		rows = append(rows, row)
	}
	var b bytes.Buffer
	err := xlsx.Write(&b, "Hours", rows)
	return b.Bytes(), err
}

// hoursExportOpts reads format, final and group; the string is a 400's detail.
func hoursExportOpts(r *http.Request) (format string, final bool, group, bad string) {
	q := r.URL.Query()
	format, group, final = strings.ToLower(q.Get("format")), q.Get("group"), true
	if format == "" {
		format = "csv"
	}
	if format != "csv" && format != "xlsx" {
		return "", false, "", "format must be csv or xlsx"
	}
	if group == "" {
		group = "member"
	}
	if hoursExportGroups[group] == nil {
		return "", false, "", "group must be member, target or day"
	}
	if f := q.Get("final"); f != "" {
		v, err := strconv.ParseBool(f)
		if err != nil {
			return "", false, "", "final must be true or false"
		}
		final = v
	}
	return format, final, group, ""
}

// GET /v1/hours/export?period=YYYY-MM-DD&format=csv|xlsx&final=&group=
func (s *Server) handleGetHoursExport(w http.ResponseWriter, r *http.Request) {
	c, ok := s.hoursTeamAuth(w, r, rbac.HoursRead)
	if !ok {
		return
	}
	now := s.o.Now()
	q, bad := parseHoursTeamQuery(r, c.set, now)
	format, final, group, badOpt := hoursExportOpts(r)
	if bad = bad + badOpt; bad != "" {
		writeErr(w, http.StatusBadRequest, "bad_export", bad)
		return
	}
	d, err := s.loadHoursTeam(r.Context(), c, q)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "export read", err)
		return
	}
	lines := hoursExportLines(d, s.hoursExportNames(r.Context(), c, d), c.set, now, final, group)
	write, ctype := hoursCSV, "text/csv; charset=utf-8"
	if format == "xlsx" {
		write, ctype = hoursXLSX, xlsx.ContentType
	}
	body, err := write(lines)
	if err != nil {
		s.hoursFail(w, c.tenant.ID, "export write", err)
		return
	}
	h := w.Header()
	h.Set("Content-Type", ctype)
	h.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="hours-%s-%s-%s.%s"`, c.tenant.ID,
		q.start.Format(hoursDayLayout), q.end.Format(hoursDayLayout), format))
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	w.Write(body) //nolint:errcheck
}
