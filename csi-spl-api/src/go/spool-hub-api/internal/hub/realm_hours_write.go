package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The person's writes into several workspaces from one screen (spec 118
// section 7, task T004):
//
//	GET /v1/me/realm/targets?workspace=<W>&q=  W's targets, as W shows them to the caller
//	PUT /v1/me/realm/hours  [{workspace, op_id, day, target, minutes | start, end, note?, state?}]
//
// The caller is the signed-in person (C2), checked as T003's read checks it
// (realmWriter): the person comes from the session and each workspace from
// the row, never from a header.
//
// The save groups the rows by workspace, in the order they first appear. A
// workspace that is not among Memberships(caller), or whose seat enters no
// hours of its own (no self.keys), fails its rows not_a_member and writes 0
// rows there. Every other group is ONE PutHoursEntries call, so one
// inTenant(W) transaction through 107's write (freeze, 1440 cap, spans with
// rdb 0176's overlap refusal), and a refusal there is the status of every
// row of that group. There is no atomicity across workspaces (7.2): a
// group's refusal leaves the others saved, and the answer is 200 with a
// status per row.
//
// A row is minutes only (an unplaced entry, the row's minutes as given) or
// start and end (a manual span, split at the member's midnight in that
// workspace as 107's timer does, its minutes added to what the row holds).
// A retry with the same rows writes nothing new: a minutes row upserts the
// same number, and a span already stored for its day and target is answered
// ok, replayed, without a second write. split, share and percent are 400 (D2).

const (
	realmRowsMax       = 100
	realmOpIDMax       = 64
	realmTargetsRecent = 8
	realmTargetsMax    = 50
)

// Row statuses (spec 118 7.2), one per row of the answer.
const (
	realmOK            = "ok"
	realmFrozen        = "period_frozen"
	realmDayCap        = "day_over_1440"
	realmOverlap       = "overlap_in_workspace"
	realmUnknownTarget = "unknown_target"
	realmNotMember     = "not_a_member"
	realmBadRow        = "bad_row"
	realmUnavailable   = "unavailable"
)

const realmFrozenDetail = "the day's hours period is frozen in this workspace"

// realmNoSplit are the fields of a split control (D2): refused by name.
var realmNoSplit = []string{"split", "share", "percent"}

var realmOpIDRE = regexp.MustCompile(`^[A-Za-z0-9._:-]+$`)

// ---- the caller ------------------------------------------------------------

// realmWriter is the person of a T004 route, "" once it answered: T003's
// realmPerson (session only, 400 person_scope on X-Spool-Tenant or member=,
// 403 person_only under act-as or for a box or agent credential) on the
// request less its workspace= (the targets route names one by design), then
// no live act-as clone in any membership. A save also needs a workspace
// where the person enters hours of their own (self.keys, not a
// time-accountant seat): else 403 forbidden before the body is read, as
// PUT /v1/me/hours refuses a demo visitor.
func (s *Server) realmWriter(w http.ResponseWriter, r *http.Request) string {
	r2 := r.Clone(r.Context())
	q := r2.URL.Query()
	q.Del("workspace")
	r2.URL.RawQuery = q.Encode()
	hum, ok := s.realmPerson(w, r2)
	if !ok {
		return ""
	}
	ml, ok := s.o.Store.(store.MembershipLister)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "hours_unavailable", "hours are not kept by this hub")
		return ""
	}
	ctx := r.Context()
	ms, err := ml.Memberships(ctx, hum)
	if err != nil {
		s.hoursFail(w, "", "realm memberships", err)
		return ""
	}
	if s.realmClone(ctx, hum, ms) {
		writeErr(w, http.StatusForbidden, "person_only", "personal hours are not entered under act-as")
		return ""
	}
	if r.Method == http.MethodGet {
		return hum
	}
	for _, m := range ms {
		if !seatAccountant(m) && s.allowed(ctx, hum, m.TenantID, rbac.SelfKeys) {
			return hum
		}
	}
	writeForbidden(w, rbac.SelfKeys, "you enter hours of your own in no workspace")
	return ""
}

