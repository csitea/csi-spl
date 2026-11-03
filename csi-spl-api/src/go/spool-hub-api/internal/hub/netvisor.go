package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The Netvisor finance routes (spec 125 v0.1 sections 5.1, 5.2, build row
// B5, SPL-4732, case C-NVS-5; owner HUM-10, topic fc0119cd). Bodies:
// internal/wire/netvisor.go. Store: store.Netvisor (B4, rdb 0255, 0257).
//
// The owner's routes, from the browser session of the workspace's Netvisor
// owner ONLY (C7):
//
//	GET  /v1/view/netvisor/forecast    the month-end cash forecast
//	GET  /v1/view/netvisor/card-costs  the card cost lines
//	POST /v1/netvisor/refresh          "Refresh now": 202, the open request
//	GET  /v1/netvisor/settings         env, accounts, vendor exclusions
//	PUT  /v1/netvisor/settings         the same, written
//
// netvisorOwner is their one door. 403 for any Authorization header (a box,
// an agent desk or CLI token, the operator service account: the data is read
// from the owner's own browser, never by a credential a machine holds), for
// an act-as clone, a session that is not a person (realmRefuses) and every
// member who is not netvisor_settings.owner_human_id, admins included: the
// check is the session's human id against the owner the STORE holds (data,
// never a literal), not a role. 404 in every workspace but the operator
// workspace (csitea): no other workspace has Netvisor data. Behind the door
// rdb 0255's RLS is the second wall: the store reads as that human, so a
// wrong door would still read 0 rows.
//
// The operator's routes, the main-box sync (B6) as the env's service account
// (operatorAuth), in the operator workspace only:
//
//	PUT  /v1/operator/netvisor/owner      names the owner (C7)
//	POST /v1/operator/netvisor/snapshots  files one fetch: counts back
//	GET  /v1/operator/netvisor/refresh    the open "Refresh now", or null
//
// No MCP tool and no spool message carries a figure (C8). Logs carry ids,
// counts and outcomes, never an amount, an account number or a label (C2).

const (
	// permNetvisor names the grant in a 403 body: a rule on data (the
	// owner in netvisor_settings), not a row of the permission table.
	permNetvisor = "netvisor.owner"
	// netvisorIngestBodyMax bounds one snapshot: store.NetvisorMaxCardCostLines
	// lines of a few hundred bytes.
	netvisorIngestBodyMax = 24 << 20
	// netvisorSettingsBodyMax bounds a settings PUT (200 exclusions of 100 bytes).
	netvisorSettingsBodyMax = 64 << 10
)

func (s *Server) routeNetvisor(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/netvisor/forecast", s.handleNetvisorForecast)
	mux.HandleFunc("OPTIONS /v1/view/netvisor/forecast", s.preflight)
	mux.HandleFunc("GET /v1/view/netvisor/card-costs", s.handleNetvisorCardCosts)
	mux.HandleFunc("OPTIONS /v1/view/netvisor/card-costs", s.preflight)
	mux.HandleFunc("POST /v1/netvisor/refresh", s.handleNetvisorRefresh)
	mux.HandleFunc("OPTIONS /v1/netvisor/refresh", s.gcalPreflight("POST"))
	mux.HandleFunc("GET /v1/netvisor/settings", s.handleNetvisorSettingsGet)
	mux.HandleFunc("PUT /v1/netvisor/settings", s.handleNetvisorSettingsPut)
	mux.HandleFunc("OPTIONS /v1/netvisor/settings", s.gcalPreflight("GET, PUT"))
}

func (s *Server) routeOperatorNetvisor(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/operator/netvisor/owner", s.handleOperatorNetvisorOwner)
	mux.HandleFunc("POST /v1/operator/netvisor/snapshots", s.handleOperatorNetvisorIngest)
	mux.HandleFunc("GET /v1/operator/netvisor/refresh", s.handleOperatorNetvisorRefresh)
}

// nvsOwner is the caller of an owner route: the operator workspace, its
// Netvisor owner (the session's human) and that owner's settings.
type nvsOwner struct {
	tenant, hum string
	nv          store.Netvisor
	settings    store.NetvisorSettings
}

func writeNetvisorNotPerson(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, "person_only",
		"the Netvisor data is read only from its owner's own browser session: no token, act-as or agent seat")
}

