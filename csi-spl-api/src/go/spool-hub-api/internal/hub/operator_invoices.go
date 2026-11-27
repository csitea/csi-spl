package hub

import (
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The owner's overdue list (spec 181 row B13, gap G14; Q-17 B, Q-18 C): a
// private workspace's monthly invoice is paid by bank transfer, due 14 days
// net from its issue date (Q-19 A). One that is unpaid past its due date is
// listed here, and the owner decides each case by hand: nothing is decided
// automatically, the workspace keeps working. When the transfer arrives,
// the owner marks the invoice paid.
//
//	GET  /v1/operator/invoices/overdue
//	  200 {"as_of", "invoices": [{workspace, workspace_name, month, currency, humans,
//	       seat_cents, vm_cost_micros, vm_price_micros, total_micros, issued_on,
//	       due_on, days_overdue, reminded_at}]}   oldest due date first
//	POST /v1/operator/invoices/{id}/{month}/paid    month = YYYY-MM
//	  200 {"workspace", "month", "paid_at"}
//	  400 bad_tenant | bad_month    404 not_found    409 already_paid
//
// Who may: the operator workspace's admin only (operatorActor); any other
// caller, a workspace's own members included, gets 403, and an act-as clone
// reads the list but marks nothing paid. Each call writes one operator_audit
// row: the list a `list` row in the operator workspace, a mark paid an
// `update` row in the invoice's workspace, {invoice_paid: <month>, ...}.

// invoiceMonthLayout is the {month} of the mark paid route.
const invoiceMonthLayout = "2006-01"

type overdueInvoiceJSON struct {
	Workspace     string  `json:"workspace"`
	WorkspaceName string  `json:"workspace_name"`
	Month         string  `json:"month"`
	Currency      string  `json:"currency"`
	Humans        int64   `json:"humans"`
	SeatCents     int64   `json:"seat_cents"`
	VMCostMicros  int64   `json:"vm_cost_micros"`
	VMPriceMicros string  `json:"vm_price_micros"`
	TotalMicros   string  `json:"total_micros"`
	IssuedOn      string  `json:"issued_on"`
	DueOn         string  `json:"due_on"`
	DaysOverdue   int     `json:"days_overdue"`
	RemindedAt    *string `json:"reminded_at"`
}

func (s *Server) routeOperatorInvoices(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/invoices/overdue", s.handleOverdueInvoices)
	mux.HandleFunc("POST /v1/operator/invoices/{id}/{month}/paid", s.handleInvoicePaid)
	mux.HandleFunc("OPTIONS /v1/operator/invoices/overdue", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/invoices/{id}/{month}/paid", s.operatorWorkspacesPreflight)
	// spec 181 B14: the month-end invoice issuer, the env SA only (operatorAuth)
	mux.HandleFunc("GET /v1/operator/invoices/private-workspaces", s.handlePrivateWorkspaces)
	mux.HandleFunc("POST /v1/operator/invoices/issue", s.handleInvoiceIssue)
}

// GET /v1/operator/invoices/overdue
func (s *Server) handleOverdueInvoices(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	od, ok := s.o.Store.(store.OverdueInvoices)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no invoices")
		return
	}
	now := s.o.Now().UTC()
	list, err := od.OverdueInvoices(r.Context(), now)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("operator overdue invoices")
		writeErr(w, http.StatusInternalServerError, "internal", "overdue invoices not read")
		return
	}
	names := s.workspaceNames(r, a)
	out := make([]overdueInvoiceJSON, 0, len(list))
	for _, inv := range list {
		out = append(out, overdueJSON(inv, names[inv.Tenant], now))
	}
	s.opAudit(r, a, a.tenant, store.AuditList, map[string]any{"overdue_invoices": len(out)})
	writeJSON(w, http.StatusOK, map[string]any{"as_of": rfc(now), "invoices": out})
}

// workspaceNames maps each workspace id to its display name; empty when the
// list is not read (the ids still show).
func (s *Server) workspaceNames(r *http.Request, a opActor) map[string]string {
	names := map[string]string{}
	list, err := a.ws.ListWorkspaces(r.Context())
	if err != nil {
		s.o.Log.Warn().Err(err).Msg("operator overdue invoices: workspace names")
		return names
	}
	for _, ws := range list {
		names[ws.ID] = ws.DisplayName
	}
	return names
}

func overdueJSON(inv store.Invoice, name string, now time.Time) overdueInvoiceJSON {
	out := overdueInvoiceJSON{Workspace: inv.Tenant, WorkspaceName: name, Month: inv.Month.Format(invoiceMonthLayout),
		Currency: inv.Currency, Humans: inv.Humans, SeatCents: inv.SeatCents, VMCostMicros: inv.VMCostMicros,
		VMPriceMicros: inv.VMPriceMicros, TotalMicros: inv.TotalMicros, IssuedOn: inv.IssuedOn.Format(time.DateOnly),
		DueOn: inv.DueOn.Format(time.DateOnly), DaysOverdue: int(now.Sub(inv.DueOn).Hours() / 24)}
	if inv.RemindedAt != nil {
		at := rfc(*inv.RemindedAt)
		out.RemindedAt = &at
	}
	return out
}