// realmWorkspace is W as the caller enters hours there: false when W is not
// among the caller's memberships, its seat is a time accountant's (107
// FR-21) or holds no self.keys, or W is gone or suspended.
func (s *Server) realmWorkspace(ctx context.Context, hum, w string) (hoursMe, bool, error) {
	ml, ok := s.o.Store.(store.MembershipLister)
	hs, ok2 := s.o.Store.(store.Hours)
	if !ok || !ok2 {
		return hoursMe{}, false, errors.New("realm: the store keeps no memberships or hours")
	}
	ms, err := ml.Memberships(ctx, hum)
	if err != nil {
		return hoursMe{}, false, err
	}
	in := false
	for _, m := range ms {
		in = in || (m.TenantID == w && !seatAccountant(m))
	}
	if !in || !s.allowed(ctx, hum, w, rbac.SelfKeys) {
		return hoursMe{}, false, nil
	}
	t, err := s.o.Store.GetTenant(ctx, w)
	if err != nil || t.Suspended() {
		return hoursMe{}, false, nil
	}
	return hoursMe{tenant: t, hum: hum, st: hs, set: store.HoursSettingsOf(t.Settings)}, true, nil
}

// ---- GET /v1/me/realm/targets ------------------------------------------------

type realmTarget struct {
	Target string `json:"target"`
	Label  string `json:"label"`
	Kind   string `json:"kind"`
}

// GET /v1/me/realm/targets?workspace=<W>&q=: W's topics, channels and the
// workspace itself as W's own read door shows them to the caller (a channel
// the caller is not in is not listed). Recent first; without q each kind is
// cut to a few.
func (s *Server) handleGetRealmTargets(w http.ResponseWriter, r *http.Request) {
	hum := s.realmWriter(w, r)
	if hum == "" {
		return
	}
	ws := r.URL.Query().Get("workspace")
	if ws == "" {
		writeErr(w, http.StatusBadRequest, "bad_workspace", "workspace is required")
		return
	}
	ctx := r.Context()
	c, ok, err := s.realmWorkspace(ctx, hum, ws)
	switch {
	case err != nil:
		s.hoursFail(w, ws, "realm targets", err)
		return
	case !ok:
		writeErr(w, http.StatusForbidden, realmNotMember, "you do not enter hours in this workspace")
		return
	}
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	out, err := s.realmTopicTargets(ctx, c, q)
	if err != nil {
		s.hoursFail(w, ws, "realm targets topics", err)
		return
	}
	chans, err := s.realmChannelTargets(ctx, c, q)
	if err != nil {
		s.hoursFail(w, ws, "realm targets channels", err)
		return
	}
	out = append(out, chans...)
	if realmHit(q, "workspace", c.tenant.DisplayName) {
		out = append(out, realmTarget{Target: "ws", Label: "workspace", Kind: "workspace"})
	}
	writeJSON(w, http.StatusOK, map[string]any{"workspace": ws, "targets": out})
}

func realmHit(q string, s ...string) bool {
	if q == "" {
		return true
	}
	for _, x := range s {
		if strings.Contains(strings.ToLower(x), q) {
			return true
		}
	}
	return false
}

func realmCut(q string, out []realmTarget) []realmTarget {
	n := realmTargetsMax
	if q == "" {
		n = realmTargetsRecent
	}
	if len(out) > n {
		out = out[:n]
	}
	return out
}

// realmTopicTargets is W's root topics the caller may read, newest first.
func (s *Server) realmTopicTargets(ctx context.Context, c hoursMe, q string) ([]realmTarget, error) {
	chans, err := s.readerChannels(ctx, c.tenant.ID, c.hum)
	if err != nil {
		return nil, err
	}
	rows, err := s.o.Store.ViewTopics(ctx, c.tenant.ID, store.TopicQuery{Roots: true, Limit: realmTargetsMax,
		Now: s.o.Now(), Reader: c.hum, ReaderChannels: chans})
	if err != nil {
		return nil, err
	}
	out := []realmTarget{}
	for _, row := range rows {
		v := topicView(row)
		label := v.Subject
		if label == "" {
			label = v.TaskID
		}
		if realmHit(q, label) {
			out = append(out, realmTarget{Target: "t:" + v.TaskID, Label: label, Kind: "topic"})
		}
	}
	return realmCut(q, out), nil
}