// netvisorOwner is the owner routes' door (see the file comment); false =
// answered.
func (s *Server) netvisorOwner(w http.ResponseWriter, r *http.Request) (nvsOwner, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if strings.TrimSpace(r.Header.Get("Authorization")) != "" {
		writeNetvisorNotPerson(w)
		return nvsOwner{}, false
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return nvsOwner{}, false
	}
	if !s.netvisorPerson(w, r, t.ID, hum) {
		return nvsOwner{}, false
	}
	if op, err := s.operatorTenant(r.Context()); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return nvsOwner{}, false
	} else if op == "" || t.ID != op {
		writeErr(w, http.StatusNotFound, "not_found", "this workspace keeps no Netvisor data")
		return nvsOwner{}, false
	}
	nv, has := s.o.Store.(store.Netvisor)
	if !has {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no Netvisor data")
		return nvsOwner{}, false
	}
	st, isOwner, err := s.netvisorIsOwner(r.Context(), nv, t.ID, hum)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("netvisor.owner_read_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the Netvisor settings were not read")
		return nvsOwner{}, false
	}
	if !isOwner {
		writeForbidden(w, permNetvisor, "only the workspace's Netvisor owner sees the Netvisor data")
		return nvsOwner{}, false
	}
	return nvsOwner{tenant: t.ID, hum: hum, nv: nv, settings: st}, true
}

// netvisorPerson answers whether the session is a person's own browser
// session (not an act-as clone, not an agent seat); false = answered 403.
func (s *Server) netvisorPerson(w http.ResponseWriter, r *http.Request, tenant, hum string) bool {
	if hum == "" || s.o.Auth == nil {
		writeNetvisorNotPerson(w)
		return false
	}
	sess, ok := s.o.Auth.SessionFromRequest(r)
	if !ok || sess.HumanID != hum {
		writeNetvisorNotPerson(w)
		return false
	}
	sess.Tenant = tenant
	refuse, err := s.realmRefuses(r.Context(), sess)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("netvisor.person_check_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the session was not checked")
		return false
	}
	if refuse {
		writeNetvisorNotPerson(w)
		return false
	}
	return true
}

// netvisorIsOwner is the C7 check: hum is the owner the store holds for
// tenant. The store answers the settings only to the owner itself
// (ErrNotFound otherwise, also with no settings row), and the id must match
// what it answers. Never a role: an admin who is not the owner is refused.
func (s *Server) netvisorIsOwner(ctx context.Context, nv store.Netvisor, tenant, hum string) (store.NetvisorSettings, bool, error) {
	st, err := nv.NetvisorSettings(ctx, tenant, hum)
	switch {
	case errors.Is(err, store.ErrNotFound) || errors.Is(err, store.ErrNoHuman):
		return store.NetvisorSettings{}, false, nil
	case err != nil:
		return store.NetvisorSettings{}, false, err
	}
	return st, st.OwnerHumanID != "" && st.OwnerHumanID == hum, nil
}

// netvisorLatest is the owner's newest snapshot of the settings' env; nil
// with no snapshot yet; false = answered.
func (s *Server) netvisorLatest(w http.ResponseWriter, r *http.Request, c nvsOwner) (*store.NetvisorSnapshot, bool) {
	snap, err := c.nv.NetvisorLatest(r.Context(), c.tenant, c.hum, c.settings.Env)
	if errors.Is(err, store.ErrNotFound) {
		return nil, true
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Msg("netvisor.latest_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the Netvisor snapshot was not read")
		return nil, false
	}
	return &snap, true
}

