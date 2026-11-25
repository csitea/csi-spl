package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The Costs > Taxes routes (spec 143 taxes-tab.md sections 3, 5 and 6,
// build slice S2, SPL-6438; owner HUM-10, csitea topic dc7c9c9a, msg
// fc8f964e: "Every person of csitea; agents never", "Weekly, after the
// weekly tax check"). Bodies: internal/wire/tax.go. Store: store.Tax
// (rdb 0326).
//
//	GET  /v1/view/tax/overview       every PERSON seated in the tax workspace
//	POST /v1/operator/tax/snapshots  the main-box sync (do_spl_tax_sync) as
//	                                 the env's service account (operatorAuth)
//
// taxReader is the view route's door, the Finance door's shape
// (netvisorReader): 403 for any Authorization header (a box, an agent desk
// or CLI token, the operator service account: the page is read from a
// person's own browser, never by a credential a machine holds), for an
// act-as clone, a session that is not a person (realmRefuses) and a seat
// that is not a person's (an agent's, a time accountant's, a channel
// guest's). In every workspace but the tax workspace (Options.TaxWorkspace,
// cnf: csitea), the operator workspace included, it answers the 404 of an
// unknown /v1/view/* route, byte for byte: no other workspace learns the
// page has data. Behind the
// door rdb 0326's RLS is the second wall: the store reads as that human.
//
// No MCP tool and no spool message carries a row. Logs carry ids, counts
// and outcomes, never a document's kind, type, period or hash.

const (
	// taxIngestBodyMax bounds one snapshot: store.TaxMaxDocuments rows of a
	// few hundred bytes.
	taxIngestBodyMax = 8 << 20
	// taxDueWindowDays is the "Due in the next 30 days" window, both ways
	// (an overdue document stays in it for as long).
	taxDueWindowDays = 30
)

func (s *Server) routeTax(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/tax/overview", s.handleTaxOverview)
	mux.HandleFunc("OPTIONS /v1/view/tax/overview", s.preflight)
}

func (s *Server) routeOperatorTax(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/tax/snapshots", s.handleOperatorTaxIngest)
}

func writeTaxNotPerson(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, "person_only",
		"the tax index is read only from a person's own browser session: no token, act-as or agent seat")
}

// taxReader is the view route's door (see the file comment); false =
// answered.
func (s *Server) taxReader(w http.ResponseWriter, r *http.Request) (string, string, store.Tax, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if strings.TrimSpace(r.Header.Get("Authorization")) != "" {
		writeTaxNotPerson(w)
		return "", "", nil, false
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return "", "", nil, false
	}
	if !s.taxPerson(w, r, t.ID, hum) {
		return "", "", nil, false
	}
	if tw := s.o.TaxWorkspace; tw == "" || t.ID != tw {
		writeErr(w, http.StatusNotFound, "not_found", "no such view") // view.go's unknown /v1/view/* answer
		return "", "", nil, false
	}
	if !s.taxPersonSeat(w, r, t.ID, hum) {
		return "", "", nil, false
	}
	tx, has := s.o.Store.(store.Tax)
	if !has {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no tax index")
		return "", "", nil, false
	}
	return t.ID, hum, tx, true
}

// taxPerson answers whether the session is a person's own browser session
// (not an act-as clone, not an agent seat); false = answered 403.
func (s *Server) taxPerson(w http.ResponseWriter, r *http.Request, tenant, hum string) bool {
	if hum == "" || s.o.Auth == nil {
		writeTaxNotPerson(w)
		return false
	}
	sess, ok := s.o.Auth.SessionFromRequest(r)
	if !ok || sess.HumanID != hum {
		writeTaxNotPerson(w)
		return false
	}
	sess.Tenant = tenant
	refuse, err := s.realmRefuses(r.Context(), sess)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("tax.person_check_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the session was not checked")
		return false
	}
	if refuse {
		writeTaxNotPerson(w)
		return false
	}
	return true
}