// realmChannelTargets is W's channels the caller may read, last active first.
func (s *Server) realmChannelTargets(ctx context.Context, c hoursMe, q string) ([]realmTarget, error) {
	rows, err := s.o.Store.ViewChannelStats(ctx, c.tenant.ID, s.o.Now(), nil, c.hum, s.o.LobbyTaskID)
	if err == nil {
		rows, err = s.visibleChannels(ctx, c.tenant.ID, c.hum, rows)
	}
	if err != nil {
		return nil, err
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].LastAt.After(rows[j].LastAt) })
	out := []realmTarget{}
	for _, ch := range rows {
		if realmHit(q, ch.Name, ch.ChannelID) {
			out = append(out, realmTarget{Target: "ch:" + ch.ChannelID, Label: "#" + ch.Name, Kind: "channel"})
		}
	}
	return realmCut(q, out), nil
}

// ---- PUT /v1/me/realm/hours ----------------------------------------------------

// realmRow is one row of the save.
type realmRow struct {
	Workspace string `json:"workspace"`
	OpID      string `json:"op_id"`
	Day       string `json:"day"`
	Target    string `json:"target"`
	Minutes   *int   `json:"minutes"`
	Start     string `json:"start"`
	End       string `json:"end"`
	Note      string `json:"note"`
	State     string `json:"state"`
}

func (row realmRow) timed() bool { return row.Start != "" || row.End != "" }

// realmResult is one row of the answer, in the request's order.
type realmResult struct {
	OpID      string `json:"op_id"`
	Workspace string `json:"workspace"`
	Status    string `json:"status"`
	Detail    string `json:"detail,omitempty"`
	Replayed  bool   `json:"replayed,omitempty"`
}

const realmShape = "body must be [{workspace, op_id, day, target, minutes | start, end, note?, state?}]"

// decodeRealmRows reads the body: the rows, else the 400's token and detail.
func decodeRealmRows(w http.ResponseWriter, r *http.Request) ([]realmRow, string, string) {
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(http.MaxBytesReader(w, r.Body, hoursBodyMax)); err != nil {
		return nil, "bad_json", realmShape
	}
	var loose []map[string]json.RawMessage
	if json.Unmarshal(buf.Bytes(), &loose) == nil {
		for _, m := range loose {
			for _, k := range realmNoSplit {
				if _, has := m[k]; has {
					return nil, "no_split", "hours are not split across workspaces: enter one row per workspace (" + k + ")"
				}
			}
		}
	}
	var rows []realmRow
	dec := json.NewDecoder(&buf)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&rows); err != nil {
		return nil, "bad_json", realmShape
	}
	if bad := checkRealmRows(rows); bad != "" {
		return nil, "bad_hours", bad
	}
	return rows, "", ""
}

// checkRealmRows is the shape of the batch, before any workspace is asked.
func checkRealmRows(rows []realmRow) string {
	if len(rows) == 0 || len(rows) > realmRowsMax {
		return "1..100 rows per save"
	}
	ops := map[string]bool{}
	for i := range rows {
		row := &rows[i]
		switch {
		case row.Workspace == "":
			return "every row names its workspace"
		case len(row.OpID) > realmOpIDMax || !realmOpIDRE.MatchString(row.OpID):
			return "every row carries an op_id of 1..64 letters, digits or ._:-"
		case ops[row.OpID]:
			return "op_id " + row.OpID + " twice"
		case row.Target == "":
			return "every row names its target"
		case row.timed() == (row.Minutes != nil):
			return "a row carries minutes or start and end, not both"
		case row.timed() && row.State == store.HoursRejected:
			return "a rejected row carries no times"
		}
		ops[row.OpID] = true
		if row.State == "" {
			row.State = store.HoursApproved
		}
	}
	return ""
}