// POST /v1/operator/invoices/{id}/{month}/paid
func (s *Server) handleInvoicePaid(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	if !msg.ValidTenantID(id) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "id must be a valid workspace slug")
		return
	}
	month, err := time.Parse(invoiceMonthLayout, r.PathValue("month"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_month", "month must be YYYY-MM")
		return
	}
	invs, ok := s.o.Store.(store.Invoices)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no invoices")
		return
	}
	inv, err := invs.Invoice(r.Context(), id, month)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no invoice of this workspace for this month")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "invoice not read")
		return
	case inv.PaidAt != nil:
		writeErr(w, http.StatusConflict, "already_paid", "this invoice is already marked paid")
		return
	}
	at := s.o.Now().UTC()
	if err := invs.MarkInvoicePaid(r.Context(), id, month, at); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", id).Msg("operator invoice paid")
		writeErr(w, http.StatusInternalServerError, "internal", "invoice not marked paid")
		return
	}
	s.opAudit(r, a, id, store.AuditUpdate, map[string]any{"invoice_paid": month.Format(invoiceMonthLayout),
		"total_micros": inv.TotalMicros, "currency": inv.Currency, "due_on": inv.DueOn.Format(time.DateOnly)})
	writeJSON(w, http.StatusOK, map[string]any{"workspace": id, "month": month.Format(invoiceMonthLayout), "paid_at": rfc(at)})
}

// The month-end invoice issuer (spec 181 row B14, gap G15; Q-9 B, Q-16 B,
// Q-19 A, Q-20 A): the box action do_spl_private_ws_invoice_issue
// (csi-spl-orc) reads the private workspaces, sums each VM's month cost from
// B4's do_spl_vm_cost_per_day, and posts it here; the hub counts the
// workspace's human members itself and writes the invoice with B12's
// IssueInvoice. No DB password on the box: the same path as the daily cost
// upload (POST /v1/operator/cost/day).
//
//	GET  /v1/operator/invoices/private-workspaces[?workspace=<id>]
//	  200 {"workspaces": [{workspace, humans}]}   by id; every workspace on
//	      the private_vm plan, or the one named (none when it is not on it)
//	  400 bad_tenant
//	POST /v1/operator/invoices/issue   {"workspace", "month": "YYYY-MM", "vm_cost_micros"}
//	  201 {"created": true, "invoice": {...}}   the new invoice
//	  200 {"created": false, "invoice": {...}}  a replay: the invoice already
//	      there, unchanged (one per workspace per month)
//	  400 bad_json | bad_tenant | bad_month | bad_cost
//	  409 not_private_workspace | month_not_closed (issued in arrears only)
//
// operatorAuth only (a Google id token of the env's service account): a
// verified identity that is not an operator gets 403, a member session 401.
// The humans are counted on the hub at the call (store.PrivateWorkspaces,
// CountMembers' rule: agents are not seats, Q-6 A). A new invoice writes
// one operator_audit `create` row in its workspace, {invoice_issued:
// <month>, humans, vm_cost_micros, total_micros, currency, due_on}, and one
// log line; a replay writes no audit row.

type privateWorkspaceJSON struct {
	Workspace string `json:"workspace"`
	Humans    int64  `json:"humans"`
}

type invoiceIssueBody struct {
	Workspace    string `json:"workspace"`
	Month        string `json:"month"`
	VMCostMicros *int64 `json:"vm_cost_micros"`
}

type issuedInvoiceJSON struct {
	Workspace     string  `json:"workspace"`
	Month         string  `json:"month"`
	Currency      string  `json:"currency"`
	Humans        int64   `json:"humans"`
	SeatCents     int64   `json:"seat_cents"`
	VMCostMicros  int64   `json:"vm_cost_micros"`
	VMPriceMicros string  `json:"vm_price_micros"`
	TotalMicros   string  `json:"total_micros"`
	IssuedOn      string  `json:"issued_on"`
	DueOn         string  `json:"due_on"`
	PaidAt        *string `json:"paid_at"`
}

func issuedJSON(inv store.Invoice) issuedInvoiceJSON {
	out := issuedInvoiceJSON{Workspace: inv.Tenant, Month: inv.Month.Format(invoiceMonthLayout), Currency: inv.Currency,
		Humans: inv.Humans, SeatCents: inv.SeatCents, VMCostMicros: inv.VMCostMicros, VMPriceMicros: inv.VMPriceMicros,
		TotalMicros: inv.TotalMicros, IssuedOn: inv.IssuedOn.Format(time.DateOnly), DueOn: inv.DueOn.Format(time.DateOnly)}
	if inv.PaidAt != nil {
		at := rfc(*inv.PaidAt)
		out.PaidAt = &at
	}
	return out
}