// taxPersonSeat answers whether hum's seat in tenant is a person's: one
// role of its set is neither an agent's nor a time accountant's, and it is
// not a channel guest's. rdb 0326's tax_read holds the same rule in the
// database. false = answered 403.
func (s *Server) taxPersonSeat(w http.ResponseWriter, r *http.Request, tenant, hum string) bool {
	a, err := s.access(r.Context(), hum, tenant)
	if err != nil {
		writeTaxNotPerson(w)
		return false
	}
	roles := a.Roles
	if len(roles) == 0 {
		roles = []string{a.Role}
	}
	for _, role := range roles {
		if role != "" && role != rbac.ChannelGuest && !realmNotPerson[role] {
			return true
		}
	}
	writeTaxNotPerson(w)
	return false
}

// GET /v1/view/tax/overview[?year=YYYY]
func (s *Server) handleTaxOverview(w http.ResponseWriter, r *http.Request) {
	tenant, hum, tx, ok := s.taxReader(w, r)
	if !ok {
		return
	}
	year := 0
	if v := r.URL.Query().Get("year"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 2000 || n > 2100 {
			writeErr(w, http.StatusBadRequest, "bad_year", "year must be YYYY")
			return
		}
		year = n
	}
	snaps, years, err := tx.TaxLatest(r.Context(), tenant, hum, year, 2)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("tax.latest_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the tax index was not read")
		return
	}
	writeJSON(w, http.StatusOK, taxOverview(snaps, years, s.o.Now().UTC()))
}

// taxKey is what makes two index rows the same document across weeks.
func taxKey(d store.TaxDocument) string {
	return d.Kind + "\x1f" + d.DocType + "\x1f" + d.TaxType + "\x1f" + d.Period
}

// taxOverview computes the page from the newest snapshot and the one
// before it (snaps newest first, as TaxLatest answers).
func taxOverview(snaps []store.TaxSnapshot, years []int, now time.Time) wire.TaxOverviewResponse {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	out := wire.TaxOverviewResponse{Years: years, Today: nvsDateOut(today), Documents: []wire.TaxDocument{}}
	if out.Years == nil {
		out.Years = []int{}
	}
	if len(snaps) == 0 {
		if len(years) > 0 {
			out.TaxYear = years[0]
		}
		return out
	}
	cur := snaps[0]
	out.TaxYear, out.SnapshotID, out.TakenAt = cur.TaxYear, cur.SnapshotID, cur.TakenAt.UTC().Format(time.RFC3339)
	var prevKeys, prevSHA map[string]bool
	if len(snaps) > 1 {
		out.PreviousTakenAt = snaps[1].TakenAt.UTC().Format(time.RFC3339)
		prevKeys, prevSHA = map[string]bool{}, map[string]bool{}
		for _, d := range snaps[1].Documents {
			prevKeys[taxKey(d)], prevSHA[d.ContentSHA256] = true, true
		}
	}
	docs := append([]store.TaxDocument(nil), cur.Documents...)
	sort.SliceStable(docs, func(i, j int) bool { return docs[i].ArrivalDate.After(docs[j].ArrivalDate) })
	for _, d := range docs {
		o := wire.TaxDocument{ArrivalDate: nvsDateOut(d.ArrivalDate), Kind: d.Kind, DocType: d.DocType, TaxType: d.TaxType,
			Period: d.Period, DueDate: nvsDateOut(d.DueDate), Category: d.Category,
			OpenQuestion: d.Category == "decisions" && d.DueDate.IsZero()}
		if prevSHA != nil && !prevSHA[d.ContentSHA256] {
			o.Status = "new"
			if prevKeys[taxKey(d)] {
				o.Status = "changed"
			}
		}
		if !d.DueDate.IsZero() {
			days := int(d.DueDate.Sub(today).Hours() / 24)
			o.Overdue = days < 0
			o.DueSoon = days >= -taxDueWindowDays && days <= taxDueWindowDays
		}
		out.Documents = append(out.Documents, o)
	}
	return out
}