// GET /v1/view/netvisor/forecast
func (s *Server) handleNetvisorForecast(w http.ResponseWriter, r *http.Request) {
	c, ok := s.netvisorOwner(w, r)
	if !ok {
		return
	}
	snap, ok := s.netvisorLatest(w, r, c)
	if !ok {
		return
	}
	out := wire.NetvisorForecastResponse{Env: c.settings.Env, Items: []wire.NetvisorForecastItem{},
		RefreshRequestedAt: nvsTimeOut(c.settings.RefreshRequestedAt)}
	if snap != nil {
		out.Snapshot = nvsHeadOut(*snap)
		for _, it := range snap.Items {
			out.Items = append(out.Items, nvsItemOut(it))
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// GET /v1/view/netvisor/card-costs
func (s *Server) handleNetvisorCardCosts(w http.ResponseWriter, r *http.Request) {
	c, ok := s.netvisorOwner(w, r)
	if !ok {
		return
	}
	snap, ok := s.netvisorLatest(w, r, c)
	if !ok {
		return
	}
	out := wire.NetvisorCardCostsResponse{Env: c.settings.Env, Lines: []wire.NetvisorCardCostLine{},
		RefreshRequestedAt: nvsTimeOut(c.settings.RefreshRequestedAt)}
	if snap != nil {
		out.Snapshot = nvsHeadOut(*snap)
		for _, l := range snap.CardLines {
			out.Lines = append(out.Lines, nvsLineOut(l))
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// POST /v1/netvisor/refresh: 202 with the open request's time; a second
// press while one is open keeps the first time.
func (s *Server) handleNetvisorRefresh(w http.ResponseWriter, r *http.Request) {
	c, ok := s.netvisorOwner(w, r)
	if !ok {
		return
	}
	at, err := c.nv.NetvisorRequestRefresh(r.Context(), c.tenant, c.hum, s.o.Now().UTC())
	if errors.Is(err, store.ErrNotFound) {
		writeForbidden(w, permNetvisor, "only the workspace's Netvisor owner requests a refresh")
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Msg("netvisor.refresh_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the refresh was not requested")
		return
	}
	s.o.Log.Info().Str("tenant", c.tenant).Str("by", c.hum).Msg("netvisor.refresh_requested")
	writeJSON(w, http.StatusAccepted, wire.NetvisorRefreshResponse{RefreshRequestedAt: nvsTimeOut(&at)})
}

// GET /v1/netvisor/settings
func (s *Server) handleNetvisorSettingsGet(w http.ResponseWriter, r *http.Request) {
	c, ok := s.netvisorOwner(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, nvsSettingsOut(c.settings))
}

// PUT /v1/netvisor/settings: replaces env, the accounts and the vendor
// exclusions; the owner is never a field it writes.
func (s *Server) handleNetvisorSettingsPut(w http.ResponseWriter, r *http.Request) {
	c, ok := s.netvisorOwner(w, r)
	if !ok {
		return
	}
	var in wire.NetvisorSettingsBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, netvisorSettingsBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {env, bank_account, vat_accounts, tax_accounts, vendor_exclusions}")
		return
	}
	st, err := c.nv.NetvisorPutSettings(r.Context(), c.tenant, c.hum, store.NetvisorSettings{Env: in.Env,
		BankAccount: in.BankAccount, VATAccounts: in.VATAccounts, TaxAccounts: in.TaxAccounts,
		VendorExclusions: in.VendorExclusions}, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrBadNetvisor):
		writeErr(w, http.StatusBadRequest, "bad_settings", "env is test or prd; accounts are 1-12 digits, at most 32 each; at most 200 vendor exclusions")
	case errors.Is(err, store.ErrNotFound):
		writeForbidden(w, permNetvisor, "only the workspace's Netvisor owner writes the Netvisor settings")
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Msg("netvisor.settings_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the Netvisor settings were not stored")
	default:
		s.o.Log.Info().Str("tenant", c.tenant).Str("by", c.hum).Str("env", st.Env).Msg("netvisor.settings_put")
		writeJSON(w, http.StatusOK, nvsSettingsOut(st))
	}
}

// netvisorOperator is the operator routes' door: the env's service account,
// on the operator workspace; a request that names another workspace (its
// Host or X-Spool-Tenant) is 403. false = answered.
func (s *Server) netvisorOperator(w http.ResponseWriter, r *http.Request) (string, string, store.Netvisor, bool) {
	email, ok := s.operatorAuth(w, r)
	if !ok {
		return "", "", nil, false
	}
	op, err := s.operatorTenant(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return "", "", nil, false
	}
	if op == "" {
		writeErr(w, http.StatusNotFound, "not_found", "this hub names no operator workspace")
		return "", "", nil, false
	}
	host, named := s.hostTenantID(r), strings.ToLower(strings.TrimSpace(r.Header.Get(TenantHeader)))
	if (host != "" && host != op) || (named != "" && named != op) {
		writeErr(w, http.StatusForbidden, "operator_workspace_only", "Netvisor data is kept in the operator workspace only")
		return "", "", nil, false
	}
	nv, has := s.o.Store.(store.Netvisor)
	if !has {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no Netvisor data")
		return "", "", nil, false
	}
	return op, email, nv, true
}

// PUT /v1/operator/netvisor/owner: {human_id}, a person seated in the
// operator workspace (not an act-as clone).
func (s *Server) handleOperatorNetvisorOwner(w http.ResponseWriter, r *http.Request) {
	op, by, nv, ok := s.netvisorOperator(w, r)
	if !ok {
		return
	}
	var in wire.NetvisorOwnerBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil || !realmPersonRe.MatchString(in.HumanID) {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {human_id: HUM-<digits>}")
		return
	}
	if _, err := s.access(r.Context(), in.HumanID, op); err != nil || s.readerIsActAsClone(r.Context(), op, in.HumanID) {
		writeErr(w, http.StatusConflict, "not_member", "the owner must be a person seated in the operator workspace")
		return
	}
	if err := nv.NetvisorSetOwner(r.Context(), op, in.HumanID, by, s.o.Now().UTC()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", op).Msg("netvisor.owner_set_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the Netvisor owner was not stored")
		return
	}
	s.o.Log.Info().Str("tenant", op).Str("owner", in.HumanID).Str("by", by).Msg("netvisor.owner_set")
	writeJSON(w, http.StatusOK, wire.NetvisorOwnerResponse{Workspace: op, HumanID: in.HumanID})
}

// POST /v1/operator/netvisor/snapshots: one fetch, filed under the
// workspace's owner; the answer and the log carry counts only.
func (s *Server) handleOperatorNetvisorIngest(w http.ResponseWriter, r *http.Request) {
	op, _, nv, ok := s.netvisorOperator(w, r)
	if !ok {
		return
	}
	var in wire.NetvisorSnapshotIn
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, netvisorIngestBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be one snapshot: {snapshot_id, env, as_of, month_end, newest_bank_voucher_date, fetched_at, items, card_lines}")
		return
	}
	snap, why := nvsSnapshotIn(in)
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_snapshot", why)
		return
	}
	got, err := nv.NetvisorIngest(r.Context(), op, snap)
	switch {
	case errors.Is(err, store.ErrBadNetvisor):
		writeErr(w, http.StatusBadRequest, "bad_snapshot", "a value is outside the snapshot's bounds (ids, categories, routes, amounts, accounts, dates)")
	case errors.Is(err, store.ErrNetvisorNoOwner):
		writeErr(w, http.StatusConflict, "no_owner", "the workspace has no Netvisor owner: PUT /v1/operator/netvisor/owner first")
	case errors.Is(err, store.ErrNetvisorEnv):
		writeErr(w, http.StatusConflict, "env_mismatch", "the snapshot's env differs from the workspace's Netvisor settings")
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", op).Int("items", len(snap.Items)).Int("card_lines", len(snap.CardLines)).Msg("netvisor.ingest_failed")
		writeErr(w, http.StatusServiceUnavailable, "internal", "the Netvisor snapshot was not stored")
	default:
		s.o.Log.Info().Str("tenant", op).Str("snapshot", got.SnapshotID).Str("env", got.Env).
			Int("items", len(got.Items)).Int("card_lines", len(got.CardLines)).Msg("netvisor.ingested")
		writeJSON(w, http.StatusOK, wire.NetvisorIngestResponse{SnapshotID: got.SnapshotID, Env: got.Env,
			Items: len(got.Items), CardLines: len(got.CardLines)})
	}
}

// GET /v1/operator/netvisor/refresh: the B6 poller's read.
func (s *Server) handleOperatorNetvisorRefresh(w http.ResponseWriter, r *http.Request) {
	op, _, nv, ok := s.netvisorOperator(w, r)
	if !ok {
		return
	}
	at, err := nv.NetvisorRefreshRequested(r.Context(), op)
	switch {
	case errors.Is(err, store.ErrNetvisorNoOwner):
		writeErr(w, http.StatusConflict, "no_owner", "the workspace has no Netvisor owner")
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", op).Msg("netvisor.refresh_read_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the refresh request was not read")
	default:
		writeJSON(w, http.StatusOK, wire.NetvisorRefreshResponse{RefreshRequestedAt: nvsTimeOut(at)})
	}
}

// nvsSnapshotIn parses the wire snapshot's dates; the store checks the rest
// (rdb 0255's CHECKs). why is "" when it parses.
func nvsSnapshotIn(in wire.NetvisorSnapshotIn) (store.NetvisorSnapshot, string) {
	snap := store.NetvisorSnapshot{SnapshotID: in.SnapshotID, Env: in.Env,
		Items: make([]store.NetvisorForecastItem, 0, len(in.Items)), CardLines: make([]store.NetvisorCardCostLine, 0, len(in.CardLines))}
	var err error
	if snap.AsOf, err = nvsDateIn(in.AsOf, true); err != nil {
		return snap, "as_of must be YYYY-MM-DD"
	}
	if snap.MonthEnd, err = nvsDateIn(in.MonthEnd, true); err != nil {
		return snap, "month_end must be YYYY-MM-DD"
	}
	if snap.NewestBankVoucherDate, err = nvsDateIn(in.NewestBankVoucherDate, false); err != nil {
		return snap, "newest_bank_voucher_date must be YYYY-MM-DD or empty"
	}
	if snap.FetchedAt, err = time.Parse(time.RFC3339, in.FetchedAt); err != nil {
		return snap, "fetched_at must be an RFC 3339 time"
	}
	for _, it := range in.Items {
		due, err := nvsDateIn(it.DueDate, false)
		if err != nil {
			return snap, "an item's due_date must be YYYY-MM-DD or empty"
		}
		snap.Items = append(snap.Items, store.NetvisorForecastItem{ItemNo: it.ItemNo, Category: it.Category, Sign: it.Sign,
			Amount: it.Amount, Currency: it.Currency, DueDate: due, Overdue: it.Overdue, Approved: it.Approved, Label: it.Label})
	}
	for _, l := range in.CardLines {
		month, err := nvsDateIn(l.Month, true)
		if err != nil {
			return snap, "a card line's month must be YYYY-MM-01"
		}
		snap.CardLines = append(snap.CardLines, store.NetvisorCardCostLine{LineNo: l.LineNo, Month: month, Route: l.Route,
			Vendor: l.Vendor, AccountNumber: l.AccountNumber, AccountName: l.AccountName, Dimension: l.Dimension,
			DimensionItem: l.DimensionItem, Amount: l.Amount, Currency: l.Currency, VATCode: l.VATCode, Excluded: l.Excluded})
	}
	return snap, ""
}

// nvsDateIn parses a wire date; "" is the zero time unless required.
func nvsDateIn(v string, required bool) (time.Time, error) {
	if v == "" && !required {
		return time.Time{}, nil
	}
	return time.Parse(wire.NetvisorDateLayout, v)
}

// nvsDateOut is a wire date: "" for the zero time.
func nvsDateOut(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(wire.NetvisorDateLayout)
}

// nvsTimeOut is a wire time: nil for none.
func nvsTimeOut(t *time.Time) *string {
	if t == nil || t.IsZero() {
		return nil
	}
	v := t.UTC().Format(time.RFC3339)
	return &v
}

func nvsHeadOut(snap store.NetvisorSnapshot) *wire.NetvisorSnapshotHead {
	return &wire.NetvisorSnapshotHead{SnapshotID: snap.SnapshotID, Env: snap.Env, AsOf: nvsDateOut(snap.AsOf),
		MonthEnd: nvsDateOut(snap.MonthEnd), NewestBankVoucherDate: nvsDateOut(snap.NewestBankVoucherDate),
		FetchedAt: snap.FetchedAt.UTC().Format(time.RFC3339)}
}

func nvsItemOut(it store.NetvisorForecastItem) wire.NetvisorForecastItem {
	return wire.NetvisorForecastItem{ItemNo: it.ItemNo, Category: it.Category, Sign: it.Sign, Amount: it.Amount,
		Currency: it.Currency, DueDate: nvsDateOut(it.DueDate), Overdue: it.Overdue, Approved: it.Approved, Label: it.Label}
}

func nvsLineOut(l store.NetvisorCardCostLine) wire.NetvisorCardCostLine {
	return wire.NetvisorCardCostLine{LineNo: l.LineNo, Month: nvsDateOut(l.Month), Route: l.Route, Vendor: l.Vendor,
		AccountNumber: l.AccountNumber, AccountName: l.AccountName, Dimension: l.Dimension, DimensionItem: l.DimensionItem,
		Amount: l.Amount, Currency: l.Currency, VATCode: l.VATCode, Excluded: l.Excluded}
}

func nvsSettingsOut(st store.NetvisorSettings) wire.NetvisorSettingsBody {
	nonNil := func(v []string) []string {
		if v == nil {
			return []string{}
		}
		return v
	}
	return wire.NetvisorSettingsBody{OwnerHumanID: st.OwnerHumanID, Env: st.Env, BankAccount: st.BankAccount,
		VATAccounts: nonNil(st.VATAccounts), TaxAccounts: nonNil(st.TaxAccounts), VendorExclusions: nonNil(st.VendorExclusions),
		UpdatedBy: st.UpdatedBy, UpdatedAt: st.UpdatedAt.UTC().Format(time.RFC3339),
		RefreshRequestedAt: nvsTimeOut(st.RefreshRequestedAt)}
}