// PUT /v1/me/realm/hours: 200 {rows: [{op_id, workspace, status, detail?, replayed?}]}.
func (s *Server) handlePutRealmHours(w http.ResponseWriter, r *http.Request) {
	hum := s.realmWriter(w, r)
	if hum == "" {
		return
	}
	rows, code, bad := decodeRealmRows(w, r)
	if bad != "" {
		writeErr(w, http.StatusBadRequest, code, bad)
		return
	}
	res := make([]realmResult, len(rows))
	var order []string
	groups := map[string][]int{}
	for i, row := range rows {
		res[i] = realmResult{OpID: row.OpID, Workspace: row.Workspace}
		if _, ok := groups[row.Workspace]; !ok {
			order = append(order, row.Workspace)
		}
		groups[row.Workspace] = append(groups[row.Workspace], i)
	}
	for _, ws := range order { // one after another (7.2), never in parallel
		g := &realmGroup{s: s, hum: hum, ws: ws, rows: rows, idx: groups[ws], res: res}
		g.save(r.Context())
	}
	writeJSON(w, http.StatusOK, map[string]any{"rows": res})
}

// ---- one workspace's group -------------------------------------------------------

// realmKey is an entry's day and target.
type realmKey [2]string

// realmGroup is the rows of one workspace being saved.
type realmGroup struct {
	s    *Server
	hum  string
	ws   string
	rows []realmRow
	idx  []int // indexes into rows and res
	res  []realmResult
	b    *hoursBatch
	// the entries being built, in first-seen order, and the rows each carries
	entries map[realmKey]*hoursEntryBody
	carries map[realmKey][]int
	keys    []realmKey
	known   map[string]bool // new targets checked in this workspace
	spans   map[realmKey][]store.HoursEntrySpan
}

func (g *realmGroup) set(i int, status, detail string) {
	g.res[i].Status, g.res[i].Detail = status, detail
}

// save writes the group: every row ends with a status.
func (g *realmGroup) save(ctx context.Context) {
	c, ok, err := g.s.realmWorkspace(ctx, g.hum, g.ws)
	if err != nil {
		g.fail(g.idx, "membership", err)
		return
	}
	if !ok {
		for _, i := range g.idx {
			g.set(i, realmNotMember, "you do not enter hours in this workspace")
		}
		return
	}
	now := g.s.o.Now()
	loc, err := g.s.hoursZone(ctx, c, now)
	if err != nil {
		g.fail(g.idx, "zone", err)
		return
	}
	g.b = &hoursBatch{s: g.s, c: c, loc: loc, now: now, periods: map[string]*hoursPeriod{}}
	g.entries, g.carries = map[realmKey]*hoursEntryBody{}, map[realmKey][]int{}
	g.known, g.spans = map[string]bool{}, map[realmKey][]store.HoursEntrySpan{}
	for _, i := range g.idx {
		if err := g.add(ctx, i); err != nil {
			g.fail(g.idx, "row", err)
			return
		}
	}
	g.write(ctx)
}

// fail answers err on the rows of idx that have no status yet.
func (g *realmGroup) fail(idx []int, op string, err error) {
	status, detail := realmStatusOf(err)
	if status == realmUnavailable {
		g.s.o.Log.Error().Err(err).Str("tenant", g.ws).Str("op", "realm "+op).Msg("hours")
	}
	for _, i := range idx {
		if g.res[i].Status == "" {
			g.set(i, status, detail)
		}
	}
}

// realmStatusOf is a store error as a row status.
func realmStatusOf(err error) (string, string) {
	switch {
	case errors.Is(err, store.ErrHoursFrozen):
		return realmFrozen, realmFrozenDetail
	case errors.Is(err, store.ErrHoursDayCap):
		return realmDayCap, "a day holds at most 1440 minutes in one workspace"
	case errors.Is(err, store.ErrHoursOverlap):
		return realmOverlap, "these times overlap other hours of yours in this workspace"
	case errors.Is(err, store.ErrHoursBad):
		return realmBadRow, strings.TrimPrefix(err.Error(), "store: ")
	}
	return realmUnavailable, "this workspace could not save; retry"
}

// open checks that day of the group is open and target known there: "" when
// the row may go on, else its status and detail. err is a store failure.
func (g *realmGroup) open(ctx context.Context, day, target string) (string, string, error) {
	p, bad, err := g.b.period(ctx, day)
	switch {
	case err != nil:
		return "", "", err
	case bad != "":
		return realmBadRow, bad, nil
	case p.frozen[day]:
		return realmFrozen, realmFrozenDetail, nil
	}
	ok, err := g.knownTarget(ctx, target, p, day)
	if err != nil || ok {
		return "", "", err
	}
	return realmUnknownTarget, "no such target in this workspace", nil
}