// taxOperator is the operator route's door: the env's service account, on
// the tax workspace (Options.TaxWorkspace); a request that names another
// workspace (its Host or X-Spool-Tenant), the operator workspace included,
// is 403, and one that names none files into the tax workspace. false =
// answered.
func (s *Server) taxOperator(w http.ResponseWriter, r *http.Request) (string, string, store.Tax, bool) {
	email, ok := s.operatorAuth(w, r)
	if !ok {
		return "", "", nil, false
	}
	tw := s.o.TaxWorkspace
	if tw == "" {
		writeErr(w, http.StatusNotFound, "not_found", "this hub names no tax workspace")
		return "", "", nil, false
	}
	host, named := s.hostTenantID(r), strings.ToLower(strings.TrimSpace(r.Header.Get(TenantHeader)))
	if (host != "" && host != tw) || (named != "" && named != tw) {
		writeErr(w, http.StatusForbidden, "tax_workspace_only", "the tax index is kept in the tax workspace only")
		return "", "", nil, false
	}
	tx, has := s.o.Store.(store.Tax)
	if !has {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no tax index")
		return "", "", nil, false
	}
	return tw, email, tx, true
}

// POST /v1/operator/tax/snapshots: one sync of one tax year's index; the
// answer and the log carry counts only.
func (s *Server) handleOperatorTaxIngest(w http.ResponseWriter, r *http.Request) {
	tw, by, tx, ok := s.taxOperator(w, r)
	if !ok {
		return
	}
	var in wire.TaxSnapshotIn
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, taxIngestBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be one snapshot: {snapshot_id, tax_year, taken_at, documents}, each document {arrival_date, kind, doc_type, tax_type, period, due_date, category, content_sha256} and nothing else")
		return
	}
	snap, why := taxSnapshotIn(in, by)
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_snapshot", why)
		return
	}
	got, err := tx.TaxIngest(r.Context(), tw, snap)
	switch {
	case errors.Is(err, store.ErrBadTax):
		writeErr(w, http.StatusBadRequest, "bad_snapshot", "a value is outside the snapshot's bounds (id, year, category, sha256, dates, text of at most 80 characters)")
	case errors.Is(err, store.ErrTaxDuplicate):
		writeErr(w, http.StatusConflict, "duplicate", "this snapshot id is already filed")
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tw).Int("documents", len(snap.Documents)).Msg("tax.ingest_failed")
		writeErr(w, http.StatusServiceUnavailable, "internal", "the tax snapshot was not stored")
	default:
		s.o.Log.Info().Str("tenant", tw).Str("snapshot", got.SnapshotID).Int("tax_year", got.TaxYear).
			Int("documents", len(got.Documents)).Msg("tax.ingested")
		writeJSON(w, http.StatusOK, wire.TaxIngestResponse{SnapshotID: got.SnapshotID, TaxYear: got.TaxYear,
			Documents: len(got.Documents)})
	}
}

// taxSnapshotIn parses the wire snapshot's dates; the store checks the rest
// (rdb 0326's CHECKs). why is "" when it parses.
func taxSnapshotIn(in wire.TaxSnapshotIn, by string) (store.TaxSnapshot, string) {
	snap := store.TaxSnapshot{SnapshotID: in.SnapshotID, TaxYear: in.TaxYear, FiledBy: by,
		Documents: make([]store.TaxDocument, 0, len(in.Documents))}
	at, err := time.Parse(time.RFC3339, in.TakenAt)
	if err != nil {
		return snap, "taken_at must be RFC 3339"
	}
	snap.TakenAt = at.UTC()
	for i, d := range in.Documents {
		arrival, err := nvsDateIn(d.ArrivalDate, true)
		if err != nil {
			return snap, "documents[" + strconv.Itoa(i) + "].arrival_date must be YYYY-MM-DD"
		}
		due, err := nvsDateIn(d.DueDate, false)
		if err != nil {
			return snap, "documents[" + strconv.Itoa(i) + "].due_date must be YYYY-MM-DD or empty"
		}
		snap.Documents = append(snap.Documents, store.TaxDocument{ArrivalDate: arrival, Kind: d.Kind, DocType: d.DocType,
			TaxType: d.TaxType, Period: d.Period, DueDate: due, Category: d.Category, ContentSHA256: d.ContentSHA256})
	}
	return snap, ""
}