// GET /v1/operator/invoices/private-workspaces
func (s *Server) handlePrivateWorkspaces(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	pw, ok := s.o.Store.(store.PrivateWorkspaces)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store lists no private workspaces")
		return
	}
	id := r.URL.Query().Get("workspace")
	if id != "" && !msg.ValidTenantID(id) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "workspace must be a valid workspace slug")
		return
	}
	list, err := pw.PrivateWorkspaceMembers(r.Context(), id)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("operator private workspaces")
		writeErr(w, http.StatusInternalServerError, "internal", "private workspaces not read")
		return
	}
	out := make([]privateWorkspaceJSON, 0, len(list))
	for _, ws := range list {
		out = append(out, privateWorkspaceJSON{Workspace: ws.Tenant, Humans: ws.Humans})
	}
	writeJSON(w, http.StatusOK, map[string]any{"workspaces": out})
}

// readIssueBody reads and checks the issue body; false = answered.
func readIssueBody(w http.ResponseWriter, r *http.Request) (invoiceIssueBody, time.Time, bool) {
	var in invoiceIssueBody
	if !readJSONStrict(w, r, &in, keysMaxBody, "invalid JSON body (only workspace, month, vm_cost_micros)") {
		return in, time.Time{}, false
	}
	if !msg.ValidTenantID(in.Workspace) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "workspace must be a valid workspace slug")
		return in, time.Time{}, false
	}
	month, err := time.Parse(invoiceMonthLayout, in.Month)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_month", "month must be YYYY-MM")
		return in, time.Time{}, false
	}
	if in.VMCostMicros == nil || *in.VMCostMicros < 0 {
		writeErr(w, http.StatusBadRequest, "bad_cost", "vm_cost_micros must be the month's VM cost in EUR micros, >= 0")
		return in, time.Time{}, false
	}
	return in, month, true
}

// POST /v1/operator/invoices/issue
func (s *Server) handleInvoiceIssue(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	pw, okList := s.o.Store.(store.PrivateWorkspaces)
	invs, okInv := s.o.Store.(store.Invoices)
	if !okList || !okInv {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no invoices")
		return
	}
	in, month, ok := readIssueBody(w, r)
	if !ok {
		return
	}
	list, err := pw.PrivateWorkspaceMembers(r.Context(), in.Workspace)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "the workspace's members were not counted", err)
		return
	}
	if len(list) != 1 {
		writeErr(w, http.StatusConflict, "not_private_workspace", "only a private workspace (price plan private_vm) is invoiced")
		return
	}
	inv, created, err := invs.IssueInvoice(r.Context(), in.Workspace, month, list[0].Humans, *in.VMCostMicros, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrInvoiceMonth):
		writeErr(w, http.StatusConflict, "month_not_closed", "an invoice is issued after its month ends (in arrears)")
		return
	case errors.Is(err, store.ErrNoPricePlan):
		writeErr(w, http.StatusConflict, "not_private_workspace", "only a private workspace (price plan private_vm) is invoiced")
		return
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "the invoice was not stored", err)
		return
	}
	if created {
		s.issueAudit(r, actor, inv)
	}
	s.o.Log.Info().Str("tenant", inv.Tenant).Str("month", in.Month).Str("by", actor).Bool("created", created).
		Int64("humans", inv.Humans).Int64("vm_cost_micros", inv.VMCostMicros).Str("total_micros", inv.TotalMicros).Msg("invoice.issued")
	code := http.StatusCreated
	if !created {
		code = http.StatusOK
	}
	writeJSON(w, code, map[string]any{"created": created, "invoice": issuedJSON(inv)})
}

// issueAudit writes the new invoice's operator_audit row in its workspace;
// a failed write is logged, the invoice stands (opAudit's rule).
func (s *Server) issueAudit(r *http.Request, actor string, inv store.Invoice) {
	ow, ok := s.o.Store.(store.OperatorWorkspaces)
	if !ok {
		return
	}
	actorTenant := s.o.OperatorTenant
	if actorTenant == "" {
		actorTenant = "operator"
	}
	err := ow.AppendOperatorAudit(r.Context(), store.OperatorAudit{At: s.o.Now().UTC(), TenantID: inv.Tenant,
		ActorTenant: actorTenant, ActorHum: actor, Action: store.AuditCreate, Detail: map[string]any{
			"invoice_issued": inv.Month.Format(invoiceMonthLayout), "humans": inv.Humans, "vm_cost_micros": inv.VMCostMicros,
			"total_micros": inv.TotalMicros, "currency": inv.Currency, "due_on": inv.DueOn.Format(time.DateOnly)}})
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", inv.Tenant).Msg("invoice.issue_audit_failed")
	}
}