// add folds row i into the group's entries, or sets its refusal.
func (g *realmGroup) add(ctx context.Context, i int) error {
	row := g.rows[i]
	if row.timed() {
		return g.addTimed(ctx, i)
	}
	status, detail, err := g.open(ctx, row.Day, row.Target)
	if err != nil || status != "" {
		g.set(i, status, detail)
		return err
	}
	k := realmKey{row.Day, row.Target}
	if _, dup := g.entries[k]; dup {
		g.set(i, realmBadRow, "a day and target take one minutes row, or times, in one save")
		return nil
	}
	g.put(k, &hoursEntryBody{Day: row.Day, Target: row.Target, Minutes: *row.Minutes, State: row.State, Note: row.Note}, i)
	return nil
}

func (g *realmGroup) put(k realmKey, e *hoursEntryBody, i int) {
	if _, ok := g.entries[k]; !ok {
		g.keys = append(g.keys, k)
	}
	g.entries[k] = e
	g.carries[k] = append(g.carries[k], i)
}

// addTimed folds a start..end row: one piece per local day of the workspace,
// each added to that day's row with its span.
func (g *realmGroup) addTimed(ctx context.Context, i int) error {
	row := g.rows[i]
	start, end, bad := parseHoursTimer(hoursTimerBody{Target: row.Target, Start: row.Start, End: row.End}, g.b.now)
	if bad != "" {
		g.set(i, realmBadRow, bad)
		return nil
	}
	pieces := splitHoursTimer(start, end, g.b.loc)
	if row.Day != "" && pieces[0].Day != row.Day {
		g.set(i, realmBadRow, "day must be the start's day in this workspace ("+pieces[0].Day+")")
		return nil
	}
	for _, pc := range pieces {
		status, detail, err := g.open(ctx, pc.Day, row.Target)
		if err != nil || status != "" {
			g.set(i, status, detail)
			return err
		}
		if e, ok := g.entries[realmKey{pc.Day, row.Target}]; ok && len(e.spans) == 0 {
			g.set(i, realmBadRow, "a day and target take one minutes row, or times, in one save")
			return nil
		}
	}
	stored, err := g.storedPieces(ctx, row.Target, pieces)
	if err != nil || stored {
		g.res[i].Replayed = stored
		return err
	}
	g.addPieces(i, row, pieces)
	return nil
}

// addPieces adds row's pieces to the group's entries: a second row on the
// same day and target adds its own minutes and span to the first.
func (g *realmGroup) addPieces(i int, row realmRow, pieces []hoursTimerPiece) {
	for _, e := range g.b.timerEntries(row.Target, pieces) {
		k := realmKey{e.Day, e.Target}
		e.spans = realmManual(e.spans)
		if have, ok := g.entries[k]; ok {
			have.Minutes += e.Minutes - realmBase(g.b.periods[e.Day], e.Day, e.Target)
			have.spans = append(have.spans, e.spans...)
			g.carries[k] = append(g.carries[k], i)
			continue
		}
		if row.Note != "" {
			e.Note = row.Note
		}
		g.put(k, &e, i)
	}
}

// realmBase is what timerEntries starts a day's row from (its approved
// minutes, else the open suggestion), so a second piece adds only itself.
func realmBase(p *hoursPeriod, day, target string) int {
	for _, e := range p.entries {
		if e.Day == day && e.Target == target {
			if e.State == store.HoursApproved {
				return e.Minutes
			}
			return 0
		}
	}
	if s, ok := p.suggest[day][target]; ok {
		return s.Minutes
	}
	return 0
}

// realmManual marks the realm screen's spans as the person's own (manual).
func realmManual(in []store.HoursSpan) []store.HoursSpan {
	out := make([]store.HoursSpan, len(in))
	for i, sp := range in {
		sp.Src = store.HoursSpanManual
		out[i] = sp
	}
	return out
}

// storedPieces reports every piece already stored as a span of target on its
// day: the same save sent again.
func (g *realmGroup) storedPieces(ctx context.Context, target string, pieces []hoursTimerPiece) (bool, error) {
	for _, pc := range pieces {
		want, ok := hoursSpanOf(pc.start, pc.end, store.HoursSpanManual)
		if !ok {
			continue
		}
		have, err := g.daySpans(ctx, pc.Day, target)
		if err != nil {
			return false, err
		}
		found := false
		for _, sp := range have {
			found = found || (sp.Start.Equal(want.Start) && sp.End.Equal(want.End))
		}
		if !found {
			return false, nil
		}
	}
	return true, nil
}

// daySpans is the member's stored spans of target on day in this workspace.
func (g *realmGroup) daySpans(ctx context.Context, day, target string) ([]store.HoursEntrySpan, error) {
	if sp, ok := g.spans[realmKey{day, target}]; ok {
		return sp, nil
	}
	all, err := g.b.c.st.HoursEntrySpans(ctx, g.ws, g.hum, day, day)
	if err != nil {
		return nil, err
	}
	for _, sp := range all {
		k := realmKey{sp.Day, sp.Target}
		g.spans[k] = append(g.spans[k], sp)
	}
	if _, ok := g.spans[realmKey{day, target}]; !ok {
		g.spans[realmKey{day, target}] = []store.HoursEntrySpan{}
	}
	return g.spans[realmKey{day, target}], nil
}

// knownTarget: target is offered by THIS workspace to the caller (T-R4c):
// a row the member already holds or is suggested on that day, the workspace
// itself, a topic or a channel they may read there. A target of another
// workspace is never known here.
func (g *realmGroup) knownTarget(ctx context.Context, target string, p *hoursPeriod, day string) (bool, error) {
	for _, e := range p.entries {
		if e.Day == day && e.Target == target {
			return true, nil
		}
	}
	if _, ok := p.suggest[day][target]; ok {
		return true, nil
	}
	if ok, seen := g.known[target]; seen {
		return ok, nil
	}
	ok, err := g.s.realmTargetIn(ctx, g.ws, g.hum, target)
	if err == nil {
		g.known[target] = ok
	}
	return ok, err
}

// realmTargetIn checks a new target against workspace ws's read door.
func (s *Server) realmTargetIn(ctx context.Context, ws, hum, target string) (bool, error) {
	kind, id, _ := strings.Cut(target, ":")
	switch {
	case target == "ws":
		return true, nil
	case kind == "t" && uuidRe.MatchString(id):
		ok, found, err := s.canReadTopic(ctx, ws, id, hum)
		return ok && found, err
	case kind == "ch" && id != "":
		ch := store.NormalizeChannel(id)
		if store.ChannelPublic(ch) {
			return true, nil
		}
		mine, err := s.readerChannels(ctx, ws, hum)
		for _, c := range mine {
			if c == ch {
				return true, err
			}
		}
		return false, err
	}
	return false, nil
}

// write is the group's one PutHoursEntries call: one inTenant(W) transaction.
func (g *realmGroup) write(ctx context.Context) {
	var es []hoursEntryBody
	var carried []int
	for _, k := range g.keys {
		es = append(es, *g.entries[k])
		carried = append(carried, g.carries[k]...)
	}
	if len(es) > 0 {
		c := g.b.c
		ses, bad, err := g.b.entries(ctx, es)
		if bad != "" {
			for _, i := range carried {
				g.set(i, realmBadRow, bad)
			}
			return
		}
		if err == nil {
			err = c.st.PutHoursEntries(ctx, c.tenant.ID, c.hum, ses, c.hum, g.b.now)
		}
		if err != nil {
			g.fail(carried, "write", err)
			return
		}
	}
	for _, i := range g.idx {
		if g.res[i].Status == "" {
			g.set(i, realmOK, "")
		}
	}
}

// ---- routes ----------------------------------------------------------------------

// realmTargetsPreflight: GET with the headers every browser route allows.
func (s *Server) realmTargetsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// routeRealmHoursWrite registers the save and the targets (118 T004). The
// read GET /v1/me/realm/hours and its preflight are 118 T003's
// (realm_hours_read.go): a browser PUT shares that OPTIONS route.
func (s *Server) routeRealmHoursWrite(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/me/realm/hours", s.handlePutRealmHours)
	mux.HandleFunc("GET /v1/me/realm/targets", s.handleGetRealmTargets)
	mux.HandleFunc("OPTIONS /v1/me/realm/targets", s.realmTargetsPreflight)
}
